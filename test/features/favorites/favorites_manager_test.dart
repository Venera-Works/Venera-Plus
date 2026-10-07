import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/favorites/favorites.dart';

FavoriteItem _favorite(String id, [ComicType type = ComicType.local]) =>
    FavoriteItem(
      id: id,
      name: 'Comic $id',
      coverPath: 'cover-$id.jpg',
      author: 'Author',
      type: type,
      tags: const ['tag'],
    );

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void _seedFolder(Database db, String name, {bool translated = false}) {
  db.execute('''
    create table "$name" (
      id text, name text, author text, type int, tags text, cover_path text,
      time text, display_order int, ${translated ? 'translated_tags text,' : ''}
      primary key (id, type)
    );
  ''');
  for (var i = 0; i < 2; i++) {
    db.execute(
      'insert into "$name" (id, name, author, type, tags, cover_path, time, display_order) '
      'values (?, ?, ?, ?, ?, ?, ?, ?);',
      [
        '$name-$i',
        'Comic $i',
        'Author',
        0,
        'tag',
        'cover.jpg',
        '2026-07-01',
        2 - i,
      ],
    );
  }
}

Future<void> _withManager(
  Future<void> Function(LocalFavoritesManager manager) run, {
  void Function(Database db)? seed,
  void Function()? settings,
}) async {
  final data = Directory.systemTemp.createTempSync('venera-favorites-data-');
  final cache = Directory.systemTemp.createTempSync('venera-favorites-cache-');
  String? previousData;
  String? previousCache;
  try {
    previousData = App.dataPath;
  } on Error {
    /* First test may initialize late paths. */
  }
  try {
    previousCache = App.cachePath;
  } on Error {
    /* First test may initialize late paths. */
  }
  final previousSettings = Map<String, dynamic>.from(
    appdata.toJson()['settings'],
  );
  final previousSearchHistory = List<String>.from(appdata.searchHistory);
  final previousManager = LocalFavoritesManager.cache;
  LocalFavoritesManager? manager;
  try {
    App.dataPath = data.path;
    App.cachePath = cache.path;
    LocalFavoritesManager.cache = null;
    appdata.settings.remove('readingFolder');
    appdata.settings.remove('followUpdatesFolder');
    appdata.settings['disableSyncFields'] = '';
    settings?.call();
    if (seed != null) {
      final db = sqlite3.open('${data.path}/local_favorite.db');
      try {
        db.execute(
          'create table folder_order (folder_name text primary key, order_value int);',
        );
        db.execute(
          'create table folder_sync (folder_name text primary key, source_key text, source_folder text);',
        );
        seed(db);
      } finally {
        db.dispose();
      }
    }
    manager = LocalFavoritesManager();
    await manager.init();
    await run(manager);
  } finally {
    await appdata.saveData(false);
    if (manager != null) {
      await manager.waitForPendingReads();
      manager.close();
    }
    LocalFavoritesManager.cache = previousManager;
    (appdata.toJson()['settings'] as Map)
      ..clear()
      ..addAll(previousSettings);
    appdata.searchHistory = previousSearchHistory;
    App.dataPath = previousData ?? Directory.systemTemp.path;
    App.cachePath = previousCache ?? Directory.systemTemp.path;
    data.deleteSync(recursive: true);
    cache.deleteSync(recursive: true);
  }
}

