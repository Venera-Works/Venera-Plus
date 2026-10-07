import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/sync_records.dart';

/// Result summary indicating which domains had actual database row changes.
class HistorySyncApplyResult {
  final bool historyChanged;
  final bool imageFavoritesChanged;

  const HistorySyncApplyResult({
    required this.historyChanged,
    required this.imageFavoritesChanged,
  });

  bool get hasChanges => historyChanged || imageFavoritesChanged;
}

/// Pure Dart SQLite synchronization reader and writer for History and ImageFavorites.
///
/// Contains no Flutter or App runtime dependencies, allowing execution by the
/// sync engine, legacy migration readers, and headless tests.
class HistorySyncData {
  /// Ensures tables and columns exist with appropriate schemas and composite keys.
  static void ensureSchema(Database db) {
    db.execute('PRAGMA busy_timeout = 5000;');

    // 1. Ensure history table exists and has exact composite primary key (id, type)
    final tables = db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='history';",
    );
    if (tables.isEmpty) {
      db.execute('''
        CREATE TABLE IF NOT EXISTS history (
          id TEXT NOT NULL,
          title TEXT,
          subtitle TEXT,
          cover TEXT,
          time INTEGER NOT NULL DEFAULT 0,
          type INTEGER NOT NULL,
          ep INTEGER NOT NULL DEFAULT 1,
          page INTEGER NOT NULL DEFAULT 1,
          readEpisode TEXT NOT NULL DEFAULT '',
          max_page INTEGER,
          chapter_group INTEGER,
          read_duration_ms INTEGER NOT NULL DEFAULT 0,
          sync_projection TEXT,
          PRIMARY KEY (id, type)
        );
      ''');
    } else {
      var columns = db.select("PRAGMA table_info(history);");
      final columnNames = columns.map((col) => col['name'] as String).toSet();
      if (!columnNames.contains("chapter_group")) {
        db.execute("ALTER TABLE history ADD COLUMN chapter_group INTEGER;");
      }
      if (!columnNames.contains("read_duration_ms")) {
        db.execute(
          "ALTER TABLE history ADD COLUMN read_duration_ms INTEGER NOT NULL DEFAULT 0;",
        );
      }
      if (!columnNames.contains("sync_projection")) {
        db.execute("ALTER TABLE history ADD COLUMN sync_projection TEXT;");
      }

      // Check primary key configuration: must be exact composite PK (id, type)
      columns = db.select("PRAGMA table_info(history);");
      final pkColumns = columns
          .where((col) => (col['pk'] as int) > 0)
          .map((col) => col['name'] as String)
          .toSet();
      final hasExactCompositePk =
          pkColumns.length == 2 &&
          pkColumns.contains('id') &&
          pkColumns.contains('type');

      if (!hasExactCompositePk) {
        // Migrate to composite primary key (id, type) inside an immediate transaction
        db.execute('BEGIN IMMEDIATE;');
        try {
          db.execute('''
            CREATE TABLE history_migrating (
              id TEXT NOT NULL,
              title TEXT,
              subtitle TEXT,
              cover TEXT,
              time INTEGER NOT NULL DEFAULT 0,
              type INTEGER NOT NULL,
              ep INTEGER NOT NULL DEFAULT 1,
              page INTEGER NOT NULL DEFAULT 1,
              readEpisode TEXT NOT NULL DEFAULT '',
              max_page INTEGER,
              chapter_group INTEGER,
              sync_projection TEXT,
              read_duration_ms INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (id, type)
            );
          ''');
          // Use explicit defaults matching History.fromRow defaults for any legacy NULLs
          db.execute('''
            INSERT OR REPLACE INTO history_migrating (
              id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms, sync_projection
            )
            SELECT
              COALESCE(id, '') AS id,
              COALESCE(title, '') AS title,
              COALESCE(subtitle, '') AS subtitle,
              COALESCE(cover, '') AS cover,
              COALESCE(time, 0) AS time,
              COALESCE(type, 0) AS type,
              COALESCE(ep, 1) AS ep,
              COALESCE(page, 1) AS page,
              COALESCE(readEpisode, '') AS readEpisode,
              max_page,
              chapter_group,
              COALESCE(read_duration_ms, 0) AS read_duration_ms,
              sync_projection
            FROM history
            WHERE id IS NOT NULL AND id != ''
            ORDER BY time ASC;
          ''');
          db.execute('DROP TABLE history;');
          db.execute('ALTER TABLE history_migrating RENAME TO history;');
          db.execute('COMMIT;');
        } catch (_) {
          db.execute('ROLLBACK;');
          rethrow;
        }
      }
    }

