import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/sync_records.dart';

/// Escapes a SQL identifier (such as a table or column name) by enclosing it
/// in double quotes and doubling any embedded double quotes.
String quoteSqlIdentifier(String name) {
  return '"${name.replaceAll('"', '""')}"';
}

/// Internal tables in local_favorite.db that must never be treated as favorites.
const internalFavoriteTables = <String>{
  'folder_order',
  'folder_sync',
  'folder_metadata',
  'android_metadata',
};

/// Returns true if the table name is an internal SQLite or metadata table.
bool isInternalFavoriteTable(String name) {
  return name.startsWith('sqlite_') || internalFavoriteTables.contains(name);
}

/// Metadata record for a favorite folder in SQLite.
class FolderMetadataRecord {
  final String folderId;
  final String folderName;
  final String logicalName;
  final int orderValue;
  final String? sourceKey;
  final String? sourceFolder;

  const FolderMetadataRecord({
    required this.folderId,
    required this.folderName,
    required this.logicalName,
    this.orderValue = 0,
    this.sourceKey,
    this.sourceFolder,
  });

  Map<String, Object?> toMap() => {
    'folder_id': folderId,
    'folder_name': folderName,
    'logical_name': logicalName,
    'order_value': orderValue,
    'source_key': sourceKey,
    'source_folder': sourceFolder,
  };
}

/// Result of applying sync records to the favorites SQLite database.
class FavoriteApplyResult {
  final bool changed;
  final bool readingFolderChanged;
  final String? newReadingFolderId;
  final String? newReadingFolderName;
  final Set<String> affectedFolderNames;

  const FavoriteApplyResult({
    required this.changed,
    required this.readingFolderChanged,
    this.newReadingFolderId,
    this.newReadingFolderName,
    required this.affectedFolderNames,
  });
}

/// Pure Dart SQLite helpers and DTOs for favorite sync records.
///
/// Contains zero dependencies on Flutter or App data to enable offline
/// verification and standalone migration tools.
class FavoriteSyncData {
  const FavoriteSyncData._();

  /// Ensures that a folder table in [db] has all expected columns, adding any
  /// missing columns if it was created by an older version of the app.
  static void ensureFolderTableSchema(Database db, String tableName) {
    final quoted = quoteSqlIdentifier(tableName);
    final columns = db.select('PRAGMA table_info($quoted);');
    final colNames = columns.map((c) => c['name'] as String).toSet();

    if (!colNames.contains('last_update_time')) {
      db.execute('ALTER TABLE $quoted ADD COLUMN last_update_time TEXT;');
    }
    if (!colNames.contains('has_new_update')) {
      db.execute(
        'ALTER TABLE $quoted ADD COLUMN has_new_update INT DEFAULT 0;',
      );
    }
    if (!colNames.contains('last_check_time')) {
      db.execute('ALTER TABLE $quoted ADD COLUMN last_check_time INT;');
    }
    if (!colNames.contains('translated_tags')) {
      db.execute('ALTER TABLE $quoted ADD COLUMN translated_tags TEXT;');
    }
  }

