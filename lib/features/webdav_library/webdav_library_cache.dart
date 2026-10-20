import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';

const webDavLibrarySnapshotFormatVersion = 8;

class WebDavLibraryCachedComic {
  const WebDavLibraryCachedComic({
    required this.id,
    required this.sortIndex,
    required this.title,
    required this.author,
    required this.tags,
    required this.cover,
    required this.snapshot,
    required this.remoteETag,
    required this.remoteModifiedAt,
  });

  factory WebDavLibraryCachedComic.fromRow(Row row) {
    final tags = jsonDecode(row['tags'] as String);
    final snapshotText = row['snapshot_json'] as String?;
    return WebDavLibraryCachedComic(
      id: row['id'] as String,
      sortIndex: row['sort_index'] as int,
      title: row['title'] as String,
      author: row['author'] as String,
      tags: tags is List ? tags.whereType<String>().toList() : const [],
      cover: row['cover'] as String,
      snapshot: snapshotText == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(snapshotText) as Map),
      remoteETag: row['remote_etag'] as String?,
      remoteModifiedAt: row['remote_modified_at'] as int?,
    );
  }

  final String id;
  final int sortIndex;
  final String title;
  final String author;
  final List<String> tags;
  final String cover;
  final Map<String, dynamic>? snapshot;
  final String? remoteETag;
  final int? remoteModifiedAt;

  bool get isReady =>
      snapshot?['formatVersion'] == webDavLibrarySnapshotFormatVersion;
  bool shouldRetryMetadataScrape({
    required String scraperVersion,
    required int now,
  }) {
    if (!isReady || snapshot?['metadataFilePresent'] == true) return false;
    if (snapshot?['metadataScraperVersion'] != scraperVersion) return true;
    final status = snapshot?['metadataScrapeStatus'];
    if (status == 'pending') return true;
    if (status != 'failed') return false;
    final retryAt = snapshot?['metadataScrapeRetryAt'];
    return retryAt is! int || retryAt <= now;
  }

  bool hasSameRemoteVersion({String? eTag, int? modifiedAt}) {
    final hasVersion = (eTag?.isNotEmpty ?? false) || modifiedAt != null;
    if (!hasVersion) return false;
    return remoteETag == eTag && remoteModifiedAt == modifiedAt;
  }
}

class WebDavLibraryRemoteDirectory {
  const WebDavLibraryRemoteDirectory({
    required this.id,
    required this.sortIndex,
    this.eTag,
    this.modifiedAt,
  });

  final String id;
  final int sortIndex;
  final String? eTag;
  final int? modifiedAt;
}

/// The result of discovering one configured recognition directory.
///
/// `id` is intentionally the complete remote comic path for new libraries.
/// It is therefore independent of the directory through which it was found;
/// selecting both a parent and one of its children cannot create two comics.
class WebDavLibraryRootIndex {
  const WebDavLibraryRootIndex({
    required this.rootPath,
    required this.directories,
  });

  final String rootPath;
  final List<WebDavLibraryRemoteDirectory> directories;
}

class WebDavLibraryCache {
  WebDavLibraryCache._();

  static final instance = WebDavLibraryCache._();

  Database? _db;
  String? _dbPath;

