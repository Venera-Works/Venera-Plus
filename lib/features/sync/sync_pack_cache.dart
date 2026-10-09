import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sync_pack.dart';

/// Rebuildable bounded LRU disk cache for verified packs and publication maps.
///
/// Manifest keys are hashed before becoming filenames; callers should scope a
/// key to the endpoint, actor, and device folder. This cache is only a reuse
/// hint: publishers must independently verify remote pack availability.
final class SyncPackCache {
  SyncPackCache(this.root, {this.maxBytes = 128 * 1024 * 1024}) {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
  }

  final Directory root;
  final int maxBytes;
  final LinkedHashMap<String, _CacheFile> _entries =
      LinkedHashMap<String, _CacheFile>();
  static const int maxEntries = 8192;
  static const int _maxManifestEntryBytes =
      ((SyncPackManifest.maxManifestBytes + 2) ~/ 3) * 4 + 256;
  Future<void> _tail = Future<void>.value();
  bool _indexed = false;
  int _usedBytes = 0;
  int hits = 0;
  int misses = 0;
  int invalidations = 0;
  int evictions = 0;

  int get usedBytes => _usedBytes;

  Directory get _packsDirectory =>
      Directory('${root.path}${Platform.pathSeparator}packs');
  Directory get _manifestsDirectory =>
      Directory('${root.path}${Platform.pathSeparator}manifests');

  Future<SyncPack?> read(String digest, {required int expectedSize}) =>
      _exclusive(() async {
        if (!_isSha256(digest) ||
            expectedSize <= 0 ||
            expectedSize > SyncPack.maxPackBytes ||
            expectedSize > maxBytes) {
          misses++;
          return null;
        }
        final id = 'p:$digest';
        final file = _packFile(digest);
        try {
          await _prepare();
          await _ensureIndexed();
          if (!await _isRegularFile(file.path)) {
            if (_entries.containsKey(id)) invalidations++;
            misses++;
            await _removeEntry(id, file);
            return null;
          }
          final bytes = await _readBounded(
            file,
            maxBytes: expectedSize,
            expectedSize: expectedSize,
          );
          if (bytes == null) {
            invalidations++;
            misses++;
            await _removeEntry(id, file);
            return null;
          }
          final pack = SyncPack.decode(bytes, expectedDigest: digest);
          await _touch(id);
          hits++;
          return pack;
        } on Object {
          if (_entries.containsKey(id)) invalidations++;
          misses++;
          await _removeEntry(id, file);
          return null;
        }
      });

  Future<void> write(SyncPack pack) => _exclusive(() async {
    final bytes = pack.bytes;
    final file = _packFile(pack.digest);
    if (bytes.isEmpty || bytes.length > maxBytes) return;
    try {
      await _prepare();
      await _ensureIndexed();
      if (!await _makeRoomForWrite(
        bytes.length,
        targetId: 'p:${pack.digest}',
      )) {
        return;
      }
      await _replaceRecoverable(file, bytes);
      _putEntry('p:${pack.digest}', file, bytes.length);
      await _evictToLimit();
    } on Object {
      // A cache write must never become a sync durability requirement.
    }
  });

  Future<SyncPackManifest?> readManifest(String key) => _exclusive(() async {
    final digest = _keyDigest(key);
    final id = 'm:$digest';
    final file = _manifestFile(digest);
    try {
      await _prepare();
      await _ensureIndexed();
      if (!await _isRegularFile(file.path)) {
        if (_entries.containsKey(id)) invalidations++;
        misses++;
        await _removeEntry(id, file);
        return null;
      }
      final bytes = await _readBounded(
        file,
        maxBytes: maxBytes < _maxManifestEntryBytes
            ? maxBytes
            : _maxManifestEntryBytes,
      );
      if (bytes == null) {
        invalidations++;
        misses++;
        await _removeEntry(id, file);
        return null;
      }
      final manifest = _decodeManifestEntry(bytes);
      await _touch(id);
      hits++;
      return manifest;
    } on Object {
      if (_entries.containsKey(id)) invalidations++;
      misses++;
      await _removeEntry(id, file);
      return null;
    }
  });