  /// Ensures metadata tables exist and seeds any unseeded legacy folder tables.
  ///
  /// Protects against collision if a legacy user folder was named 'folder_metadata'.
  static void ensureFolderMetadataTable(Database db) {
    // If a table named 'folder_metadata' already exists, verify whether it is
    // our internal metadata table (has column 'folder_id') or a legacy user folder.
    final existingMetaCheck = db.select(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='folder_metadata';",
    );
    if (existingMetaCheck.isNotEmpty) {
      final pragma = db.select('PRAGMA table_info("folder_metadata");');
      final hasFolderId = pragma.any((col) => col['name'] == 'folder_id');
      if (!hasFolderId) {
        // Legacy user folder named 'folder_metadata'. Rename it to avoid overwriting user data.
        var migratedName = 'folder_metadata (2)';
        var i = 3;
        while (db.select(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?;",
          [migratedName],
        ).isNotEmpty) {
          migratedName = 'folder_metadata ($i)';
          i++;
        }
        db.execute(
          'ALTER TABLE "folder_metadata" RENAME TO ${quoteSqlIdentifier(migratedName)};',
        );
      }
    }

    db.execute('''
      CREATE TABLE IF NOT EXISTS folder_order (
        folder_name TEXT PRIMARY KEY,
        order_value INT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS folder_sync (
        folder_name TEXT PRIMARY KEY,
        source_key TEXT,
        source_folder TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS folder_metadata (
        folder_id TEXT PRIMARY KEY,
        folder_name TEXT UNIQUE,
        logical_name TEXT,
        order_value INT DEFAULT 0,
        source_key TEXT,
        source_folder TEXT
      );
    ''');

    final tableRows = db.select(
      "SELECT name FROM sqlite_master WHERE type='table';",
    );
    final userTables = <String>{};
    for (final row in tableRows) {
      final name = row['name'] as String;
      if (!isInternalFavoriteTable(name)) {
        userTables.add(name);
      }
    }

    final metadataRows = db.select(
      'SELECT folder_id, folder_name FROM folder_metadata;',
    );
    final existingFolders = <String, String>{};
    for (final row in metadataRows) {
      final physicalName = row['folder_name'] as String;
      final folderId = row['folder_id'] as String;
      if (userTables.contains(physicalName)) {
        existingFolders[physicalName] = folderId;
      }
    }

    for (final table in userTables) {
      if (!existingFolders.containsKey(table)) {
        final seededId = legacySyncFolderId(table);
        final orderRows = db.select(
          'SELECT order_value FROM folder_order WHERE folder_name = ?;',
          [table],
        );
        final order = orderRows.isNotEmpty
            ? (orderRows.first['order_value'] as int? ?? 0)
            : 0;

        final syncRows = db.select(
          'SELECT source_key, source_folder FROM folder_sync WHERE folder_name = ?;',
          [table],
        );
        final sourceKey = syncRows.isNotEmpty
            ? syncRows.first['source_key'] as String?
            : null;
        final sourceFolder = syncRows.isNotEmpty
            ? syncRows.first['source_folder'] as String?
            : null;

        db.execute(
          '''
          INSERT OR REPLACE INTO folder_metadata (folder_id, folder_name, logical_name, order_value, source_key, source_folder)
          VALUES (?, ?, ?, ?, ?, ?);
        ''',
          [seededId, table, table, order, sourceKey, sourceFolder],
        );
        existingFolders[table] = seededId;
      }
    }
  }

