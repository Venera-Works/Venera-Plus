import 'dart:async';
import 'dart:convert';
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
import 'package:venera_plus/features/history/reading_progress.dart';

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

  ReadingProgress? readingProgress;

  History.fromModel({
    required HistoryMixin model,
    required this.ep,
    required this.page,
    this.group,
    Set<String>? readChapters,
    DateTime? time,
    this.readDurationMs = 0,
    this.readingProgress,
  }) : type = model.historyType,
       title = model.title,
       subtitle = model.subTitle ?? '',
       cover = model.cover,
       id = model.id,
       readEpisode = readChapters ?? <String>{},
       time = time ?? DateTime.now();

  // Progress and its catalog are immutable; only the mutable chapter set
  // needs a copy when taking a snapshot for a queued write.
  History._copy(History other)
    : type = other.type,
      time = other.time,
      title = other.title,
      subtitle = other.subtitle,
      cover = other.cover,
      ep = other.ep,
      page = other.page,
      group = other.group,
      id = other.id,
      readEpisode = Set<String>.of(other.readEpisode),
      maxPage = other.maxPage,
      readDurationMs = other.readDurationMs,
      readingProgress = other.readingProgress;

  History.fromMap(Map<String, dynamic> map)
    : type = HistoryType(map["type"]),
      time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
      title = map["title"] ?? '',
      subtitle = map["subtitle"] ?? '',
      cover = map["cover"] ?? '',
      ep = (map["ep"] as num?)?.toInt() ?? 0,
      page = (map["page"] as num?)?.toInt() ?? 0,
      id = map["id"],
      readEpisode = _readEpisodeSet(map["readEpisode"]),
      maxPage = (map["max_page"] ?? map["maxPage"]) as int?,
      group = (map["chapter_group"] ?? map["group"]) as int?,
      readDurationMs = (map["read_duration_ms"] as num?)?.round() ?? 0,
      readingProgress = _readReadingProgress(
        map["readingProgress"] ?? map["reading_progress"],
      );

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
      readDurationMs = ((row["read_duration_ms"] as num?) ?? 0).round(),
      readingProgress = _readReadingProgress(row["reading_progress"]);

  ReadingPosition? get resumePosition {
    final progress = readingProgress;
    if (progress != null) return progress.resumePosition;
    final position = ReadingPosition(ep: ep, page: page, group: group);
    return position.isValid ? position : null;
  }

  bool get hasReadingProgress =>
      readingProgress?.hasProgress ?? (resumePosition != null);

  bool get hasOrderConflict => readingProgress?.hasOrderConflict ?? false;

  String? get activeRereadId => readingProgress?.activeRoundId;
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

Set<String> _readEpisodeSet(Object? value) {
  if (value is String) {
    return value.split(',').where((element) => element.isNotEmpty).toSet();
  }
  if (value is Iterable) {
    return value.map((element) => element.toString()).toSet();
  }
  return <String>{};
}

ReadingProgress? _readReadingProgress(Object? value) {
  if (value == null) return null;
  return ReadingProgress.fromJson(value is String ? jsonDecode(value) : value);
}

typedef HistoryReadingProgressCatalogResolver =
    Future<bool> Function(String recordKey, ReadingCatalog catalog);

HistoryReadingProgressCatalogResolver? _historyReadingProgressCatalogResolver;