  Future<void> writeManifest(
    String key,
    SyncPackManifest manifest,
  ) => _exclusive(() async {
    final bytes = _encodeManifestEntry(manifest);
    if (bytes.isEmpty || bytes.length > maxBytes) return;
    try {
      await _prepare();
      await _ensureIndexed();
      final digest = _keyDigest(key);
      final file = _manifestFile(digest);
      if (!await _makeRoomForWrite(bytes.length, targetId: 'm:$digest')) {
        return;
      }
      await _replaceRecoverable(file, bytes);
      _putEntry('m:$digest', file, bytes.length);
      await _evictToLimit();
    } on Object {
      // This persisted publication hint is recoverable from a full snapshot.
    }
  });

  Future<T> _exclusive<T>(Future<T> Function() operation) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await operation();
    } finally {
      release.complete();
    }
  }

  File _packFile(String digest) =>
      File('${_packsDirectory.path}${Platform.pathSeparator}$digest.pack');

  File _manifestFile(String digest) =>
      File('${_manifestsDirectory.path}${Platform.pathSeparator}$digest.json');

  Future<void> _prepare() async {
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('Invalid sync cache root');
    }
    await _ensureDirectory(_packsDirectory);
    await _ensureDirectory(_manifestsDirectory);
  }

  Future<void> _ensureDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      await directory.create();
    } else if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('Invalid sync cache directory');
    }
  }

  Future<void> _ensureIndexed() async {
    if (_indexed) return;
    _entries.clear();
    _usedBytes = 0;
    final discovered = <_CacheFile>[];
    for (final directory in [_packsDirectory, _manifestsDirectory]) {
      await for (final entity in directory.list(followLinks: false)) {
        final path = entity.path;
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          await _deletePath(path);
          continue;
        }
        if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final name = _basename(path);
        final isPack =
            directory.path == _packsDirectory.path &&
            RegExp(r'^[0-9a-f]{64}\.pack$').hasMatch(name);
        final isManifest =
            directory.path == _manifestsDirectory.path &&
            RegExp(r'^[0-9a-f]{64}\.json$').hasMatch(name);
        if (!isPack && !isManifest) {
          await _deletePath(path);
          continue;
        }
        final file = File(path);
        final size = await file.length();
        if (size <= 0 || size > maxBytes) {
          await _deletePath(path);
          continue;
        }
        final prefix = isPack ? 'p:' : 'm:';
        if (discovered.length >= maxEntries) {
          await _deletePath(path);
          continue;
        }
        final key = name.substring(0, 64);
        discovered.add(
          _CacheFile('$prefix$key', file, size, await file.lastModified()),
        );
      }
    }
    discovered.sort((a, b) {
      final time = a.lastAccess.compareTo(b.lastAccess);
      return time != 0 ? time : a.id.compareTo(b.id);
    });
    for (final entry in discovered) {
      _putEntry(entry.id, entry.file, entry.size, entry.lastAccess);
    }
    _indexed = true;
    await _evictToLimit();
  }

  /// Stages complete bytes; interruption can only lose this rebuildable hint.
  Future<void> _replaceRecoverable(File target, List<int> bytes) async {
    final temporary = File(
      '${target.parent.path}${Platform.pathSeparator}.tmp-${_randomHex()}',
    );
    try {
      await temporary.create(exclusive: true);
      await temporary.writeAsBytes(bytes, flush: true);
      await _deletePath(target.path);
      await temporary.rename(target.path);
      try {
        await target.setLastModified(DateTime.now());
      } on Object {
        // Persisted file content is valid even if access-time metadata fails.
      }
    } finally {
      await _deletePath(temporary.path);
    }
  }

  Future<bool> _isRegularFile(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) ==
      FileSystemEntityType.file;
  Future<bool> _makeRoomForWrite(
    int incomingBytes, {
    required String targetId,
  }) async {
    final target = _entries[targetId];
    if (target != null && incomingBytes > maxBytes - _usedBytes) {
      if (!await _removeEntry(targetId, target.file)) return false;
    }
    while ((incomingBytes > maxBytes - _usedBytes ||
            (_entries.length >= maxEntries &&
                !_entries.containsKey(targetId))) &&
        _entries.isNotEmpty) {
      final oldestId = _entries.keys.first;
      final oldest = _entries[oldestId]!;
      if (!await _removeEntry(oldestId, oldest.file)) return false;
      evictions++;
    }
    return incomingBytes <= maxBytes - _usedBytes &&
        (_entries.containsKey(targetId) || _entries.length < maxEntries);
  }

  Future<Uint8List?> _readBounded(
    File file, {
    required int maxBytes,
    int? expectedSize,
  }) async {
    RandomAccessFile? handle;
    try {
      handle = await file.open(mode: FileMode.read);
      final length = await handle.length();
      if (length <= 0 ||
          length > maxBytes ||
          (expectedSize != null && length != expectedSize)) {
        return null;
      }
      final bytes = await handle.read(maxBytes + 1);
      if (bytes.length != length || bytes.length > maxBytes) return null;
      return bytes;
    } finally {
      await handle?.close();
    }
  }

  Uint8List _encodeManifestEntry(SyncPackManifest manifest) {
    final manifestBytes = manifest.serializeManifest();
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 1,
          'sha256': sha256.convert(manifestBytes).toString(),
          'manifest': base64Encode(manifestBytes),
        }),
      ),
    );
  }

  SyncPackManifest _decodeManifestEntry(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: false);
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid cached sync manifest envelope');
    }
    final envelope = decoded.cast<String, Object?>();
    if (envelope.length != 3 ||
        !envelope.containsKey('schema') ||
        !envelope.containsKey('sha256') ||
        !envelope.containsKey('manifest') ||
        envelope['schema'] is! int ||
        envelope['schema'] != 1 ||
        envelope['sha256'] is! String ||
        envelope['manifest'] is! String ||
        jsonEncode(envelope) != text) {
      throw const FormatException('Invalid cached sync manifest envelope');
    }
    final digest = envelope['sha256']! as String;
    final encodedManifest = envelope['manifest']! as String;
    final manifestBytes = base64Decode(encodedManifest);
    if (base64Encode(manifestBytes) != encodedManifest ||
        manifestBytes.length > SyncPackManifest.maxManifestBytes ||
        sha256.convert(manifestBytes).toString() != digest) {
      throw const FormatException('Cached sync manifest digest mismatch');
    }
    return SyncPackManifest.parse(Uint8List.fromList(manifestBytes));
  }

  void _putEntry(String id, File file, int size, [DateTime? lastAccess]) {
    final previous = _entries.remove(id);
    if (previous != null) _usedBytes -= previous.size;
    final entry = _CacheFile(id, file, size, lastAccess ?? DateTime.now());
    _entries[id] = entry;
    _usedBytes += size;
  }

  Future<void> _touch(String id) async {
    final previous = _entries.remove(id);
    if (previous == null) return;
    previous.lastAccess = DateTime.now();
    _entries[id] = previous;
    try {
      await previous.file.setLastModified(previous.lastAccess);
    } on Object {
      // Runtime LRU ordering remains valid if the filesystem is read-only.
    }
  }

  Future<void> _evictToLimit() async {
    while ((_usedBytes > maxBytes || _entries.length > maxEntries) &&
        _entries.isNotEmpty) {
      final oldestId = _entries.keys.first;
      final oldest = _entries[oldestId]!;
      if (!await _removeEntry(oldestId, oldest.file)) break;
      evictions++;
    }
  }

  Future<bool> _removeEntry(String id, File file) async {
    try {
      await _deletePath(file.path);
      final entry = _entries.remove(id);
      if (entry != null) _usedBytes -= entry.size;
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _deletePath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    }
  }

  String _keyDigest(String key) => sha256.convert(utf8.encode(key)).toString();

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static String _basename(String path) {
    final separator = path.lastIndexOf(Platform.pathSeparator);
    return separator < 0 ? path : path.substring(separator + 1);
  }

  static String _randomHex() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${Random.secure().nextInt(0x7fffffff).toRadixString(16)}';
}

final class _CacheFile {
  _CacheFile(this.id, this.file, this.size, this.lastAccess);

  final String id;
  final File file;
  final int size;
  DateTime lastAccess;
}
