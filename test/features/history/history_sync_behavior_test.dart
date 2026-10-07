import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/merge_engine.dart';
import 'package:venera_plus/foundation/sync_records.dart';

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
  group('HistorySyncData standalone pure Dart behaviors', () {
    test(
      'migrates legacy id-only primary key to composite (id, type) schema',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        // Create legacy table where id alone is the primary key
        db.execute('''
        CREATE TABLE history (
          id TEXT PRIMARY KEY,
          title TEXT,
          subtitle TEXT,
          cover TEXT,
          time INT,
          type INT,
          ep INT,
          page INT,
          readEpisode TEXT,
          max_page INT
        );
      ''');
        db.execute('''
        INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page)
        VALUES ('comic-1', 'Legacy 1', 'Author', 'c1.jpg', 1000, 0, 1, 1, '1', 10);
      ''');

        // Run schema migration
        HistorySyncData.ensureSchema(db);

        // Verify PRAGMA table_info confirms composite primary key on (id, type)
        final columns = db.select('PRAGMA table_info(history);');
        final pkColumns = columns
            .where((col) => (col['pk'] as int) > 0)
            .map((col) => col['name'] as String)
            .toSet();
        expect(pkColumns, containsAll(['id', 'type']));

        // Verify column additions
        final colNames = columns.map((col) => col['name'] as String).toSet();
        expect(
          colNames,
          containsAll(['chapter_group', 'read_duration_ms', 'sync_projection']),
        );

        // Now insert another comic with same id but different type
        db.execute('''
        INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        VALUES ('comic-1', 'Legacy 2', 'Author 2', 'c2.jpg', 2000, 1, 2, 5, '1,2', 20, NULL, 500);
      ''');

        // Both must coexist
        final rows = db.select(
          'SELECT id, type, title FROM history WHERE id = ?;',
          ['comic-1'],
        );
        expect(rows, hasLength(2));
        expect(rows.map((r) => r['type']).toSet(), {0, 1});
        final exported = HistorySyncData.readSyncRecords(db);
        expect(exported, contains(syncRecordKey('history', ['comic-1', 0])));
        expect(exported, contains(syncRecordKey('history', ['comic-1', 1])));
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'readSyncRecords exports history with atomic progress and independent historyChapter records',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        db.execute('''
        INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        VALUES ('naruto', 'Naruto', 'Kishimoto', 'naruto.jpg', 1700000000, 10, 3, 12, '1,2,3', 50, 1, 45000);
      ''');

        final records = HistorySyncData.readSyncRecords(db);

        // Check history domain record
        final histKey = syncRecordKey('history', ['naruto', 10]);
        expect(records, contains(histKey));
        final histData = records[histKey]!;
        expect(histData['title'], 'Naruto');
        expect(histData['subtitle'], 'Kishimoto');
        expect(histData['cover'], 'naruto.jpg');
        expect(histData['maxPage'], 50);
        expect(histData['readDurationMs'], 45000);

        final progress = histData['progress'] as Map;
        expect(progress['ep'], 3);
        expect(progress['page'], 12);
        expect(progress['group'], 1);
        expect(progress['time'], 1700000000);

        // Check historyChapter domain records (independent per chapter)
        for (final ch in ['1', '2', '3']) {
          final chKey = syncRecordKey('historyChapter', ['naruto', 10, ch]);
          expect(records, contains(chKey));
          final chData = records[chKey]!;
          expect(chData['comicId'], 'naruto');
          expect(chData['typeValue'], 10);
          expect(chData['chapter'], ch);
          expect(chData['title'], 'Naruto');
          expect(chData['cover'], 'naruto.jpg');
        }
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'reading rewind is preserved and not clamped to max chapter',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        // Initial state: read up to chapter 10
        db.execute('''
        INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        VALUES ('onepiece', 'One Piece', 'Oda', 'op.jpg', 1000, 1, 10, 20, '1,2,3,4,5,6,7,8,9,10', 100, NULL, 60000);
      ''');

        // Incoming sync has rewinded progress to chapter 2, page 1, but chapters 1-10 still read
        final records = <String, Map<String, Object?>>{
          syncRecordKey('history', ['onepiece', 1]): {
            'title': 'One Piece',
            'subtitle': 'Oda',
            'cover': 'op.jpg',
            'maxPage': 100,
            'readDurationMs': 75000,
            'progress': {'ep': 2, 'page': 1, 'group': null, 'time': 2000},
          },
          for (var i = 1; i <= 10; i++)
            syncRecordKey('historyChapter', ['onepiece', 1, '$i']): {
              'comicId': 'onepiece',
              'typeValue': 1,
              'chapter': '$i',
              'title': 'One Piece',
              'cover': 'op.jpg',
            },
        };

        HistorySyncData.applySyncRecords(db, records);

        final row = db.select(
          'SELECT ep, page, readEpisode, read_duration_ms FROM history WHERE id = ?;',
          ['onepiece'],
        ).first;
        expect(
          row['ep'],
          2,
          reason:
              'Reading progress ep must be rewinded to 2, not max chapter 10',
        );
        expect(row['page'], 1);
        expect(row['read_duration_ms'], 75000);
        expect((row['readEpisode'] as String).split(','), hasLength(10));
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'preserves comic metadata when parent history is deleted but child historyChapter survives',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        // Incoming records contains ONLY historyChapter records (parent history was deleted concurrently)
        final records = <String, Map<String, Object?>>{
          syncRecordKey('historyChapter', ['bleach', 2, '5']): {
            'comicId': 'bleach',
            'typeValue': 2,
            'chapter': '5',
            'title': 'Bleach',
            'subtitle': 'Kubo',
            'cover': 'bleach.jpg',
            'maxPage': 60,
            'readAt': 5000,
          },
        };

        HistorySyncData.applySyncRecords(db, records);

        final rows = db.select(
          'SELECT id, type, title, subtitle, cover, readEpisode, ep FROM history WHERE id = ?;',
          ['bleach'],
        );
        expect(rows, hasLength(1));
        final row = rows.first;
        expect(
          row['title'],
          'Bleach',
          reason: 'Surviving child chapter must retain comic metadata',
        );
        expect(row['subtitle'], 'Kubo');
        expect(row['cover'], 'bleach.jpg');
        expect(row['readEpisode'], '5');
        expect(row['ep'], 5);
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );
    test(
      'a resolved parent deletion survives SQL projection, restart, and causal capture',
      () {
        final tempDir = Directory.systemTemp.createTempSync(
          'venera-history-parent-projection-',
        );
        var db = sqlite3.open('${tempDir.path}/history.sqlite');
        addTearDown(() {
          db.dispose();
          tempDir.deleteSync(recursive: true);
        });

        final parentKey = syncRecordKey('history', ['merge-comic', 1]);
        final oldChapterKey = syncRecordKey('historyChapter', [
          'merge-comic',
          1,
          '1',
        ]);
        final newChapterKey = syncRecordKey('historyChapter', [
          'merge-comic',
          1,
          '2',
        ]);
        final base = <String, Map<String, Object?>>{
          parentKey: {
            'title': 'Merged Comic',
            'subtitle': 'Author',
            'cover': 'cover.jpg',
            'maxPage': 30,
            'readDurationMs': 12000,
            'progress': {'ep': 1, 'page': 3, 'group': null, 'time': 1000},
          },
          oldChapterKey: {
            'comicId': 'merge-comic',
            'typeValue': 1,
            'chapter': '1',
            'title': 'Merged Comic',
            'subtitle': 'Author',
            'cover': 'cover.jpg',
            'maxPage': 30,
          },
        };
        HistorySyncData.applySyncRecords(db, base);

        final seed = MergeDocument()..captureLocal('seed', {}, base);
        final deviceA = seed.clone();
        final deviceB = seed.clone();
        deviceA.captureLocal('device-a', base, {});
        final deviceBRecords = <String, Map<String, Object?>>{
          parentKey: {
            'title': 'Merged Comic',
            'subtitle': 'Author',
            'cover': 'cover.jpg',
            'maxPage': 30,
            'readDurationMs': 15000,
            'progress': {'ep': 2, 'page': 5, 'group': null, 'time': 2000},
          },
          oldChapterKey: base[oldChapterKey]!,
          newChapterKey: {
            'comicId': 'merge-comic',
            'typeValue': 1,
            'chapter': '2',
            'title': 'Merged Comic',
            'subtitle': 'Author',
            'cover': 'cover.jpg',
            'maxPage': 30,
          },
        };
        deviceB.captureLocal('device-b', base, deviceBRecords);
        deviceA.merge(deviceB);

        final presenceConflict = deviceA.conflicts.singleWhere(
          (conflict) =>
              conflict.recordKey == parentKey && conflict.field == 'presence',
        );
        final deletion = presenceConflict.candidates.singleWhere(
          (candidate) => candidate.isDeleted,
        );
        deviceA.resolve('resolver', parentKey, 'presence', deletion.id);
        final resolved = deviceA.materialize();
        expect(resolved, isNot(contains(parentKey)));
        expect(resolved, contains(newChapterKey));
        expect(resolved, isNot(contains(oldChapterKey)));

        HistorySyncData.applySyncRecords(db, resolved);
        final exported = HistorySyncData.readSyncRecords(db);
        expect(exported, isNot(contains(parentKey)));
        expect(exported, contains(newChapterKey));
        expect(exported, isNot(contains(oldChapterKey)));
        expect(deviceA.captureLocal('receiver', resolved, exported), 0);
        expect(deviceA.materialize(), isNot(contains(parentKey)));
        expect(deviceA.materialize(), contains(newChapterKey));

        db.dispose();
        db = sqlite3.open('${tempDir.path}/history.sqlite');
        final afterRestart = HistorySyncData.readSyncRecords(db);
        expect(afterRestart, isNot(contains(parentKey)));
        expect(afterRestart, contains(newChapterKey));

        db.execute(
          'UPDATE history SET ep = 2, page = 6, time = 5000, read_duration_ms = 24000 WHERE id = ? AND type = ?;',
          ['merge-comic', 1],
        );
        final afterReading = HistorySyncData.readSyncRecords(db);
        expect(afterReading, contains(parentKey));
        expect(afterReading, contains(newChapterKey));
        expect(((afterReading[parentKey]!['progress'] as Map)['time']), 5000);
        deviceA.captureLocal('reader', afterRestart, afterReading);
        expect(deviceA.materialize(), contains(parentKey));
        expect(deviceA.materialize(), contains(newChapterKey));
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'independent imageFavorite records reconstruct complete comic and episode in image_favorites table',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        // Two independent image records for the same comic, one in ep 1 and one in ep 2
        final records = <String, Map<String, Object?>>{
          syncRecordKey('imageFavorite', ['c1', 'picacg', 'ep1', 3]): {
            'comicId': 'c1',
            'sourceKey': 'picacg',
            'page': 3,
            'imageKey': 'img_ep1_p3',
            'eid': 'ep1',
            'ep': 1,
            'epName': 'Episode 1',
            'epMaxPage': 20,
            'title': 'Art Book',
            'subTitle': 'Artist A',
            'author': 'Artist A',
            'tags': ['art', 'fullcolor'],
            'time': 1000,
            'maxPage': 40,
            'other': {'rate': 5},
          },
          syncRecordKey('imageFavorite', ['c1', 'picacg', 'ep2', 7]): {
            'comicId': 'c1',
            'sourceKey': 'picacg',
            'page': 7,
            'imageKey': 'img_ep2_p7',
            'eid': 'ep2',
            'ep': 2,
            'epName': 'Episode 2',
            'epMaxPage': 20,
            'title': 'Art Book',
            'subTitle': 'Artist A',
            'author': 'Artist A',
            'time': 2000,
            'maxPage': 40,
            'other': {'rate': 5},
          },
        };

        HistorySyncData.applySyncRecords(db, records);

        final row = db.select(
          'SELECT * FROM image_favorites WHERE id = ? AND source_key = ?;',
          ['c1', 'picacg'],
        ).first;
        expect(row['title'], 'Art Book');
        expect(row['author'], 'Artist A');
        expect(row['tags'], 'art,fullcolor');

        final eps = jsonDecode(row['image_favorites_ep'] as String) as List;
        expect(eps, hasLength(2));
        expect(eps[0]['ep'], 1);
        expect(
          (eps[0]['imageFavorites'] as List).first['imageKey'],
          'img_ep1_p3',
        );
        expect(eps[1]['ep'], 2);
        expect(
          (eps[1]['imageFavorites'] as List).first['imageKey'],
          'img_ep2_p7',
        );

        // Exporting must reproduce the exact imageFavorite records
        final exported = HistorySyncData.readSyncRecords(db);
        expect(
          exported,
          contains(syncRecordKey('imageFavorite', ['c1', 'picacg', 'ep1', 3])),
        );
        expect(
          exported,
          contains(syncRecordKey('imageFavorite', ['c1', 'picacg', 'ep2', 7])),
        );
        final firstKey = syncRecordKey('imageFavorite', [
          'c1',
          'picacg',
          'ep1',
          3,
        ]);
        final secondKey = syncRecordKey('imageFavorite', [
          'c1',
          'picacg',
          'ep2',
          7,
        ]);
        expect(syncValuesEqual(exported[firstKey], records[firstKey]), isTrue);
        expect(
          syncValuesEqual(exported[secondKey], records[secondKey]),
          isTrue,
        );
        expect(exported[firstKey]!['tags'], ['art', 'fullcolor']);
        expect(exported[secondKey]!.containsKey('tags'), isFalse);
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );
    test(
      'imageFavorite tuple projections preserve logical metadata and expose real physical edits',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        HistorySyncData.ensureSchema(db);

        final firstKey = syncRecordKey('imageFavorite', [
          'shared-comic',
          'source',
          'ep1',
          1,
        ]);
        final secondKey = syncRecordKey('imageFavorite', [
          'shared-comic',
          'source',
          'ep2',
          7,
        ]);
        final addedKey = syncRecordKey('imageFavorite', [
          'shared-comic',
          'source',
          'ep2',
          9,
        ]);
        final records = <String, Map<String, Object?>>{
          firstKey: {
            'comicId': 'shared-comic',
            'sourceKey': 'source',
            'page': 1,
            'imageKey': 'first-image',
            'eid': 'ep1',
            'ep': 1,
            'epName': 'First Episode',
            'epMaxPage': 10,
            'title': 'First Title',
            'subTitle': 'First Subtitle',
            'author': 'First Author',
            'tags': ['first-tag'],
            'time': 1000,
            'maxPage': 11,
            'other': {'edition': 'first'},
          },
          secondKey: {
            'comicId': 'shared-comic',
            'sourceKey': 'source',
            'page': 7,
            'imageKey': 'second-image',
            'eid': 'ep2',
            'ep': 2,
            'epName': 'Second Episode',
            'epMaxPage': 20,
            'title': 'Second Title',
            'subTitle': 'Second Subtitle',
            'author': 'Second Author',
            'tags': ['second-tag'],
            'time': 2000,
            'maxPage': 22,
            'other': {'edition': 'second'},
          },
        };

        HistorySyncData.applySyncRecords(db, records);
        final exported = HistorySyncData.readSyncRecords(db);
        expect(syncValuesEqual(exported[firstKey], records[firstKey]), isTrue);
        expect(
          syncValuesEqual(exported[secondKey], records[secondKey]),
          isTrue,
        );

        final row = db.select(
          'SELECT image_favorites_ep FROM image_favorites WHERE id = ? AND source_key = ?;',
          ['shared-comic', 'source'],
        ).single;
        final episodes =
            jsonDecode(row['image_favorites_ep'] as String) as List;
        final firstEpisode = episodes.singleWhere(
          (episode) => episode['eid'] == 'ep1',
        );
        (firstEpisode['imageFavorites'] as List).clear();
        final secondEpisode = episodes.singleWhere(
          (episode) => episode['eid'] == 'ep2',
        );
        final secondImages = secondEpisode['imageFavorites'] as List;
        (secondImages.singleWhere((image) => image['page'] == 7)
                as Map)['imageKey'] =
            'physically-edited-image';
        secondImages.add({
          'page': 9,
          'imageKey': 'physically-added-image',
          'isAutoFavorite': false,
        });
        db.execute(
          'UPDATE image_favorites SET tags = ?, image_favorites_ep = ? WHERE id = ? AND source_key = ?;',
          ['physical-tag', jsonEncode(episodes), 'shared-comic', 'source'],
        );

        final afterPhysicalEdits = HistorySyncData.readSyncRecords(db);
        expect(afterPhysicalEdits, isNot(contains(firstKey)));
        expect(afterPhysicalEdits, contains(secondKey));
        expect(
          afterPhysicalEdits[secondKey]!['imageKey'],
          'physically-edited-image',
        );
        expect(afterPhysicalEdits[secondKey]!['tags'], ['physical-tag']);
        expect(afterPhysicalEdits, contains(addedKey));
        expect(
          afterPhysicalEdits[addedKey]!['imageKey'],
          'physically-added-image',
        );
        expect(afterPhysicalEdits[addedKey]!['isAutoFavorite'], isFalse);
        expect(afterPhysicalEdits[addedKey]!['tags'], ['physical-tag']);
        expect(
          syncValuesEqual(
            HistorySyncData.readSyncRecords(db),
            afterPhysicalEdits,
          ),
          isTrue,
        );
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'omitted records in applySyncRecords are deleted, avoiding stale data',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        // Pre-seed history and image favorites
        db.execute('''
        INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        VALUES ('to-delete', 'To Delete', '', '', 1000, 1, 1, 1, '1', 10, NULL, 0);
      ''');
        db.execute('''
        INSERT INTO image_favorites (id, title, sub_title, author, tags, translated_tags, time, max_page, source_key, image_favorites_ep, other)
        VALUES ('to-delete-fav', 'Fav', '', '', '', '', 1000, 10, 'src', '[]', '{}');
      ''');

        // Apply empty records
        HistorySyncData.applySyncRecords(db, {});

        expect(db.select('SELECT count(*) FROM history;').first[0], 0);
        expect(db.select('SELECT count(*) FROM image_favorites;').first[0], 0);
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'apply followed by export is idempotent and produces no false dirty changes',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        final originalRecords = <String, Map<String, Object?>>{
          syncRecordKey('history', ['idem-comic', 3]): {
            'title': 'Idempotent Comic',
            'subtitle': 'Sub',
            'cover': 'cover.png',
            'maxPage': 25,
            'readDurationMs': 12345,
            'progress': {'ep': 4, 'page': 8, 'group': null, 'time': 1710000000},
          },
          syncRecordKey('historyChapter', ['idem-comic', 3, '1']): {
            'comicId': 'idem-comic',
            'typeValue': 3,
            'chapter': '1',
            'title': 'Idempotent Comic',
            'subtitle': 'Sub',
            'cover': 'cover.png',
            'maxPage': 25,
          },
          syncRecordKey('historyChapter', ['idem-comic', 3, '4']): {
            'comicId': 'idem-comic',
            'typeValue': 3,
            'chapter': '4',
            'title': 'Idempotent Comic',
            'subtitle': 'Sub',
            'cover': 'cover.png',
            'maxPage': 25,
          },
        };

        HistorySyncData.applySyncRecords(db, originalRecords);
        final reExported = HistorySyncData.readSyncRecords(db);

        for (final key in originalRecords.keys) {
          expect(reExported, contains(key));
          expect(
            syncValuesEqual(originalRecords[key], reExported[key]),
            isTrue,
            reason:
                'Field values for $key must match canonically to prevent phantom dirty sync diffs',
          );
        }
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );
    test(
      'handles comicId containing @ symbol without delimiter corruption',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        // comicId with @ symbol: author@book@title
        const specialComicId = 'author@book@title';
        const specialSourceKey = 'custom@source';
        final records = <String, Map<String, Object?>>{
          syncRecordKey('imageFavorite', [
            specialComicId,
            specialSourceKey,
            '1',
            5,
          ]): {
            'comicId': specialComicId,
            'sourceKey': specialSourceKey,
            'page': 5,
            'imageKey': 'img_key_1',
            'eid': '1',
            'ep': 1,
            'epName': 'Ep 1',
            'epMaxPage': 10,
            'title': 'Special Comic',
            'subTitle': 'Sub',
            'author': 'Author',
            'tags': ['tag1'],
            'time': 1000,
            'maxPage': 10,
            'other': {},
          },
        };

        final result = HistorySyncData.applySyncRecords(db, records);
        expect(result.imageFavoritesChanged, isTrue);

        final rows = db.select(
          'SELECT id, source_key FROM image_favorites WHERE id = ?;',
          [specialComicId],
        );
        expect(rows, hasLength(1));
        expect(rows.first['id'], specialComicId);
        expect(rows.first['source_key'], specialSourceKey);

        final reExported = HistorySyncData.readSyncRecords(db);
        final expectedKey = syncRecordKey('imageFavorite', [
          specialComicId,
          specialSourceKey,
          '1',
          5,
        ]);
        expect(reExported, contains(expectedKey));
        expect(reExported[expectedKey]!['comicId'], specialComicId);
        expect(reExported[expectedKey]!['sourceKey'], specialSourceKey);
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'historyChapter does not export mutable readAt to avoid marking all chapters dirty on new progress',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        // Comic with chapter 1 read at time 1000
        db.execute('''
        INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        VALUES ('stable-ch', 'Title', 'Sub', 'cov.jpg', 1000, 1, 1, 1, '1', 10, NULL, 0);
      ''');
        final export1 = HistorySyncData.readSyncRecords(db);
        final ch1Key = syncRecordKey('historyChapter', ['stable-ch', 1, '1']);
        expect(
          export1[ch1Key]!.containsKey('readAt'),
          isFalse,
          reason: 'readAt must not be exported in chapter membership',
        );

        // User reads chapter 2 at time 2000
        db.execute('''
        UPDATE history
        SET time = 2000, ep = 2, readEpisode = '1,2'
        WHERE id = 'stable-ch' AND type = 1;
      ''');
        final export2 = HistorySyncData.readSyncRecords(db);

        // Chapter 1 record must be canonically IDENTICAL to previous export
        expect(
          syncValuesEqual(export1[ch1Key], export2[ch1Key]),
          isTrue,
          reason:
              'Reading a new chapter must not mutate the sync record of previously read chapters',
        );
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'applySyncRecords detects unchanged projection and skips redundant DB writes',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        HistorySyncData.ensureSchema(db);

        final records = <String, Map<String, Object?>>{
          syncRecordKey('history', ['diff-comic', 1]): {
            'title': 'Diff Test',
            'subtitle': '',
            'cover': 'cov.jpg',
            'maxPage': 10,
            'readDurationMs': 1000,
            'progress': {'ep': 1, 'page': 1, 'group': null, 'time': 5000},
          },
        };

        final firstResult = HistorySyncData.applySyncRecords(db, records);
        expect(firstResult.historyChanged, isTrue);

        // Applying identical projection a second time
        final secondResult = HistorySyncData.applySyncRecords(db, records);
        expect(
          secondResult.hasChanges,
          isFalse,
          reason:
              'Unchanged projection must return hasChanges == false and skip write',
        );
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );

    test(
      'schema migration tolerates legacy NULL column values without constraint failure',
      () {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);

        // Legacy table with only id as PK and NULL in several columns
        db.execute('''
        CREATE TABLE history (
          id TEXT PRIMARY KEY,
          title TEXT,
          subtitle TEXT,
          cover TEXT,
          time INT,
          type INT,
          ep INT,
          page INT,
          readEpisode TEXT,
          max_page INT
        );
      ''');
        db.execute('''
        INSERT INTO history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page)
        VALUES ('null-test', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
      ''');

        // Must not throw NOT NULL constraint failure
        HistorySyncData.ensureSchema(db);

        final row = db.select(
          'SELECT id, type, ep, page, readEpisode FROM history WHERE id = ?;',
          ['null-test'],
        ).first;
        expect(row['id'], 'null-test');
        expect(row['type'], 0);
        expect(row['ep'], 1);
        expect(row['page'], 1);
        expect(row['readEpisode'], '');
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );
  });

  group('HistoryManager integration with sync', () {
    test(
      'HistoryManager exportSyncRecords waits for async writes and applySyncRecords clears cache',
      () async {
        final dataDir = Directory.systemTemp.createTempSync(
          'venera-history-sync-test-data-',
        );
        final cacheDir = Directory.systemTemp.createTempSync(
          'venera-history-sync-test-cache-',
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

        var notified = false;
        manager.addListener(() {
          notified = true;
        });

        // Add a comic asynchronously
        final item = History.fromMap({
          'type': ComicType.local.value,
          'time': 10000,
          'title': 'Async Comic',
          'subtitle': 'Author',
          'cover': 'cov.jpg',
          'ep': 1,
          'page': 3,
          'id': 'async-1',
          'readEpisode': ['1'],
          'max_page': 10,
          'read_duration_ms': 5000,
        });
        await manager.addHistoryAsync(item);

        // Export sync records (which automatically awaits pending async writes)
        final records = await manager.exportSyncRecords();
        final histKey = syncRecordKey('history', [
          'async-1',
          ComicType.local.value,
        ]);
        expect(records, contains(histKey));

        // Apply incoming sync records to update the comic
        final updatedRecords = <String, Map<String, Object?>>{
          syncRecordKey('history', ['async-1', ComicType.local.value]): {
            'title': 'Updated Async Comic',
            'subtitle': 'Author',
            'cover': 'cov.jpg',
            'maxPage': 10,
            'readDurationMs': 15000,
            'progress': {'ep': 2, 'page': 5, 'group': null, 'time': 20000},
          },
          syncRecordKey('historyChapter', [
            'async-1',
            ComicType.local.value,
            '1',
          ]): {
            'comicId': 'async-1',
            'typeValue': ComicType.local.value,
            'chapter': '1',
            'title': 'Updated Async Comic',
            'cover': 'cov.jpg',
          },
          syncRecordKey('historyChapter', [
            'async-1',
            ComicType.local.value,
            '2',
          ]): {
            'comicId': 'async-1',
            'typeValue': ComicType.local.value,
            'chapter': '2',
            'title': 'Updated Async Comic',
            'cover': 'cov.jpg',
          },
        };

        notified = false;
        manager.applySyncRecords(updatedRecords);

        expect(
          notified,
          isTrue,
          reason: 'applySyncRecords must notify listeners',
        );

        // find must return the newly updated entity
        final reloaded = manager.find('async-1', ComicType.local);
        expect(reloaded, isNotNull);
        expect(reloaded!.title, 'Updated Async Comic');
        expect(reloaded.ep, 2);
        expect(reloaded.page, 5);
        expect(reloaded.readDurationMs, 15000);
        expect(reloaded.readEpisode, containsAll(['1', '2']));
      },
      skip: _sqliteAvailable()
          ? false
          : 'sqlite3 native library is unavailable',
    );
  });
}
