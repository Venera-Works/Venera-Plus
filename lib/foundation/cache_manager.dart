import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';

import 'app.dart';

typedef _CacheScan = ({int size, List<String> unmanagedFiles});
typedef _CacheLookup = ({String? path, int removedBytes, bool changed});
typedef _CachePrune = ({int removedBytes, bool changed, bool more, bool empty});

class CacheManager {
  static String get cachePath => '${App.cachePath}/cache';

  static CacheManager? instance;

  @visibleForTesting
  static Future<int> Function(String dbPath, String dir)? debugScanDirOverride;

  @visibleForTesting
  static bool debugDisableInitialScan = false;

  @visibleForTesting
  static void Function()? debugOnCheckCacheStart;

  @visibleForTesting
  static SendPort? debugBeforeLookup;

  @visibleForTesting
  static Future<void> resetForTesting() async {
    final previous = instance;
    instance = null;
    debugScanDirOverride = null;
    debugDisableInitialScan = false;
    debugOnCheckCacheStart = null;
    debugBeforeLookup = null;
    if (previous == null) return;
    previous._disposed = true;
    final pending = <Future<void>>[
      previous._initialScanTask,
      ?previous._scanTask,
      ?previous._checkingTask,
      previous._operations,
      previous._ready,
    ];
    await Future.wait(
      pending.map(
        (task) => task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
  }

  final String _dbPath;
  final String _root;
  late final Future<void> _ready;
  late final Future<void> _initialScanTask;
  Future<void> _operations = Future<void>.value();
  Future<void>? _scanTask;
  Future<void>? _checkingTask;
  int _fileRevision = 0;
  bool _disposed = false;
  int? _currentSize;

  /// Last known size of managed cache files, in bytes.
  int get currentSize => _currentSize ?? 0;

  int dir = 0;
  int _limitSize = 2 * 1024 * 1024 * 1024;

  @visibleForTesting
  Future<void> get debugInitialScanTask => _initialScanTask;

  CacheManager._create()
    : _dbPath = '${App.dataPath}/cache.db',
      _root = cachePath {
    final dbPath = _dbPath;
    final root = _root;
    _ready = _initializeAsync(dbPath, root);
    if (debugDisableInitialScan) {
      _currentSize = 0;
      _initialScanTask = _ready;
    } else {
      _initialScanTask = _startScan().then((_) => checkCache()).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (!_disposed) Log.warning('Cache initialization', '$error\n$stack');
      });
    }
  }

  factory CacheManager() => instance ??= CacheManager._create();

  // Keep isolate closures out of instance/async contexts, whose shared closure
  // context may otherwise retain this manager and its unsendable Futures.
  static Future<void> _initializeAsync(String dbPath, String root) =>
      Isolate.run(() => _initialize(dbPath, root));

  static Future<_CacheScan> _scanDirAsync(String dbPath, String root) =>
      Isolate.run(() => _scanDir(dbPath, root));

  static Future<void> _deleteUnmanagedFilesAsync(
    String dbPath,
    List<String> files,
  ) => Isolate.run(() => _deleteUnmanagedFiles(dbPath, files));

  static Future<int> _writeCacheAsync(
    String dbPath,
    String root,
    String key,
    List<int> data,
    int directory,
    int duration,
  ) => Isolate.run(
    () => _writeCache(dbPath, root, key, data, directory, duration),
  );

  static Future<_CacheLookup> _findCacheAsync(
    String dbPath,
    String root,
    String key,
    SendPort? signal,
  ) => Isolate.run(() {
    signal?.send(null);
    return _findCache(dbPath, root, key);
  });

  static Future<_CachePrune> _pruneBatchAsync(
    String dbPath,
    String root,
    int size,
    int limit,
  ) => Isolate.run(() => _pruneBatch(dbPath, root, size, limit));

  static Future<int> _deleteCacheAsync(
    String dbPath,
    String root,
    String key,
  ) => Isolate.run(() => _deleteCache(dbPath, root, key));

