import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  group(
    'cache file and database operations',
    () {
      late Directory directory;

      setUp(() async {
        directory = await Directory.systemTemp.createTemp('venera-cache-');
        App.dataPath = (await Directory(
          '${directory.path}/data',
        ).create()).path;
        App.cachePath = (await Directory(
          '${directory.path}/files',
        ).create()).path;
        CacheManager.debugDisableInitialScan = true;
      });

      tearDown(() async {
        await CacheManager.resetForTesting();
        await directory.delete(recursive: true);
      });

      test('checkCache resets checking flag after failure', () async {
        final manager = CacheManager();
        var checkCount = 0;
        CacheManager.debugOnCheckCacheStart = () {
          if (++checkCount == 1) {
            throw StateError('forced cache check failure');
          }
        };
        await expectLater(manager.checkCache(), throwsStateError);
        await manager.checkCache();
        expect(checkCount, 2);
      });

      test('failed initial scan keeps sizes tracked during the scan', () async {
        CacheManager.debugDisableInitialScan = false;
        final started = Completer<void>();
        final release = Completer<void>();
        CacheManager.debugScanDirOverride = (dbPath, root) async {
          if (!started.isCompleted) started.complete();
          await release.future;
          throw StateError('forced cache check failure');
        };
        final manager = CacheManager();
        await started.future;
        await manager.writeCache('key', [1, 2, 3]);
        release.complete();
        await manager.debugInitialScanTask;
        expect(manager.currentSize, 3);
        expect(await (await manager.findCache('key'))!.readAsBytes(), [
          1,
          2,
          3,
        ]);
      });

      test(
        'replacement keeps only the new file and updates tracked size',
        () async {
          final manager = CacheManager();
          await manager.writeCache('same-key', [1, 2, 3]);
          final oldFile = (await manager.findCache('same-key'))!;
          await manager.writeCache('same-key', [4, 5]);
          final replacement = (await manager.findCache('same-key'))!;
          expect(await replacement.readAsBytes(), [4, 5]);
          expect(await oldFile.exists(), isFalse);
          expect(manager.currentSize, 2);
          await manager.delete('same-key');
          expect(await manager.findCache('same-key'), isNull);
          expect(manager.currentSize, 0);
        },
      );

      test('queued writes delete and clear follow invocation order', () async {
        final manager = CacheManager();
        final first = manager.writeCache('same', [1]);
        final second = manager.writeCache('same', [2, 2]);
        final removed = manager.delete('same');
        final third = manager.writeCache('same', [3, 3, 3]);
        await Future.wait([first, second, removed, third]);
        expect(await (await manager.findCache('same'))!.readAsBytes(), [
          3,
          3,
          3,
        ]);
        expect(manager.currentSize, 3);

        final beforeClear = manager.writeCache('before-clear', [4, 4]);
        final clear = manager.clear();
        final afterClear = manager.writeCache('after-clear', [5]);
        await Future.wait([beforeClear, clear, afterClear]);
        expect(await manager.findCache('same'), isNull);
        expect(await manager.findCache('before-clear'), isNull);
        expect(await (await manager.findCache('after-clear'))!.readAsBytes(), [
          5,
        ]);
        expect(manager.currentSize, 1);
      });

      test('lookup removes expired files and renews valid entries', () async {
        final manager = CacheManager();
        await manager.writeCache('expired', [1, 2], -1);
        expect(await manager.findCache('expired'), isNull);
        expect(manager.currentSize, 0);

        await manager.writeCache('valid', [3], 1000);
        final beforeLookup = DateTime.now().millisecondsSinceEpoch;
        expect(await manager.findCache('valid'), isNotNull);
        final db = sqlite3.open('${App.dataPath}/cache.db');
        try {
          final expires =
              db.select('SELECT expires FROM cache WHERE key = ?;', [
                    'valid',
                  ]).single['expires']
                  as int;
          expect(
            expires,
            greaterThanOrEqualTo(beforeLookup + 7 * 24 * 60 * 60 * 1000),
          );
        } finally {
          db.dispose();
        }
      });

      test('a missing file invalidates its database entry', () async {
        final manager = CacheManager();
        await manager.writeCache('missing', [1, 2, 3]);
        final file = (await manager.findCache('missing'))!;
        await file.delete();
        expect(await manager.findCache('missing'), isNull);
        final db = sqlite3.open('${App.dataPath}/cache.db');
        try {
          expect(
            db.select('SELECT * FROM cache WHERE key = ?;', ['missing']),
            isEmpty,
          );
        } finally {
          db.dispose();
        }
      });

      test(
        'startup scan does not block lookups and discards stale totals',
        () async {
          CacheManager.debugDisableInitialScan = false;
          final started = Completer<void>();
          final release = Completer<int>();
          var scanCount = 0;
          CacheManager.debugScanDirOverride = (dbPath, root) async {
            if (++scanCount == 1) {
              started.complete();
              return release.future;
            }
            return 3;
          };
          final manager = CacheManager();
          await started.future;
          await manager.writeCache('new', [1, 2, 3]);
          expect(await manager.findCache('new'), isNotNull);
          release.complete(999);
          await manager.debugInitialScanTask;
          expect(scanCount, 2);
          expect(manager.currentSize, 3);
          expect(await (await manager.findCache('new'))!.readAsBytes(), [
            1,
            2,
            3,
          ]);
        },
      );

      test('a scan started before clear cannot restore old totals', () async {
        CacheManager.debugDisableInitialScan = false;
        final started = Completer<void>();
        final release = Completer<int>();
        var scanCount = 0;
        CacheManager.debugScanDirOverride = (dbPath, root) async {
          if (++scanCount == 1) {
            started.complete();
            return release.future;
          }
          return 0;
        };
        final manager = CacheManager();
        await started.future;
        await manager.writeCache('old', [1, 2, 3]);
        await manager.clear();
        release.complete(500);
        await manager.debugInitialScanTask;
        expect(scanCount, 2);
        expect(manager.currentSize, 0);
        expect(await manager.findCache('old'), isNull);
      });

      test(
        'reopened scan keeps managed files and removes orphaned files',
        () async {
          final first = CacheManager();
          await first.writeCache('persisted', [1, 2, 3]);
          await CacheManager.resetForTesting();
          final orphan = File('${CacheManager.cachePath}/orphan');
          await orphan.writeAsBytes([9, 9]);
          final reopened = CacheManager();
          await reopened.debugInitialScanTask;
          expect(reopened.currentSize, 3);
          expect(await orphan.exists(), isFalse);
          expect(await (await reopened.findCache('persisted'))!.readAsBytes(), [
            1,
            2,
            3,
          ]);
        },
      );

      test(
        'database lock wait leaves the foreground event loop available',
        () async {
          final manager = CacheManager();
          await manager.writeCache('locked', [1, 2, 3]);
          final locker = sqlite3.open('${App.dataPath}/cache.db');
          final started = ReceivePort();
          CacheManager.debugBeforeLookup = started.sendPort;
          var locked = false;
          try {
            locker.execute('BEGIN EXCLUSIVE;');
            locked = true;
            final lookup = manager.findCache('locked');
            // The message is sent by the worker before attempting the locked DB.
            // Its receipt requires the foreground isolate to remain responsive.
            await started.first;
            locker.execute('COMMIT;');
            locked = false;
            expect(await (await lookup)!.readAsBytes(), [1, 2, 3]);
          } finally {
            if (locked) locker.execute('ROLLBACK;');
            locker.dispose();
            started.close();
            CacheManager.debugBeforeLookup = null;
          }
        },
      );

      test('image lookups interleave between cleanup batches', () async {
        final manager = CacheManager();
        for (var index = 0; index < 21; index++) {
          await manager.writeCache('expired-$index', [index], -1);
        }
        await manager.writeCache('live', [9, 9]);
        var completed = false;
        final cleanup = manager.checkCache().then((_) => completed = true);
        expect(await manager.findCache('live'), isNotNull);
        expect(completed, isFalse);
        await cleanup;
        expect(manager.currentSize, 2);
      });

      test(
        'scan IO failure after a mutation retries the persisted total',
        () async {
          await CacheManager().writeCache('existing', [7, 8]);
          await CacheManager.resetForTesting();
          final started = Completer<void>();
          final release = Completer<void>();
          var scans = 0;
          CacheManager.debugScanDirOverride = (dbPath, root) async {
            if (++scans == 1) {
              started.complete();
              await release.future;
              throw const FileSystemException('File disappeared during scan');
            }
            return 5;
          };
          final manager = CacheManager();
          await started.future;
          await manager.writeCache('new', [1, 2, 3]);
          release.complete();
          await manager.debugInitialScanTask;
          expect(scans, 2);
          expect(manager.currentSize, 5);
          expect(await (await manager.findCache('existing'))!.readAsBytes(), [
            7,
            8,
          ]);
        },
      );

      test('failed cleanup still drains queued writes during reset', () async {
        final manager = CacheManager();
        await manager.writeCache('expired', [1, 2, 3], -1);
        final db = sqlite3.open('${App.dataPath}/cache.db');
        try {
          db.execute('''
            CREATE TRIGGER fail_cache_delete BEFORE DELETE ON cache
            BEGIN SELECT RAISE(ABORT, 'forced cleanup failure'); END;
          ''');
        } finally {
          db.close();
        }
        final cleanup = expectLater(
          manager.checkCache(),
          throwsA(isA<SqliteException>()),
        );
        final write = manager.writeCache('new', [4, 4]);
        final reset = CacheManager.resetForTesting();
        await Future.wait([cleanup, write, reset]);
        final restoredDb = sqlite3.open('${App.dataPath}/cache.db');
        try {
          restoredDb.execute('DROP TRIGGER fail_cache_delete;');
        } finally {
          restoredDb.close();
        }
        final reopened = CacheManager();
        await reopened.debugInitialScanTask;
        expect(reopened.currentSize, 2);
        expect(await (await reopened.findCache('new'))!.readAsBytes(), [4, 4]);
        expect(await reopened.findCache('expired'), isNull);
      });

      test('automatic cleanup respects the configured size limit', () async {
        final manager = CacheManager()..setLimitSize(0);
        await manager.writeCache('over-limit', [1, 2, 3]);
        await manager.checkCache();
        expect(manager.currentSize, 0);
        expect(await manager.findCache('over-limit'), isNull);
      });

      test(
        'reset waits for queued writes before releasing the instance',
        () async {
          final manager = CacheManager();
          final write = manager.writeCache('queued', [1, 2, 3]);
          final reset = CacheManager.resetForTesting();
          await Future.wait([write, reset]);
          final reopened = CacheManager();
          await reopened.debugInitialScanTask;
          expect(await (await reopened.findCache('queued'))!.readAsBytes(), [
            1,
            2,
            3,
          ]);
        },
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