  Database get _database {
    final path = '${App.dataPath}/webdav_library.db';
    if (_db != null && _dbPath == path) return _db!;
    _db?.close();
    _dbPath = path;
    final db = openSqliteDatabase(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS webdav_library_comics (
        config_key TEXT NOT NULL,
        id TEXT NOT NULL,
        sort_index INTEGER NOT NULL,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        tags TEXT NOT NULL,
        cover TEXT NOT NULL,
        snapshot_json TEXT,
        remote_etag TEXT,
        remote_modified_at INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (config_key, id)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS webdav_library_root_membership (
        config_key TEXT NOT NULL,
        root_path TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        PRIMARY KEY (config_key, root_path, comic_id)
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS webdav_library_root_membership_comic
      ON webdav_library_root_membership(config_key, comic_id);
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS webdav_library_root_state (
        config_key TEXT NOT NULL,
        root_path TEXT NOT NULL,
        last_successful_sync INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        PRIMARY KEY (config_key, root_path)
      );
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS webdav_library_comics_page
      ON webdav_library_comics(config_key, sort_index);
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS webdav_library_state (
        config_key TEXT PRIMARY KEY,
        last_successful_sync INTEGER NOT NULL DEFAULT 0,
        index_initialized INTEGER NOT NULL DEFAULT 0
      );
    ''');
    final stateColumns = db.select('PRAGMA table_info(webdav_library_state);');
    if (!stateColumns.any((row) => row['name'] == 'index_initialized')) {
      db.execute(
        'ALTER TABLE webdav_library_state ADD COLUMN index_initialized INTEGER NOT NULL DEFAULT 0;',
      );
    }
    _db = db;
    return db;
  }

  int count(String configKey, {Iterable<String>? roots}) {
    final rootList = roots?.toList(growable: false);
    if (rootList != null && rootList.isEmpty) return 0;
    final hasRoots = rootList != null || _hasRootMembership(configKey);
    return _database.select(
          hasRoots
              ? '''
                SELECT COUNT(DISTINCT comic_id) AS count
                FROM webdav_library_root_membership
                WHERE config_key = ?${rootList == null ? '' : ' AND root_path IN (${List.filled(rootList.length, '?').join(', ')})'};
                '''
              : 'SELECT COUNT(*) AS count FROM webdav_library_comics WHERE config_key = ?;',
          [configKey, ...?rootList],
        ).single['count']
        as int;
  }

  List<WebDavLibraryCachedComic> page(
    String configKey, {
    required int page,
    required int pageSize,
    Iterable<String>? roots,
  }) {
    final offset = (page - 1) * pageSize;
    final rootList = roots?.toList(growable: false);
    if (rootList != null && rootList.isEmpty) return const [];
    final hasRoots = rootList != null || _hasRootMembership(configKey);
    return _database
        .select(
          '''
          SELECT ${hasRoots ? 'DISTINCT c.*' : '*'}
          FROM webdav_library_comics c
          ${hasRoots ? 'INNER JOIN webdav_library_root_membership m ON m.config_key = c.config_key AND m.comic_id = c.id' : ''}
          WHERE c.config_key = ?
          ${rootList == null ? '' : 'AND m.root_path IN (${List.filled(rootList.length, '?').join(', ')})'}
          ORDER BY c.sort_index
          LIMIT ? OFFSET ?;
          ''',
          [configKey, ...?rootList, pageSize, offset],
        )
        .map(WebDavLibraryCachedComic.fromRow)
        .toList();
  }

  Map<String, WebDavLibraryCachedComic> all(String configKey) {
    return {
      for (final row in _database.select(
        'SELECT * FROM webdav_library_comics WHERE config_key = ?;',
        [configKey],
      ))
        row['id'] as String: WebDavLibraryCachedComic.fromRow(row),
    };
  }

  WebDavLibraryCachedComic? find(String configKey, String id) {
    final rows = _database.select(
      '''
      SELECT * FROM webdav_library_comics
      WHERE config_key = ? AND id = ?
      LIMIT 1;
      ''',
      [configKey, id],
    );
    return rows.isEmpty ? null : WebDavLibraryCachedComic.fromRow(rows.single);
  }

  void replaceDirectoryIndex(
    String configKey,
    List<WebDavLibraryRemoteDirectory> directories,
  ) {
    final db = _database;
    db.execute('BEGIN IMMEDIATE;');
    try {
      final remoteIds = directories.map((entry) => entry.id).toSet();
      final cachedIds = db
          .select(
            'SELECT id FROM webdav_library_comics WHERE config_key = ?;',
            [configKey],
          )
          .map((row) => row['id'] as String);
      for (final id in cachedIds) {
        if (!remoteIds.contains(id)) {
          db.execute(
            'DELETE FROM webdav_library_comics WHERE config_key = ? AND id = ?;',
            [configKey, id],
          );
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      for (final directory in directories) {
        db.execute(
          '''
          INSERT INTO webdav_library_comics (
            config_key, id, sort_index, title, author, tags, cover,
            snapshot_json, remote_etag, remote_modified_at, updated_at
          ) VALUES (?, ?, ?, ?, '', '[]', '', NULL, ?, ?, ?)
          ON CONFLICT(config_key, id) DO UPDATE SET
            sort_index = excluded.sort_index;
          ''',
          [
            configKey,
            directory.id,
            directory.sortIndex,
            directory.id,
            directory.eTag,
            directory.modifiedAt,
            now,
          ],
        );
      }
      db.execute(
        '''
        INSERT INTO webdav_library_state(
          config_key, last_successful_sync, index_initialized
        ) VALUES (?, 0, 1)
        ON CONFLICT(config_key) DO UPDATE SET index_initialized = 1;
        ''',
        [configKey],
      );
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// Replaces only one recognition directory's membership.  Cached comic rows
  /// are deliberately retained when a root is removed or fails: this keeps
  /// old comic ids, history and bindings available if the root is added back.
  void replaceRootDirectoryIndex(
    String configKey,
    WebDavLibraryRootIndex index,
  ) {
    final db = _database;
    db.execute('BEGIN IMMEDIATE;');
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      db.execute(
        'DELETE FROM webdav_library_root_membership WHERE config_key = ? AND root_path = ?;',
        [configKey, index.rootPath],
      );
      for (final directory in index.directories) {
        db.execute(
          '''
          INSERT INTO webdav_library_comics (
            config_key, id, sort_index, title, author, tags, cover,
            snapshot_json, remote_etag, remote_modified_at, updated_at
          ) VALUES (?, ?, ?, ?, '', '[]', '', NULL, ?, ?, ?)
          ON CONFLICT(config_key, id) DO UPDATE SET
            sort_index = excluded.sort_index,
            remote_etag = excluded.remote_etag,
            remote_modified_at = excluded.remote_modified_at,
            updated_at = excluded.updated_at;
          ''',
          [
            configKey,
            directory.id,
            directory.sortIndex,
            directory.id,
            directory.eTag,
            directory.modifiedAt,
            now,
          ],
        );
        db.execute(
          '''
          INSERT INTO webdav_library_root_membership(config_key, root_path, comic_id)
          VALUES (?, ?, ?);
          ''',
          [configKey, index.rootPath, directory.id],
        );
      }
      db.execute(
        '''
        INSERT INTO webdav_library_root_state(
          config_key, root_path, last_successful_sync, last_error
        ) VALUES (?, ?, ?, NULL)
        ON CONFLICT(config_key, root_path) DO UPDATE SET
          last_successful_sync = excluded.last_successful_sync,
          last_error = NULL;
        ''',
        [configKey, index.rootPath, now],
      );
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void addRootMembership(String configKey, String rootPath, String comicId) {
    _database.execute(
      '''
      INSERT OR IGNORE INTO webdav_library_root_membership(config_key, root_path, comic_id)
      VALUES (?, ?, ?);
      ''',
      [configKey, rootPath, comicId],
    );
  }

  void markRootFailure(String configKey, String rootPath, String error) {
    _database.execute(
      '''
      INSERT INTO webdav_library_root_state(
        config_key, root_path, last_successful_sync, last_error
      ) VALUES (?, ?, 0, ?)
      ON CONFLICT(config_key, root_path) DO UPDATE SET
        last_error = excluded.last_error;
      ''',
      [configKey, rootPath, error],
    );
  }

  Map<String, String> rootFailures(String configKey) {
    return {
      for (final row in _database.select(
        '''
        SELECT root_path, last_error FROM webdav_library_root_state
        WHERE config_key = ? AND last_error IS NOT NULL;
        ''',
        [configKey],
      ))
        row['root_path'] as String: row['last_error'] as String,
    };
  }

  /// Membership is intentionally not deleted for a removed root.  It is not
  /// visible unless the caller selects that root, and makes a later re-add
  /// immediately recover the former identity/cache even if its first refresh
  /// fails.
  void removeRootsExcept(String configKey, Set<String> selectedRoots) {}

  bool _hasRootMembership(String configKey) => _database.select(
    'SELECT 1 FROM webdav_library_root_membership WHERE config_key = ? LIMIT 1;',
    [configKey],
  ).isNotEmpty;

  void upsertSnapshot(String configKey, WebDavLibraryCachedComic comic) {
    _database.execute(
      '''
      INSERT INTO webdav_library_comics (
        config_key, id, sort_index, title, author, tags, cover,
        snapshot_json, remote_etag, remote_modified_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(config_key, id) DO UPDATE SET
        sort_index = excluded.sort_index,
        title = excluded.title,
        author = excluded.author,
        tags = excluded.tags,
        cover = excluded.cover,
        snapshot_json = excluded.snapshot_json,
        remote_etag = excluded.remote_etag,
        remote_modified_at = excluded.remote_modified_at,
        updated_at = excluded.updated_at;
      ''',
      [
        configKey,
        comic.id,
        comic.sortIndex,
        comic.title,
        comic.author,
        jsonEncode(comic.tags),
        comic.cover,
        comic.snapshot == null ? null : jsonEncode(comic.snapshot),
        comic.remoteETag,
        comic.remoteModifiedAt,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  int lastSuccessfulSync(String configKey) {
    final rows = _database.select(
      'SELECT last_successful_sync FROM webdav_library_state WHERE config_key = ?;',
      [configKey],
    );
    return rows.isEmpty ? 0 : rows.single['last_successful_sync'] as int;
  }

  bool hasDirectoryIndex(String configKey) {
    final rows = _database.select(
      'SELECT index_initialized FROM webdav_library_state WHERE config_key = ?;',
      [configKey],
    );
    return rows.isNotEmpty && rows.single['index_initialized'] == 1;
  }

  void setLastSuccessfulSync(String configKey, int timestamp) {
    _database.execute(
      '''
      INSERT INTO webdav_library_state(config_key, last_successful_sync, index_initialized)
      VALUES (?, ?, 1)
      ON CONFLICT(config_key) DO UPDATE SET
        last_successful_sync = excluded.last_successful_sync,
        index_initialized = 1;
      ''',
      [configKey, timestamp],
    );
  }

  void clear(String configKey) {
    final db = _database;
    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute('DELETE FROM webdav_library_comics WHERE config_key = ?;', [
        configKey,
      ]);
      db.execute('DELETE FROM webdav_library_state WHERE config_key = ?;', [
        configKey,
      ]);
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  void resetForTesting() {
    _db?.close();
    _db = null;
    _dbPath = null;
  }
}
