import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/history_contract.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/image_favorites.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/throttled_task_runner.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/features/history/history_sync_data.dart';

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  /// Cumulative foreground reading time for this comic.
  int readDurationMs;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
    this.readDurationMs = 0,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"],
      subtitle = map["subtitle"],
      cover = map["cover"],
      ep = map["ep"],
      page = map["page"],
      id = map["id"],
      readEpisode = Set<String>.from(
        (map["readEpisode"] as List<dynamic>?)?.toSet() ?? const <String>{},
      ),
      maxPage = map["max_page"],
      readDurationMs = (map["read_duration_ms"] as num?)?.round() ?? 0;

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
    : type = HistoryType(row["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
      title = row["title"] ?? '',
      subtitle = row["subtitle"] ?? '',
      cover = row["cover"] ?? '',
      ep = row["ep"],
      page = row["page"],
      id = row["id"],
      readEpisode = Set<String>.from(
        (row["readEpisode"] as String? ?? '')
            .split(',')
            .where((element) => element != ""),
      ),
      maxPage = row["max_page"],
      group = row["chapter_group"],
      readDurationMs = ((row["read_duration_ms"] as num?) ?? 0).round();
  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description {
    var res = "";
    if (group != null) {
      res += "${"Group @group".tlParams({"group": group!})} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({"ep": ep});
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({"page": page});
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  Database get imageFavoritesDatabase => _db;

  late String _dbPath;

  int get length => _db.select("select count(*) from history;").first[0] as int;

  static String _historyKey(String id, ComicType type) => "${type.value}:$id";

  /// Cache of history keys (type:id). Improves the performance of find operations.
  Map<String, bool>? _cachedHistoryKeys;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _dbPath = "${App.dataPath}/history.db";
    _db = openSqliteDatabase(_dbPath);
    HistorySyncData.ensureSchema(_db);

    notifyListeners();
    ImageFavoriteManager().init();
    clearExpiredHistory(
      (appdata.settings['historyRetentionDays'] as num?)?.round() ?? 0,
    );
    isInitialized = true;
  }

  static const _insertHistorySql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  static const _updateHistorySql = """
        update history set
          title = ?,
          subtitle = ?,
          cover = ?,
          time = ?,
          ep = ?,
          page = ?,
          readEpisode = ?,
          max_page = ?,
          chapter_group = ?
        where id = ? and type = ?;
      """;

  static const _insertReadDurationSql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, read_duration_ms)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """;

  static const _incrementReadDurationSql = """
        update history
        set read_duration_ms = read_duration_ms + ?
        where id = ? and type = ?;
      """;

  static List<Object?> _historyValues(History item) {
    return [
      item.id,
      item.title,
      item.subtitle,
      item.cover,
      item.time.millisecondsSinceEpoch,
      item.type.value,
      item.ep,
      item.page,
      item.readEpisode.join(','),
      item.maxPage,
      item.group,
    ];
  }

  static void _runWriteTransaction(Database db, void Function() write) {
    db.execute('BEGIN IMMEDIATE;');
    try {
      write();
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  // Legacy databases do not consistently expose a single-column UNIQUE(id).
  static void _writeHistory(Database db, History item) {
    _runWriteTransaction(db, () {
      db.execute(_updateHistorySql, [
        item.title,
        item.subtitle,
        item.cover,
        item.time.millisecondsSinceEpoch,
        item.ep,
        item.page,
        item.readEpisode.join(','),
        item.maxPage,
        item.group,
        item.id,
        item.type.value,
      ]);
      if (db.updatedRows == 0) {
        db.execute(_insertHistorySql, [
          ..._historyValues(item),
          item.readDurationMs,
        ]);
      }
    });
  }

  static void _writeReadDuration(Database db, History item, int durationMs) {
    _runWriteTransaction(db, () {
      db.execute(_incrementReadDurationSql, [
        durationMs,
        item.id,
        item.type.value,
      ]);
      if (db.updatedRows == 0) {
        db.execute(_insertReadDurationSql, [
          ..._historyValues(item),
          durationMs,
        ]);
      }
    });
  }

  static Future<void> _addHistoryAsync(String dbPath, History newItem) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        db.execute('PRAGMA busy_timeout = 5000;');
        _writeHistory(db, newItem);
      } finally {
        db.dispose();
      }
    });
  }

  static Future<void> _addReadDurationAsync(
    String dbPath,
    History item,
    int durationMs,
  ) {
    return Isolate.run(() {
      var db = openSqliteDatabase(dbPath);
      try {
        db.execute('PRAGMA busy_timeout = 5000;');
        _writeReadDuration(db, item, durationMs);
      } finally {
        db.dispose();
      }
    });
  }

  Future<void> _asyncHistoryQueue = Future.value();

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem) {
    return _enqueueAsyncWrite(() => _writeHistoryAsync(newItem));
  }

  Future<void> _enqueueAsyncWrite(Future<void> Function() write) {
    final next = _asyncHistoryQueue.then(
      (_) => write(),
      onError: (_) => write(),
    );
    _asyncHistoryQueue = next.catchError((Object error, StackTrace stackTrace) {
      Log.error("History", error, stackTrace);
    });
    return next;
  }

  Future<void> _writeHistoryAsync(History newItem) async {
    await _addHistoryAsync(_dbPath, newItem);
    _cacheHistory(newItem);
    notifyListeners();
  }

  /// Atomically adds foreground reading time without replacing progress data.
  Future<void> addReadDuration(History item, Duration duration) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0) return Future.value();
    return _enqueueAsyncWrite(() async {
      await _addReadDurationAsync(_dbPath, item, durationMs);
      item.readDurationMs += durationMs;
      _cacheHistory(item);
      notifyListeners();
    });
  }

  Future<void> waitForAsyncWrites() {
    return _asyncHistoryQueue;
  }

  void _cacheHistory(History newItem) {
    final key = _historyKey(newItem.id, newItem.type);
    if (_cachedHistoryKeys == null) {
      updateCache();
    } else {
      _cachedHistoryKeys![key] = true;
    }
    cachedHistories[key] = newItem;
    if (cachedHistories.length > 20) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
  }

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem) {
    _writeHistory(_db, newItem);
    _cacheHistory(newItem);
    notifyListeners();
  }

  void clearHistory() {
    _db.execute("delete from history;");
    updateCache();
    notifyListeners();
  }

  void clearExpiredHistory(int retentionDays) {
    if (retentionDays <= 0) return;
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .millisecondsSinceEpoch;
    _db.execute(
      """
      delete from history
      where time < ?;
    """,
      [cutoff],
    );
    updateCache();
    notifyListeners();
  }

  void clearUnfavoritedHistory() {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = ComicType(element["type"] as int);
        if (!LocalFavoritesManager().isExist(id, type)) {
          _db.execute(
            """
          delete from history
          where id == ? and type == ?;
        """,
            [id, type.value],
          );
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  void remove(String id, ComicType type) async {
    _db.execute(
      """
      delete from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    updateCache();
    notifyListeners();
  }

  void updateCache() {
    _cachedHistoryKeys = {};
    var res = _db.select("""
        select id, type from history;
      """);
    for (var element in res) {
      final key = _historyKey(
        element["id"] as String,
        ComicType(element["type"] as int),
      );
      _cachedHistoryKeys![key] = true;
    }
    for (var key in cachedHistories.keys.toList()) {
      if (!_cachedHistoryKeys!.containsKey(key)) {
        cachedHistories.remove(key);
      }
    }
  }

  History? find(String id, ComicType type) {
    if (_cachedHistoryKeys == null) {
      updateCache();
    }
    final key = _historyKey(id, type);
    if (!_cachedHistoryKeys!.containsKey(key)) {
      return null;
    }
    if (cachedHistories.containsKey(key)) {
      return cachedHistories[key];
    }

    var res = _db.select(
      """
      select * from history
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      return null;
    }
    final item = History.fromRow(res.first);
    cachedHistories[key] = item;
    return item;
  }

  /// Exports sync records for history, historyChapter, and imageFavorite domains.
  ///
  /// Awaits all pending asynchronous history writes before reading.
  Future<SyncRecords> exportSyncRecords() async {
    await waitForAsyncWrites();
    return HistorySyncData.readSyncRecords(_db);
  }

  /// Transactionally applies incoming history and image-favorite sync records.
  ///
  /// [applyHistory] controls history and read-chapter records, while
  /// [applyImageFavorites] controls image-favorite records. Disabled domains
  /// retain local records rather than interpreting omissions as deletions.
  void applySyncRecords(
    SyncRecords records, {
    bool applyHistory = true,
    bool applyImageFavorites = true,
  }) {
    if (!applyHistory && !applyImageFavorites) return;
    final result = HistorySyncData.applySyncRecords(
      _db,
      records,
      applyHistory: applyHistory,
      applyImageFavorites: applyImageFavorites,
    );
    if (!result.hasChanges) {
      return;
    }
    if (result.historyChanged) {
      cachedHistories.clear();
      updateCache();
      notifyListeners();
    }
    if (result.imageFavoritesChanged) {
      ImageFavoriteManager().notifyChanges();
    }
  }

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history;
    """);
    return res.first[0] as int;
  }

  int getTotalReadDurationMs() {
    var res = _db.select("""
      select coalesce(sum(read_duration_ms), 0) from history;
    """);
    return (res.first[0] as num).round();
  }

  int countWithReadDuration() {
    var res = _db.select("""
      select count(*) from history where read_duration_ms > 0;
    """);
    return (res.first[0] as num).round();
  }

  List<History> getAllByReadDuration() {
    var res = _db.select("""
      select * from history
      where read_duration_ms > 0
      order by read_duration_ms desc, time desc;
    """);
    return res.map(History.fromRow).toList();
  }

  void close() {
    isInitialized = false;
    _db.dispose();
  }

  void notifyChanges() {
    updateCache();
    notifyListeners();
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute(
          """
          delete from history
          where id == ? and type == ?;
        """,
          [history.id, history.type.value],
        );
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(
    History history, {
    Future<void> Function(Duration duration)? retryDelay,
  }) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history, retryDelay: retryDelay);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(
    History history, {
    Future<void> Function(Duration duration)? retryDelay,
  }) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    final waitRetry = retryDelay ?? Future<void>.delayed;
    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          retries--;
          if (retries == 0) {
            return false;
          }
          await waitRetry(const Duration(seconds: 2));
          continue;
        }

        var comicDetails = res.data;
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
          'read_duration_ms': history.readDurationMs,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        retries--;
        if (retries == 0) {
          return false;
        }
        await waitRetry(const Duration(seconds: 2));
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  static const _refreshConcurrency = 5;
  static const _refreshThrottleEvery = 5;

  Stream<RefreshProgress> refreshAllHistoriesStream() {
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
  ) async {
    var histories = getAll();
    int total = histories.length;
    int current = 0;
    int success = 0;
    int failed = 0;
    int skipped = 0;

    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var historiesToRefresh = <History>[];
    for (var history in histories) {
      if (history.sourceKey == 'local') {
        skipped++;
        current++;
        controller.add(
          RefreshProgress(total, current, success, failed, skipped),
        );
        continue;
      }
      historiesToRefresh.add(history);
    }

    total = historiesToRefresh.length;
    current = 0;
    controller.add(RefreshProgress(total, current, success, failed, skipped));

    await runThrottledTasks(
      historiesToRefresh,
      concurrency: _refreshConcurrency,
      throttleEvery: _refreshThrottleEvery,
      run: (history) async {
        var result = await _refreshSingleHistory(history);
        current++;
        if (result) {
          success++;
        } else {
          failed++;
        }
        controller.add(
          RefreshProgress(total, current, success, failed, skipped),
        );
      },
    );

    notifyListeners();
    controller.close();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