  static Future<void> _clearCacheAsync(String dbPath, String root) =>
      Isolate.run(() => _clearCache(dbPath, root));

  static void _initialize(String dbPath, String root) {
    Directory(root).createSync(recursive: true);
    final db = openSqliteDatabase(dbPath);
    try {
      db.execute('''
        CREATE TABLE IF NOT EXISTS cache (
          key TEXT PRIMARY KEY NOT NULL,
          dir TEXT NOT NULL,
          name TEXT NOT NULL,
          expires INTEGER NOT NULL,
          type TEXT
        );
      ''');
    } finally {
      db.close();
    }
  }

  /// Serializes complete operations, including their size-accounting results.
  /// Every SQLite connection belongs exclusively to its background isolate.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_disposed) {
      return Future<T>.error(StateError('Cache manager is closed'));
    }
    final next = _operations.then((_) async {
      await _ready;
      return operation();
    });
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _subtractSize(int bytes) {
    _currentSize = math.max(0, (_currentSize ?? 0) - bytes);
  }

  Future<void> _startScan() {
    if (_disposed) return Future<void>.value();
    final active = _scanTask;
    if (active != null) return active;
    final task = _scanUntilCurrent();
    _scanTask = task;
    unawaited(
      task.then<void>(
        (_) => _scanTask = null,
        onError: (Object _, StackTrace _) => _scanTask = null,
      ),
    );
    return task;
  }

  Future<void> _scanUntilCurrent() async {
    try {
      await _ready;
      while (!_disposed) {
        // Do not hold the operation queue while traversing the cache directory.
        await _operations;
        if (_disposed) return;
        final revision = _fileRevision;
        final dbPath = _dbPath;
        final root = _root;
        final override = debugScanDirOverride;
        final _CacheScan scanned;
        try {
          scanned = override == null
              ? await _scanDirAsync(dbPath, root)
              : (
                  size: await override(dbPath, root),
                  unmanagedFiles: <String>[],
                );
        } catch (_) {
          if (!_disposed && revision != _fileRevision) continue;
          rethrow;
        }
        if (_disposed) return;
        var stale = false;
        final files = scanned.unmanagedFiles;
        for (var offset = 0; offset < files.length; offset += 10) {
          if (_disposed) return;
          final batch = files.sublist(
            offset,
            math.min(offset + 10, files.length),
          );
          final applied = await _enqueue(() async {
            if (revision != _fileRevision) return false;
            await _deleteUnmanagedFilesAsync(dbPath, batch);
            return true;
          });
          if (!applied) {
            stale = true;
            break;
          }
        }
        if (stale || _disposed) continue;
        final applied = await _enqueue(() async {
          // A mutation between scanning and adoption also invalidates the size.
          if (revision != _fileRevision) return false;
          _currentSize = scanned.size;
          return true;
        });
        if (applied) return;
      }
    } catch (error, stack) {
      // Keep sizes already tracked by operations during a failed initial scan.
      _currentSize ??= 0;
      if (!_disposed) Log.warning('Cache scan', '$error\n$stack');
    }
  }

  static _CacheScan _scanDir(String dbPath, String root) {
    final db = openSqliteDatabase(dbPath);
    try {
      var size = 0;
      final unmanaged = <String>[];
      for (final entity in Directory(root).listSync(recursive: true)) {
        if (entity is! File) continue;
        final segments = entity.uri.pathSegments;
        final name = segments.last;
        final directory = segments.elementAtOrNull(segments.length - 2) ?? '*';
        final managed = db.select(
          'SELECT 1 FROM cache WHERE dir = ? AND name = ?;',
          [directory, name],
        );
        if (managed.isEmpty) {
          unmanaged.add(entity.path);
        } else {
          size += entity.lengthSync();
        }
      }
      return (size: size, unmanagedFiles: unmanaged);
    } finally {
      db.close();
    }
  }

  static void _deleteUnmanagedFiles(String dbPath, List<String> files) {
    final db = openSqliteDatabase(dbPath);
    try {
      for (final path in files) {
        final file = File(path);
        final segments = file.uri.pathSegments;
        final name = segments.last;
        final directory = segments.elementAtOrNull(segments.length - 2) ?? '*';
        if (db.select('SELECT 1 FROM cache WHERE dir = ? AND name = ?;', [
              directory,
              name,
            ]).isEmpty &&
            file.existsSync()) {
          file.deleteSync();
        }
      }
    } finally {
      db.close();
    }
  }

  void _rescanAfterFailure() {
    if (_disposed) return;
    unawaited(
      _startScan().then((_) => checkCache()).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (!_disposed) Log.warning('Cache scan', '$error\n$stack');
      }),
    );
  }

  void setLimitSize(int size) {
    _limitSize = size * 1024 * 1024;
  }

  Future<void> writeCache(
    String key,
    List<int> data, [
    int duration = 7 * 24 * 60 * 60 * 1000,
  ]) async {
    await _enqueue(() async {
      _fileRevision++;
      dir = (dir + 1) % 100;
      final directory = dir;
      final dbPath = _dbPath;
      final root = _root;
      try {
        final delta = await _writeCacheAsync(
          dbPath,
          root,
          key,
          data,
          directory,
          duration,
        );
        _currentSize = math.max(0, (_currentSize ?? 0) + delta);
      } catch (_) {
        _rescanAfterFailure();
        rethrow;
      }
    });
    checkCacheIfRequired();
  }

  static int _writeCache(
    String dbPath,
    String root,
    String key,
    List<int> data,
    int directory,
    int duration,
  ) {
    final db = openSqliteDatabase(dbPath);
    try {
      final rows = db.select('SELECT * FROM cache WHERE key = ?;', [key]);
      final oldFile = rows.isEmpty ? null : _fileForRow(root, rows.first);
      final oldSize = oldFile?.existsSync() == true ? oldFile!.lengthSync() : 0;
      final name = md5.convert(key.codeUnits).toString();
      final file = File('$root/$directory/$name');
      file.createSync(recursive: true);
      file.writeAsBytesSync(data);
      db.execute(
        'INSERT OR REPLACE INTO cache (key, dir, name, expires) VALUES (?, ?, ?, ?);',
        [
          key,
          directory.toString(),
          name,
          DateTime.now().millisecondsSinceEpoch + duration,
        ],
      );
      if (oldFile != null &&
          oldFile.path != file.path &&
          oldFile.existsSync()) {
        oldFile.deleteSync();
      }
      return data.length - oldSize;
    } finally {
      db.close();
    }
  }

  Future<File?> findCache(String key) => _enqueue(() async {
    final dbPath = _dbPath;
    final root = _root;
    final signal = debugBeforeLookup;
    try {
      final found = await _findCacheAsync(dbPath, root, key, signal);
      if (found.changed) _fileRevision++;
      _subtractSize(found.removedBytes);
      return found.path == null ? null : File(found.path!);
    } catch (_) {
      _fileRevision++;
      _rescanAfterFailure();
      rethrow;
    }
  });

  static _CacheLookup _findCache(String dbPath, String root, String key) {
    final db = openSqliteDatabase(dbPath);
    try {
      final rows = db.select('SELECT * FROM cache WHERE key = ?;', [key]);
      if (rows.isEmpty) return (path: null, removedBytes: 0, changed: false);
      final row = rows.first;
      final file = _fileForRow(root, row);
      final now = DateTime.now().millisecondsSinceEpoch;
      final exists = file.existsSync();
      if ((row['expires'] as int) < now || !exists) {
        final bytes = exists ? file.lengthSync() : 0;
        if (exists) file.deleteSync();
        db.execute('DELETE FROM cache WHERE key = ?;', [key]);
        return (path: null, removedBytes: bytes, changed: true);
      }
      db.execute('UPDATE cache SET expires = ? WHERE key = ?;', [
        now + 7 * 24 * 60 * 60 * 1000,
        key,
      ]);
      return (path: file.path, removedBytes: 0, changed: false);
    } finally {
      db.close();
    }
  }

  static File _fileForRow(String root, Row row) =>
      File('$root/${row['dir']}/${row['name']}');

  void checkCacheIfRequired() {
    if (!_disposed && currentSize > _limitSize) {
      unawaited(
        checkCache().catchError((Object error, StackTrace stack) {
          Log.warning('Cache cleanup', '$error\n$stack');
        }),
      );
    }
  }

  Future<void> checkCache() {
    if (_disposed) return Future<void>.value();
    final active = _checkingTask;
    if (active != null) return active;
    final task = _checkCache();
    _checkingTask = task;
    unawaited(
      task.then<void>(
        (_) => _checkingTask = null,
        onError: (Object _, StackTrace _) => _checkingTask = null,
      ),
    );
    return task;
  }

  Future<void> _checkCache() async {
    debugOnCheckCacheStart?.call();
    while (!_disposed) {
      final result = await _enqueue(() async {
        final dbPath = _dbPath;
        final root = _root;
        final size = currentSize;
        final limit = _limitSize;
        try {
          final batch = await _pruneBatchAsync(dbPath, root, size, limit);
          if (batch.changed) _fileRevision++;
          _subtractSize(batch.removedBytes);
          if (batch.empty) _currentSize = 0;
          return batch;
        } catch (_) {
          _fileRevision++;
          _rescanAfterFailure();
          rethrow;
        }
      });
      if (!result.more) return;
      // Each batch is a separate queue entry so image lookups can interleave.
    }
  }

  static _CachePrune _pruneBatch(
    String dbPath,
    String root,
    int size,
    int limit,
  ) {
    final db = openSqliteDatabase(dbPath);
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      var rows = db.select(
        'SELECT * FROM cache WHERE expires < ? ORDER BY expires ASC LIMIT 10;',
        [now],
      );
      final expired = rows.isNotEmpty;
      if (!expired && size <= limit) {
        return (removedBytes: 0, changed: false, more: false, empty: false);
      }
      if (!expired) {
        rows = db.select('SELECT * FROM cache ORDER BY expires ASC LIMIT 10;');
      }
      var removed = 0;
      for (final row in rows) {
        final file = _fileForRow(root, row);
        if (file.existsSync()) {
          removed += file.lengthSync();
          file.deleteSync();
        }
        db.execute('DELETE FROM cache WHERE key = ?;', [row['key']]);
        if (!expired && size - removed <= limit) break;
      }
      return (
        removedBytes: removed,
        changed: rows.isNotEmpty,
        more: rows.isNotEmpty && (expired || size - removed > limit),
        empty: rows.isEmpty,
      );
    } finally {
      db.close();
    }
  }

  Future<void> delete(String key) => _enqueue(() async {
    _fileRevision++;
    final dbPath = _dbPath;
    final root = _root;
    try {
      final bytes = await _deleteCacheAsync(dbPath, root, key);
      _subtractSize(bytes);
    } catch (_) {
      _rescanAfterFailure();
      rethrow;
    }
  });

  static int _deleteCache(String dbPath, String root, String key) {
    final db = openSqliteDatabase(dbPath);
    try {
      final rows = db.select('SELECT * FROM cache WHERE key = ?;', [key]);
      if (rows.isEmpty) return 0;
      final file = _fileForRow(root, rows.first);
      var size = 0;
      if (file.existsSync()) {
        size = file.lengthSync();
        file.deleteSync();
      }
      db.execute('DELETE FROM cache WHERE key = ?;', [key]);
      return size;
    } finally {
      db.close();
    }
  }

  Future<void> clear() => _enqueue(() async {
    _fileRevision++;
    final dbPath = _dbPath;
    final root = _root;
    try {
      await _clearCacheAsync(dbPath, root);
      _currentSize = 0;
    } catch (_) {
      _rescanAfterFailure();
      rethrow;
    }
  });

  static void _clearCache(String dbPath, String root) {
    final db = openSqliteDatabase(dbPath);
    try {
      final directory = Directory(root);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      directory.createSync(recursive: true);
      db.execute('DELETE FROM cache;');
    } finally {
      db.close();
    }
  }
}