void configureHistoryReadingProgressCatalogResolver(
  HistoryReadingProgressCatalogResolver? resolver,
) {
  _historyReadingProgressCatalogResolver = resolver;
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
  final Map<String, History> _pendingReadingProgress = {};
  final Map<String, History> _queuedHistories = {};
  Timer? _readingProgressTimer;
  final Map<String, int> _historyDeletionGeneration = {};
  final Map<String, int> _historyOperationRevision = {};

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

  static ReadingProgress _progressForHistory(History item) {
    final progress = item.readingProgress;
    if (progress != null) return progress;
    final position = item.resumePosition;
    return position == null
        ? ReadingProgress.fromJson(null)
        : ReadingProgress.seed(
            position,
            time: item.time.millisecondsSinceEpoch,
          );
  }

  static int _maxInt(int left, int right) => left > right ? left : right;

  static History? _readPersistedHistory(Database db, History item) {
    final rows = db.select('SELECT * FROM history WHERE id = ? AND type = ?;', [
      item.id,
      item.type.value,
    ]);
    return rows.isEmpty ? null : History.fromRow(rows.first);
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

  static History _writeHistory(Database db, History item) {
    _runWriteTransaction(db, () {
      final rows = db.select(
        'SELECT * FROM history WHERE id = ? AND type = ?;',
        [item.id, item.type.value],
      );
      final existing = rows.isEmpty ? null : History.fromRow(rows.first);
      final progress = _progressForHistory(item).merge(
        existing == null
            ? ReadingProgress.fromJson(null)
            : _progressForHistory(existing),
      );
      final position = progress.resumePosition;
      final ep = position?.ep ?? (existing?.ep ?? item.ep);
      final page = position?.page ?? (existing?.page ?? item.page);
      final group = position != null
          ? position.group
          : existing != null
          ? existing.group
          : item.group;
      final visitedChapters = {
        ...?existing?.readEpisode,
        ...item.readEpisode,
      }.toList()..sort();
      final time = _maxInt(
        _maxInt(
          item.time.millisecondsSinceEpoch,
          existing?.time.millisecondsSinceEpoch ?? 0,
        ),
        progress.time,
      );
      db.execute(
        '''
        INSERT OR REPLACE INTO history (
          id, title, subtitle, cover, time, type, ep, page, readEpisode,
          max_page, chapter_group, read_duration_ms, reading_progress,
          sync_projection
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL);
        ''',
        [
          item.id,
          item.title,
          item.subtitle,
          item.cover,
          time,
          item.type.value,
          ep,
          page,
          visitedChapters.join(','),
          item.maxPage ?? existing?.maxPage,
          group,
          _maxInt(item.readDurationMs, existing?.readDurationMs ?? 0),
          jsonEncode(progress.toJson()),
        ],
      );
    });
    return _readPersistedHistory(db, item)!;
  }

  static History _writeReadDuration(Database db, History item, int durationMs) {
    _runWriteTransaction(db, () {
      final existing = _readPersistedHistory(db, item);
      if (existing != null) {
        db.execute(
          '''
          UPDATE history
          SET read_duration_ms = COALESCE(read_duration_ms, 0) + ?,
              sync_projection = NULL
          WHERE id = ? AND type = ?;
          ''',
          [durationMs, item.id, item.type.value],
        );
        return;
      }

      final progress = _progressForHistory(item);
      final position = progress.resumePosition;
      final time = _maxInt(item.time.millisecondsSinceEpoch, progress.time);
      final visitedChapters = item.readEpisode.toList()..sort();
      db.execute(
        '''
        INSERT OR REPLACE INTO history (
          id, title, subtitle, cover, time, type, ep, page, readEpisode,
          max_page, chapter_group, read_duration_ms, reading_progress,
          sync_projection
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL);
        ''',
        [
          item.id,
          item.title,
          item.subtitle,
          item.cover,
          time,
          item.type.value,
          position?.ep ?? item.ep,
          position?.page ?? item.page,
          visitedChapters.join(','),
          item.maxPage,
          position != null ? position.group : item.group,
          item.readDurationMs + durationMs,
          jsonEncode(progress.toJson()),
        ],
      );
    });
    return _readPersistedHistory(db, item)!;
  }

  static Future<void> _addHistoryAsync(String dbPath, History newItem) {
    return Isolate.run(() {
      final db = openSqliteDatabase(dbPath);
      try {
        db.execute('PRAGMA busy_timeout = 5000;');
        HistorySyncData.ensureSchema(db);
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
      final db = openSqliteDatabase(dbPath);
      try {
        db.execute('PRAGMA busy_timeout = 5000;');
        HistorySyncData.ensureSchema(db);
        _writeReadDuration(db, item, durationMs);
      } finally {
        db.dispose();
      }
    });
  }

  Future<void> _asyncHistoryQueue = Future.value();

  void _mergeHistorySnapshot(History target, History other) {
    target.readingProgress = _progressForHistory(
      target,
    ).merge(_progressForHistory(other));
    target.readDurationMs = _maxInt(
      target.readDurationMs,
      other.readDurationMs,
    );
    target.maxPage ??= other.maxPage;
    if (other.time.isAfter(target.time)) target.time = other.time;
    target.readEpisode.addAll(other.readEpisode);
    final resume = target.readingProgress!.resumePosition;
    if (resume != null) {
      target
        ..ep = resume.ep
        ..page = resume.page
        ..group = resume.group;
    }
  }

  History _historySnapshotForWrite(History item) {
    final snapshot = History._copy(item);
    final key = _historyKey(item.id, item.type);
    for (final candidate in [
      _pendingReadingProgress[key],
      _queuedHistories[key],
      cachedHistories[key],
    ]) {
      if (candidate != null && !identical(candidate, item)) {
        _mergeHistorySnapshot(snapshot, candidate);
      }
    }
    return snapshot;
  }

  int _writeGeneration(String key) => _historyDeletionGeneration[key] ?? 0;

  int _advanceHistoryRevision(String key) {
    final next = (_historyOperationRevision[key] ?? 0) + 1;
    _historyOperationRevision[key] = next;
    return next;
  }

  int _invalidateHistory(String key) {
    _historyDeletionGeneration[key] = _writeGeneration(key) + 1;
    final revision = _advanceHistoryRevision(key);
    _pendingReadingProgress.remove(key);
    _queuedHistories.remove(key);
    cachedHistories.remove(key);
    if (_pendingReadingProgress.isEmpty) {
      _readingProgressTimer?.cancel();
      _readingProgressTimer = null;
    } else {
      _scheduleReadingProgressFlush();
    }
    return revision;
  }

  void _queueDelete(String key, int revision, {int? beforeTime}) {
    final (id, typeValue) = _historyIdentity(key);
    _enqueueAsyncWrite(() async {
      if (_historyOperationRevision[key] != revision) return;
      final cutoffClause = beforeTime == null ? '' : ' AND time < ?';
      _db.execute(
        'DELETE FROM history WHERE id = ? AND type = ?$cutoffClause;',
        beforeTime == null ? [id, typeValue] : [id, typeValue, beforeTime],
      );
      updateCache();
      notifyListeners();
    });
  }

  Future<void> addHistoryAsync(History newItem) {
    final snapshot = _historySnapshotForWrite(newItem);
    final key = _historyKey(snapshot.id, snapshot.type);
    _advanceHistoryRevision(key);
    final generation = _writeGeneration(key);
    _queuedHistories[key] = snapshot;
    return _enqueueAsyncWrite(() => _writeHistoryAsync(snapshot, generation));
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

  Future<void> _writeHistoryAsync(History newItem, int generation) async {
    final key = _historyKey(newItem.id, newItem.type);
    if (_writeGeneration(key) != generation) return;
    await _addHistoryAsync(_dbPath, newItem);
    if (_writeGeneration(key) != generation || !isInitialized) return;
    final actual = _readPersistedHistory(_db, newItem);
    if (actual == null) return;
    if (identical(_queuedHistories[key], newItem)) {
      _queuedHistories.remove(key);
    }
    _cacheHistory(actual);
    notifyListeners();
  }

  /// Atomically adds foreground reading time without replacing progress data.
  Future<void> addReadDuration(History item, Duration duration) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0) return Future.value();
    final snapshot = _historySnapshotForWrite(item);
    final key = _historyKey(snapshot.id, snapshot.type);
    _advanceHistoryRevision(key);
    final generation = _writeGeneration(key);
    _queuedHistories[key] = snapshot;
    return _enqueueAsyncWrite(() async {
      if (_writeGeneration(key) != generation) return;
      await _addReadDurationAsync(_dbPath, snapshot, durationMs);
      if (_writeGeneration(key) != generation || !isInitialized) return;
      final actual = _readPersistedHistory(_db, snapshot);
      if (actual == null) return;
      if (identical(_queuedHistories[key], snapshot)) {
        _queuedHistories.remove(key);
      }
      item.readDurationMs = actual.readDurationMs;
      _cacheHistory(actual);
      notifyListeners();
    });
  }

  Future<void> waitForAsyncWrites() {
    return _asyncHistoryQueue;
  }

  ReadingProgress recordReadingProgress(
    History item, {
    required ReadingPosition position,
    required ReadingNavigationSource source,
    String? sessionRoundId,
    String? commandId,
    ReadingCatalog? catalog,
    ReadingProgress? observedProgress,
    void Function(String commandId, ReadingProgress progress)?
    onLocalProgressRecorded,
  }) {
    final key = _historyKey(item.id, item.type);
    _advanceHistoryRevision(key);
    final cached = cachedHistories[key] ?? find(item.id, item.type);
    final pending = _pendingReadingProgress[key];
    final queued = _queuedHistories[key];
    var latestProgress = _progressForHistory(item);
    for (final current in [pending, queued, cached]) {
      if (current != null && !identical(current, item)) {
        latestProgress = latestProgress.merge(_progressForHistory(current));
      }
    }
    final actionSnapshot = observedProgress ?? latestProgress;
    if (catalog != null) {
      latestProgress = latestProgress.rebaseCatalog(catalog);
    }
    var progress = catalog == null
        ? actionSnapshot
        : actionSnapshot.rebaseCatalog(catalog);
    final observedRoundIds =
        source == ReadingNavigationSource.userBackward ||
            source == ReadingNavigationSource.userSeek ||
            source == ReadingNavigationSource.userConfirm
        ? actionSnapshot.activeRoundIds.toList(growable: false)
        : null;
    final now = DateTime.now();
    progress = progress.record(
      position,
      source: source,
      sessionRoundId: sessionRoundId,
      newRoundId: commandId,
      catalog: catalog,
      time: now.millisecondsSinceEpoch,
      observedRoundIds: observedRoundIds,
    );
    if (commandId != null) {
      // Retained gestures observe their own validated writes, not roots that
      // arrived remotely after the gesture started.
      onLocalProgressRecorded?.call(commandId, progress);
    }
    if (observedProgress != null) {
      progress = progress.merge(latestProgress);
    }
    item
      ..readingProgress = progress
      ..time = now;
    if (position.isValid) {
      final visiblePosition = catalog?.rebasePosition(position) ?? position;
      item
        ..ep = visiblePosition.ep
        ..page = visiblePosition.page
        ..group = visiblePosition.group;
    }
    _pendingReadingProgress[key] = History._copy(item);
    _scheduleReadingProgressFlush();
    _cacheHistory(item);
    notifyListeners();
    return progress;
  }

  void _scheduleReadingProgressFlush() {
    _readingProgressTimer?.cancel();
    if (_pendingReadingProgress.isEmpty) {
      _readingProgressTimer = null;
      return;
    }
    _readingProgressTimer = Timer(const Duration(seconds: 1), () {
      _readingProgressTimer = null;
      unawaited(
        flushReadingProgress().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          Log.error("History", error, stackTrace);
        }),
      );
    });
  }

  Future<void> flushReadingProgress({String? id, ComicType? type}) async {
    bool matches(String key, History item) =>
        (id == null || item.id == id) && (type == null || item.type == type);

    while (true) {
      final batch = _pendingReadingProgress.entries
          .where((entry) => matches(entry.key, entry.value))
          .map((entry) => MapEntry(entry.key, History._copy(entry.value)))
          .toList(growable: false);
      if (batch.isEmpty) {
        await waitForAsyncWrites();
        final pendingRemains = _pendingReadingProgress.entries.any(
          (entry) => matches(entry.key, entry.value),
        );
        if (!pendingRemains) break;
        continue;
      }
      _readingProgressTimer?.cancel();
      _readingProgressTimer = null;
      for (final entry in batch) {
        _pendingReadingProgress.remove(entry.key);
      }
      final writes = <Future<void>>[];
      for (final entry in batch) {
        final generation = _writeGeneration(entry.key);
        _queuedHistories[entry.key] = entry.value;
        writes.add(
          _enqueueAsyncWrite(() => _writeHistoryAsync(entry.value, generation)),
        );
      }
      try {
        await Future.wait(writes);
      } catch (_) {
        for (final entry in batch) {
          final latest = _pendingReadingProgress[entry.key];
          if (latest == null) {
            _pendingReadingProgress[entry.key] = entry.value;
          } else {
            _mergeHistorySnapshot(latest, entry.value);
          }
        }
        _scheduleReadingProgressFlush();
        rethrow;
      }
    }
    if (_pendingReadingProgress.isEmpty) {
      _readingProgressTimer?.cancel();
      _readingProgressTimer = null;
    } else {
      _scheduleReadingProgressFlush();
    }
  }

  Future<History> resolveReadingProgressCatalog(
    History fallback,
    ReadingCatalog catalog,
  ) async {
    await flushReadingProgress(id: fallback.id, type: fallback.type);
    final recordKey = syncRecordKey('history', [
      fallback.id,
      fallback.type.value,
    ]);
    final resolver = _historyReadingProgressCatalogResolver;
    final before = _reloadCurrentHistory(fallback);
    if (resolver != null && await resolver(recordKey, catalog)) {
      // A reader that was already open can record progress while the sync
      // resolver is waiting. Drain it after resolution as well, so the
      // resolver's database result cannot hide a later local write.
      await flushReadingProgress(id: fallback.id, type: fallback.type);
      await waitForAsyncWrites();
      final current = _reloadCurrentHistory(fallback);
      return current ?? _historyWithoutProgress(before ?? fallback);
    }

    await flushReadingProgress(id: fallback.id, type: fallback.type);
    final current = _reloadCurrentHistory(fallback);
    if (current == null) {
      return before == null
          ? _normalizeFallbackHistory(fallback, catalog)
          : _historyWithoutProgress(before);
    }
    if (current.readingProgress == null && current.resumePosition == null) {
      return current;
    }

    final progress = current.readingProgress ?? _progressForHistory(current);
    final normalized = progress.normalizeForCatalog(catalog);
    if (normalized == null ||
        jsonEncode(normalized.toJson()) == jsonEncode(progress.toJson())) {
      return current;
    }

    final resolved = History._copy(current)..readingProgress = normalized;
    final position = normalized.resumePosition;
    if (position != null) {
      resolved
        ..ep = position.ep
        ..page = position.page
        ..group = position.group;
    }
    await _writeCatalogNormalizedHistory(current, resolved);
    return _reloadCurrentHistory(fallback) ?? _historyWithoutProgress(current);
  }

  History? _reloadCurrentHistory(History identity) {
    final key = _historyKey(identity.id, identity.type);
    final current = _readPersistedHistory(_db, identity);
    final queued = _queuedHistories[key];
    final pending = _pendingReadingProgress[key];
    if (current == null) {
      if (queued == null && pending == null) {
        updateCache();
        return null;
      }
      final live = History._copy(pending ?? queued!);
      if (queued != null && pending != null && !identical(queued, pending)) {
        _mergeHistorySnapshot(live, queued);
      }
      _cacheHistory(live);
      return live;
    }
    if (queued != null && !identical(queued, current)) {
      _mergeHistorySnapshot(current, queued);
    }
    if (pending != null && !identical(pending, current)) {
      _mergeHistorySnapshot(current, pending);
    }
    _cacheHistory(current);
    return current;
  }

  History _historyWithoutProgress(History history) {
    final copy = History._copy(history)
      ..ep = 0
      ..page = 0
      ..group = null
      ..readingProgress = null;
    return copy;
  }

  History _normalizeFallbackHistory(History history, ReadingCatalog catalog) {
    if (history.readingProgress == null && history.resumePosition == null) {
      return History._copy(history);
    }
    final progress = history.readingProgress ?? _progressForHistory(history);
    final normalized = progress.normalizeForCatalog(catalog);
    if (normalized == null) return History._copy(history);
    final copy = History._copy(history)..readingProgress = normalized;
    final position = normalized.resumePosition;
    if (position != null) {
      copy
        ..ep = position.ep
        ..page = position.page
        ..group = position.group;
    }
    return copy;
  }

  bool _sameReadingProgressInput(History current, History expected) =>
      current.ep == expected.ep &&
      current.page == expected.page &&
      current.group == expected.group &&
      jsonEncode(current.readingProgress?.toJson()) ==
          jsonEncode(expected.readingProgress?.toJson());

  Future<void> _writeCatalogNormalizedHistory(
    History expected,
    History normalized,
  ) async {
    final key = _historyKey(expected.id, expected.type);
    final revision = _advanceHistoryRevision(key);
    final generation = _writeGeneration(key);
    final snapshot = History._copy(normalized);
    _queuedHistories[key] = snapshot;
    await _enqueueAsyncWrite(() async {
      var updated = false;
      try {
        if (_historyOperationRevision[key] != revision ||
            _writeGeneration(key) != generation) {
          return;
        }
        _runWriteTransaction(_db, () {
          final rows = _db.select(
            'SELECT * FROM history WHERE id = ? AND type = ?;',
            [expected.id, expected.type.value],
          );
          if (rows.isEmpty) return;
          final current = History.fromRow(rows.first);
          if (!_sameReadingProgressInput(current, expected)) return;
          _db.execute(
            '''
            UPDATE history
            SET ep = ?, page = ?, chapter_group = ?, reading_progress = ?,
                sync_projection = NULL
            WHERE id = ? AND type = ?;
            ''',
            [
              snapshot.ep,
              snapshot.page,
              snapshot.group,
              jsonEncode(snapshot.readingProgress!.toJson()),
              snapshot.id,
              snapshot.type.value,
            ],
          );
          updated = true;
        });
        if (updated &&
            _historyOperationRevision[key] == revision &&
            _writeGeneration(key) == generation) {
          final actual = _readPersistedHistory(_db, snapshot);
          if (actual != null) {
            _cacheHistory(actual);
            notifyListeners();
          }
        }
      } finally {
        if (identical(_queuedHistories[key], snapshot)) {
          _queuedHistories.remove(key);
        }
      }
    });
  }

  void _cacheHistory(History newItem) {
    final key = _historyKey(newItem.id, newItem.type);
    final pending = _pendingReadingProgress[key];
    if (pending != null && !identical(pending, newItem)) {
      _mergeHistorySnapshot(newItem, pending);
    }
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
    final snapshot = _historySnapshotForWrite(newItem);
    final key = _historyKey(snapshot.id, snapshot.type);
    _advanceHistoryRevision(key);
    _queuedHistories[key] = snapshot;
    final actual = _writeHistory(_db, snapshot);
    if (identical(_queuedHistories[key], snapshot)) {
      _queuedHistories.remove(key);
    }
    _cacheHistory(actual);
    notifyListeners();
  }

  Set<String> _knownHistoryKeys() {
    final keys = <String>{
      ..._pendingReadingProgress.keys,
      ..._queuedHistories.keys,
      ...cachedHistories.keys,
    };
    for (final row in _db.select('SELECT id, type FROM history;')) {
      keys.add(_historyKey(row['id'] as String, ComicType(row['type'] as int)));
    }
    return keys;
  }

  (String, int) _historyIdentity(String key) {
    final separator = key.indexOf(':');
    return (
      key.substring(separator + 1),
      int.parse(key.substring(0, separator)),
    );
  }

  void clearHistory() {
    final keys = _knownHistoryKeys();
    final revisions = {for (final key in keys) key: _invalidateHistory(key)};
    _db.execute('DELETE FROM history;');
    updateCache();
    notifyListeners();
    for (final entry in revisions.entries) {
      _queueDelete(entry.key, entry.value);
    }
  }

  void clearExpiredHistory(int retentionDays) {
    if (retentionDays <= 0) return;
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays))
        .millisecondsSinceEpoch;
    final rowTimes = <String, int>{};
    final keysToDelete = <String>{};
    for (final row in _db.select('SELECT id, type, time FROM history;')) {
      final key = _historyKey(
        row['id'] as String,
        ComicType((row['type'] as num).toInt()),
      );
      final time = (row['time'] as num?)?.toInt() ?? 0;
      rowTimes[key] = time;
      final pending = _pendingReadingProgress[key] ?? _queuedHistories[key];
      if (time < cutoff &&
          (pending == null || pending.time.millisecondsSinceEpoch < cutoff)) {
        keysToDelete.add(key);
      }
    }
    for (final entry in {
      ..._pendingReadingProgress.entries,
      ..._queuedHistories.entries,
    }) {
      final rowTime = rowTimes[entry.key];
      if ((rowTime == null || rowTime < cutoff) &&
          entry.value.time.millisecondsSinceEpoch < cutoff) {
        keysToDelete.add(entry.key);
      }
    }
    final revisions = {
      for (final key in keysToDelete) key: _invalidateHistory(key),
    };
    for (final entry in revisions.entries) {
      final (id, typeValue) = _historyIdentity(entry.key);
      _db.execute(
        'DELETE FROM history WHERE id = ? AND type = ? AND time < ?;',
        [id, typeValue, cutoff],
      );
    }
    updateCache();
    notifyListeners();
    for (final entry in revisions.entries) {
      _queueDelete(entry.key, entry.value, beforeTime: cutoff);
    }
  }

  void clearUnfavoritedHistory() {
    final favorites = LocalFavoritesManager();
    final keysToDelete = <String>{};
    for (final row in _db.select('SELECT id, type FROM history;')) {
      final id = row['id'] as String;
      final type = ComicType((row['type'] as num).toInt());
      if (!favorites.isExist(id, type)) keysToDelete.add(_historyKey(id, type));
    }
    for (final item in [
      ..._pendingReadingProgress.values,
      ..._queuedHistories.values,
    ]) {
      if (!favorites.isExist(item.id, item.type)) {
        keysToDelete.add(_historyKey(item.id, item.type));
      }
    }
    final revisions = {
      for (final key in keysToDelete) key: _invalidateHistory(key),
    };
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (final key in keysToDelete) {
        final (id, typeValue) = _historyIdentity(key);
        _db.execute('DELETE FROM history WHERE id = ? AND type = ?;', [
          id,
          typeValue,
        ]);
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
    for (final entry in revisions.entries) {
      _queueDelete(entry.key, entry.value);
    }
  }

  void remove(String id, ComicType type) async {
    final key = _historyKey(id, type);
    final revision = _invalidateHistory(key);
    _db.execute('DELETE FROM history WHERE id = ? AND type = ?;', [
      id,
      type.value,
    ]);
    updateCache();
    notifyListeners();
    _queueDelete(key, revision);
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
  /// Flushes coalesced reading progress and queued writes before sync capture.
  Future<SyncRecords> exportSyncRecords() async {
    await flushReadingProgress();
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
    final previousHistoryKeys = applyHistory ? _knownHistoryKeys() : <String>{};
    final result = HistorySyncData.applySyncRecords(
      _db,
      records,
      applyHistory: applyHistory,
      applyImageFavorites: applyImageFavorites,
    );
    if (applyHistory) {
      final remainingKeys = <String>{
        for (final row in _db.select('SELECT id, type FROM history;'))
          _historyKey(
            row['id'] as String,
            ComicType((row['type'] as num).toInt()),
          ),
      };
      for (final key in previousHistoryKeys) {
        if (remainingKeys.contains(key)) continue;
        final revision = _invalidateHistory(key);
        _queueDelete(key, revision);
      }
    }
    if (!result.hasChanges) return;
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
    _readingProgressTimer?.cancel();
    _readingProgressTimer = null;
    final pending = _pendingReadingProgress.values.toList(growable: false);
    _pendingReadingProgress.clear();
    for (final item in pending) {
      _writeHistory(_db, item);
    }
    isInitialized = false;
    _db.dispose();
  }

  void notifyChanges() {
    updateCache();
    notifyListeners();
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    final keys = histories
        .map((history) => _historyKey(history.id, history.type))
        .toSet();
    final revisions = {for (final key in keys) key: _invalidateHistory(key)};
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (final history in histories) {
        _db.execute('DELETE FROM history WHERE id = ? AND type = ?;', [
          history.id,
          history.type.value,
        ]);
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
    for (final entry in revisions.entries) {
      _queueDelete(entry.key, entry.value);
    }
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
