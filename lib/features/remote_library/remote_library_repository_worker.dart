part of 'remote_library_repository.dart';

enum _RemoteLibraryOperation {
  count,
  page,
  versions,
  all,
  find,
  replaceDirectoryIndex,
  replaceRootDirectoryIndex,
  addRootMembership,
  markRootFailure,
  rootFailures,
  upsertSnapshots,
  upsertSummaries,
  lastSuccessfulSync,
  hasDirectoryIndex,
  setLastSuccessfulSync,
  clear,
  close,
}

class _RemoteLibraryWorkerError {
  const _RemoteLibraryWorkerError(this.message, this.stack);

  final String message;
  final String stack;
}

class _RemoteLibraryWorker {
  _RemoteLibraryWorker(
    this.dataPath,
    this._isolate,
    this._requests,
    this._replies,
    this._messages,
  );

  final String dataPath;
  final Isolate _isolate;
  final SendPort _requests;
  final ReceivePort _replies;
  final StreamIterator<Object?> _messages;
  bool exited = false;

  static Future<_RemoteLibraryWorker> start(String dataPath) async {
    final replies = ReceivePort();
    final messages = StreamIterator<Object?>(replies);
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _runRemoteLibraryWorker,
        (dataPath, replies.sendPort),
        onError: replies.sendPort,
        onExit: replies.sendPort,
        debugName: 'remote-library-database',
      );
      final requests = await _receive(messages) as SendPort;
      return _RemoteLibraryWorker(
        dataPath,
        isolate,
        requests,
        replies,
        messages,
      );
    } catch (_) {
      isolate?.kill(priority: Isolate.immediate);
      await messages.cancel();
      replies.close();
      rethrow;
    }
  }

  static Future<Object?> _receive(StreamIterator<Object?> messages) async {
    if (!await messages.moveNext() || messages.current == null) {
      throw StateError('云端库数据库 worker 已退出');
    }
    final message = messages.current;
    if (message is _RemoteLibraryWorkerError) {
      Error.throwWithStackTrace(
        StateError(message.message),
        StackTrace.fromString(message.stack),
      );
    }
    // 未捕获的 isolate 错误由 Dart 以二元素列表发送。
    if (message is List) {
      Error.throwWithStackTrace(
        StateError(message[0] as String),
        StackTrace.fromString(message[1] as String),
      );
    }
    return message;
  }

  Future<Object?> request(
    _RemoteLibraryOperation operation,
    List<Object?> arguments,
  ) async {
    _requests.send((operation, arguments));
    try {
      final response = await _receive(_messages) as ({Object? value});
      return response.value;
    } catch (_) {
      if (_messages.current is! _RemoteLibraryWorkerError) exited = true;
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      if (!exited) {
        await request(_RemoteLibraryOperation.close, const []);
        // 关闭响应发出时连接已释放，继续等待 isolate 真正退出。
        await _messages.moveNext();
      }
    } finally {
      exited = true;
      _isolate.kill(priority: Isolate.immediate);
      await _messages.cancel();
      _replies.close();
    }
  }
}

void _runRemoteLibraryWorker((String, SendPort) startup) async {
  final requests = ReceivePort();
  try {
    final database = _RemoteLibraryDatabase.open(startup.$1);
    try {
      startup.$2.send(requests.sendPort);
      await for (final message in requests) {
        final (operation, arguments) =
            message as (_RemoteLibraryOperation, List<Object?>);
        if (operation == _RemoteLibraryOperation.close) break;
        try {
          final value = database.handle(operation, arguments);
          startup.$2.send((value: value));
        } catch (error, stack) {
          startup.$2.send(_RemoteLibraryWorkerError('$error', '$stack'));
        }
      }
    } finally {
      database.db.close();
    }
    startup.$2.send((value: null));
  } catch (error, stack) {
    startup.$2.send(_RemoteLibraryWorkerError('$error', '$stack'));
  } finally {
    requests.close();
  }
}

