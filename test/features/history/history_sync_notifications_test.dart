import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import '../../support/sqlite.dart';

History _history() => History.fromMap({
  'id': 'reading',
  'type': ComicType.local.value,
  'time': DateTime(2020).millisecondsSinceEpoch,
  'title': 'Reading',
  'subtitle': '',
  'cover': '',
  'ep': 1,
  'page': 1,
});

void main() {
  group(
    'durable history synchronization notifications',
    () {
      late Directory directory;
      late HistoryManager manager;
      late DataSync sync;
      late Map<String, dynamic> previousSettings;
      late Map<String, dynamic> previousImplicit;

      setUp(() async {
        directory = Directory.systemTemp.createTempSync('history-sync-events-');
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        previousSettings = Map<String, dynamic>.from(
          appdata.toJson()['settings'],
        );
        previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
        appdata.settings['webdav'] = ['https://example.com/dav', '', ''];
        appdata.settings.remove('syncRemoteLocation');
        appdata.implicitData.clear();
        DataSync.resetForTesting();
        DataSync.debugDisableWindowCloseHandler = true;
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        manager = HistoryManager();
        await manager.init();
        await LocalFavoritesManager().init();
        sync = DataSync();
        configureHistoryDataChangedHandler(sync.onDataChanged);
      });

      tearDown(() async {
        configureHistoryDataChangedHandler(null);
        await manager.flushReadingProgress();
        await manager.waitForAsyncWrites();
        DataSync.resetForTesting();
        manager.close();
        LocalFavoritesManager().close();
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        appdata.settings.replaceAll(previousSettings);
        appdata.implicitData
          ..clear()
          ..addAll(previousImplicit);
        await appdata.saveData(false);
        await directory.delete(recursive: true);
      });

      test(
        'page turns notify after persistence and reading time is already durable',
        () async {
          final item = _history();
          manager.addHistory(item);
          appdata.implicitData['webdavSyncPending'] = false;
          final persistedPages = <int>[];
          final persistedDurations = <int>[];
          configureHistoryDataChangedHandler(() {
            persistedPages.add(
              manager.imageFavoritesDatabase
                      .select('SELECT page FROM history;')
                      .single['page']
                  as int,
            );
            persistedDurations.add(manager.getTotalReadDurationMs());
            sync.onDataChanged();
          });

          manager.recordReadingProgress(
            item,
            position: const ReadingPosition(ep: 1, page: 2),
            source: ReadingNavigationSource.userForward,
          );
          expect(persistedPages, isEmpty);
          expect(sync.hasPendingChanges, isFalse);
          await manager.flushReadingProgress();
          expect(persistedPages, [2]);
          expect(sync.hasPendingChanges, isTrue);

          await manager.addReadDuration(item, const Duration(seconds: 3));
          expect(persistedDurations.last, 3000);
        },
      );

      final deletions = <String, void Function(HistoryManager, History)>{
        'single deletion': (manager, item) =>
            manager.remove(item.id, item.type),
        'batch deletion': (manager, item) =>
            manager.batchDeleteHistories([ComicID(item.type, item.id)]),
        'clear history and statistics': (manager, item) =>
            manager.clearHistory(),
        'expiration cleanup': (manager, item) =>
            manager.clearExpiredHistory(30),
        'unfavorited cleanup': (manager, item) =>
            manager.clearUnfavoritedHistory(),
      };
      for (final deletion in deletions.entries) {
        test(
          '${deletion.key} marks sync pending after rows and statistics are deleted',
          () async {
            final item = _history();
            manager.addHistory(item);
            await manager.addReadDuration(item, const Duration(seconds: 3));
            appdata.implicitData['webdavSyncPending'] = false;
            final counts = <int>[];
            configureHistoryDataChangedHandler(() {
              counts.add(manager.count());
              expect(manager.getTotalReadDurationMs(), 0);
              sync.onDataChanged();
            });

            deletion.value(manager, item);
            await manager.waitForAsyncWrites();

            expect(counts, [0]);
            expect(sync.hasPendingChanges, isTrue);
          },
        );
      }

      test(
        'image-favorite insertions and deletion notify after committing the shared database',
        () {
          final image = ImageFavorite(
            1,
            'page.jpg',
            false,
            'chapter',
            'reading',
            1,
            'source',
            'Chapter',
          );
          final comic = ImageFavoritesComic(
            'reading',
            [
              ImageFavoritesEp('chapter', 1, [image], 'Chapter', 1),
            ],
            'Reading',
            'source',
            [],
            [],
            DateTime(2020),
            '',
            {},
            '',
            1,
          );
          final counts = <int>[];
          configureHistoryDataChangedHandler(() {
            counts.add(ImageFavoriteManager().length);
            sync.onDataChanged();
          });

          ImageFavoriteManager().addOrUpdateOrDelete(comic);
          appdata.implicitData['webdavSyncPending'] = false;
          ImageFavoriteManager().deleteImageFavorite([image]);

          expect(counts, [1, 0]);
          expect(sync.hasPendingChanges, isTrue);
        },
      );

      test(
        'empty cleanup and view refreshes do not schedule synchronization',
        () async {
          manager.clearHistory();
          manager.clearExpiredHistory(30);
          manager.clearUnfavoritedHistory();
          manager.notifyChanges();
          ImageFavoriteManager().notifyChanges();
          await manager.waitForAsyncWrites();

          expect(sync.hasPendingChanges, isFalse);
        },
      );
    },
    skip: !isSqliteAvailable() ? 'SQLite not available' : false,
  );
}