    // 2. Ensure image_favorites table exists
    db.execute('''
      CREATE TABLE IF NOT EXISTS image_favorites (
        id TEXT,
        title TEXT NOT NULL,
        sub_title TEXT,
        author TEXT,
        tags TEXT,
        translated_tags TEXT,
        time INTEGER,
        max_page INTEGER,
        source_key TEXT NOT NULL,
        image_favorites_ep TEXT NOT NULL,
        other TEXT NOT NULL,
        PRIMARY KEY (id, source_key)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS image_favorites_sync_projection (
        record_key TEXT PRIMARY KEY,
        comic_id TEXT NOT NULL,
        source_key TEXT NOT NULL,
        logical_record TEXT NOT NULL,
        physical_record TEXT NOT NULL
      );
    ''');
  }

  /// Exports current database contents into [SyncRecords].
  static SyncRecords readSyncRecords(Database db) {
    ensureSchema(db);
    final SyncRecords records = {};

    // 1. Export history and historyChapter domains
    final historyRows = db.select(
      'SELECT id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms, sync_projection FROM history;',
    );

    for (final row in historyRows) {
      final id = row['id'] as String;
      final type = (row['type'] as num).toInt();
      final title = row['title'] as String? ?? '';
      final subtitle = row['subtitle'] as String? ?? '';
      final cover = row['cover'] as String? ?? '';
      final time = (row['time'] as num).toInt();
      final ep = (row['ep'] as num).toInt();
      final page = (row['page'] as num).toInt();
      final maxPage = (row['max_page'] as num?)?.toInt();
      final group = (row['chapter_group'] as num?)?.toInt();
      final readDurationMs = (row['read_duration_ms'] as num?)?.round() ?? 0;
      final readEpisodeStr = row['readEpisode'] as String? ?? '';
      final chapters =
          readEpisodeStr.split(',').where((s) => s.isNotEmpty).toList()..sort();

      // Export history record with atomic progress map.
      final histKey = syncRecordKey('history', [id, type]);
      final historyRecord = <String, Object?>{
        'title': title,
        'subtitle': subtitle,
        'cover': cover,
        'maxPage': maxPage,
        'readDurationMs': readDurationMs,
        'progress': {'ep': ep, 'page': page, 'group': group, 'time': time},
      };
      final syncProjection = row['sync_projection'] as String?;
      final projected = syncProjection == null
          ? null
          : jsonDecode(syncProjection);
      if (syncProjection != null && projected is! Map) {
        throw const FormatException('History projection must be an object');
      }
      if (syncProjection == null ||
          canonicalSyncJson(projected) != canonicalSyncJson(historyRecord)) {
        if (syncProjection != null) {
          db.execute(
            'UPDATE history SET sync_projection = NULL WHERE id = ? AND type = ?;',
            [id, type],
          );
        }
        records[histKey] = historyRecord;
      }

      // Export independent historyChapter records with retained comic metadata.
      // Excludes derived mutable parent timestamp to prevent touching all historical chapters.
      for (final chapter in chapters) {
        final chKey = syncRecordKey('historyChapter', [id, type, chapter]);
        records[chKey] = {
          'comicId': id,
          'typeValue': type,
          'chapter': chapter,
          'title': title,
          'subtitle': subtitle,
          'cover': cover,
          'maxPage': maxPage,
        };
      }
    }

    // 2. Export independent imageFavorite records
    final imageProjections = <String, Map<String, Object?>>{};
    for (final projectionRow in db.select(
      'SELECT record_key, logical_record, physical_record FROM image_favorites_sync_projection;',
    )) {
      imageProjections[projectionRow['record_key'] as String] = {
        'logical': Map<String, Object?>.from(
          jsonDecode(projectionRow['logical_record'] as String) as Map,
        ),
        'physical': Map<String, Object?>.from(
          jsonDecode(projectionRow['physical_record'] as String) as Map,
        ),
      };
    }
    final imgFavRows = db.select(
      'SELECT id, title, sub_title, author, tags, time, max_page, source_key, image_favorites_ep, other FROM image_favorites;',
    );

    final exportedImageKeys = <String>{};
    for (final row in imgFavRows) {
      final comicId = row['id'] as String;
      final sourceKey = row['source_key'] as String;
      final title = row['title'] as String? ?? '';
      final subTitle = row['sub_title'] as String? ?? '';
      final author = row['author'] as String? ?? '';
      final tags = (row['tags'] as String? ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toList();
      // NOTE: translated_tags is device-local derived presentation data and is excluded from sync records.
      final time = (row['time'] as num?)?.toInt() ?? 0;
      final maxPage = (row['max_page'] as num?)?.toInt();
      final other =
          jsonDecode(row['other'] as String? ?? '{}') as Map<String, dynamic>;

      final epsJson =
          jsonDecode(row['image_favorites_ep'] as String? ?? '[]') as List;
      for (final epItem in epsJson) {
        if (epItem is! Map) continue;
        final eid = (epItem['eid'] as String?) ?? '';
        final ep = (epItem['ep'] as num?)?.toInt() ?? 0;
        final epName = (epItem['epName'] as String?) ?? '';
        final epMaxPage = (epItem['maxPage'] as num?)?.toInt() ?? 1;
        final images = (epItem['imageFavorites'] as List?) ?? [];

        final epOrEid = eid.isNotEmpty ? eid : ep.toString();

        for (final imgItem in images) {
          if (imgItem is! Map) continue;
          final page = (imgItem['page'] as num?)?.toInt() ?? 0;
          final imageKey = (imgItem['imageKey'] as String?) ?? '';
          final isAutoFavorite = imgItem['isAutoFavorite'] as bool?;

          final imgRecordKey = syncRecordKey('imageFavorite', [
            comicId,
            sourceKey,
            epOrEid,
            page,
          ]);
          exportedImageKeys.add(imgRecordKey);

          final physicalRecord = <String, Object?>{
            'comicId': comicId,
            'sourceKey': sourceKey,
            'page': page,
            'imageKey': imageKey,
            if (isAutoFavorite != null) 'isAutoFavorite': isAutoFavorite,
            'eid': eid,
            'ep': ep,
            'epName': epName,
            'epMaxPage': epMaxPage,
            'title': title,
            'subTitle': subTitle,
            'author': author,
            'tags': tags,
            'time': time,
            'maxPage': maxPage,
            'other': other,
          };
          final projection = imageProjections[imgRecordKey];
          if (projection == null) {
            records[imgRecordKey] = physicalRecord;
          } else {
            final logicalRecord = _mergeImageFavoriteProjection(
              physicalRecord,
              projection['logical'] as Map<String, Object?>,
              projection['physical'] as Map<String, Object?>,
            );
            records[imgRecordKey] = logicalRecord;
            final physicalJson = canonicalSyncJson(physicalRecord);
            final logicalJson = canonicalSyncJson(logicalRecord);
            if (logicalJson == physicalJson) {
              db.execute(
                'DELETE FROM image_favorites_sync_projection WHERE record_key = ?;',
                [imgRecordKey],
              );
            } else if (logicalJson !=
                    canonicalSyncJson(projection['logical']) ||
                physicalJson != canonicalSyncJson(projection['physical'])) {
              db.execute(
                '''
                UPDATE image_favorites_sync_projection
                SET logical_record = ?, physical_record = ?
                WHERE record_key = ?;
                ''',
                [logicalJson, physicalJson, imgRecordKey],
              );
            }
          }
        }
      }
    }
    for (final recordKey in imageProjections.keys) {
      if (!exportedImageKeys.contains(recordKey)) {
        db.execute(
          'DELETE FROM image_favorites_sync_projection WHERE record_key = ?;',
          [recordKey],
        );
      }
    }

    return records;
  }

  /// Applies incoming [records] transactionally to [db].
  ///
  /// Compares records against existing database state to skip unchanged projections
  /// and returns a [HistorySyncApplyResult] indicating which domains were changed.
  static HistorySyncApplyResult applySyncRecords(
    Database db,
    SyncRecords records,
  ) {
    ensureSchema(db);

    db.execute('BEGIN IMMEDIATE;');
    try {
      final historyChanged = _applyHistoryRecords(db, records);
      final imageFavoritesChanged = _applyImageFavoriteRecords(db, records);
      db.execute('COMMIT;');
      return HistorySyncApplyResult(
        historyChanged: historyChanged,
        imageFavoritesChanged: imageFavoritesChanged,
      );
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  static bool _applyHistoryRecords(Database db, SyncRecords records) {
    bool changed = false;
    final historyMap = <String, Map<String, Object?>>{};
    final chaptersMap = <String, Map<String, Map<String, Object?>>>{};

    for (final entry in records.entries) {
      final domain = syncRecordDomain(entry.key);
      if (domain == 'history') {
        final idParts = syncRecordIdentity(entry.key);
        final comicId = idParts[0].toString();
        final typeVal = (idParts[1] as num).toInt();
        historyMap['$typeVal:$comicId'] = entry.value;
      } else if (domain == 'historyChapter') {
        final idParts = syncRecordIdentity(entry.key);
        final comicId = idParts[0].toString();
        final typeVal = (idParts[1] as num).toInt();
        final chapter = idParts[2].toString();
        final key = '$typeVal:$comicId';
        chaptersMap.putIfAbsent(key, () => {})[chapter] = entry.value;
      }
    }

    final survivingKeys = {...historyMap.keys, ...chaptersMap.keys};

    final existingRows = db.select(
      'SELECT id, type, title, subtitle, cover, max_page, read_duration_ms, ep, page, chapter_group, time, readEpisode, sync_projection FROM history;',
    );
    final existingMap = <String, Row>{};
    for (final row in existingRows) {
      final key = '${row['type']}:${row['id']}';
      existingMap[key] = row;
    }

    for (final key in survivingKeys) {
      final colonIdx = key.indexOf(':');
      final typeVal = int.parse(key.substring(0, colonIdx));
      final comicId = key.substring(colonIdx + 1);

      final histRecord = historyMap[key];
      final chapMap = chaptersMap[key] ?? {};
      final localRow = existingMap[key];

      String title = '';
      String subtitle = '';
      String cover = '';
      int? maxPage;
      int readDurationMs = 0;
      int ep = 1;
      int page = 1;
      int? group;
      int time = DateTime.now().millisecondsSinceEpoch;

      if (histRecord != null) {
        title = histRecord['title'] as String? ?? '';
        subtitle = histRecord['subtitle'] as String? ?? '';
        cover = histRecord['cover'] as String? ?? '';
        maxPage = (histRecord['maxPage'] as num?)?.toInt();
        readDurationMs = (histRecord['readDurationMs'] as num?)?.round() ?? 0;
        final progress = histRecord['progress'] as Map?;
        if (progress != null) {
          ep = (progress['ep'] as num?)?.toInt() ?? 1;
          page = (progress['page'] as num?)?.toInt() ?? 1;
          group = (progress['group'] as num?)?.toInt();
          time = (progress['time'] as num?)?.toInt() ?? time;
        }
      } else {
        // Parent deleted remotely, child added concurrently!
        final firstChapRecord = chapMap.values.first;
        title =
            firstChapRecord['title'] as String? ??
            (localRow?['title'] as String? ?? '');
        subtitle =
            firstChapRecord['subtitle'] as String? ??
            (localRow?['subtitle'] as String? ?? '');
        cover =
            firstChapRecord['cover'] as String? ??
            (localRow?['cover'] as String? ?? '');
        maxPage =
            (firstChapRecord['maxPage'] as num?)?.toInt() ??
            (localRow?['max_page'] as num?)?.toInt();
        readDurationMs = (localRow?['read_duration_ms'] as num?)?.round() ?? 0;
        time = (localRow?['time'] as num?)?.toInt() ?? time;

        if (localRow != null) {
          ep = (localRow['ep'] as num).toInt();
          page = (localRow['page'] as num).toInt();
          group = (localRow['chapter_group'] as num?)?.toInt();
        } else {
          final firstChapKey = chapMap.keys.first;
          ep = int.tryParse(firstChapKey.split('-').last) ?? 1;
          page = 1;
          group = firstChapKey.contains('-')
              ? int.tryParse(firstChapKey.split('-').first)
              : null;
        }
      }

      final chapterList = chapMap.keys.toList()..sort();
      final readEpisodeStr = chapterList.join(',');
      final syncProjection = histRecord == null
          ? canonicalSyncJson({
              'title': title,
              'subtitle': subtitle,
              'cover': cover,
              'maxPage': maxPage,
              'readDurationMs': readDurationMs,
              'progress': {
                'ep': ep,
                'page': page,
                'group': group,
                'time': time,
              },
            })
          : null;

      // Check whether existing row matches projection exactly
      if (localRow != null) {
        final matches =
            (localRow['title'] as String? ?? '') == title &&
            (localRow['subtitle'] as String? ?? '') == subtitle &&
            (localRow['cover'] as String? ?? '') == cover &&
            (localRow['time'] as num).toInt() == time &&
            (localRow['ep'] as num).toInt() == ep &&
            (localRow['page'] as num).toInt() == page &&
            (localRow['readEpisode'] as String? ?? '') == readEpisodeStr &&
            (localRow['max_page'] as num?)?.toInt() == maxPage &&
            (localRow['chapter_group'] as num?)?.toInt() == group &&
            (localRow['read_duration_ms'] as num?)?.round() == readDurationMs;

        if (matches) {
          if ((localRow['sync_projection'] as String?) != syncProjection) {
            db.execute(
              'UPDATE history SET sync_projection = ? WHERE id = ? AND type = ?;',
              [syncProjection, comicId, typeVal],
            );
          }
          continue; // Unchanged row projection: skip write
        }
      }

      db.execute(
        '''
        INSERT OR REPLACE INTO history (
          id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms, sync_projection
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      ''',
        [
          comicId,
          title,
          subtitle,
          cover,
          time,
          typeVal,
          ep,
          page,
          readEpisodeStr,
          maxPage,
          group,
          readDurationMs,
          syncProjection,
        ],
      );
      changed = true;
    }

    // Delete comics omitted from the incoming materialized view
    for (final existingKey in existingMap.keys) {
      if (!survivingKeys.contains(existingKey)) {
        final colonIdx = existingKey.indexOf(':');
        final typeVal = int.parse(existingKey.substring(0, colonIdx));
        final comicId = existingKey.substring(colonIdx + 1);
        db.execute('DELETE FROM history WHERE id = ? AND type = ?;', [
          comicId,
          typeVal,
        ]);
        changed = true;
      }
    }

    return changed;
  }

  static bool _applyImageFavoriteRecords(Database db, SyncRecords records) {
    bool changed = false;
    // Key by exact (comicId, sourceKey) tuple without delimiter guesswork
    final comicsMap = <(String, String), List<Map<String, Object?>>>{};

    for (final entry in records.entries) {
      if (syncRecordDomain(entry.key) != 'imageFavorite') continue;
      final idParts = syncRecordIdentity(entry.key);
      final comicId = idParts[0].toString();
      final sourceKey = idParts[1].toString();
      final key = (comicId, sourceKey);
      comicsMap.putIfAbsent(key, () => []).add(entry.value);
    }

    final existingRows = db.select(
      'SELECT id, source_key, title, sub_title, author, tags, translated_tags, time, max_page, image_favorites_ep, other FROM image_favorites;',
    );
    final existingMap = <(String, String), Row>{};
    for (final row in existingRows) {
      existingMap[(row['id'] as String, row['source_key'] as String)] = row;
    }

    for (final entry in comicsMap.entries) {
      final (comicId, sourceKey) = entry.key;
      final imgRecords = entry.value;
      if (imgRecords.isEmpty) continue;

      final localRow = existingMap[(comicId, sourceKey)];

      final title =
          _latestImageMetadataValue(imgRecords, 'title', localRow?['title'])
              as String? ??
          '';
      final subTitle =
          _latestImageMetadataValue(
                imgRecords,
                'subTitle',
                localRow?['sub_title'],
              )
              as String? ??
          '';
      final author =
          _latestImageMetadataValue(imgRecords, 'author', localRow?['author'])
              as String? ??
          '';
      final existingTags = (localRow?['tags'] as String? ?? '')
          .split(',')
          .where((tag) => tag.isNotEmpty)
          .toList();
      final tags =
          (_latestImageMetadataValue(imgRecords, 'tags', existingTags) as List?)
              ?.map((e) => e.toString())
              .toList() ??
          <String>[];
      final time =
          (_latestImageMetadataValue(imgRecords, 'time', localRow?['time'])
                  as num?)
              ?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      final maxPage =
          (_latestImageMetadataValue(
                    imgRecords,
                    'maxPage',
                    localRow?['max_page'],
                  )
                  as num?)
              ?.toInt();
      final existingOther = localRow == null
          ? <String, dynamic>{}
          : jsonDecode(localRow['other'] as String? ?? '{}') as Map;
      final other =
          (_latestImageMetadataValue(imgRecords, 'other', existingOther)
                  as Map?)
              ?.cast<String, dynamic>() ??
          <String, dynamic>{};

      // Preserve existing local translated_tags to avoid cross-device language overwrites
      final translatedTagsStr = localRow?['translated_tags'] as String? ?? '';

      // Group images by episode
      final epMap = <String, Map<String, dynamic>>{};
      for (final imgRec in imgRecords) {
        final ep = (imgRec['ep'] as num?)?.toInt() ?? 0;
        final eid = (imgRec['eid'] as String?) ?? '';
        final epName = (imgRec['epName'] as String?) ?? '';
        final epMaxPage = (imgRec['epMaxPage'] as num?)?.toInt() ?? 1;
        final page = (imgRec['page'] as num?)?.toInt() ?? 0;
        final imageKey = (imgRec['imageKey'] as String?) ?? '';
        final isAutoFavorite = imgRec['isAutoFavorite'] as bool?;

        final epGroupKey = eid.isNotEmpty ? eid : ep.toString();
        final epData = epMap.putIfAbsent(
          epGroupKey,
          () => {
            'eid': eid,
            'ep': ep,
            'epName': epName,
            'maxPage': epMaxPage,
            'images': <int, Map<String, dynamic>>{},
          },
        );

        (epData['images'] as Map<int, Map<String, dynamic>>)[page] = {
          'page': page,
          'imageKey': imageKey,
          if (isAutoFavorite != null) 'isAutoFavorite': isAutoFavorite,
        };
      }

      final finalEpList = <Map<String, dynamic>>[];
      for (final epData in epMap.values) {
        final imagesMap = epData['images'] as Map<int, Map<String, dynamic>>;
        final sortedImages = imagesMap.values.toList()
          ..sort((a, b) => (a['page'] as int).compareTo(b['page'] as int));

        finalEpList.add({
          'eid': epData['eid'],
          'ep': epData['ep'],
          'epName': epData['epName'],
          'maxPage': epData['maxPage'],
          'imageFavorites': sortedImages,
        });
      }
      finalEpList.sort((a, b) => (a['ep'] as int).compareTo(b['ep'] as int));

      if (finalEpList.isNotEmpty) {
        final epJsonStr = jsonEncode(finalEpList);
        final otherJsonStr = jsonEncode(other);
        final tagsStr = tags.join(',');

        if (localRow != null) {
          final matches =
              (localRow['title'] as String? ?? '') == title &&
              (localRow['sub_title'] as String? ?? '') == subTitle &&
              (localRow['author'] as String? ?? '') == author &&
              (localRow['tags'] as String? ?? '') == tagsStr &&
              (localRow['time'] as num?)?.toInt() == time &&
              (localRow['max_page'] as num?)?.toInt() == maxPage &&
              (localRow['image_favorites_ep'] as String? ?? '') == epJsonStr &&
              (localRow['other'] as String? ?? '') == otherJsonStr;

          if (matches) {
            _storeImageFavoriteProjections(
              db,
              comicId,
              sourceKey,
              imgRecords,
              epMap,
              title,
              subTitle,
              author,
              tags,
              time,
              maxPage,
              other,
            );
            continue; // Unchanged projection: skip write
          }
        }

        db.execute(
          '''
          INSERT OR REPLACE INTO image_favorites (
            id, title, sub_title, author, tags, translated_tags, time, max_page, source_key, image_favorites_ep, other
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          [
            comicId,
            title,
            subTitle,
            author,
            tagsStr,
            translatedTagsStr,
            time,
            maxPage,
            sourceKey,
            epJsonStr,
            otherJsonStr,
          ],
        );
        _storeImageFavoriteProjections(
          db,
          comicId,
          sourceKey,
          imgRecords,
          epMap,
          title,
          subTitle,
          author,
          tags,
          time,
          maxPage,
          other,
        );
        changed = true;
      } else {
        db.execute(
          'DELETE FROM image_favorites WHERE id = ? AND source_key = ?;',
          [comicId, sourceKey],
        );
        db.execute(
          'DELETE FROM image_favorites_sync_projection WHERE comic_id = ? AND source_key = ?;',
          [comicId, sourceKey],
        );
        changed = true;
      }
    }

    // Delete omitted image favorites
    for (final existingKey in existingMap.keys) {
      if (!comicsMap.containsKey(existingKey)) {
        final (comicId, sourceKey) = existingKey;
        db.execute(
          'DELETE FROM image_favorites WHERE id = ? AND source_key = ?;',
          [comicId, sourceKey],
        );
        db.execute(
          'DELETE FROM image_favorites_sync_projection WHERE comic_id = ? AND source_key = ?;',
          [comicId, sourceKey],
        );
        changed = true;
      }
    }

    return changed;
  }

  static void _storeImageFavoriteProjections(
    Database db,
    String comicId,
    String sourceKey,
    List<Map<String, Object?>> records,
    Map<String, Map<String, dynamic>> episodes,
    String title,
    String subTitle,
    String author,
    List<String> tags,
    int time,
    int? maxPage,
    Map<String, dynamic> other,
  ) {
    final existingProjections = {
      for (final row in db.select(
        'SELECT record_key, logical_record, physical_record '
        'FROM image_favorites_sync_projection WHERE comic_id = ? AND source_key = ?;',
        [comicId, sourceKey],
      ))
        row['record_key'] as String: row,
    };
    for (final logicalRecord in records) {
      final eid = logicalRecord['eid'] as String? ?? '';
      final ep = (logicalRecord['ep'] as num?)?.toInt() ?? 0;
      final epGroupKey = eid.isNotEmpty ? eid : ep.toString();
      final episode = episodes[epGroupKey]!;
      final page = (logicalRecord['page'] as num?)?.toInt() ?? 0;
      final image =
          (episode['images'] as Map<int, Map<String, dynamic>>)[page]!;
      final recordKey = syncRecordKey('imageFavorite', [
        comicId,
        sourceKey,
        (episode['eid'] as String).isNotEmpty
            ? episode['eid']
            : (episode['ep'] as int).toString(),
        page,
      ]);
      final existing = existingProjections.remove(recordKey);
      final physicalRecord = <String, Object?>{
        'comicId': comicId,
        'sourceKey': sourceKey,
        'page': page,
        'imageKey': image['imageKey'],
        if (image['isAutoFavorite'] != null)
          'isAutoFavorite': image['isAutoFavorite'],
        'eid': episode['eid'],
        'ep': episode['ep'],
        'epName': episode['epName'],
        'epMaxPage': episode['maxPage'],
        'title': title,
        'subTitle': subTitle,
        'author': author,
        'tags': tags,
        'time': time,
        'maxPage': maxPage,
        'other': other,
      };
      final logicalJson = canonicalSyncJson(logicalRecord);
      final physicalJson = canonicalSyncJson(physicalRecord);
      if (logicalJson == physicalJson) {
        if (existing != null) {
          db.execute(
            'DELETE FROM image_favorites_sync_projection WHERE record_key = ?;',
            [recordKey],
          );
        }
      } else if (existing == null ||
          existing['logical_record'] != logicalJson ||
          existing['physical_record'] != physicalJson) {
        db.execute(
          '''
          INSERT OR REPLACE INTO image_favorites_sync_projection (
            record_key, comic_id, source_key, logical_record, physical_record
          ) VALUES (?, ?, ?, ?, ?);
          ''',
          [recordKey, comicId, sourceKey, logicalJson, physicalJson],
        );
      }
    }

    for (final recordKey in existingProjections.keys) {
      db.execute(
        'DELETE FROM image_favorites_sync_projection WHERE record_key = ?;',
        [recordKey],
      );
    }
  }
}

Map<String, Object?> _mergeImageFavoriteProjection(
  Map<String, Object?> physical,
  Map<String, Object?> logical,
  Map<String, Object?> previousPhysical,
) {
  final merged = <String, Object?>{};
  final fields = {...physical.keys, ...logical.keys, ...previousPhysical.keys};
  for (final field in fields) {
    final physicalHasField = physical.containsKey(field);
    final previousHasField = previousPhysical.containsKey(field);
    final unchanged =
        physicalHasField == previousHasField &&
        (!physicalHasField ||
            syncValuesEqual(physical[field], previousPhysical[field]));
    if (unchanged) {
      if (logical.containsKey(field)) merged[field] = logical[field];
    } else if (physicalHasField) {
      merged[field] = physical[field];
    }
  }
  return merged;
}

Object? _latestImageMetadataValue(
  List<Map<String, Object?>> records,
  String field,
  Object? fallback,
) {
  Map<String, Object?>? selected;
  var selectedTime = 0;
  for (final record in records) {
    if (!record.containsKey(field)) continue;
    final recordTime = (record['time'] as num?)?.toInt() ?? 0;
    if (selected == null ||
        recordTime > selectedTime ||
        (recordTime == selectedTime &&
            _compareImageIdentity(record, selected) < 0)) {
      selected = record;
      selectedTime = recordTime;
    }
  }
  return selected == null ? fallback : selected[field];
}

int _compareImageIdentity(Map<String, Object?> a, Map<String, Object?> b) {
  final eid = (a['eid'] as String? ?? '').compareTo(b['eid'] as String? ?? '');
  if (eid != 0) return eid;
  final ep = ((a['ep'] as num?)?.toInt() ?? 0).compareTo(
    (b['ep'] as num?)?.toInt() ?? 0,
  );
  if (ep != 0) return ep;
  return ((a['page'] as num?)?.toInt() ?? 0).compareTo(
    (b['page'] as num?)?.toInt() ?? 0,
  );
}

/// Feature-namespaced standalone reader for legacy sync migration and headless execution.
SyncRecords readHistorySyncRecords(Database db) =>
    HistorySyncData.readSyncRecords(db);

/// Feature-namespaced standalone applier for headless execution.
HistorySyncApplyResult applyHistorySyncRecords(
  Database db,
  SyncRecords records,
) => HistorySyncData.applySyncRecords(db, records);

/// Feature-namespaced schema helper.
void ensureHistorySchema(Database db) => HistorySyncData.ensureSchema(db);