class _RemoteLibraryDatabase {
  _RemoteLibraryDatabase(this.db);

  final Database db;

  static _RemoteLibraryDatabase open(String dataPath) {
    final db = openSqliteDatabase('$dataPath/remote_library.db');
    try {
      final database = _RemoteLibraryDatabase(db);
      final legacyPath = '$dataPath/webdav_library.db';
      final hasLegacyFile =
          File(legacyPath).existsSync() &&
          !database._migrationCompleted('legacy_database');
      if (hasLegacyFile) {
        db.execute('ATTACH DATABASE ? AS legacy_library;', [legacyPath]);
      }
      try {
        database._transaction(() {
          database._createSchema();
          database._importLegacy('main', 'legacy_tables');
          if (hasLegacyFile) {
            database._importLegacy('legacy_library', 'legacy_database');
          }
          database._backfillSnapshotStates();
        });
      } finally {
        if (hasLegacyFile) db.execute('DETACH DATABASE legacy_library;');
      }
      return database;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  void _createSchema() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS remote_library_comics (
        config_key TEXT NOT NULL,
        id TEXT NOT NULL,
        sort_index INTEGER NOT NULL,
        title TEXT NOT NULL,
        author TEXT NOT NULL,
        tags TEXT NOT NULL,
        cover TEXT NOT NULL,
        snapshot_json TEXT,
        snapshot_state_json TEXT,
        remote_etag TEXT,
        remote_modified_at INTEGER,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (config_key, id)
      );
      CREATE TABLE IF NOT EXISTS remote_library_root_membership (
        config_key TEXT NOT NULL,
        root_path TEXT NOT NULL,
        comic_id TEXT NOT NULL,
        PRIMARY KEY (config_key, root_path, comic_id)
      );
      CREATE INDEX IF NOT EXISTS remote_library_root_membership_comic
        ON remote_library_root_membership(config_key, comic_id);
      CREATE TABLE IF NOT EXISTS remote_library_root_state (
        config_key TEXT NOT NULL,
        root_path TEXT NOT NULL,
        last_successful_sync INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        PRIMARY KEY (config_key, root_path)
      );
      CREATE INDEX IF NOT EXISTS remote_library_comics_page
        ON remote_library_comics(config_key, sort_index, id);
      CREATE TABLE IF NOT EXISTS remote_library_state (
        config_key TEXT PRIMARY KEY,
        last_successful_sync INTEGER NOT NULL DEFAULT 0,
        index_initialized INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS remote_library_migrations (
        name TEXT PRIMARY KEY
      );
    ''');
    if (!_columns(
      'main',
      'remote_library_comics',
    ).contains('snapshot_state_json')) {
      db.execute(
        'ALTER TABLE remote_library_comics ADD COLUMN snapshot_state_json TEXT;',
      );
    }
    if (!_columns(
      'main',
      'remote_library_state',
    ).contains('index_initialized')) {
      db.execute('''
        ALTER TABLE remote_library_state
          ADD COLUMN index_initialized INTEGER NOT NULL DEFAULT 0;
      ''');
    }
  }

  Set<String> _columns(String schema, String table) => {
    for (final row in db.select('PRAGMA $schema.table_info($table);'))
      row['name'] as String,
  };

  bool _migrationCompleted(String name) {
    if (db.select('''
      SELECT 1 FROM sqlite_master
      WHERE type = 'table' AND name = 'remote_library_migrations';
    ''').isEmpty) {
      return false;
    }
    return db.select(
      'SELECT 1 FROM remote_library_migrations WHERE name = ?;',
      [name],
    ).isNotEmpty;
  }

  void _importLegacy(String schema, String migration) {
    if (_migrationCompleted(migration)) return;
    final tables = {
      for (final row in db.select(
        "SELECT name FROM $schema.sqlite_master WHERE type = 'table';",
      ))
        row['name'] as String,
    };
    // 新库内可能仍是旧表名，旧文件也可能已含新表名。两者均幂等合并。
    for (final prefix in [
      'webdav_library',
      if (schema != 'main') 'remote_library',
    ]) {
      if (tables.contains('${prefix}_comics')) {
        db.execute('''
          INSERT INTO remote_library_comics (
            config_key, id, sort_index, title, author, tags, cover,
            snapshot_json, remote_etag, remote_modified_at, updated_at
          )
          SELECT config_key, id, sort_index, title, author, tags, cover,
            snapshot_json, remote_etag, remote_modified_at, updated_at
          FROM $schema.${prefix}_comics WHERE true
          ON CONFLICT(config_key, id) DO UPDATE SET
            sort_index = excluded.sort_index,
            title = excluded.title,
            author = excluded.author,
            tags = excluded.tags,
            cover = excluded.cover,
            snapshot_json = excluded.snapshot_json,
            snapshot_state_json = NULL,
            remote_etag = excluded.remote_etag,
            remote_modified_at = excluded.remote_modified_at,
            updated_at = excluded.updated_at
          WHERE (excluded.snapshot_json IS NOT NULL
                 AND remote_library_comics.snapshot_json IS NULL)
             OR ((excluded.snapshot_json IS NULL) =
                 (remote_library_comics.snapshot_json IS NULL)
                 AND excluded.updated_at > remote_library_comics.updated_at);
        ''');
      }
      if (tables.contains('${prefix}_root_membership')) {
        db.execute('''
          INSERT OR IGNORE INTO remote_library_root_membership
          SELECT config_key, root_path, comic_id
          FROM $schema.${prefix}_root_membership;
        ''');
      }
      if (tables.contains('${prefix}_root_state')) {
        db.execute('''
          INSERT INTO remote_library_root_state
          SELECT config_key, root_path, last_successful_sync, last_error
          FROM $schema.${prefix}_root_state WHERE true
          ON CONFLICT(config_key, root_path) DO UPDATE SET
            last_successful_sync = excluded.last_successful_sync,
            last_error = excluded.last_error
          WHERE excluded.last_successful_sync > remote_library_root_state.last_successful_sync;
        ''');
      }
      if (tables.contains('${prefix}_state')) {
        final hasIndexState = _columns(
          schema,
          '${prefix}_state',
        ).contains('index_initialized');
        db.execute('''
          INSERT INTO remote_library_state
          SELECT config_key, last_successful_sync,
            ${hasIndexState ? 'index_initialized' : '0'}
          FROM $schema.${prefix}_state WHERE true
          ON CONFLICT(config_key) DO UPDATE SET
            last_successful_sync = MAX(remote_library_state.last_successful_sync,
                                       excluded.last_successful_sync),
            index_initialized = MAX(remote_library_state.index_initialized,
                                    excluded.index_initialized);
        ''');
      }
    }
    // 标记与导入同事务提交。旧库保留，失败或中断时可重新导入。
    db.execute('INSERT INTO remote_library_migrations(name) VALUES (?);', [
      migration,
    ]);
  }

  static String? _snapshotState(Map<String, dynamic>? snapshot) =>
      snapshot == null
      ? null
      : jsonEncode({
          for (final key in const [
            'formatVersion',
            'metadataFilePresent',
            'metadataScrapeStatus',
            'metadataScraperVersion',
            'metadataScrapeRetryAt',
            'metadataScrapeAttemptedAt',
            'bangumiSubjectId',
            'chaptersInspected',
          ])
            if (snapshot.containsKey(key)) key: snapshot[key],
        });

  void _backfillSnapshotStates() {
    final update = db.prepare('''
      UPDATE remote_library_comics SET snapshot_state_json = ?
      WHERE config_key = ? AND id = ?;
    ''');
    try {
      // 先读取键，每次只解码一个旧快照，避免迁移时同时载入全部大 JSON。
      for (final row in db.select('''
        SELECT config_key, id FROM remote_library_comics
        WHERE snapshot_json IS NOT NULL AND snapshot_state_json IS NULL;
      ''')) {
        final snapshot = Map<String, dynamic>.from(
          jsonDecode(
                db
                        .select(
                          '''
            SELECT snapshot_json FROM remote_library_comics
            WHERE config_key = ? AND id = ?;
          ''',
                          [row['config_key'], row['id']],
                        )
                        .single['snapshot_json']
                    as String,
              )
              as Map,
        );
        update.execute([
          _snapshotState(snapshot),
          row['config_key'],
          row['id'],
        ]);
      }
    } finally {
      update.close();
    }
  }

  Object? handle(_RemoteLibraryOperation operation, List<Object?> arguments) {
    final configKey = arguments[0] as String;
    switch (operation) {
      case _RemoteLibraryOperation.count:
        return count(configKey, arguments[1] as List<String>?);
      case _RemoteLibraryOperation.page:
        return page(
          configKey,
          page: arguments[1] as int,
          pageSize: arguments[2] as int,
          roots: arguments[3] as List<String>?,
        );
      case _RemoteLibraryOperation.versions:
        return versions(configKey);
      case _RemoteLibraryOperation.all:
        return {
          for (final row in db.select(
            'SELECT * FROM remote_library_comics WHERE config_key = ?;',
            [configKey],
          ))
            row['id'] as String: _comic(row, fullSnapshot: true),
        };
      case _RemoteLibraryOperation.find:
        final rows = db.select(
          'SELECT * FROM remote_library_comics WHERE config_key = ? AND id = ?;',
          [configKey, arguments[1] as String],
        );
        return rows.isEmpty ? null : _comic(rows.single, fullSnapshot: true);
      case _RemoteLibraryOperation.replaceDirectoryIndex:
        replaceDirectoryIndex(
          configKey,
          arguments[1] as List<RemoteLibraryRemoteDirectory>,
        );
        return null;
      case _RemoteLibraryOperation.replaceRootDirectoryIndex:
        replaceRootDirectoryIndex(
          configKey,
          arguments[1] as RemoteLibraryRootIndex,
        );
        return null;
      case _RemoteLibraryOperation.addRootMembership:
        db.execute(
          '''
          INSERT OR IGNORE INTO remote_library_root_membership
            (config_key, root_path, comic_id) VALUES (?, ?, ?);
        ''',
          [configKey, arguments[1] as String, arguments[2] as String],
        );
        return null;
      case _RemoteLibraryOperation.markRootFailure:
        db.execute(
          '''
          INSERT INTO remote_library_root_state
            (config_key, root_path, last_successful_sync, last_error)
          VALUES (?, ?, 0, ?)
          ON CONFLICT(config_key, root_path) DO UPDATE SET
            last_error = excluded.last_error;
        ''',
          [configKey, arguments[1] as String, arguments[2] as String],
        );
        return null;
      case _RemoteLibraryOperation.rootFailures:
        return {
          for (final row in db.select(
            '''
            SELECT root_path, last_error FROM remote_library_root_state
            WHERE config_key = ? AND last_error IS NOT NULL;
          ''',
            [configKey],
          ))
            row['root_path'] as String: row['last_error'] as String,
        };
      case _RemoteLibraryOperation.upsertSnapshots:
        upsertComics(configKey, arguments[1] as List<RemoteLibraryCachedComic>);
        return null;
      case _RemoteLibraryOperation.upsertSummaries:
        upsertComics(
          configKey,
          arguments[1] as List<RemoteLibraryCachedComic>,
          summariesOnly: true,
          rootPath: arguments[2] as String?,
        );
        return null;
      case _RemoteLibraryOperation.lastSuccessfulSync:
        final rows = db.select(
          'SELECT last_successful_sync FROM remote_library_state WHERE config_key = ?;',
          [configKey],
        );
        return rows.isEmpty ? 0 : rows.single['last_successful_sync'] as int;
      case _RemoteLibraryOperation.hasDirectoryIndex:
        return db
            .select(
              '''
          SELECT 1 FROM remote_library_state
          WHERE config_key = ? AND index_initialized = 1;
        ''',
              [configKey],
            )
            .isNotEmpty;
      case _RemoteLibraryOperation.setLastSuccessfulSync:
        db.execute(
          '''
          INSERT INTO remote_library_state
            (config_key, last_successful_sync, index_initialized)
          VALUES (?, ?, 1)
          ON CONFLICT(config_key) DO UPDATE SET
            last_successful_sync = excluded.last_successful_sync,
            index_initialized = 1;
        ''',
          [configKey, arguments[1] as int],
        );
        return null;
      case _RemoteLibraryOperation.clear:
        _transaction(() {
          for (final table in [
            'comics',
            'state',
            'root_membership',
            'root_state',
          ]) {
            db.execute(
              'DELETE FROM remote_library_$table WHERE config_key = ?;',
              [configKey],
            );
          }
        });
        return null;
      case _RemoteLibraryOperation.close:
        throw StateError('关闭请求应由 worker 处理');
    }
  }

  // EXISTS 避免重叠根产生重复行，也避免 DISTINCT 将大快照带入临时排序。
  String _rootFilter(String configKey, List<String>? roots) {
    final hasRoots =
        roots != null ||
        db
            .select(
              '''
      SELECT 1 FROM remote_library_root_state WHERE config_key = ?
      UNION ALL
      SELECT 1 FROM remote_library_root_membership WHERE config_key = ?
      LIMIT 1;
    ''',
              [configKey, configKey],
            )
            .isNotEmpty;
    if (!hasRoots) return '';
    if (roots != null && roots.isEmpty) return ' AND 0';
    return ''' AND EXISTS (
      SELECT 1 FROM remote_library_root_membership m
      WHERE m.config_key = c.config_key AND m.comic_id = c.id
      ${roots == null ? '' : 'AND m.root_path IN (${List.filled(roots.length, '?').join(', ')})'}
    )''';
  }

  int count(String configKey, List<String>? roots) {
    return db
            .select(
              '''
      SELECT COUNT(*) AS count FROM remote_library_comics c
      WHERE c.config_key = ?${_rootFilter(configKey, roots)};
    ''',
              [configKey, ...?roots],
            )
            .single['count']
        as int;
  }

  List<RemoteLibraryCachedComic> page(
    String configKey, {
    required int page,
    required int pageSize,
    List<String>? roots,
  }) {
    return db
        .select(
          '''
      SELECT c.id, c.sort_index, c.title, c.author, c.tags, c.cover,
        c.remote_etag, c.remote_modified_at, c.snapshot_state_json
      FROM remote_library_comics c
      WHERE c.config_key = ?${_rootFilter(configKey, roots)}
      ORDER BY c.sort_index, c.id LIMIT ? OFFSET ?;
    ''',
          [configKey, ...?roots, pageSize, (page - 1) * pageSize],
        )
        .map((row) => _comic(row))
        .toList();
  }

  Map<String, RemoteLibraryCachedComic> versions(String configKey) => {
    for (final row in db.select(
      '''
      SELECT id, sort_index, remote_etag, remote_modified_at, snapshot_state_json
      FROM remote_library_comics WHERE config_key = ?;
    ''',
      [configKey],
    ))
      row['id'] as String: _comic(row, versionOnly: true),
  };

  RemoteLibraryCachedComic _comic(
    Row row, {
    bool fullSnapshot = false,
    bool versionOnly = false,
  }) {
    final snapshotText =
        row[fullSnapshot ? 'snapshot_json' : 'snapshot_state_json'] as String?;
    final tags = versionOnly ? const [] : jsonDecode(row['tags'] as String);
    return RemoteLibraryCachedComic(
      id: row['id'] as String,
      sortIndex: row['sort_index'] as int,
      title: versionOnly ? row['id'] as String : row['title'] as String,
      author: versionOnly ? '' : row['author'] as String,
      tags: tags is List ? tags.whereType<String>().toList() : const [],
      cover: versionOnly ? '' : row['cover'] as String,
      snapshot: snapshotText == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(snapshotText) as Map),
      remoteETag: row['remote_etag'] as String?,
      remoteModifiedAt: row['remote_modified_at'] as int?,
    );
  }

  static const _directoryUpsert = '''
    INSERT INTO remote_library_comics (
      config_key, id, sort_index, title, author, tags, cover,
      remote_etag, remote_modified_at, updated_at
    ) VALUES (?, ?, ?, ?, '', '[]', '', ?, ?, ?)
    ON CONFLICT(config_key, id) DO UPDATE SET sort_index = excluded.sort_index
    WHERE remote_library_comics.sort_index != excluded.sort_index;
  ''';

  void replaceDirectoryIndex(
    String configKey,
    List<RemoteLibraryRemoteDirectory> directories,
  ) {
    _transaction(() {
      final ids = directories.map((directory) => directory.id).toSet();
      final remove = db.prepare(
        'DELETE FROM remote_library_comics WHERE config_key = ? AND id = ?;',
      );
      try {
        for (final row in db.select(
          'SELECT id FROM remote_library_comics WHERE config_key = ?;',
          [configKey],
        )) {
          if (!ids.contains(row['id'])) remove.execute([configKey, row['id']]);
        }
      } finally {
        remove.close();
      }
      _upsertDirectories(configKey, directories);
      db.execute(
        '''
        INSERT INTO remote_library_state
          (config_key, last_successful_sync, index_initialized)
        VALUES (?, 0, 1)
        ON CONFLICT(config_key) DO UPDATE SET index_initialized = 1;
      ''',
        [configKey],
      );
    });
  }

  void _upsertDirectories(
    String configKey,
    List<RemoteLibraryRemoteDirectory> directories,
  ) {
    final insert = db.prepare(_directoryUpsert);
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      for (final directory in directories) {
        insert.execute([
          configKey,
          directory.id,
          directory.sortIndex,
          directory.id,
          directory.eTag,
          directory.modifiedAt,
          now,
        ]);
      }
    } finally {
      insert.close();
    }
  }

  void replaceRootDirectoryIndex(
    String configKey,
    RemoteLibraryRootIndex index,
  ) {
    _transaction(() {
      final existing = {
        for (final row in db.select(
          '''
          SELECT comic_id FROM remote_library_root_membership
          WHERE config_key = ? AND root_path = ?;
        ''',
          [configKey, index.rootPath],
        ))
          row['comic_id'] as String,
      };
      final ids = index.directories.map((directory) => directory.id).toSet();
      _upsertDirectories(configKey, index.directories);
      final remove = db.prepare('''
        DELETE FROM remote_library_root_membership
        WHERE config_key = ? AND root_path = ? AND comic_id = ?;
      ''');
      PreparedStatement? insert;
      try {
        insert = db.prepare('''
          INSERT INTO remote_library_root_membership
            (config_key, root_path, comic_id) VALUES (?, ?, ?);
        ''');
        for (final id in existing.difference(ids)) {
          remove.execute([configKey, index.rootPath, id]);
        }
        for (final id in ids.difference(existing)) {
          insert.execute([configKey, index.rootPath, id]);
        }
      } finally {
        remove.close();
        insert?.close();
      }
      db.execute(
        '''
        INSERT INTO remote_library_root_state
          (config_key, root_path, last_successful_sync, last_error)
        VALUES (?, ?, ?, NULL)
        ON CONFLICT(config_key, root_path) DO UPDATE SET
          last_successful_sync = excluded.last_successful_sync,
          last_error = NULL;
      ''',
        [configKey, index.rootPath, DateTime.now().millisecondsSinceEpoch],
      );
    });
  }

  void upsertComics(
    String configKey,
    List<RemoteLibraryCachedComic> comics, {
    bool summariesOnly = false,
    String? rootPath,
  }) {
    _transaction(() {
      final updates = summariesOnly
          ? '''
          sort_index = excluded.sort_index,
          title = CASE WHEN remote_library_comics.snapshot_json IS NULL
            THEN excluded.title ELSE remote_library_comics.title END,
          author = CASE WHEN remote_library_comics.snapshot_json IS NULL
            THEN excluded.author ELSE remote_library_comics.author END,
          tags = CASE WHEN remote_library_comics.snapshot_json IS NULL
            THEN excluded.tags ELSE remote_library_comics.tags END,
          cover = CASE WHEN remote_library_comics.snapshot_json IS NULL
            THEN excluded.cover ELSE remote_library_comics.cover END,
          remote_etag = CASE WHEN remote_library_comics.snapshot_json IS NULL
            THEN excluded.remote_etag ELSE remote_library_comics.remote_etag END,
          remote_modified_at = CASE WHEN remote_library_comics.snapshot_json IS NULL
            THEN excluded.remote_modified_at ELSE remote_library_comics.remote_modified_at END,
          updated_at = CASE WHEN remote_library_comics.snapshot_json IS NULL
            THEN excluded.updated_at ELSE remote_library_comics.updated_at END
          WHERE remote_library_comics.sort_index IS NOT excluded.sort_index
            OR (remote_library_comics.snapshot_json IS NULL AND (
              remote_library_comics.title IS NOT excluded.title
              OR remote_library_comics.author IS NOT excluded.author
              OR remote_library_comics.tags IS NOT excluded.tags
              OR remote_library_comics.cover IS NOT excluded.cover
              OR remote_library_comics.remote_etag IS NOT excluded.remote_etag
              OR remote_library_comics.remote_modified_at IS NOT excluded.remote_modified_at
            ))
          '''
          : '''
          sort_index = excluded.sort_index,
          title = excluded.title,
          author = excluded.author,
          tags = excluded.tags,
          cover = excluded.cover,
          snapshot_json = excluded.snapshot_json,
          snapshot_state_json = excluded.snapshot_state_json,
          remote_etag = excluded.remote_etag,
          remote_modified_at = excluded.remote_modified_at,
          updated_at = excluded.updated_at
          ''';
      final upsert = db.prepare('''
        INSERT INTO remote_library_comics (
          config_key, id, sort_index, title, author, tags, cover,
          snapshot_json, snapshot_state_json, remote_etag, remote_modified_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(config_key, id) DO UPDATE SET $updates;
      ''');
      PreparedStatement? membership;
      try {
        if (rootPath != null) {
          membership = db.prepare('''
            INSERT OR IGNORE INTO remote_library_root_membership
              (config_key, root_path, comic_id) VALUES (?, ?, ?);
          ''');
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final comic in comics) {
          final snapshot = summariesOnly ? null : comic.snapshot;
          upsert.execute([
            configKey,
            comic.id,
            comic.sortIndex,
            comic.title,
            comic.author,
            jsonEncode(comic.tags),
            comic.cover,
            snapshot == null ? null : jsonEncode(snapshot),
            _snapshotState(snapshot),
            comic.remoteETag,
            comic.remoteModifiedAt,
            now,
          ]);
          membership?.execute([configKey, rootPath, comic.id]);
        }
      } finally {
        upsert.close();
        membership?.close();
      }
    });
  }

  void _transaction(void Function() action) {
    db.execute('BEGIN IMMEDIATE;');
    try {
      action();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }
}