void main() {
  group(
    'reading role and favorites persistence',
    () {
      test(
        'new database binds canonical reading and initializes update baseline',
        () async {
          await _withManager((manager) async {
            expect(manager.readingFolder, '在读');
            expect(
              appdata.settings.containsKey('followUpdatesFolder'),
              isFalse,
            );
            expect(appdata.settings['quickFavorite'], '在读');
            final comic = _favorite('new');
            manager.addComic('在读', comic, null, '2026-07-01');
            expect(
              manager
                  .getComicWithUpdatesInfo('在读', comic.id, comic.type)
                  .updateTime,
              '2026-07-01',
            );
            expect(manager.hasNewUpdate(comic.id, comic.type), isFalse);
          }, settings: () => appdata.settings['quickFavorite'] = 'missing');
        },
      );

      test(
        'legacy migration preserves comic order, folder order and source mapping',
        () async {
          await _withManager(
            (manager) async {
              expect(manager.readingFolder, '在读');
              expect(manager.folderNames, ['other', '在读']);
              expect(manager.getFolderComics('在读').map((c) => c.id), [
                '追更-1',
                '追更-0',
              ]);
              expect(manager.findLinked('在读'), ('source', 'remote-folder'));
              expect(appdata.settings['quickFavorite'], '在读');
              // Both a pre-migrated table and a later legacy table get update columns.
              expect(manager.getComicsWithUpdatesInfo('other'), hasLength(2));
              expect(manager.getComicsWithUpdatesInfo('在读'), hasLength(2));
            },
            seed: (db) {
              _seedFolder(db, 'other', translated: true);
              _seedFolder(db, '追更');
              db.execute(
                "insert into folder_order values ('other', 1), ('追更', 7);",
              );
              db.execute(
                "insert into folder_sync values ('追更', 'source', 'remote-folder');",
              );
            },
            settings: () {
              appdata.settings['followUpdatesFolder'] = '追更';
              appdata.settings['quickFavorite'] = '追更';
            },
          );
        },
      );

      test(
        'coexisting canonical and legacy folders never merge or repoint quick favorite',
        () async {
          await _withManager(
            (manager) async {
              expect(manager.readingFolder, '在读');
              expect(manager.getFolderComics('在读').map((c) => c.id), [
                '在读-1',
                '在读-0',
              ]);
              expect(manager.getFolderComics('追更').map((c) => c.id), [
                '追更-1',
                '追更-0',
              ]);
              expect(manager.folderNames, ['追更', '在读']);
              expect(manager.findLinked('追更'), (
                'legacy-source',
                'legacy-folder',
              ));
              expect(manager.findLinked('在读'), (
                'reading-source',
                'reading-folder',
              ));
              expect(appdata.settings['quickFavorite'], '追更');
              await manager.reconcileReadingFolderBinding();
              expect(appdata.settings['quickFavorite'], '追更');
            },
            seed: (db) {
              _seedFolder(db, '在读');
              _seedFolder(db, '追更');
              db.execute(
                "insert into folder_order values ('追更', 1), ('在读', 2);",
              );
              db.execute(
                "insert into folder_sync values ('追更', 'legacy-source', 'legacy-folder'), ('在读', 'reading-source', 'reading-folder');",
              );
            },
            settings: () {
              appdata.settings['followUpdatesFolder'] = '追更';
              appdata.settings['quickFavorite'] = '追更';
            },
          );
        },
      );

      test(
        'custom old tracker is preserved but is not the reading role',
        () async {
          await _withManager(
            (manager) async {
              expect(manager.readingFolder, '在读');
              expect(manager.count('custom'), 2);
              expect(manager.count('在读'), 0);
              expect(appdata.settings['quickFavorite'], 'custom');
            },
            seed: (db) => _seedFolder(db, 'custom'),
            settings: () {
              appdata.settings['followUpdatesFolder'] = 'custom';
              appdata.settings['quickFavorite'] = 'custom';
            },
          );
        },
      );

      test(
        'rename follows role, deletion stays unbound, explicit recreation rebinds',
        () async {
          await _withManager((manager) async {
            manager.rename('在读', 'My reading');
            manager.createFolder('在读');
            expect(manager.readingFolder, 'My reading');
            await manager.waitForPendingReads();
            manager.close();
            await manager.init();
            expect(manager.readingFolder, 'My reading');
            manager.deleteFolder('My reading');
            await manager.reconcileReadingFolderBinding();
            expect(manager.readingFolder, isNull);
            await appdata.saveData(false);
            appdata.settings['readingFolder'] = 'incorrect-memory-value';
            await appdata.loadDataForTesting(App.dataPath);
            expect(appdata.settings.containsKey('readingFolder'), isTrue);
            expect(appdata.settings['readingFolder'], isNull);
            await manager.waitForPendingReads();
            manager.close();
            await manager.init();
            expect(manager.readingFolder, isNull);
            manager.deleteFolder('在读');
            manager.createFolder('在读');
            expect(manager.readingFolder, '在读');
          });
        },
      );

      test(
        'database reload does not mutate settings before imported settings reconcile',
        () async {
          await _withManager((manager) async {
            manager.rename('在读', '追更');
            await manager.waitForPendingReads();
            manager.close();
            final before = Map<String, dynamic>.from(
              appdata.toJson()['settings'],
            );
            await manager.init(reconcileReadingBinding: false);
            expect(appdata.toJson()['settings'], before);
            await appdata.syncData({
              'settings': {'followUpdatesFolder': '追更'},
            });
            expect(appdata.settings.containsKey('readingFolder'), isFalse);
            await manager.reconcileReadingFolderBinding();
            expect(manager.readingFolder, '在读');
            expect(manager.folderNames, ['在读']);
            expect(manager.folderComics('在读'), 0);
            expect(
              appdata.settings.containsKey('followUpdatesFolder'),
              isFalse,
            );
          });
        },
      );

      test(
        'failed legacy rename rolls back tables, order and network mapping',
        () async {
          await _withManager((manager) async {
            manager.rename('在读', '追更');
            manager.linkFolderToNetwork('追更', 'source', 'remote');
            manager.addComic('追更', _favorite('kept'), 7, 'old');
            // A dangling order row deliberately makes the metadata rename fail.
            manager.updateOrder(['在读', '追更']);
            appdata.settings.remove('readingFolder');
            appdata.settings['followUpdatesFolder'] = '追更';
            appdata.settings['quickFavorite'] = '追更';
            await expectLater(
              manager.reconcileReadingFolderBinding(),
              throwsA(isA<SqliteException>()),
            );
            expect(manager.folderNames, ['追更']);
            expect(manager.getFolderComics('追更').single.id, 'kept');
            expect(manager.findLinked('追更'), ('source', 'remote'));
            expect(appdata.settings['quickFavorite'], '追更');
            expect(appdata.settings.containsKey('readingFolder'), isFalse);
          });
        },
      );

      test(
        'all-folder identity and unread cache are collision safe even without reading role',
        () async {
          await _withManager((manager) async {
            manager.createFolder('other');
            manager.deleteFolder('在读');
            final first = _favorite('a', const ComicType(17));
            final second = _favorite(
              'b',
              ComicType('a'.hashCode ^ 'b'.hashCode ^ 17),
            );
            expect(
              first.id.hashCode ^ first.type.value,
              second.id.hashCode ^ second.type.value,
            );
            manager.addComic('other', first, null, 'old');
            expect(manager.isExist(second.id, second.type), isFalse);
            manager.addComic('other', second, null, 'old');
            await manager.waitForPendingReads();
            expect(manager.totalComics, 2);
            manager.updateUpdateTime('other', first.id, first.type, 'new');
            expect(manager.getAllComicsWithUpdatesInfo(), hasLength(2));
            expect(manager.hasNewUpdate(first.id, first.type), isTrue);
            expect(manager.hasNewUpdate(second.id, second.type), isFalse);
            manager.markAsRead(second.id, second.type);
            expect(manager.hasNewUpdate(first.id, first.type), isTrue);
          });
        },
      );

      test(
        'same timestamp retains unread until reading clears all memberships',
        () async {
          await _withManager((manager) async {
            manager.createFolder('other');
            final comic = _favorite('shared');
            for (final folder in manager.folderNames) {
              manager.addComic(folder, comic, null, 'old');
              manager.updateUpdateTime(folder, comic.id, comic.type, 'new');
              manager.updateUpdateTime(folder, comic.id, comic.type, 'new');
              expect(
                manager.hasNewUpdate(comic.id, comic.type, folder),
                isTrue,
              );
            }
            appdata.settings['moveFavoriteAfterRead'] = 'none';
            manager.onRead(comic.id, comic.type);
            for (final folder in manager.folderNames) {
              manager.updateUpdateTime(folder, comic.id, comic.type, 'new');
              expect(
                manager.hasNewUpdate(comic.id, comic.type, folder),
                isFalse,
              );
            }
          });
        },
      );

      test(
        'delete operations clear only removed identities from unread cache',
        () async {
          await _withManager((manager) async {
            for (final id in ['one', 'batch', 'all']) {
              final comic = _favorite(id);
              manager.addComic('在读', comic, null, 'old');
              manager.updateUpdateTime('在读', id, comic.type, 'new');
            }
            manager.deleteComicWithId('在读', 'one', ComicType.local);
            manager.batchDeleteComics('在读', [_favorite('batch')]);
            manager.batchDeleteComicsInAllFolders([
              ComicID(ComicType.local, 'all'),
            ]);
            for (final id in ['one', 'batch', 'all']) {
              expect(manager.hasNewUpdate(id, ComicType.local), isFalse);
            }
          });
        },
      );

      test(
        'moving, copying and adding memberships preserve unread metadata',
        () async {
          await _withManager((manager) async {
            manager.createFolder('moved');
            manager.createFolder('copied');
            final comic = _favorite('unread');
            manager.addComic('在读', comic, null, 'old');
            manager.updateUpdateTime('在读', comic.id, comic.type, 'new');
            manager.moveFavorite('在读', 'moved', comic.id, comic.type);
            manager.batchCopyFavorites('moved', 'copied', [comic]);
            manager.addComic('在读', comic);
            for (final folder in manager.folderNames) {
              final state = manager.getComicWithUpdatesInfo(
                folder,
                comic.id,
                comic.type,
              );
              expect(state.updateTime, 'new');
              expect(state.hasNewUpdate, isTrue);
            }
            manager.batchMoveFavorites('moved', 'copied', [comic]);
            expect(
              manager.hasNewUpdate(comic.id, comic.type, 'copied'),
              isTrue,
            );
            expect(manager.count('moved'), 0);
          });
        },
      );

      test(
        'batch no-ops do not notify and moves notify with updated counts',
        () async {
          await _withManager((manager) async {
            manager.createFolder('source');
            manager.createFolder('target');
            await manager.waitForPendingReads();
            final first = _favorite('first');
            final second = _favorite('second');
            manager.addComic('source', first);
            manager.addComic('source', second);
            final observed = <(int, int)>[];
            void listener() => observed.add((
              manager.folderComics('source'),
              manager.folderComics('target'),
            ));
            manager.addListener(listener);
            try {
              manager.batchMoveFavorites('source', 'target', []);
              manager.batchCopyFavorites('source', 'target', []);
              manager.batchDeleteComics('source', []);
              manager.batchDeleteComicsInAllFolders([]);
              expect(observed, isEmpty);
              manager.batchMoveFavorites('source', 'target', [first, second]);
              expect(observed, [(0, 2)]);
            } finally {
              manager.removeListener(listener);
            }
          });
        },
      );

      test(
        'reopening keeps custom folder order and unread and reading updates ordering',
        () async {
          await _withManager((manager) async {
            manager.createFolder('Read later');
            final first = _favorite('c1');
            final second = _favorite('c2');
            manager.addComic('Read later', first, 1, 'old');
            manager.addComic('Read later', second, 2, 'old');
            manager.updateUpdateTime(
              'Read later',
              second.id,
              second.type,
              'new',
            );
            await manager.waitForPendingReads();
            manager.close();
            await manager.init();
            expect(manager.getFolderComics('Read later').map((c) => c.id), [
              'c1',
              'c2',
            ]);
            expect(manager.hasNewUpdate('c2', ComicType.local), isTrue);
            appdata.settings['moveFavoriteAfterRead'] = 'start';
            manager.onRead('c2', ComicType.local);
            expect(manager.getFolderComics('Read later').map((c) => c.id), [
              'c2',
              'c1',
            ]);
            expect(manager.hasNewUpdate('c2', ComicType.local), isFalse);
          });
        },
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
