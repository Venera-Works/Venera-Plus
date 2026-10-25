import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sync_records.dart';

History _history(String id) {
  return History.fromMap({
    'type': ComicType.local.value,
    'time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
    'title': 'Title $id',
    'subtitle': 'Author',
    'cover': 'cover.jpg',
    'ep': 1,
    'page': 2,
    'id': id,
    'readEpisode': ['1'],
    'max_page': 10,
  });
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

class _CountingCatalog extends ReadingCatalog {
  _CountingCatalog(super.chapters);

  int serializations = 0;
  int chapterReads = 0;

  @override
  List<ReadingChapter> get chapters {
    chapterReads++;
    return super.chapters;
  }

  @override
  Map<String, Object?> toJson() {
    serializations++;
    return super.toJson();
  }
}

class _HistoryResultGate {
  final reached = Completer<void>();
  final _release = Completer<void>();

  Future<void> pause() {
    reached.complete();
    return _release.future;
  }

  void open() {
    if (!_release.isCompleted) _release.complete();
  }
}

SyncRecords _syncedHistory(
  History item,
  ReadingProgress progress, {
  required int durationMs,
  String? title,
}) => {
  syncRecordKey('history', [item.id, item.type.value]): {
    'title': title ?? item.title,
    'subtitle': item.subtitle,
    'cover': item.cover,
    'maxPage': item.maxPage,
    'readDurationMs': durationMs,
    'readingProgress': progress.toJson(),
  },
};

void main() {
  test('History.fromMap defaults missing reading duration to zero', () {
    expect(_history('legacy-map').readDurationMs, 0);
  });

  group(
    'reading progress snapshots',
    () {
      late Directory directory;
      late HistoryManager manager;

      setUp(() async {
        directory = Directory.systemTemp.createTempSync('history-snapshot-');
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        HistoryManager.cache = null;
        manager = HistoryManager();
        await manager.init();
      });

      tearDown(() async {
        await manager.flushReadingProgress();
        await manager.waitForAsyncWrites();
        manager.close();
        HistoryManager.cache = null;
        await directory.delete(recursive: true);
      });

      test('page turns reuse the catalog without serializing it', () async {
        final catalog = _CountingCatalog([
          for (var chapter = 1; chapter <= 1000; chapter++)
            ReadingChapter(id: 'chapter-$chapter', ep: chapter),
        ]);
        final item = _history('large-catalog');
        manager.addHistory(item);
        manager.recordReadingProgress(
          item,
          position: const ReadingPosition(
            ep: 1,
            page: 2,
            chapterId: 'chapter-1',
          ),
          source: ReadingNavigationSource.userForward,
          catalog: catalog,
        );
        final first = item.readingProgress!;
        catalog.serializations = 0;

        for (var page = 3; page <= 20; page++) {
          final progress = manager.recordReadingProgress(
            item,
            position: ReadingPosition(
              ep: 1,
              page: page,
              chapterId: 'chapter-1',
            ),
            source: ReadingNavigationSource.userForward,
            catalog: catalog,
          );
          expect(item.readingProgress, same(progress));
          expect(progress.catalog, same(catalog));
        }
        expect(catalog.serializations, 0);
        expect(first.resumePosition?.page, 2);
        expect(item.resumePosition?.page, 20);

        await manager.flushReadingProgress();
        final saved = manager.getAll().single;
        expect(saved.resumePosition?.page, 20);
        expect(saved.readingProgress!.catalog!.chapters, hasLength(1000));
      });

      test(
        'page turns after progress and duration writes reuse the live catalog',
        () async {
          final catalog = _CountingCatalog([
            for (var chapter = 1; chapter <= 1000; chapter++)
              ReadingChapter(id: 'chapter-$chapter', ep: chapter),
          ]);
          final item = _history('persisted-catalog')
            ..readingProgress = ReadingProgress.seed(
              const ReadingPosition(ep: 1, page: 2, chapterId: 'chapter-1'),
              catalog: ReadingCatalog.fromJson(catalog.toJson()),
            );
          manager.addHistory(item);
          manager.recordReadingProgress(
            item,
            position: const ReadingPosition(
              ep: 1,
              page: 2,
              chapterId: 'chapter-1',
            ),
            source: ReadingNavigationSource.userForward,
            catalog: catalog,
          );

          manager.debugBeforeAsyncHistoryResultApplied = () async {
            catalog.chapterReads = 0;
            catalog.serializations = 0;
          };
          for (var page = 3; page <= 5; page++) {
            await manager.flushReadingProgress();
            expect(catalog.chapterReads, lessThan(40));
            expect(catalog.serializations, 0);
            if (page == 4) {
              await manager.addReadDuration(item, const Duration(seconds: 5));
              expect(catalog.chapterReads, lessThan(40));
              expect(catalog.serializations, 0);
            }
            final persisted = manager
                .find(item.id, item.type)!
                .readingProgress!;
            expect(persisted.catalog, same(catalog));
            catalog.serializations = 0;
            final observed = persisted.merge(item.readingProgress!);
            manager.recordReadingProgress(
              item,
              position: ReadingPosition(
                ep: 1,
                page: page,
                chapterId: 'chapter-1',
              ),
              source: ReadingNavigationSource.userForward,
              commandId: 'gesture-$page',
              catalog: catalog,
              observedProgress: observed,
            );
            expect(catalog.serializations, 0);
            expect(item.readingProgress!.catalog, same(catalog));
            expect(item.resumePosition?.page, page);
          }
          await manager.flushReadingProgress();
          final saved = manager.getAll().single;
          expect(saved.resumePosition?.page, 5);
          expect(saved.readDurationMs, 5000);
        },
      );

      test(
        'catalog reuse preserves a remotely written reread and changed directory',
        () async {
          final catalog = ReadingCatalog(const [
            ReadingChapter(id: 'one', ep: 1),
            ReadingChapter(id: 'two', ep: 2),
          ]);
          final item = _history('remote-catalog');
          manager.recordReadingProgress(
            item,
            position: const ReadingPosition(ep: 2, page: 5, chapterId: 'two'),
            source: ReadingNavigationSource.userForward,
            catalog: catalog,
          );
          await manager.flushReadingProgress();
          final remote = item.readingProgress!.record(
            const ReadingPosition(ep: 1, page: 2, chapterId: 'one'),
            source: ReadingNavigationSource.userBackward,
            newRoundId: 'remote-round',
          );
          final database = sqlite3.open('${directory.path}/history.db');
          try {
            database.execute(
              'UPDATE history SET reading_progress = ? WHERE id = ? AND type = ?',
              [jsonEncode(remote.toJson()), item.id, item.type.value],
            );
            await manager.addReadDuration(item, const Duration(seconds: 1));
            final cached = manager.find(item.id, item.type)!.readingProgress!;
            expect(cached.catalog, same(catalog));
            expect(cached.activeRoundId, 'remote-round');
            expect(cached.resumePosition, remote.resumePosition);

            final expanded = ReadingCatalog([
              ...catalog.chapters,
              const ReadingChapter(id: 'three', ep: 3),
            ]);
            database.execute(
              'UPDATE history SET reading_progress = ? WHERE id = ? AND type = ?',
              [
                jsonEncode(remote.rebaseCatalog(expanded).toJson()),
                item.id,
                item.type.value,
              ],
            );
            await manager.addReadDuration(item, const Duration(seconds: 1));
            final updated = manager.find(item.id, item.type)!.readingProgress!;
            expect(updated.catalog!.chapters, hasLength(3));
            expect(updated.activeRoundId, 'remote-round');
            expect(updated.resumePosition, remote.resumePosition);
          } finally {
            database.close();
          }
        },
      );

      test(
        'history worker rechecks a sync written in the result adoption window',
        () async {
          final catalog = ReadingCatalog(const [
            ReadingChapter(id: 'one', ep: 1),
            ReadingChapter(id: 'two', ep: 2),
          ]);
          final item = _history('sync-adoption')
            ..readingProgress = ReadingProgress.seed(
              const ReadingPosition(ep: 2, page: 8, chapterId: 'two'),
              catalog: catalog,
            );
          manager.addHistory(item);
          final gate = _HistoryResultGate();
          addTearDown(gate.open);
          var results = 0;
          manager.debugBeforeAsyncHistoryResultApplied = () {
            return ++results == 1 ? gate.pause() : Future.value();
          };
          final write = manager.addHistoryAsync(item);
          await gate.reached.future;

          final expanded = ReadingCatalog([
            ...catalog.chapters,
            const ReadingChapter(id: 'three', ep: 3),
          ]);
          final remote = item.readingProgress!
              .record(
                const ReadingPosition(ep: 1, page: 2, chapterId: 'one'),
                source: ReadingNavigationSource.userBackward,
                newRoundId: 'synced-round',
              )
              .rebaseCatalog(expanded);
          manager.applySyncRecords(
            _syncedHistory(item, remote, durationMs: 12000, title: 'Synced'),
          );
          gate.open();
          await write;

          final cached = manager.find(item.id, item.type)!;
          expect(results, 2);
          expect(cached.title, 'Synced');
          expect(cached.readDurationMs, 12000);
          expect(cached.activeRereadId, 'synced-round');
          expect(cached.resumePosition, remote.resumePosition);
          expect(cached.readingProgress!.catalog!.chapters, hasLength(3));
        },
      );

      test(
        'duration rechecks successive sync and import changes without adding twice',
        () async {
          final catalog = ReadingCatalog(const [
            ReadingChapter(id: 'one', ep: 1),
            ReadingChapter(id: 'two', ep: 2),
          ]);
          final item = _history('duration-adoption')
            ..readDurationMs = 1000
            ..readingProgress = ReadingProgress.seed(
              const ReadingPosition(ep: 2, page: 8, chapterId: 'two'),
              catalog: catalog,
            );
          manager.addHistory(item);
          final writeGate = _HistoryResultGate();
          final readGate = _HistoryResultGate();
          addTearDown(writeGate.open);
          addTearDown(readGate.open);
          var results = 0;
          manager.debugBeforeAsyncHistoryResultApplied = () {
            return switch (++results) {
              1 => writeGate.pause(),
              2 => readGate.pause(),
              _ => Future.value(),
            };
          };
          final first = manager.addReadDuration(
            item,
            const Duration(seconds: 5),
          );
          await writeGate.reached.future;

          final expanded = ReadingCatalog([
            ...catalog.chapters,
            const ReadingChapter(id: 'three', ep: 3),
          ]);
          final remote = item.readingProgress!
              .record(
                const ReadingPosition(ep: 1, page: 2, chapterId: 'one'),
                source: ReadingNavigationSource.userBackward,
                newRoundId: 'remote-duration-round',
              )
              .rebaseCatalog(expanded);
          manager.applySyncRecords(
            _syncedHistory(
              item,
              remote,
              durationMs: 20000,
              title: 'Sync title',
            ),
          );
          final second = manager.addReadDuration(
            item,
            const Duration(seconds: 2),
          );
          writeGate.open();
          await readGate.reached.future;

          expect(manager.find(item.id, item.type)!.title, 'Sync title');
          final database = sqlite3.open('${directory.path}/history.db');
          try {
            database.execute(
              'UPDATE history SET title = ?, read_duration_ms = ? '
              'WHERE id = ? AND type = ?;',
              ['Imported title', 25000, item.id, item.type.value],
            );
          } finally {
            database.dispose();
          }
          manager.notifyChanges();
          expect(manager.find(item.id, item.type)!.title, 'Imported title');
          readGate.open();
          await Future.wait([first, second]);

          final cached = manager.find(item.id, item.type)!;
          expect(results, 4);
          expect(cached.title, 'Imported title');
          expect(cached.readDurationMs, 27000);
          expect(item.readDurationMs, 27000);
          expect(manager.getAll().single.readDurationMs, 27000);
          expect(cached.activeRereadId, 'remote-duration-round');
          expect(cached.resumePosition, remote.resumePosition);
          expect(cached.readingProgress!.catalog!.chapters, hasLength(3));
        },
      );

      test(
        'synchronous history writes invalidate a completed worker result',
        () async {
          final catalog = ReadingCatalog(const [
            ReadingChapter(id: 'one', ep: 1),
            ReadingChapter(id: 'two', ep: 2),
          ]);
          final item = _history('sync-local-adoption')
            ..readingProgress = ReadingProgress.seed(
              const ReadingPosition(ep: 2, page: 8, chapterId: 'two'),
              catalog: catalog,
            );
          manager.addHistory(item);
          final gate = _HistoryResultGate();
          addTearDown(gate.open);
          var results = 0;
          manager.debugBeforeAsyncHistoryResultApplied = () {
            return ++results == 1 ? gate.pause() : Future.value();
          };
          final write = manager.addHistoryAsync(item);
          await gate.reached.future;

          final expanded = ReadingCatalog([
            ...catalog.chapters,
            const ReadingChapter(id: 'three', ep: 3),
          ]);
          final progress = item.readingProgress!
              .record(
                const ReadingPosition(ep: 1, page: 3, chapterId: 'one'),
                source: ReadingNavigationSource.userBackward,
                newRoundId: 'synchronous-round',
              )
              .rebaseCatalog(expanded);
          final replacement = _history(item.id)
            ..title = 'Synchronous title'
            ..readDurationMs = 17000
            ..readingProgress = progress;
          manager.addHistory(replacement);
          gate.open();
          await write;

          final cached = manager.find(item.id, item.type)!;
          expect(results, 2);
          expect(cached.title, 'Synchronous title');
          expect(cached.readDurationMs, 17000);
          expect(cached.activeRereadId, 'synchronous-round');
          expect(cached.resumePosition, progress.resumePosition);
          expect(cached.readingProgress!.catalog!.chapters, hasLength(3));
        },
      );

      test(
        'worker adoption uses returned data and the keys loaded at init',
        () async {
          final item = _history('returned-result');
          final gate = _HistoryResultGate();
          addTearDown(gate.open);
          manager.debugBeforeAsyncHistoryResultApplied = gate.pause;
          final write = manager.addHistoryAsync(item);
          await gate.reached.future;

          final database = sqlite3.open('${directory.path}/history.db');
          try {
            // These unannounced sentinel changes expose a completion-time
            // row decode or lazy full-table key read on the UI connection.
            database.execute(
              'UPDATE history SET reading_progress = ? WHERE id = ?;',
              ['invalid JSON sentinel', item.id],
            );
            database.execute('INSERT INTO history (id, type) VALUES (?, ?);', [
              'unannounced-key',
              item.type.value,
            ]);
            gate.open();
            await write;
            expect(manager.find(item.id, item.type)!.page, item.page);
            expect(manager.find('unannounced-key', item.type), isNull);
          } finally {
            database.dispose();
          }
        },
      );

      test(
        'new queued and pending pages merge without invalidating worker results',
        () async {
          final catalog = ReadingCatalog(const [
            ReadingChapter(id: 'one', ep: 1),
          ]);
          final item = _history('latest-local-pages')
            ..readingProgress = ReadingProgress.seed(
              const ReadingPosition(ep: 1, page: 2, chapterId: 'one'),
              catalog: catalog,
            );
          manager.addHistory(item);
          final firstGate = _HistoryResultGate();
          final secondGate = _HistoryResultGate();
          addTearDown(firstGate.open);
          addTearDown(secondGate.open);
          var results = 0;
          manager.debugBeforeAsyncHistoryResultApplied = () {
            return switch (++results) {
              1 => firstGate.pause(),
              2 => secondGate.pause(),
              _ => Future.value(),
            };
          };
          final first = manager.addHistoryAsync(item);
          await firstGate.reached.future;
          manager.recordReadingProgress(
            item,
            position: const ReadingPosition(ep: 1, page: 7, chapterId: 'one'),
            source: ReadingNavigationSource.automatic,
            catalog: catalog,
          );
          final flushing = manager.flushReadingProgress();
          firstGate.open();
          await first;
          await secondGate.reached.future;
          expect(manager.find(item.id, item.type)!.resumePosition?.page, 7);

          manager.recordReadingProgress(
            item,
            position: const ReadingPosition(ep: 1, page: 9, chapterId: 'one'),
            source: ReadingNavigationSource.automatic,
            catalog: catalog,
          );
          secondGate.open();
          await flushing;
          expect(results, 3);
          final cached = manager.find(item.id, item.type)!;
          expect(cached.resumePosition?.page, 9);
          expect(cached.readingProgress!.catalog, same(catalog));
          expect(manager.getAll().single.resumePosition?.page, 9);
        },
      );

      test(
        'imported deletion does not revive a completed worker row',
        () async {
          final item = _history('imported-delete');
          manager.addHistory(item);
          final gate = _HistoryResultGate();
          addTearDown(gate.open);
          var results = 0;
          manager.debugBeforeAsyncHistoryResultApplied = () {
            return ++results == 1 ? gate.pause() : Future.value();
          };
          final write = manager.addReadDuration(
            item,
            const Duration(seconds: 5),
          );
          await gate.reached.future;
          final database = sqlite3.open('${directory.path}/history.db');
          try {
            database.execute('DELETE FROM history WHERE id = ?;', [item.id]);
          } finally {
            database.dispose();
          }
          manager.notifyChanges();
          gate.open();
          await write;
          expect(results, 2);
          expect(manager.find(item.id, item.type), isNull);
          expect(manager.cachedHistories, isEmpty);
          expect(manager.getAll(), isEmpty);
        },
      );

      test('deleting a completed write keeps later reading progress', () async {
        final catalog = ReadingCatalog(const [
          ReadingChapter(id: 'one', ep: 1),
        ]);
        final item = _history('delete-then-read')
          ..readingProgress = ReadingProgress.seed(
            const ReadingPosition(ep: 1, page: 2, chapterId: 'one'),
            catalog: catalog,
          );
        manager.addHistory(item);
        final gate = _HistoryResultGate();
        addTearDown(gate.open);
        var results = 0;
        manager.debugBeforeAsyncHistoryResultApplied = () {
          return ++results == 1 ? gate.pause() : Future.value();
        };
        final write = manager.addHistoryAsync(item);
        await gate.reached.future;
        manager.remove(item.id, item.type);
        manager.recordReadingProgress(
          item,
          position: const ReadingPosition(ep: 1, page: 7, chapterId: 'one'),
          source: ReadingNavigationSource.automatic,
          catalog: catalog,
        );
        gate.open();
        await write;
        await manager.waitForAsyncWrites();
        expect(manager.getAll(), isEmpty);
        expect(manager.find(item.id, item.type)!.resumePosition?.page, 7);
        await manager.flushReadingProgress();
        expect(results, 2);
        expect(manager.getAll().single.resumePosition?.page, 7);
        expect(
          manager.find(item.id, item.type)!.readingProgress!.catalog,
          same(catalog),
        );
      });

      test(
        'pending progress is isolated from later mutable history edits',
        () async {
          final item = _history('snapshot')
            ..group = 2
            ..readDurationMs = 1200
            ..readEpisode = {'2-1'};
          manager.recordReadingProgress(
            item,
            position: const ReadingPosition(ep: 1, page: 7, group: 2),
            source: ReadingNavigationSource.userForward,
          );
          final recordedAt = item.time;
          item
            ..title = 'Changed'
            ..subtitle = 'Changed author'
            ..cover = 'changed.jpg'
            ..ep = 9
            ..page = 9
            ..group = 3
            ..maxPage = 99
            ..readDurationMs = 5000
            ..time = DateTime(2030)
            ..readingProgress = ReadingProgress.seed(
              const ReadingPosition(ep: 9, page: 9, group: 3),
            );
          item.readEpisode
            ..clear()
            ..add('3-9');

          await manager.flushReadingProgress();
          final saved = manager.getAll().single;
          expect(saved.id, 'snapshot');
          expect(saved.type, ComicType.local);
          expect(saved.title, 'Title snapshot');
          expect(saved.subtitle, 'Author');
          expect(saved.cover, 'cover.jpg');
          expect(saved.ep, 1);
          expect(saved.page, 7);
          expect(saved.group, 2);
          expect(saved.maxPage, 10);
          expect(saved.readDurationMs, 1200);
          expect(
            saved.time.millisecondsSinceEpoch,
            recordedAt.millisecondsSinceEpoch,
          );
          expect(saved.readEpisode, {'2-1'});
          expect(
            saved.resumePosition,
            const ReadingPosition(ep: 1, page: 7, group: 2),
          );
        },
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test('refreshHistoryInfo does not wait after final retry failure', () async {
    const sourceKey = 'history_refresh_test_source';
    var attempts = 0;
    final retryDelays = <Duration>[];
    final source = _source(
      sourceKey,
      loadComicInfo: (id) async {
        attempts++;
        return const Res.error('network unavailable');
      },
    );
    ComicSourceManager().add(source);
    addTearDown(() {
      ComicSourceManager().remove(sourceKey);
    });

    final history = History.fromMap({
      'type': ComicType.fromKey(sourceKey).value,
      'time': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'title': 'Remote Comic',
      'subtitle': 'Author',
      'cover': 'cover.jpg',
      'ep': 1,
      'page': 2,
      'id': 'comic-1',
      'readEpisode': ['1'],
      'max_page': 10,
    });

    final result = await HistoryManager.create().refreshHistoryInfo(
      history,
      retryDelay: (duration) {
        retryDelays.add(duration);
        return Future.value();
      },
    );

    expect(result, isFalse);
    expect(attempts, 3);
    expect(retryDelays, const [Duration(seconds: 2), Duration(seconds: 2)]);
  });

  test(
    'addHistoryAsync queues concurrent writes and updates cache',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      final futures = List.generate(
        5,
        (index) => manager.addHistoryAsync(_history('comic-$index')),
      );
      await Future.wait(futures);

      expect(manager.count(), 5);
      for (var i = 0; i < 5; i++) {
        final saved = manager.find('comic-$i', ComicType.local);
        expect(saved, isNotNull);
        expect(saved!.title, 'Title comic-$i');
        expect(saved.page, 2);
        expect(saved.maxPage, 10);
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'waitForAsyncWrites drains queued history writes before close',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;

      final manager = HistoryManager();
      await manager.init();

      final write = manager.addHistoryAsync(_history('comic-drained'));
      await manager.waitForAsyncWrites();
      await write;
      manager.close();
      HistoryManager.cache = null;

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final rows = db.select(
          'select page, max_page from history where id = ?',
          ['comic-drained'],
        );

        expect(rows, hasLength(1));
        expect(rows.first['page'], 2);
        expect(rows.first['max_page'], 10);
      } finally {
        db.dispose();
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'init migrates reading duration for an existing history database',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-migration-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-migration-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      final oldDb = sqlite3.open('${dataDir.path}/history.db');
      oldDb.execute('''
        create table history (
          id text primary key,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int
        );
      ''');
      oldDb.execute(
        '''
        insert into history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'legacy-comic',
          'Legacy Comic',
          'Author',
          'cover.jpg',
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ComicType.local.value,
          1,
          2,
          '1',
          10,
          null,
        ],
      );
      oldDb.dispose();

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final saved = manager.find('legacy-comic', ComicType.local);
      expect(saved, isNotNull);
      expect(saved!.readDurationMs, 0);
      expect(manager.getTotalReadDurationMs(), 0);
      expect(saved.readingProgress!.maximumPositions, const [
        ReadingPosition(ep: 1, page: 2),
      ]);
      expect(saved.activeRereadId, isNull);
      expect(saved.readingProgress!.activeRoundIds, isEmpty);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'history writes support legacy tables without a unique id constraint',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-legacy-key-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-legacy-key-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      final oldDb = sqlite3.open('${dataDir.path}/history.db');
      oldDb.execute('''
        create table history (
          id text,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          primary key (id, type)
        );
      ''');
      oldDb.execute(
        '''
        insert into history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
        [
          'legacy-comic',
          'Legacy Comic',
          'Author',
          'cover.jpg',
          DateTime(2026, 1, 1).millisecondsSinceEpoch,
          ComicType.local.value,
          1,
          2,
          '1',
          10,
          null,
        ],
      );
      oldDb.dispose();

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final existing = _history('legacy-comic')..page = 7;
      manager.addHistory(existing);
      await manager.addReadDuration(existing, const Duration(seconds: 15));
      await manager.addHistoryAsync(_history('new-comic'));
      await manager.waitForAsyncWrites();

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final existingRows = db.select(
          '''
          select page, read_duration_ms
          from history where id = ? and type = ?;
          ''',
          ['legacy-comic', ComicType.local.value],
        );
        expect(existingRows, hasLength(1));
        expect(existingRows.first['page'], 7);
        expect(existingRows.first['read_duration_ms'], 15000);
        expect(db.select('select count(*) from history;').first[0], 2);
      } finally {
        db.dispose();
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'reading duration accumulates and survives progress upserts',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-duration-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-duration-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {
          // ignore cleanup failures in partially initialized tests
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final first = _history('comic-first');
      final second = _history('comic-second');
      manager.addHistory(first);
      manager.addHistory(second);

      await Future.wait([
        manager.addReadDuration(first, const Duration(seconds: 40)),
        manager.addReadDuration(first, const Duration(seconds: 20)),
        manager.addReadDuration(second, const Duration(seconds: 30)),
      ]);
      first.page = 8;
      first.maxPage = 12;
      await manager.addHistoryAsync(first);
      await manager.waitForAsyncWrites();

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final row = db
            .select(
              '''
          select page, max_page, read_duration_ms
          from history where id = ?;
          ''',
              ['comic-first'],
            )
            .first;
        expect(row['page'], 8);
        expect(row['max_page'], 12);
        expect(row['read_duration_ms'], 60000);
      } finally {
        db.dispose();
      }

      expect(manager.getTotalReadDurationMs(), 90000);
      expect(manager.countWithReadDuration(), 2);
      expect(manager.getAllByReadDuration().map((history) => history.id), [
        'comic-first',
        'comic-second',
      ]);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
  test(
    'sync capture flushes the last page without adopting a remote reread',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-progress-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-progress-cache-',
      );
      addTearDown(() {
        try {
          HistoryManager().close();
        } catch (_) {}
        HistoryManager.cache = null;
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final item = _history('progress-sync');
      manager.addHistory(item);
      manager.recordReadingProgress(
        item,
        position: const ReadingPosition(ep: 1, page: 9),
        source: ReadingNavigationSource.automatic,
      );
      final observedAtCommand = item.readingProgress!;
      final remoteProgress =
          ReadingProgress.seed(
            const ReadingPosition(ep: 10, page: 1),
            time: 2000,
          ).record(
            const ReadingPosition(ep: 2, page: 4),
            source: ReadingNavigationSource.userBackward,
            newRoundId: 'remote-reread',
            time: 3000,
          );
      manager.applySyncRecords({
        syncRecordKey('history', ['progress-sync', ComicType.local.value]): {
          'title': 'Progress Comic',
          'subtitle': 'Author',
          'cover': 'cover.jpg',
          'maxPage': 10,
          'readDurationMs': 0,
          'readingProgress': remoteProgress.toJson(),
        },
      });
      manager.recordReadingProgress(
        item,
        position: const ReadingPosition(ep: 1, page: 8),
        source: ReadingNavigationSource.userBackward,
        commandId: 'local-reread',
        observedProgress: observedAtCommand,
      );

      final exported = await manager.exportSyncRecords();
      final key = syncRecordKey('history', [
        'progress-sync',
        ComicType.local.value,
      ]);
      final progress = ReadingProgress.fromJson(
        exported[key]!['readingProgress'],
      );
      expect(progress.maximumPositions, const [
        ReadingPosition(ep: 10, page: 1),
      ]);
      expect(progress.activeRoundIds.toSet(), {
        'local-reread',
        'remote-reread',
      });
      expect(item.ep, 1);
      expect(item.page, 8);
      final persisted = manager.find('progress-sync', ComicType.local)!;
      expect(persisted.activeRereadId, 'local-reread');
      expect(persisted.ep, 1);
      expect(persisted.page, 8);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'catalog resolution flushes queued reread state before handler and keeps it',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-catalog-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-catalog-cache-',
      );
      addTearDown(() async {
        configureHistoryReadingProgressCatalogResolver(null);
        final manager = HistoryManager.cache;
        if (manager != null && manager.isInitialized) {
          await manager.flushReadingProgress();
          await manager.waitForAsyncWrites();
          manager.close();
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) await dataDir.delete(recursive: true);
        if (cacheDir.existsSync()) await cacheDir.delete(recursive: true);
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final originalCatalog = ReadingCatalog(const [
        ReadingChapter(id: 'one', ep: 1),
        ReadingChapter(id: 'two', ep: 2),
      ]);
      final reorderedCatalog = ReadingCatalog(const [
        ReadingChapter(id: 'two', ep: 1),
        ReadingChapter(id: 'one', ep: 2),
      ]);
      final item = _history('catalog-progress')
        ..ep = 2
        ..page = 8
        ..readingProgress = ReadingProgress.seed(
          const ReadingPosition(ep: 2, page: 8, chapterId: 'two'),
          catalog: originalCatalog,
          time: 1700000000000,
        );
      manager.addHistory(item);
      manager.recordReadingProgress(
        item,
        position: const ReadingPosition(ep: 1, page: 2, chapterId: 'one'),
        source: ReadingNavigationSource.userBackward,
        commandId: 'same-round',
        catalog: originalCatalog,
      );
      manager.recordReadingProgress(
        item,
        position: const ReadingPosition(ep: 1, page: 4, chapterId: 'one'),
        source: ReadingNavigationSource.automatic,
        sessionRoundId: 'same-round',
        catalog: originalCatalog,
      );

      ReadingProgress? progressSeenByHandler;
      configureHistoryReadingProgressCatalogResolver((
        recordKey,
        catalog,
      ) async {
        final db = sqlite3.open('${dataDir.path}/history.db');
        try {
          final row = db.select(
            'SELECT reading_progress FROM history WHERE id = ?;',
            ['catalog-progress'],
          ).single;
          progressSeenByHandler = ReadingProgress.fromJson(
            jsonDecode(row['reading_progress'] as String),
          );
        } finally {
          db.dispose();
        }
        return true;
      });
      var resolved = await manager.resolveReadingProgressCatalog(
        item,
        reorderedCatalog,
      );
      expect(progressSeenByHandler?.activeRoundId, 'same-round');
      expect(
        progressSeenByHandler?.resumePosition,
        const ReadingPosition(ep: 1, page: 4, chapterId: 'one'),
      );
      expect(
        resolved.readingProgress?.catalog?.toJson(),
        originalCatalog.toJson(),
      );

      configureHistoryReadingProgressCatalogResolver(null);
      item
        ..readingProgress = resolved.readingProgress
        ..ep = resolved.ep
        ..page = resolved.page
        ..group = resolved.group;
      manager.recordReadingProgress(
        item,
        position: const ReadingPosition(ep: 1, page: 6, chapterId: 'one'),
        source: ReadingNavigationSource.automatic,
        sessionRoundId: 'same-round',
        catalog: originalCatalog,
      );
      final timeBeforeNormalization = item.readingProgress!.time;
      resolved = await manager.resolveReadingProgressCatalog(
        item,
        reorderedCatalog,
      );
      expect(resolved.activeRereadId, 'same-round');
      expect(
        resolved.resumePosition,
        const ReadingPosition(ep: 2, page: 6, chapterId: 'one'),
      );
      expect(resolved.readingProgress!.time, timeBeforeNormalization);
      expect(resolved.readingProgress!.maximumPositions, const [
        ReadingPosition(ep: 1, page: 8, chapterId: 'two'),
      ]);
      expect(
        manager
            .find('catalog-progress', ComicType.local)!
            .readingProgress!
            .resumePosition,
        resolved.resumePosition,
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'catalog resolution keeps new progress after a concurrent deletion',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-catalog-race-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-catalog-race-cache-',
      );
      addTearDown(() async {
        configureHistoryReadingProgressCatalogResolver(null);
        final manager = HistoryManager.cache;
        if (manager != null && manager.isInitialized) {
          await manager.flushReadingProgress();
          await manager.waitForAsyncWrites();
          manager.close();
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) await dataDir.delete(recursive: true);
        if (cacheDir.existsSync()) await cacheDir.delete(recursive: true);
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();
      final catalog = ReadingCatalog(const [ReadingChapter(id: 'one', ep: 1)]);
      final item = _history('catalog-resolution-race')
        ..ep = 1
        ..page = 4
        ..readingProgress = ReadingProgress.seed(
          const ReadingPosition(ep: 1, page: 4, chapterId: 'one'),
          catalog: catalog,
        );
      manager.addHistory(item);

      final resolverStarted = Completer<void>();
      final finishResolver = Completer<void>();
      configureHistoryReadingProgressCatalogResolver((
        recordKey,
        currentCatalog,
      ) async {
        resolverStarted.complete();
        await finishResolver.future;
        return true;
      });
      final resolution = manager.resolveReadingProgressCatalog(item, catalog);
      await resolverStarted.future;

      manager.remove(item.id, item.type);
      manager.recordReadingProgress(
        item,
        position: const ReadingPosition(ep: 1, page: 7, chapterId: 'one'),
        source: ReadingNavigationSource.automatic,
        catalog: catalog,
      );
      finishResolver.complete();

      final resolved = await resolution;
      expect(
        resolved.resumePosition,
        const ReadingPosition(ep: 1, page: 7, chapterId: 'one'),
      );
      expect(
        manager.find(item.id, item.type)?.resumePosition,
        resolved.resumePosition,
      );
      final persisted = await manager.exportSyncRecords();
      final persistedProgress = ReadingProgress.fromJson(
        persisted[syncRecordKey('history', [
          item.id,
          item.type.value,
        ])]!['readingProgress'],
      );
      expect(persistedProgress.resumePosition, resolved.resumePosition);
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'clear and close consume pending progress without resurrection or loss',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-history-progress-close-data-',
      );
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-history-progress-close-cache-',
      );
      addTearDown(() async {
        final manager = HistoryManager.cache;
        if (manager != null && manager.isInitialized) {
          await manager.flushReadingProgress();
          await manager.waitForAsyncWrites();
          manager.close();
        }
        HistoryManager.cache = null;
        if (dataDir.existsSync()) await dataDir.delete(recursive: true);
        if (cacheDir.existsSync()) await cacheDir.delete(recursive: true);
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      HistoryManager.cache = null;
      final manager = HistoryManager();
      await manager.init();

      final deleted = _history('deleted-pending');
      manager.addHistory(deleted);
      manager.recordReadingProgress(
        deleted,
        position: const ReadingPosition(ep: 2, page: 9),
        source: ReadingNavigationSource.automatic,
      );
      manager.clearHistory();
      await manager.waitForAsyncWrites();
      await manager.flushReadingProgress();
      expect(manager.count(), 0);

      final closing = _history('closing-pending');
      manager.addHistory(closing);
      manager.recordReadingProgress(
        closing,
        position: const ReadingPosition(ep: 1, page: 8),
        source: ReadingNavigationSource.automatic,
      );
      manager.close();
      HistoryManager.cache = null;

      final db = sqlite3.open('${dataDir.path}/history.db');
      try {
        final row = db.select(
          'SELECT reading_progress FROM history WHERE id = ?;',
          ['closing-pending'],
        ).single;
        final progress = ReadingProgress.fromJson(
          jsonDecode(row['reading_progress'] as String),
        );
        expect(progress.maximumPositions, const [
          ReadingPosition(ep: 1, page: 8),
        ]);
      } finally {
        db.dispose();
      }
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}

ComicSource _source(String key, {LoadComicFunc? loadComicInfo}) {
  return ComicSource(
    'Test Source',
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    loadComicInfo,
    null,
    null,
    null,
    null,
    'test.js',
    '',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}
