import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/features/favorites/favorites.dart';

FavoriteItem _testComic(
  String id, {
  String name = 'Test Comic',
  ComicType type = ComicType.local,
  List<String> tags = const ['action', 'comedy'],
}) => FavoriteItem(
  id: id,
  name: name,
  coverPath: 'cover-$id.jpg',
  author: 'Author $id',
  type: type,
  tags: tags,
);

Future<void> _withManager(
  Future<void> Function(LocalFavoritesManager manager) run, {
  void Function(Database db)? seed,
  void Function()? settings,
}) async {
  final data = Directory.systemTemp.createTempSync('venera-fav-sync-data-');
  final cache = Directory.systemTemp.createTempSync('venera-fav-sync-cache-');
  String? previousData;
  String? previousCache;
  try {
    previousData = App.dataPath;
  } on Error {
    // late paths unset
  }
  try {
    previousCache = App.cachePath;
  } on Error {
    // late paths unset
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
    final managersToClose = <LocalFavoritesManager>{
      if (manager != null) manager,
      if (LocalFavoritesManager.cache != null) LocalFavoritesManager.cache!,
    };
    for (final current in managersToClose) {
      await current.waitForPendingReads();
      current.close();
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
  group('Favorites Sync & Stable Folder Identity', () {
    test(
      'legacy folders are deterministically seeded and preserved across re-init',
      () async {
        await _withManager(
          (manager) async {
            final expectedId = legacySyncFolderId('漫画');
            final actualId = manager.getFolderId('漫画');
            expect(actualId, equals(expectedId));

            // Close and re-open to ensure persistence across reloads
            await manager.waitForPendingReads();
            manager.close();
            LocalFavoritesManager.cache = null;
            final reopened = LocalFavoritesManager();
            await reopened.init();
            expect(reopened.getFolderId('漫画'), equals(expectedId));
            expect(reopened.getFolderNameById(expectedId), equals('漫画'));
          },
          seed: (db) {
            db.execute('''
              create table "漫画" (
                id text, name text, author text, type int, tags text, cover_path text,
                time text, display_order int, translated_tags text, last_update_time text,
                has_new_update int default 0, last_check_time int,
                primary key (id, type)
              );
            ''');
          },
        );
      },
    );

    test(
      'newly created folders get UUID v4 while existing folders retain ID on rename',
      () async {
        await _withManager((manager) async {
          final folderName = manager.createFolder('我的收藏');
          final folderId = manager.getFolderId(folderName);
          expect(folderId, isNotNull);
          // Must not be a legacy seed
          expect(folderId, isNot(equals(legacySyncFolderId('我的收藏'))));

          // Renaming folder must preserve the exact same folderId
          manager.rename('我的收藏', '重命名收藏');
          expect(manager.existsFolder('我的收藏'), isFalse);
          expect(manager.existsFolder('重命名收藏'), isTrue);

          final renamedFolderId = manager.getFolderId('重命名收藏');
          expect(renamedFolderId, equals(folderId));
          expect(manager.getFolderNameById(folderId!), equals('重命名收藏'));
          expect(manager.getFolderLogicalName('重命名收藏'), equals('重命名收藏'));

          // Export records verifies logical name with original ID
          final exported = manager.exportSyncRecords();
          final folderKey = syncRecordKey('folder', [folderId]);
          expect(exported.containsKey(folderKey), isTrue);
          expect(exported[folderKey]!['name'], equals('重命名收藏'));
        });
      },
    );

    test(
      'exportSyncRecords adheres to contract: canonical fields only, excludes last_check_time and aliases',
      () async {
        await _withManager((manager) async {
          manager.createFolder('测试导出');
          final comic = _testComic('c1');
          manager.addComic('测试导出', comic);
          manager.updateUpdateTime(
            '测试导出',
            'c1',
            ComicType.local,
            '2026-10-07 12:00:00',
            unread: true,
          );
          manager.updateCheckTime('测试导出', 'c1', ComicType.local);

          final exported = manager.exportSyncRecords();
          final folderId = manager.getFolderId('测试导出')!;
          final comicKey = syncRecordKey('favorite', [
            folderId,
            'c1',
            ComicType.local.value,
          ]);

          expect(exported.containsKey(comicKey), isTrue);
          final fields = exported[comicKey]!;

          // Canonical fields that MUST be exported
          expect(fields['title'], equals('Test Comic'));
          expect(fields['author'], equals('Author c1'));
          expect(fields['cover'], equals('cover-c1.jpg'));
          expect(fields['tags'], equals(['action', 'comedy']));
          expect(fields['lastUpdateTime'], equals('2026-10-07 12:00:00'));
          expect(fields['hasNewUpdate'], isTrue);

          // Redundant aliases MUST NOT be exported
          expect(fields.containsKey('name'), isFalse);
          expect(fields.containsKey('coverPath'), isFalse);

          // Internal fields that MUST be excluded from sync
          expect(fields.containsKey('last_check_time'), isFalse);
          expect(fields.containsKey('lastCheckTime'), isFalse);
          expect(fields.containsKey('translated_tags'), isFalse);
          expect(fields.containsKey('translatedTags'), isFalse);
        });
      },
    );

    test(
      'two devices adding favorites concurrently co-exist without data loss',
      () async {
        await _withManager((manager) async {
          manager.createFolder('在读');
          await manager.setReadingFolder('在读');
          final folderId = manager.getFolderId('在读')!;

          // Device A added c1 locally
          manager.addComic('在读', _testComic('c1', name: 'Device A Comic'));

          // Materialized records from merge containing both c1 (Device A) and c2 (Device B)
          final records = <String, Map<String, Object?>>{
            syncRecordKey('folder', [folderId]): {'name': '在读', 'order': 0},
            syncRecordKey('favorite', [
              folderId,
              'c1',
              ComicType.local.value,
            ]): {
              'title': 'Device A Comic',
              'author': 'Author c1',
              'cover': 'cover-c1.jpg',
              'tags': ['tagA'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
            syncRecordKey('favorite', [
              folderId,
              'c2',
              ComicType.local.value,
            ]): {
              'title': 'Device B Comic',
              'author': 'Author c2',
              'cover': 'cover-c2.jpg',
              'tags': ['tagB'],
              'time': '2026-10-07 10:05:00',
              'displayOrder': 1,
              'hasNewUpdate': true,
            },
          };

          manager.applySyncRecords(records);

          final comics = manager.getFolderComics('在读');
          expect(comics.map((c) => c.id).toSet(), equals({'c1', 'c2'}));
          expect(manager.folderComics('在读'), equals(2));
          expect(manager.hasNewUpdate('c2', ComicType.local), isTrue);
        });
      },
    );

    test(
      'concurrent folder delete vs alive favorite child addition revives folder metadata without losing favorite',
      () async {
        await _withManager((manager) async {
          final folderId = const Uuid().v4();

          // Incoming records omit folder definition, but contain an alive favorite
          final records = <String, Map<String, Object?>>{
            syncRecordKey('favorite', [
              folderId,
              'alive-1',
              ComicType.local.value,
            ]): {
              'title': 'Resurrected Comic',
              'author': 'Author R',
              'cover': 'cover-r.jpg',
              'tags': ['revived'],
              'time': '2026-10-07 11:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
          };

          manager.applySyncRecords(records);

          // Folder metadata must have been revived / created
          final physicalName = manager.getFolderNameById(folderId);
          expect(physicalName, isNotNull);
          expect(manager.existsFolder(physicalName!), isTrue);

          // Favorite must be present in the revived folder
          final comics = manager.getFolderComics(physicalName);
          expect(comics.length, equals(1));
          expect(comics.first.id, equals('alive-1'));
          expect(comics.first.name, equals('Resurrected Comic'));
        });
      },
    );

    test(
      'folders with duplicate logical names are deterministically disambiguated and preserve reading role',
      () async {
        await _withManager((manager) async {
          final idA = 'id-device-a';
          final idB = 'id-device-b';

          // Records contain two distinct folders with same logical name "漫画"
          final records = <String, Map<String, Object?>>{
            syncRecordKey('folder', [idA]): {'name': '漫画', 'order': 0},
            syncRecordKey('folder', [idB]): {'name': '漫画', 'order': 1},
            syncRecordKey('favorite', [idA, 'c-a', ComicType.local.value]): {
              'title': 'Comic A',
              'author': 'Author A',
              'cover': 'cover-a.jpg',
              'tags': ['a'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
            syncRecordKey('favorite', [idB, 'c-b', ComicType.local.value]): {
              'title': 'Comic B',
              'author': 'Author B',
              'cover': 'cover-b.jpg',
              'tags': ['b'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
            // reading role binds to idB (the disambiguated one)
            syncRecordKey('favoriteRole', ['reading']): {'folderId': idB},
          };

          manager.applySyncRecords(records);

          // Both folders exist locally
          expect(manager.existsFolder('漫画'), isTrue);
          expect(manager.existsFolder('漫画 (2)'), isTrue);

          // Comics belong to their respective folders
          expect(
            manager.getFolderComics('漫画').map((c) => c.id),
            equals(['c-a']),
          );
          expect(
            manager.getFolderComics('漫画 (2)').map((c) => c.id),
            equals(['c-b']),
          );

          // Reading folder binding cleanly mapped to the physical name without breakage
          expect(manager.readingFolder, equals('漫画 (2)'));
          expect(manager.readingFolderId, equals(idB));

          // Exporting preserves the original logical requested names without phantom edits
          final exported = manager.exportSyncRecords();
          expect(
            exported[syncRecordKey('folder', [idA])]!['name'],
            equals('漫画'),
          );
          expect(
            exported[syncRecordKey('folder', [idB])]!['name'],
            equals('漫画'),
          );
          expect(
            exported[syncRecordKey('favoriteRole', ['reading'])]!['folderId'],
            equals(idB),
          );
        });
      },
    );

    test(
      'two folders swapping names (A <-> B) in single sync succeeds via two-phase rename',
      () async {
        await _withManager((manager) async {
          final id1 = 'folder-swap-1';
          final id2 = 'folder-swap-2';

          // Initial state: id1 is "FolderA", id2 is "FolderB"
          final initialRecords = <String, Map<String, Object?>>{
            syncRecordKey('folder', [id1]): {'name': 'FolderA', 'order': 0},
            syncRecordKey('folder', [id2]): {'name': 'FolderB', 'order': 1},
            syncRecordKey('favorite', [id1, 'item-a', ComicType.local.value]): {
              'title': 'Item A',
              'author': 'Author A',
              'cover': 'cover-a.jpg',
              'tags': ['a'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
            syncRecordKey('favorite', [id2, 'item-b', ComicType.local.value]): {
              'title': 'Item B',
              'author': 'Author B',
              'cover': 'cover-b.jpg',
              'tags': ['b'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
          };
          manager.applySyncRecords(initialRecords);

          expect(
            manager.getFolderComics('FolderA').map((c) => c.id),
            equals(['item-a']),
          );
          expect(
            manager.getFolderComics('FolderB').map((c) => c.id),
            equals(['item-b']),
          );

          // Swap logical names: id1 becomes "FolderB", id2 becomes "FolderA"
          final swappedRecords = <String, Map<String, Object?>>{
            syncRecordKey('folder', [id1]): {'name': 'FolderB', 'order': 0},
            syncRecordKey('folder', [id2]): {'name': 'FolderA', 'order': 1},
            syncRecordKey('favorite', [id1, 'item-a', ComicType.local.value]): {
              'title': 'Item A',
              'author': 'Author A',
              'cover': 'cover-a.jpg',
              'tags': ['a'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
            syncRecordKey('favorite', [id2, 'item-b', ComicType.local.value]): {
              'title': 'Item B',
              'author': 'Author B',
              'cover': 'cover-b.jpg',
              'tags': ['b'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
          };

          // Must not throw table collision error
          manager.applySyncRecords(swappedRecords);

          // Now FolderB has item-a (because id1 is now FolderB), and FolderA has item-b!
          expect(
            manager.getFolderComics('FolderB').map((c) => c.id),
            equals(['item-a']),
          );
          expect(
            manager.getFolderComics('FolderA').map((c) => c.id),
            equals(['item-b']),
          );
        });
      },
    );

    test(
      'absence of favoriteRole in full materialized view clears reading role without resurrection',
      () async {
        await _withManager((manager) async {
          manager.createFolder('在读');
          await manager.setReadingFolder('在读');
          expect(manager.readingFolder, equals('在读'));
          final rId = manager.readingFolderId!;

          // Records that omit favoriteRole completely
          final records = <String, Map<String, Object?>>{
            syncRecordKey('folder', [rId]): {'name': '在读', 'order': 0},
          };

          manager.applySyncRecords(records);

          // Reading role must be cleared (null)
          expect(manager.readingFolder, isNull);
          expect(manager.readingFolderId, isNull);

          // Re-export must NOT resurrect the cleared reading role
          final exported = manager.exportSyncRecords();
          expect(
            exported.containsKey(syncRecordKey('favoriteRole', ['reading'])),
            isFalse,
          );
        });
      },
    );

    test(
      'folder names with quotes and special characters are safely escaped',
      () async {
        await _withManager((manager) async {
          final quotedName = 'My "Special" Folder';
          final createdName = manager.createFolder(quotedName);
          expect(createdName, equals(quotedName));
          expect(manager.existsFolder(quotedName), isTrue);

          final comic = _testComic('q1');
          manager.addComic(quotedName, comic);
          expect(
            manager.comicExists(quotedName, 'q1', ComicType.local),
            isTrue,
          );
          expect(manager.getFolderComics(quotedName).length, equals(1));

          // Renaming to another name with quotes
          final newQuoted = 'Another "Quoted" Name';
          manager.rename(quotedName, newQuoted);
          expect(manager.existsFolder(newQuoted), isTrue);
          expect(manager.existsFolder(quotedName), isFalse);
          expect(manager.getFolderComics(newQuoted).first.id, equals('q1'));

          // Export and apply round trip
          final exported = manager.exportSyncRecords();
          final folderId = manager.getFolderId(newQuoted)!;
          expect(
            exported[syncRecordKey('folder', [folderId])]!['name'],
            equals(newQuoted),
          );

          manager.applySyncRecords(exported);
          expect(manager.existsFolder(newQuoted), isTrue);
          expect(manager.getFolderComics(newQuoted).first.id, equals('q1'));
        });
      },
    );

    test(
      'legacy isolated DB with missing update columns is safely migrated without skipping favorites',
      () async {
        await _withManager(
          (manager) async {
            // "旧库" was seeded with bare legacy schema without last_update_time / has_new_update
            expect(manager.existsFolder('旧库'), isTrue);
            final comics = manager.getFolderComics('旧库');
            expect(comics.length, equals(1));
            expect(comics.first.id, equals('legacy-c1'));

            // readSyncRecords exports all favorites despite older schema
            final exported = manager.exportSyncRecords();
            final legacyId = manager.getFolderId('旧库')!;
            final favKey = syncRecordKey('favorite', [
              legacyId,
              'legacy-c1',
              ComicType.local.value,
            ]);
            expect(exported.containsKey(favKey), isTrue);
            expect(exported[favKey]!['title'], equals('Comic 1'));
          },
          seed: (db) {
            // Table with ONLY bare initial columns
            db.execute('''
              create table "旧库" (
                id text, name text, author text, type int, tags text, cover_path text,
                time text, display_order int,
                primary key (id, type)
              );
            ''');
            db.execute('''
              insert into "旧库" (id, name, author, type, tags, cover_path, time, display_order)
              values ('legacy-c1', 'Comic 1', 'Author 1', 0, 'tag', 'cover.jpg', '2026-07-01', 0);
            ''');
          },
        );
      },
    );

    test(
      'legacy user folder named folder_metadata is preserved and renamed rather than eaten',
      () async {
        await _withManager(
          (manager) async {
            // The user's folder named folder_metadata must have been renamed to avoid collision
            expect(manager.folderNames.contains('folder_metadata'), isFalse);
            expect(manager.existsFolder('folder_metadata (2)'), isTrue);
            final comics = manager.getFolderComics('folder_metadata (2)');
            expect(comics.length, equals(1));
            expect(comics.first.id, equals('user-fav-1'));
          },
          seed: (db) {
            // Legacy user table named "folder_metadata"
            db.execute('''
              create table "folder_metadata" (
                id text, name text, author text, type int, tags text, cover_path text,
                time text, display_order int,
                primary key (id, type)
              );
            ''');
            db.execute('''
              insert into "folder_metadata" (id, name, author, type, tags, cover_path, time, display_order)
              values ('user-fav-1', 'User Comic', 'Author', 0, 'tag', 'cover.jpg', '2026-07-01', 0);
            ''');
          },
        );
      },
    );

    test(
      'omitted records in materialized sync view are deleted without clearing unrelated data',
      () async {
        await _withManager((manager) async {
          manager.createFolder('保留夹');
          manager.addComic('保留夹', _testComic('item-1'));
          manager.addComic('保留夹', _testComic('item-to-delete'));

          final folderId = manager.getFolderId('保留夹')!;

          // Incoming view retains item-1 but omits item-to-delete
          final records = <String, Map<String, Object?>>{
            syncRecordKey('folder', [folderId]): {'name': '保留夹', 'order': 0},
            syncRecordKey('favorite', [
              folderId,
              'item-1',
              ComicType.local.value,
            ]): {
              'title': 'Test Comic',
              'author': 'Author item-1',
              'cover': 'cover-item-1.jpg',
              'tags': ['action'],
              'time': '2026-10-07 10:00:00',
              'displayOrder': 0,
              'hasNewUpdate': false,
            },
          };

          manager.applySyncRecords(records);

          final remaining = manager.getFolderComics('保留夹');
          expect(remaining.map((c) => c.id), equals(['item-1']));
          expect(
            manager.comicExists('保留夹', 'item-to-delete', ComicType.local),
            isFalse,
          );
        });
      },
    );

    test(
      'internal metadata tables are never exposed as user favorite folders',
      () async {
        await _withManager((manager) async {
          final folders = manager.folderNames;
          expect(folders.contains('folder_metadata'), isFalse);
          expect(folders.contains('folder_order'), isFalse);
          expect(folders.contains('folder_sync'), isFalse);
          expect(folders.contains('android_metadata'), isFalse);
          expect(folders.any((f) => f.startsWith('sqlite_')), isFalse);
        });
      },
    );

    test(
      'applySyncRecords updates counts, caches, and does not fire spurious listeners on identical state',
      () async {
        await _withManager((manager) async {
          manager.createFolder('在读');
          await manager.setReadingFolder('在读');
          final folderId = manager.getFolderId('在读')!;
          final records = <String, Map<String, Object?>>{
            syncRecordKey('folder', [folderId]): {'name': '在读', 'order': 0},
            syncRecordKey('favorite', [
              folderId,
              'sync-item',
              ComicType.local.value,
            ]): {
              'title': 'Sync Item',
              'author': 'Author S',
              'cover': 'cover-s.jpg',
              'tags': ['s'],
              'time': '2026-10-07 12:00:00',
              'displayOrder': 0,
              'hasNewUpdate': true,
            },
            syncRecordKey('favoriteRole', ['reading']): {'folderId': folderId},
          };

          var listenerFired = 0;
          manager.addListener(() {
            listenerFired++;
          });

          manager.applySyncRecords(records);
          expect(listenerFired, equals(1));
          await manager.waitForPendingReads();
          expect(manager.folderComics('在读'), equals(1));
          expect(manager.isExist('sync-item', ComicType.local), isTrue);
          expect(manager.hasNewUpdate('sync-item', ComicType.local), isTrue);

          // Applying the identical state again must NOT fire spurious notifications
          final listenerCountAfterSync = listenerFired;
          manager.applySyncRecords(records);
          expect(listenerFired, equals(listenerCountAfterSync));
        });
      },
    );
  });
}
