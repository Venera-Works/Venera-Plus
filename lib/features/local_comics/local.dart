import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';
import 'package:venera_plus/features/local_comics/download.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/search/library_search_query.dart';
import 'package:venera_plus/foundation/file_interaction.dart';

import 'package:venera_plus/foundation/translations.dart';
import 'local_storage_guard.dart';
import 'local_storage_migration.dart';
import 'incomplete_chapter.dart';
import 'package:venera_plus/foundation/missing_download_page.dart';
import 'import_export/document_import.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/history/history.dart';

export 'local_comic_image.dart';
export 'incomplete_chapter.dart';

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final Map<String, IncompleteChapter> incompleteChapters;
  bool get isIncomplete => incompleteChapters.isNotEmpty;
  int get missingImageCount => incompleteChapters.values.fold(
    0,
    (count, chapter) => count + chapter.missing.length,
  );

  final DateTime createdAt;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
    this.incompleteChapters = const {},
  });

  LocalComic.fromRow(Row row)
    : id = row[0] as String,
      title = row[1] as String,
      subtitle = row[2] as String,
      tags = List.from(jsonDecode(row[3] as String)),
      directory = row[4] as String,
      chapters = ComicChapters.fromJsonOrNull(jsonDecode(row[5] as String)),
      cover = row[6] as String,
      comicType = ComicType(row[7] as int),
      downloadedChapters = List.from(jsonDecode(row[8] as String)),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row[9] as int),
      incompleteChapters = {
        for (final entry
            in (jsonDecode(row['incomplete_pages'] as String)
                    as Map<String, dynamic>)
                .entries)
          entry.key: IncompleteChapter.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      };

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  @override
  String get description => "";

  @override
  String get sourceKey =>
      comicType == ComicType.local ? "local" : comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    final availableChapters = {
      ...downloadedChapters,
      ...incompleteChapters.keys,
    };
    if (availableChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (availableChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (availableChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    final hasReadingProgress = history?.hasReadingProgress ?? false;
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: hasReadingProgress ? null : firstDownloadedChapter,
        initialPage: hasReadingProgress || firstDownloadedChapter == null
            ? null
            : 1,
        initialChapterGroup: hasReadingProgress
            ? null
            : firstDownloadedChapterGroup,
        initialNavigationSource: ReadingNavigationSource.restore,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

typedef LocalComicCategory = ({int id, String name});

class LocalManager with ChangeNotifier {
  static const allCategories = -1;
  static const uncategorized = 0;
  static const _searchPageSize = 20;

  static LocalManager? _instance;

  @visibleForTesting
  static bool debugSkipComicSourceInit = false;

  @visibleForTesting
  static void resetForTesting() {
    try {
      _instance?.dispose();
    } catch (_) {
      // ignore cleanup failures in partially initialized tests
    }
    _instance = null;
    debugSkipComicSourceInit = false;
  }

  LocalManager._();
  (String, String)? _relocatedRoot;

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

  void _checkNoMedia() {
    if (!App.isAndroid) return;
    try {
      final file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) file.createSync();
    } on FileSystemException catch (error, stack) {
      if (!path.startsWith('android://')) rethrow;
      Log.error('IO', 'Failed to create .nomedia: $error', stack);
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    try {
      return await LocalComicStorageGuard.instance.runExclusive(
        () => _setNewPath(newPath),
      );
    } on LocalComicStorageBusy catch (error) {
      return error.message.tl;
    }
  }

  Future<String?> _setNewPath(String newPath) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!await newDir.list().isEmpty) {
      return "Directory is not empty";
    }
    try {
      for (final task in downloadingTasks.toList()) {
        task.pause();
        await task.pendingCleanup;
      }
      await downloadTransition;
      await pendingDownloadTaskWrites;
      await _storageMigration.move(directory, newDir);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    _checkNoMedia();
    notifyListeners();
    return null;
  }

  LocalStorageMigration get _storageMigration => LocalStorageMigration(
    db: _db,
    pathFile: File(FilePath.join(App.dataPath, 'local_path')),
    persistRelated: saveCurrentDownloadingTasks,
    publish: (source, destination) {
      path = destination;
      _relocatedRoot = (source, destination);
      for (final task in downloadingTasks) {
        task.relocateOutput(source, destination);
      }
      final cancelledOutputs = _cancelledDownloadOutputs.toList();
      for (final output in cancelledOutputs) {
        if (p.isWithin(source, output)) {
          _cancelledDownloadOutputs.remove(output);
          _cancelledDownloadOutputs.add(
            p.join(destination, p.relative(output, from: source)),
          );
        }
      }
    },
  );

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    try {
      final testFile = File(FilePath.join(path, 'venera_test'));
      testFile.createSync();
      testFile.deleteSync();
    } catch (error, stack) {
      if (_relocatedRoot != null) rethrow;
      if (path.startsWith('android://')) {
        Log.error(
          'IO',
          'SAF storage unavailable; keeping configured path: $error',
          stack,
        );
        return;
      }
      Log.error(
        'IO',
        'Failed to create test file in local path: $error\nUsing default path instead.',
        stack,
      );
      path = await findDefaultPath();
    }
  }

  Future<void> init() async {
    _db = openSqliteDatabase('${App.dataPath}/local.db');
    _db.execute('''
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS local_comic_categories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE
      );
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS natural_sort_migration (
        id TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        history_time INTEGER,
        old_page INTEGER,
        new_page INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    final columns = _db
        .select('PRAGMA table_info(comics)')
        .map((row) => row['name'])
        .toSet();
    if (!columns.contains('incomplete_pages')) {
      _db.execute(
        "ALTER TABLE comics ADD COLUMN incomplete_pages TEXT NOT NULL DEFAULT '{}'",
      );
    }
    if (!columns.contains('category_id')) {
      _db.execute('''
        ALTER TABLE comics ADD COLUMN category_id INTEGER
          REFERENCES local_comic_categories(id) ON DELETE SET NULL;
      ''');
    }
    if (!columns.contains('original_search_metadata')) {
      _db.execute(
        'ALTER TABLE comics ADD COLUMN original_search_metadata TEXT',
      );
    }
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!path.startsWith('android://') && !directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!path.startsWith('android://') && !directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    if (!debugSkipComicSourceInit) {
      await ComicSourceManager().ensureInit();
    }
    restoreDownloadingTasks();
    await _storageMigration.recover();
    await _checkPathValidation();
    _checkNoMedia();
  }

  String findValidId(ComicType type) {
    var highest = BigInt.zero;
    void includeIds(ResultSet rows) {
      for (final row in rows) {
        final value = BigInt.tryParse(row['id'] as String, radix: 10);
        if (value != null && value > highest) highest = value;
      }
    }

    includeIds(
      _db.select('SELECT id FROM comics WHERE comic_type = ?', [type.value]),
    );
    final databasePath =
        _db
                .select('PRAGMA database_list;')
                .singleWhere((row) => row['name'] == 'main')['file']
            as String;
    final favoritesPath = FilePath.join(
      File(databasePath).parent.path,
      'local_favorite.db',
    );
    final favoritesKind = FileSystemEntity.typeSync(favoritesPath);
    if (favoritesKind != FileSystemEntityType.notFound) {
      if (favoritesKind != FileSystemEntityType.file) {
        throw FileSystemException(
          'Favorites database is unavailable',
          favoritesPath,
        );
      }
      // Migrated favorites can outlive local.db and its UI index.
      final favorites = sqlite3.open(favoritesPath, mode: OpenMode.readOnly);
      try {
        final tables = favorites.select(
          "SELECT name FROM sqlite_master WHERE type = 'table';",
        );
        for (final row in tables) {
          final table = row['name'] as String;
          if (isInternalFavoriteTable(table)) continue;
          includeIds(
            favorites.select(
              'SELECT id FROM ${quoteSqlIdentifier(table)} WHERE type = ?',
              [type.value],
            ),
          );
        }
      } finally {
        favorites.close();
      }
    }
    return (highest + BigInt.one).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    _writeComic(comic, id);
    notifyListeners();
  }

  void _writeComic(LocalComic comic, String? id) {
    var old = find(id ?? comic.id, comic.comicType);
    if (old == null) {
      // Newly imported books already use natural ordering.
      _db.execute(
        'INSERT OR REPLACE INTO natural_sort_migration (id, comic_type) VALUES (?, ?)',
        [id ?? comic.id, comic.comicType.value],
      );
    }
    final downloaded = {
      ...?old?.downloadedChapters,
      ...comic.downloadedChapters,
    }.toList();
    final incomplete = {...?old?.incompleteChapters}
      ..removeWhere(
        (chapter, _) =>
            comic.chapters == null ||
            comic.downloadedChapters.contains(chapter),
      )
      ..addAll(comic.incompleteChapters);
    downloaded.removeWhere(incomplete.containsKey);
    _db.execute(
      '''
      INSERT INTO comics (
        id, title, subtitle, tags, directory, chapters, cover, comic_type,
        downloadedChapters, created_at, incomplete_pages
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id, comic_type) DO UPDATE SET
        title = excluded.title, subtitle = excluded.subtitle, tags = excluded.tags,
        directory = excluded.directory, chapters = excluded.chapters,
        cover = excluded.cover, downloadedChapters = excluded.downloadedChapters,
        created_at = excluded.created_at, incomplete_pages = excluded.incomplete_pages;
      ''',
      [
        id ?? comic.id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded),
        comic.createdAt.millisecondsSinceEpoch,
        jsonEncode({
          for (final entry in incomplete.entries)
            entry.key: entry.value.toJson(),
        }),
      ],
    );
  }

  void remove(String id, ComicType comicType, {bool notify = true}) {
    _db.execute(
      'DELETE FROM natural_sort_migration WHERE id = ? AND comic_type = ?',
      [id, comicType.value],
    );
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    if (notify) {
      notifyListeners();
    }
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
  }

  List<LocalComic> getComics(LocalSortType sortType) =>
      search('', sortType: sortType);

  List<LocalComicCategory> get comicCategories => _db
      .select('SELECT id, name FROM local_comic_categories ORDER BY id')
      .map((row) => (id: row['id'] as int, name: row['name'] as String))
      .toList();

  int? createComicCategory(String name) {
    name = name.trim();
    if (name.isEmpty) return null;
    _db.execute(
      '''
      INSERT INTO local_comic_categories (name) VALUES (?)
      ON CONFLICT(name) DO NOTHING;
    ''',
      [name],
    );
    if (_db.updatedRows == 0) return null;
    final id = _db.lastInsertRowId;
    notifyListeners();
    return id;
  }

  bool renameComicCategory(int id, String name) {
    name = name.trim();
    if (name.isEmpty) return false;
    _db.execute(
      'UPDATE OR IGNORE local_comic_categories SET name = ? WHERE id = ?',
      [name, id],
    );
    if (_db.updatedRows == 0) return false;
    notifyListeners();
    return true;
  }

  void deleteComicCategory(int id) {
    _db.execute('DELETE FROM local_comic_categories WHERE id = ?', [id]);
    notifyListeners();
  }

  void moveComicsToCategory(List<LocalComic> comics, int categoryId) {
    final storedId = categoryId == uncategorized ? null : categoryId;
    _db.execute('BEGIN');
    try {
      for (final comic in comics) {
        _db.execute(
          'UPDATE comics SET category_id = ? WHERE id = ? AND comic_type = ?',
          [storedId, comic.id, comic.comicType.value],
        );
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    notifyListeners();
  }

  void updateImportedMetadata(
    String id, {
    required List<String> tags,
    required String author,
  }) {
    final identity = [id, ComicType.local.value];
    final row = _db.select('''
      SELECT subtitle, tags, original_search_metadata FROM comics
      WHERE id = ? AND comic_type = ?;
    ''', identity).firstOrNull;
    if (row == null) return;

    // 重选条目时用最新刮削结果替换上次补入的内容。
    final raw = row['original_search_metadata'] as String?;
    final original = raw == null
        ? {
            'subtitle': row['subtitle'] as String,
            'tags': jsonDecode(row['tags'] as String),
          }
        : jsonDecode(raw) as Map<String, dynamic>;
    final subtitle = original['subtitle'] as String;
    final originalTags = (original['tags'] as List).cast<String>();
    final seen = {for (final tag in originalTags) tag.trim().toLowerCase()};
    final mergedTags = [
      ...originalTags,
      for (final tag in tags)
        if (seen.add(tag.trim().toLowerCase())) tag,
    ];
    _db.execute(
      '''
      UPDATE comics SET subtitle = ?, tags = ?, original_search_metadata = ?
      WHERE id = ? AND comic_type = ?;
      ''',
      [
        subtitle.trim().isEmpty ? author : subtitle,
        jsonEncode(mergedTags),
        raw ?? jsonEncode(original),
        ...identity,
      ],
    );
    notifyListeners();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  @override
  void dispose() {
    super.dispose();
    _db.dispose();
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(
    String keyword, {
    LocalSortType sortType = LocalSortType.timeDesc,
    int categoryId = allCategories,
    Iterable<String> tags = const [],
  }) {
    final category = _categoryFilter(categoryId);
    final filter = _searchFilter(keyword, tags);
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE 1${category.sql}${filter.sql}
      ORDER BY
        ${sortType == LocalSortType.name ? 'title' : 'created_at'}
        ${sortType == LocalSortType.timeAsc ? 'ASC' : 'DESC'};
    ''',
      [...category.parameters, ...filter.parameters],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  Future<Res<List<LocalComic>>> searchPage(
    int page, {
    String keyword = '',
    Iterable<String> tags = const [],
  }) async {
    if (page < 1) return const Res([], subData: 1);

    final filter = _searchFilter(keyword, tags);
    final countRow = _db
        .select(
          'SELECT COUNT(*) FROM comics WHERE 1${filter.sql}',
          filter.parameters,
        )
        .single;
    final count = countRow[0] as int;
    final maxPage = count == 0
        ? 1
        : (count + _searchPageSize - 1) ~/ _searchPageSize;
    if (page > maxPage) return Res([], subData: maxPage);

    final rows = _db.select(
      '''
      SELECT * FROM comics
      WHERE 1${filter.sql}
      ORDER BY created_at DESC, id, comic_type
      LIMIT ? OFFSET ?;
      ''',
      [...filter.parameters, _searchPageSize, (page - 1) * _searchPageSize],
    );
    return Res(rows.map(LocalComic.fromRow).toList(), subData: maxPage);
  }

  ({String sql, List<Object?> parameters}) _searchFilter(
    String keyword,
    Iterable<String> tags,
  ) => librarySearchFilter(
    titleColumn: 'title',
    authorColumn: 'subtitle',
    tagsColumn: 'tags',
    keyword: keyword,
    tags: tags,
  );

  List<String> availableTags(int categoryId) {
    final category = _categoryFilter(categoryId);
    return _db
        .select('''
      SELECT DISTINCT ${libraryTagSql('t.value')} COLLATE NOCASE AS tag_name
      FROM comics, json_each(comics.tags) t
      WHERE tag_name IS NOT NULL AND tag_name <> ''${category.sql}
      ORDER BY tag_name;
    ''', category.parameters)
        .map((row) => row['tag_name'] as String)
        .toList();
  }

  ({String sql, List<Object?> parameters}) _categoryFilter(int categoryId) =>
      switch (categoryId) {
        allCategories => (sql: '', parameters: const []),
        uncategorized => (
          sql: ' AND category_id IS NULL',
          parameters: const [],
        ),
        _ => (sql: ' AND category_id = ?', parameters: [categoryId]),
      };

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var comic = find(id, type) ?? (throw "Comic Not Found");
    var directory = Directory(comic.baseDir);
    final chapterId = comic.chapters == null
        ? ''
        : ep is int
        ? comic.chapters!.ids.elementAt(ep - 1)
        : ep as String;
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.chapters!.ids.elementAt(ep - 1)
          : (ep as String);
      cid = getChapterDirectoryName(cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        if (isIgnoredComicStorageEntry(entity.name) ||
            !isComicImageFileName(entity.name) ||
            isNamedComicCover(entity.name)) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) => compareComicFileNames(a.name, b.name));
    final incomplete = comic.incompleteChapters[chapterId];
    if (incomplete != null) {
      final byIndex = {
        for (final file in files)
          int.tryParse(file.name.split('.').first): file,
      };
      return List.generate(
        incomplete.pageCount,
        (index) => byIndex[index] == null
            ? '$missingDownloadPagePrefix${Uri.encodeComponent(id)}/$index'
            : 'file://${byIndex[index]!.path}',
      );
    }
    return files.map((e) => "file://${e.path}").toList();
  }

  /// Preserve the actual saved image on the first read after the sort upgrade.
  /// Record the mapping before writing history so an interrupted migration can
  /// be resumed without interpreting an already converted page a second time.
  Future<void> migrateLegacyPageOrder(
    History history, [
    List<String>? loadedImages,
  ]) async {
    final key = [history.id, history.type.value];
    var rows = _db.select(
      'SELECT * FROM natural_sort_migration WHERE id = ? AND comic_type = ?',
      key,
    );
    if (rows.isEmpty) {
      var page = history.page;
      if (history.ep > 0 && page > 0) {
        List<String>? images = loadedImages;
        if (images == null) {
          var chapter = history.ep;
          final comic = find(history.id, history.type);
          if (comic != null) {
            final chapters = comic.chapters;
            if (chapters != null &&
                chapters.isGrouped &&
                history.group != null) {
              for (var group = 0; group < history.group! - 1; group++) {
                chapter += chapters.getGroupByIndex(group).length;
              }
            }
            images = await getImages(history.id, history.type, chapter);
          }
        }
        if (images != null) {
          final legacy = images.toList()..sort(compareLegacyComicFileNames);
          if (page <= legacy.length)
            page = images.indexOf(legacy[page - 1]) + 1;
        }
      }
      _db.execute('INSERT INTO natural_sort_migration VALUES (?, ?, ?, ?, ?)', [
        ...key,
        history.time.millisecondsSinceEpoch,
        history.page,
        page,
      ]);
      rows = _db.select(
        'SELECT * FROM natural_sort_migration WHERE id = ? AND comic_type = ?',
        key,
      );
    }
    final migration = rows.single;
    if (migration['history_time'] == history.time.millisecondsSinceEpoch &&
        migration['old_page'] == history.page &&
        migration['new_page'] != history.page) {
      history.page = migration['new_page'] as int;
      HistoryManager().addHistory(history);
    }
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
            incompleteChapters: comic.incompleteChapters,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1),
    );
  }

  List<DownloadTask> downloadingTasks = [];
  final _cancellingDownloads = Map<DownloadTask, Future<void>>.identity();
  static const _cancelledDownloadOutputType = 'CancelledDownloadOutput';
  final _cancelledDownloadOutputs = <String>{};
  Future<void>? _downloadTransition;

  Iterable<DownloadTask> get downloadsWithUnfinishedOutput =>
      downloadingTasks.followedBy(_cancellingDownloads.keys);

  Iterable<String> get cancelledDownloadOutputs => _cancelledDownloadOutputs;

  Future<void>? get downloadTransition {
    final previous = _downloadTransition;
    if (_cancellingDownloads.isEmpty) return previous;
    return Future.wait([
      ?previous,
      ..._cancellingDownloads.values,
    ]).then<void>((_) {});
  }

  int _downloadCommand = 0;
  DownloadTask? get currentDownloadTask => downloadingTasks
      .where((task) => !task.isAwaitingMissingPages)
      .firstOrNull;

  Future<void> retainIncompleteTask(DownloadTask task) async {
    _writeComic(task.toLocalComic(), null);
    _downloadTransition = task.pendingCleanup;
    currentDownloadTask?.resume();
    notifyListeners();
    await saveCurrentDownloadingTasks();
  }

  Future<void> resumeTask(DownloadTask task) async {
    final command = ++_downloadCommand;
    for (final other in downloadingTasks.toList()) {
      if (!identical(other, task) && !other.isPaused) {
        other.pause();
        await other.pendingCleanup;
        if (command != _downloadCommand) return;
      }
    }
    if (!downloadingTasks.contains(task)) return;
    downloadingTasks.remove(task);
    downloadingTasks.insert(0, task);
    task.resume();
    notifyListeners();
  }

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(FilePath.join(path, comic.directory));
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    final directory = DocumentImportSession.allocateDirectory(path, name);
    _cancelledDownloadOutputs.removeWhere(
      (output) => p.equals(output, directory.path),
    );
    return directory;
  }

  Future<void> completeTask(DownloadTask task) async {
    await add(task.toLocalComic());
    final index = downloadingTasks.indexWhere(
      (entry) => identical(entry, task),
    );
    if (index < 0) return;
    downloadingTasks.removeAt(index);
    notifyListeners();
    try {
      await saveCurrentDownloadingTasks();
    } catch (_) {
      downloadingTasks.insert(index, task);
      notifyListeners();
      rethrow;
    }
    _downloadTransition = task.pendingCleanup;
    currentDownloadTask?.resume();
  }

  void removeTask(DownloadTask task) {
    final index = downloadingTasks.indexWhere(
      (entry) => identical(entry, task),
    );
    if (index < 0) return;
    _downloadCommand++;
    downloadingTasks.removeAt(index);
    notifyListeners();
    if (!_cancellingDownloads.containsKey(task)) saveCurrentDownloadingTasks();
  }

  Future<void> cancelTask(
    DownloadTask task, {
    required Future<void>? stopped,
    required Future<void> Function(String output) cleanOutput,
  }) {
    final done = Completer<void>();
    _cancellingDownloads[task] = done.future;
    removeTask(task);
    done.complete(() async {
      var checkpointSaved = false;
      try {
        final initialOutput = task.path;
        // 清理前同时等待旧任务停写和取消状态落盘。
        await Future.wait([
          saveCurrentDownloadingTasks().then((_) {
            checkpointSaved = true;
          }),
          ?stopped,
        ]);
        final output = task.path;
        if (output != null && output.isNotEmpty) {
          if (output != initialOutput) await saveCurrentDownloadingTasks();
          await cleanOutput(output);
        }
      } catch (error, stack) {
        final output = task.path;
        if (output != null && output.isNotEmpty) {
          _cancelledDownloadOutputs.add(output);
        }
        Log.error('Download cancellation', error, stack);
      } finally {
        _cancellingDownloads.remove(task);
        final output = task.path;
        if (!checkpointSaved || (output != null && output.isNotEmpty)) {
          try {
            await saveCurrentDownloadingTasks();
          } catch (error, stack) {
            Log.error('Download checkpoint', error, stack);
          }
        }
      }
    }());
    return done.future;
  }

  void moveToFirst(DownloadTask task) {
    final current = currentDownloadTask;
    if (current != task && downloadingTasks.contains(task)) {
      var shouldResume = current != null && !current.isPaused;
      current?.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasks();
      if (shouldResume) {
        resumeTask(task);
      }
    }
  }

  Future<void> _downloadTaskWrites = Future.value();
  Future<void> get pendingDownloadTaskWrites => _downloadTaskWrites;

  Future<void> saveCurrentDownloadingTasks() {
    final cancelledOutputs = {
      ..._cancelledDownloadOutputs,
      for (final task in _cancellingDownloads.keys)
        if (task.path case final String output when output.isNotEmpty) output,
    };
    final snapshot = jsonEncode([
      for (final task in downloadingTasks) task.toJson(),
      for (final output in cancelledOutputs)
        {'type': _cancelledDownloadOutputType, 'path': output},
    ]);
    final file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    return _downloadTaskWrites = _downloadTaskWrites
        .catchError((Object error, StackTrace stack) {
          Log.error('Download checkpoint', error, stack);
        })
        .then((_) async {
          if (snapshot == '[]' && !await file.exists()) return;
          final temporary = File('${file.path}.new');
          await temporary.writeAsString(snapshot, flush: true);
          await temporary.rename(file.path);
        });
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (file.existsSync()) {
      try {
        final entries = jsonDecode(file.readAsStringSync()) as List;
        for (final entry in entries.whereType<Map<String, dynamic>>()) {
          if (entry['type'] == _cancelledDownloadOutputType) {
            if (entry['path'] case final String output when output.isNotEmpty) {
              _cancelledDownloadOutputs.add(output);
            }
            continue;
          }
          try {
            final task = DownloadTask.fromJson(entry);
            if (task != null) downloadingTasks.add(task);
          } catch (error, stack) {
            Log.error('Download checkpoint', error, stack);
          }
        }
      } catch (e) {
        file.delete();
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    currentDownloadTask?.resume();
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk) {
      _deleteDirectories([FilePath.join(path, c.directory)]);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    final incomplete = {...c.incompleteChapters}
      ..removeWhere((chapter, _) => chapters.contains(chapter));
    if (newDownloadedChapters.isNotEmpty || incomplete.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ?, incomplete_pages = ? WHERE id = ? AND comic_type = ?;',
        [
          jsonEncode(newDownloadedChapters),
          jsonEncode({
            for (final entry in incomplete.entries)
              entry.key: entry.value.toJson(),
          }),
          c.id,
          c.comicType.value,
        ],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
    }
    var shouldRemovedDirs = <String>[];
    for (var chapter in chapters) {
      var dir = Directory(
        FilePath.join(c.baseDir, getChapterDirectoryName(chapter)),
      );
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir.path);
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _deleteDirectories(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <String>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk) {
          var dir = Directory(FilePath.join(path, c.directory));
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir.path);
          }
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  static bool _isSafChildPath(String root, String target) {
    final prefix = root.endsWith('/') ? root : '$root/';
    if (!target.startsWith(prefix)) return false;
    return target
        .substring(prefix.length)
        .split('/')
        .every(
          (part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              !part.contains('\\'),
        );
  }

  /// Deletes the directories in a separate isolate to avoid blocking the UI thread.
  static void _deleteDirectories(List<String> paths) {
    if (paths.isEmpty) return;
    final root = LocalManager().path;
    Isolate.run(() async {
      final errors = <String>[];
      await SAFTaskWorker().init();
      await overrideIO(() async {
        for (final path in paths) {
          try {
            if (root.startsWith('android://') &&
                path.startsWith('android://') &&
                !_isSafChildPath(root, path)) {
              throw FileSystemException(
                'Refusing to delete outside the SAF library',
                path,
              );
            }
            final directory = Directory(path);
            if (directory.existsSync()) await directory.delete(recursive: true);
          } catch (error) {
            errors.add('Failed to delete $path: $error');
          }
        }
      });
      return errors;
    }).then<void>(
      (errors) {
        for (final error in errors) {
          Log.error('LocalManager', error);
        }
      },
      onError: (Object error, StackTrace stack) {
        Log.error('LocalManager', 'Directory cleanup failed: $error', stack);
      },
    );
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }
}

enum LocalSortType {
  name("name"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}