  /// Exports sync records for all folders and favorite comics in [db].
  ///
  /// Uses canonical 'title' and 'cover' fields only (no redundant aliases).
  /// Excludes `last_check_time`, derived `translated_tags`, and local caches.
  /// If [readingFolderId] is provided, exports `favoriteRole ['reading']`.
  static SyncRecords readSyncRecords(Database db, {String? readingFolderId}) {
    ensureFolderMetadataTable(db);
    final records = <String, Map<String, Object?>>{};

    final folderRows = db.select('''
      SELECT folder_id, folder_name, logical_name, order_value, source_key, source_folder
      FROM folder_metadata
      ORDER BY order_value, folder_id;
    ''');

    for (final fRow in folderRows) {
      final folderId = fRow['folder_id'] as String;
      final physicalName = fRow['folder_name'] as String;
      final logicalName = fRow['logical_name'] as String? ?? physicalName;
      final orderValue = fRow['order_value'] as int? ?? 0;
      final sourceKey = fRow['source_key'] as String?;
      final sourceFolder = fRow['source_folder'] as String?;

      records[syncRecordKey('folder', [folderId])] = {
        'name': logicalName,
        'order': orderValue,
        if (sourceKey != null) 'sourceKey': sourceKey,
        if (sourceFolder != null) 'sourceFolder': sourceFolder,
      };

      final tableExists = db.select(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?;",
        [physicalName],
      ).isNotEmpty;
      if (!tableExists) continue;

      // Ensure all expected columns exist before query (handles legacy tables)
      ensureFolderTableSchema(db, physicalName);

      final quotedPhysical = quoteSqlIdentifier(physicalName);
      final comicRows = db.select('''
        SELECT id, type, name, author, tags, cover_path, time, display_order, last_update_time, has_new_update
        FROM $quotedPhysical
        ORDER BY display_order;
      ''');

      for (final cRow in comicRows) {
        final comicId = cRow['id'] as String;
        final comicType = cRow['type'] as int;
        final title = cRow['name'] as String? ?? '';
        final author = cRow['author'] as String? ?? '';
        final coverPath = cRow['cover_path'] as String? ?? '';
        final tagsStr = cRow['tags'] as String? ?? '';
        final tags = tagsStr.split(',').where((t) => t.isNotEmpty).toList();
        final time = cRow['time'] as String? ?? '';
        final displayOrder = cRow['display_order'] as int? ?? 0;
        final lastUpdateTime = cRow['last_update_time'] as String?;
        final hasNewUpdate = (cRow['has_new_update'] as int? ?? 0) == 1;

        // Canonical fields ONLY: 'title' and 'cover'
        records[syncRecordKey('favorite', [folderId, comicId, comicType])] = {
          'title': title,
          'author': author,
          'cover': coverPath,
          'tags': tags,
          'time': time,
          'displayOrder': displayOrder,
          if (lastUpdateTime != null) 'lastUpdateTime': lastUpdateTime,
          'hasNewUpdate': hasNewUpdate,
        };
      }
    }

    if (readingFolderId != null) {
      records[syncRecordKey('favoriteRole', ['reading'])] = {
        'folderId': readingFolderId,
      };
    }

    return records;
  }

  /// Assigns deterministic local physical table names for folders.
  ///
  /// Reserves internal metadata and sqlite names.
  /// Disambiguates collisions when multiple folders share the same logical name,
  /// preserving both folders while preferring existing physical names where possible.
  static Map<String, String> assignPhysicalNames({
    required List<FolderMetadataRecord> folders,
    Map<String, String> existingPhysicalNames = const {},
  }) {
    final result = <String, String>{};
    final usedNames = <String>{...internalFavoriteTables};

    final sortedFolders = List<FolderMetadataRecord>.from(folders)
      ..sort((a, b) {
        final cmp = a.orderValue.compareTo(b.orderValue);
        if (cmp != 0) return cmp;
        return a.folderId.compareTo(b.folderId);
      });

    // Pass 1: Keep existing physical names if they match the logical name and have no collision.
    for (final folder in sortedFolders) {
      final existing = existingPhysicalNames[folder.folderId];
      if (existing != null &&
          !isInternalFavoriteTable(existing) &&
          !existing.startsWith('__tmp_') &&
          (existing == folder.logicalName ||
              existing.startsWith('${folder.logicalName} (')) &&
          !usedNames.contains(existing)) {
        result[folder.folderId] = existing;
        usedNames.add(existing);
      }
    }

    // Pass 2: Assign names for remaining folders deterministically.
    for (final folder in sortedFolders) {
      if (result.containsKey(folder.folderId)) continue;

      final base = folder.logicalName.trim().isNotEmpty
          ? folder.logicalName.trim()
          : 'Untitled';
      if (!isInternalFavoriteTable(base) &&
          !base.startsWith('__tmp_') &&
          !usedNames.contains(base)) {
        result[folder.folderId] = base;
        usedNames.add(base);
      } else {
        var counter = 2;
        while (isInternalFavoriteTable('$base ($counter)') ||
            usedNames.contains('$base ($counter)')) {
          counter++;
        }
        final assigned = '$base ($counter)';
        result[folder.folderId] = assigned;
        usedNames.add(assigned);
      }
    }

    return result;
  }

  /// Transactionally applies [records] to [db].
  ///
  /// Handles:
  /// - Folder rename, deletion, recreation, and deterministic disambiguation.
  /// - Two-phase table rename to handle name swaps (A <-> B) without SQLite collision.
  /// - Escapes all SQLite identifiers against injection and quotes.
  /// - Survives concurrent folder deletion when alive favorites exist (revives folder metadata).
  /// - Updates items per record without wiping DB or touching unrelated tables.
  /// - Preserves local `translated_tags` and `last_check_time`.
  /// - Materialized view absence of `favoriteRole ['reading']` clears reading role.
  static FavoriteApplyResult applyFavoriteSyncRecords(
    Database db,
    SyncRecords records, {
    String? currentReadingFolderId,
  }) {
    ensureFolderMetadataTable(db);

    final incomingFolders = <String, Map<String, Object?>>{};
    final incomingFavorites =
        <String, List<(String, int, Map<String, Object?>)>>{};
    String? incomingReadingFolderId;
    var hasIncomingReadingRole = false;

    for (final entry in records.entries) {
      final key = entry.key;
      final fields = entry.value;
      final decoded = decodeSyncRecordKey(key);
      if (decoded.isEmpty) continue;
      final domain = decoded[0] as String;

      if (domain == 'folder') {
        if (decoded.length >= 2) {
          final folderId = decoded[1].toString();
          incomingFolders[folderId] = fields;
        }
      } else if (domain == 'favorite') {
        if (decoded.length >= 4) {
          final folderId = decoded[1].toString();
          final comicId = decoded[2].toString();
          final type = decoded[3] is int
              ? decoded[3] as int
              : int.tryParse(decoded[3].toString()) ?? 0;
          incomingFavorites.putIfAbsent(folderId, () => []).add((
            comicId,
            type,
            fields,
          ));
        }
      } else if (domain == 'favoriteRole') {
        if (decoded.length >= 2 && decoded[1] == 'reading') {
          hasIncomingReadingRole = true;
          incomingReadingFolderId = fields['folderId'] as String?;
        }
      }
    }

    // Query current local state in DB.
    final localMetadataRows = db.select('''
      SELECT folder_id, folder_name, logical_name, order_value, source_key, source_folder
      FROM folder_metadata;
    ''');
    final localFoldersById = <String, FolderMetadataRecord>{};
    final localPhysicalByFolderId = <String, String>{};
    for (final row in localMetadataRows) {
      final folderId = row['folder_id'] as String;
      final physicalName = row['folder_name'] as String;
      final logicalName = row['logical_name'] as String? ?? physicalName;
      final orderVal = row['order_value'] as int? ?? 0;
      final srcKey = row['source_key'] as String?;
      final srcFolder = row['source_folder'] as String?;
      final meta = FolderMetadataRecord(
        folderId: folderId,
        folderName: physicalName,
        logicalName: logicalName,
        orderValue: orderVal,
        sourceKey: srcKey,
        sourceFolder: srcFolder,
      );
      localFoldersById[folderId] = meta;
      localPhysicalByFolderId[folderId] = physicalName;
    }

    // Revive metadata for any folder that has alive favorites but was omitted from incomingFolders.
    for (final folderId in incomingFavorites.keys) {
      if (!incomingFolders.containsKey(folderId)) {
        final existing = localFoldersById[folderId];
        if (existing != null) {
          incomingFolders[folderId] = {
            'name': existing.logicalName,
            'order': existing.orderValue,
            if (existing.sourceKey != null) 'sourceKey': existing.sourceKey,
            if (existing.sourceFolder != null)
              'sourceFolder': existing.sourceFolder,
          };
        } else {
          final prefix = folderId.length > 8
              ? folderId.substring(0, 8)
              : folderId;
          incomingFolders[folderId] = {'name': 'Folder $prefix', 'order': 0};
        }
      }
    }

    // Prepare folder records for disambiguation.
    final candidateFolders = <FolderMetadataRecord>[];
    for (final entry in incomingFolders.entries) {
      final folderId = entry.key;
      final fields = entry.value;
      final name = (fields['name'] as String?)?.trim().isNotEmpty == true
          ? (fields['name'] as String).trim()
          : 'Untitled';
      final orderVal = fields['order'] is num
          ? (fields['order'] as num).toInt()
          : 0;
      final srcKey = fields['sourceKey'] as String?;
      final srcFolder = fields['sourceFolder'] as String?;

      candidateFolders.add(
        FolderMetadataRecord(
          folderId: folderId,
          folderName: '', // to be assigned
          logicalName: name,
          orderValue: orderVal,
          sourceKey: srcKey,
          sourceFolder: srcFolder,
        ),
      );
    }

    final assignedPhysicalNames = assignPhysicalNames(
      folders: candidateFolders,
      existingPhysicalNames: localPhysicalByFolderId,
    );

    var changed = false;
    final affectedFolders = <String>{};

    db.execute('BEGIN TRANSACTION');
    try {
      // 1. Delete omitted folders (folders in localFoldersById but not in incomingFolders).
      for (final local in localFoldersById.values) {
        if (!incomingFolders.containsKey(local.folderId)) {
          final tableName = local.folderName;
          db.execute('DROP TABLE IF EXISTS ${quoteSqlIdentifier(tableName)};');
          db.execute('DELETE FROM folder_metadata WHERE folder_id = ?;', [
            local.folderId,
          ]);
          db.execute('DELETE FROM folder_order WHERE folder_name = ?;', [
            tableName,
          ]);
          db.execute('DELETE FROM folder_sync WHERE folder_name = ?;', [
            tableName,
          ]);
          changed = true;
          affectedFolders.add(tableName);
        }
      }

      // 2. Synchronize alive folders with Two-Phase Renaming:
      // Phase 1: Rename old physical tables that must change into unique temporary names
      // to avoid collision on name swaps (e.g. A <-> B).
      final tempPhysicalByFolderId = <String, String>{};
      for (final candidate in candidateFolders) {
        final folderId = candidate.folderId;
        final targetPhysicalName = assignedPhysicalNames[folderId]!;
        final existing = localFoldersById[folderId];

        if (existing != null && existing.folderName != targetPhysicalName) {
          final oldPhysical = existing.folderName;
          final oldTableExists = db.select(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?;",
            [oldPhysical],
          ).isNotEmpty;

          if (oldTableExists) {
            final sanitizedId = folderId.replaceAll(
              RegExp(r'[^a-zA-Z0-9]'),
              '_',
            );
            final tempPhysical =
                '__tmp_fav_${sanitizedId}_${DateTime.now().microsecondsSinceEpoch}';
            db.execute(
              'ALTER TABLE ${quoteSqlIdentifier(oldPhysical)} RENAME TO ${quoteSqlIdentifier(tempPhysical)};',
            );
            tempPhysicalByFolderId[folderId] = tempPhysical;
          }
          db.execute('DELETE FROM folder_order WHERE folder_name = ?;', [
            oldPhysical,
          ]);
          db.execute('DELETE FROM folder_sync WHERE folder_name = ?;', [
            oldPhysical,
          ]);
          changed = true;
          affectedFolders.add(oldPhysical);
          affectedFolders.add(targetPhysicalName);
        }
      }

      // Phase 2: Move from temporary name to targetPhysicalName, or create new table.
      for (final candidate in candidateFolders) {
        final folderId = candidate.folderId;
        final logicalName = candidate.logicalName;
        final orderValue = candidate.orderValue;
        final sourceKey = candidate.sourceKey;
        final sourceFolder = candidate.sourceFolder;
        final targetPhysicalName = assignedPhysicalNames[folderId]!;
        final existing = localFoldersById[folderId];

        if (tempPhysicalByFolderId.containsKey(folderId)) {
          final tempName = tempPhysicalByFolderId[folderId]!;
          db.execute(
            'ALTER TABLE ${quoteSqlIdentifier(tempName)} RENAME TO ${quoteSqlIdentifier(targetPhysicalName)};',
          );
        } else {
          final tableExists = db.select(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?;",
            [targetPhysicalName],
          ).isNotEmpty;
          if (!tableExists) {
            _createFolderTable(db, targetPhysicalName);
            changed = true;
            affectedFolders.add(targetPhysicalName);
          }
        }

        // Ensure schema has all columns (for legacy databases)
        ensureFolderTableSchema(db, targetPhysicalName);

        // Check if metadata changed.
        if (existing == null ||
            existing.folderName != targetPhysicalName ||
            existing.logicalName != logicalName ||
            existing.orderValue != orderValue ||
            existing.sourceKey != sourceKey ||
            existing.sourceFolder != sourceFolder) {
          db.execute(
            '''
            INSERT OR REPLACE INTO folder_metadata (folder_id, folder_name, logical_name, order_value, source_key, source_folder)
            VALUES (?, ?, ?, ?, ?, ?);
          ''',
            [
              folderId,
              targetPhysicalName,
              logicalName,
              orderValue,
              sourceKey,
              sourceFolder,
            ],
          );
          db.execute(
            '''
            INSERT OR REPLACE INTO folder_order (folder_name, order_value)
            VALUES (?, ?);
          ''',
            [targetPhysicalName, orderValue],
          );

          if (sourceKey != null) {
            db.execute(
              '''
              INSERT OR REPLACE INTO folder_sync (folder_name, source_key, source_folder)
              VALUES (?, ?, ?);
            ''',
              [targetPhysicalName, sourceKey, sourceFolder],
            );
          } else {
            db.execute('DELETE FROM folder_sync WHERE folder_name = ?;', [
              targetPhysicalName,
            ]);
          }
          changed = true;
          affectedFolders.add(targetPhysicalName);
        }

        // 3. Synchronize favorite items in this folder.
        final incomingItems = incomingFavorites[folderId] ?? [];
        final incomingKeys = <(String, int)>{};
        for (final item in incomingItems) {
          incomingKeys.add((item.$1, item.$2));
        }

        final quotedPhysical = quoteSqlIdentifier(targetPhysicalName);
        final existingRows = db.select('''
          SELECT id, type, name, author, tags, cover_path, time, display_order, last_update_time, has_new_update, translated_tags, last_check_time
          FROM $quotedPhysical;
        ''');
        final existingMap = <(String, int), Row>{};
        for (final row in existingRows) {
          existingMap[(row['id'] as String, row['type'] as int)] = row;
        }

        // Delete omitted items.
        for (final existingKey in existingMap.keys) {
          if (!incomingKeys.contains(existingKey)) {
            db.execute(
              'DELETE FROM $quotedPhysical WHERE id = ? AND type = ?;',
              [existingKey.$1, existingKey.$2],
            );
            changed = true;
            affectedFolders.add(targetPhysicalName);
          }
        }

        // Upsert incoming items.
        for (final item in incomingItems) {
          final comicId = item.$1;
          final comicType = item.$2;
          final fields = item.$3;

          final title =
              (fields['title'] as String?) ?? (fields['name'] as String?) ?? '';
          final author = fields['author'] as String? ?? '';
          final cover =
              (fields['cover'] as String?) ??
              (fields['coverPath'] as String?) ??
              '';
          final rawTags = fields['tags'];
          final List<String> tagsList;
          if (rawTags is List) {
            tagsList = rawTags.map((e) => e.toString()).toList();
          } else if (rawTags is String) {
            tagsList = rawTags.split(',').where((e) => e.isNotEmpty).toList();
          } else {
            tagsList = [];
          }
          final tags = tagsList.join(',');
          final time = fields['time'] as String? ?? '';
          final displayOrder = fields['displayOrder'] is num
              ? (fields['displayOrder'] as num).toInt()
              : 0;
          final lastUpdateTime = fields['lastUpdateTime'] as String?;
          final hasNewUpdate = fields['hasNewUpdate'] == true ? 1 : 0;

          final existingRow = existingMap[(comicId, comicType)];
          if (existingRow == null) {
            db.execute(
              '''
              INSERT INTO $quotedPhysical (id, name, author, type, tags, cover_path, time, display_order, translated_tags, last_update_time, has_new_update, last_check_time)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            ''',
              [
                comicId,
                title,
                author,
                comicType,
                tags,
                cover,
                time,
                displayOrder,
                null,
                lastUpdateTime,
                hasNewUpdate,
                null,
              ],
            );
            changed = true;
            affectedFolders.add(targetPhysicalName);
          } else {
            final oldTitle = existingRow['name'] as String? ?? '';
            final oldAuthor = existingRow['author'] as String? ?? '';
            final oldCover = existingRow['cover_path'] as String? ?? '';
            final oldTags = existingRow['tags'] as String? ?? '';
            final oldTime = existingRow['time'] as String? ?? '';
            final oldOrder = existingRow['display_order'] as int? ?? 0;
            final oldUpdateTime = existingRow['last_update_time'] as String?;
            final oldHasNew = (existingRow['has_new_update'] as int? ?? 0) == 1
                ? 1
                : 0;

            if (oldTitle != title ||
                oldAuthor != author ||
                oldCover != cover ||
                oldTags != tags ||
                oldTime != time ||
                oldOrder != displayOrder ||
                oldUpdateTime != lastUpdateTime ||
                oldHasNew != hasNewUpdate) {
              db.execute(
                '''
                UPDATE $quotedPhysical
                SET name = ?, author = ?, cover_path = ?, tags = ?, time = ?, display_order = ?, last_update_time = ?, has_new_update = ?
                WHERE id = ? AND type = ?;
              ''',
                [
                  title,
                  author,
                  cover,
                  tags,
                  time,
                  displayOrder,
                  lastUpdateTime,
                  hasNewUpdate,
                  comicId,
                  comicType,
                ],
              );
              changed = true;
              affectedFolders.add(targetPhysicalName);
            }
          }
        }
      }

      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      rethrow;
    }

    // 4. Handle favoriteRole ['reading'].
    // In full materialized view, absence of favoriteRole ['reading'] clears the role!
    String? newReadingFolderId;
    String? newReadingFolderName;
    var readingFolderChanged = false;

    if (hasIncomingReadingRole && incomingReadingFolderId != null) {
      if (assignedPhysicalNames.containsKey(incomingReadingFolderId)) {
        newReadingFolderId = incomingReadingFolderId;
        newReadingFolderName = assignedPhysicalNames[incomingReadingFolderId];
      }
    } else {
      // Cleared / deleted in materialized view
      newReadingFolderId = null;
      newReadingFolderName = null;
    }

    final previousPhysical = currentReadingFolderId != null
        ? localPhysicalByFolderId[currentReadingFolderId]
        : null;

    if (newReadingFolderId != currentReadingFolderId ||
        newReadingFolderName != previousPhysical) {
      readingFolderChanged = true;
    }

    return FavoriteApplyResult(
      changed: changed,
      readingFolderChanged: readingFolderChanged,
      newReadingFolderId: newReadingFolderId,
      newReadingFolderName: newReadingFolderName,
      affectedFolderNames: affectedFolders,
    );
  }

  static void _createFolderTable(Database db, String name) {
    final quoted = quoteSqlIdentifier(name);
    db.execute('''
      CREATE TABLE IF NOT EXISTS $quoted(
        id TEXT,
        name TEXT,
        author TEXT,
        type INT,
        tags TEXT,
        cover_path TEXT,
        time TEXT,
        display_order INT,
        translated_tags TEXT,
        last_update_time TEXT,
        has_new_update INT DEFAULT 0,
        last_check_time INT,
        PRIMARY KEY (id, type)
      );
    ''');
  }
}
