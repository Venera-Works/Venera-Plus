import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/cache.dart';
import 'package:venera_plus/network/request_scope.dart';

import 'follow_update_queue.dart';

class ComicUpdateResult {
  final String? errorMessage;
  final ComicUpdateCheckStatus status;
  final int newChapterCount;

  bool get updated =>
      errorMessage == null && status == ComicUpdateCheckStatus.updated;

  ComicUpdateResult(this.status, this.errorMessage, {this.newChapterCount = 0});
}

class ComicRefreshResult extends ComicUpdateResult {
  final FavoriteItem? item;
  final String? updateTime;
  final ComicDetails? details;

  ComicRefreshResult(
    super.status,
    super.errorMessage, {
    this.item,
    this.updateTime,
    this.details,
    super.newChapterCount,
  });
}

final _activeComics =
    <(LocalFavoritesManager, int, int, String), Future<ComicRefreshResult>>{};

/// Loads fresh details once across overlapping local, automatic and remote
/// refreshes. Only memberships existing at request start are eligible for writes.
Future<ComicRefreshResult> refreshComic(
  String id,
  ComicType type, {
  String? fallbackAuthor,
}) {
  final manager = LocalFavoritesManager();
  final key = (manager, manager.generation, type.value, id);
  final active = _activeComics[key];
  if (active != null) return active;
  final future = _refreshComic(id, type, manager, fallbackAuthor);
  _activeComics[key] = future;
  return future.whenComplete(() {
    if (identical(_activeComics[key], future)) _activeComics.remove(key);
  });
}

Future<ComicRefreshResult> _refreshComic(
  String id,
  ComicType type,
  LocalFavoritesManager manager,
  String? fallbackAuthor,
) async {
  if (type == ComicType.local) {
    return ComicRefreshResult(ComicUpdateCheckStatus.unchanged, null);
  }
  final source = type.comicSource;
  if (source == null) {
    return ComicRefreshResult(
      ComicUpdateCheckStatus.unknown,
      'Comic source not found',
    );
  }
  if (source.loadComicInfo == null) {
    return ComicRefreshResult(
      ComicUpdateCheckStatus.unknown,
      'Comic source does not support loading info',
    );
  }
  final generation = manager.generation;
  final folders = manager.isCurrentGeneration(generation)
      ? manager.find(id, type)
      : <String>[];
  final previousAuthor =
      fallbackAuthor ??
      (folders.isEmpty
          ? null
          : manager.getComic(folders.first, id, type).author);
  final ComicDetails info;
  try {
    // Source loaders already handle transient read failures.
    info = (await source.loadComicInfoForReading(id, refresh: true)).data;
  } catch (e, s) {
    Log.error('Check Updates', e, s);
    return ComicRefreshResult(ComicUpdateCheckStatus.unknown, e.toString());
  }
  final tags = <String>[];
  for (final entry in info.tags.entries) {
    if (const ['author', 'artist', 'time'].contains(entry.key.toLowerCase())) {
      continue;
    }
    tags.addAll(entry.value.map((tag) => '${entry.key}:$tag'));
  }
  final item = FavoriteItem(
    id: id,
    name: info.title,
    coverPath: info.cover,
    author:
        info.subTitle ??
        info.tags['author']?.firstOrNull ??
        previousAuthor ??
        '',
    type: type,
    tags: tags,
  );
  final updateTime = info.findUpdateTime();
  final snapshot = ComicUpdateSnapshot.fromChapters(
    info.chapters?.toJson(),
    updateTime: updateTime,
    maxPage: info.maxPage,
    chapterPageCounts: info.chapterPageCounts,
  );
  if (!manager.isCurrentGeneration(generation)) {
    return ComicRefreshResult(
      ComicUpdateCheckStatus.unknown,
      'Favorites changed during refresh. Refresh again.',
    );
  }
  final memberships = folders
      .where(
        (folder) =>
            manager.existsFolder(folder) &&
            manager.comicExists(folder, id, type),
      )
      .toList();

  final currentState = manager.getUpdateState(id, type);
  final observation = currentState.observe(snapshot);
  final status = observation.status;
  final nowMs = DateTime.now().millisecondsSinceEpoch;

  manager.saveUpdateState(
    id,
    type,
    observation.state,
    checkedAt: nowMs,
    notify: false,
  );

  var metadataChanged = false;
  for (final folder in memberships) {
    final previous = manager.getComic(folder, id, type);
    if (previous.name != item.name ||
        previous.author != item.author ||
        previous.coverPath != item.coverPath ||
        !listEquals(previous.tags, item.tags)) {
      metadataChanged = true;
      break;
    }
  }
  if (metadataChanged) {
    for (final folder in memberships) {
      manager.updateInfo(folder, item, false);
    }
    manager.notifyChanges();
  } else if (observation.state != currentState) {
    manager.notifyChanges();
  }

  return ComicRefreshResult(
    status,
    null,
    item: item,
    updateTime: updateTime,
    details: info,
    newChapterCount: observation.newChapterCount,
  );
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo comic,
  String folder,
) async {
  final manager = LocalFavoritesManager();
  if (manager.isCurrentGeneration(manager.generation) &&
      (!manager.existsFolder(folder) ||
          !manager.comicExists(folder, comic.id, comic.type))) {
    return ComicUpdateResult(
      ComicUpdateCheckStatus.unknown,
      'Favorites changed during refresh. Refresh again.',
    );
  }
  return refreshComic(comic.id, comic.type, fallbackAuthor: comic.author);
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final int baseline;
  final int unknown;
  final int newChapters;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;
  final ComicUpdateCheckStatus? status;

  int get unchanged => current - errors - updated - baseline - unknown;

  UpdateProgress({
    required this.total,
    required this.current,
    required this.errors,
    required this.updated,
    this.comic,
    this.errorMessage,
    this.baseline = 0,
    this.unknown = 0,
    this.newChapters = 0,
    this.status,
  });
}

final _activeFolderUpdates =
    <(LocalFavoritesManager, int, String, bool), _FolderRefresh>{};

bool isFolderUpdating(String folder) =>
    _activeFolderUpdates.keys.any((key) => key.$3 == folder);

class _FolderRefresh {
  final _listeners = <MultiStreamController<UpdateProgress>>{};
  UpdateProgress? _latest;
  (Object, StackTrace)? _failure;
  bool _started = false;
  bool _finished = false;

  void subscribe(
    MultiStreamController<UpdateProgress> listener,
    Future<void> Function() start,
  ) {
    final latest = _latest;
    if (latest != null) listener.add(latest);
    final failure = _failure;
    if (failure != null) listener.addError(failure.$1, failure.$2);
    if (_finished) {
      listener.close();
      return;
    }
    _listeners.add(listener);
    listener.onCancel = () => _listeners.remove(listener);
    if (!_started) {
      _started = true;
      unawaited(start());
    }
  }

  void add(UpdateProgress progress) {
    _latest = progress;
    for (final listener in _listeners) {
      listener.add(progress);
    }
  }

  void addError(Object error, StackTrace trace) {
    _failure = (error, trace);
    for (final listener in _listeners) {
      listener.addError(error, trace);
    }
  }

  void close() {
    _finished = true;
    for (final listener in _listeners) {
      listener.close();
    }
    _listeners.clear();
  }
}

/// Equivalent scopes share work, including the most recent cumulative progress.
/// Detail loads also coalesce between different scopes and remote favorites.
Stream<UpdateProgress> updateFolder(String folder, bool ignoreCheckTime) {
  return Stream<UpdateProgress>.multi((listener) {
    final manager = LocalFavoritesManager();
    final key = (manager, manager.generation, folder, ignoreCheckTime);
    final operation = _activeFolderUpdates.putIfAbsent(key, _FolderRefresh.new);
    operation.subscribe(listener, () {
      // Source APIs do not expose their request URLs for targeted invalidation.
      // Invalidate once per explicit refresh, never once per comic.
      if (ignoreCheckTime) NetworkCacheManager().clear();
      return _runFolderUpdate(
        manager,
        key.$2,
        folder,
        ignoreCheckTime,
        operation,
        () => _activeFolderUpdates.remove(key),
      );
    });
  });
}

Future<void> _runFolderUpdate(
  LocalFavoritesManager manager,
  int generation,
  String folder,
  bool ignoreCheckTime,
  _FolderRefresh stream,
  void Function() onFinished,
) async {
  final scope = RequestScope();
  try {
    if (!manager.isCurrentGeneration(generation)) {
      throw StateError('Favorites changed during refresh. Refresh again.');
    }
    if (folder != localAllFolderLabel && !manager.existsFolder(folder)) {
      throw StateError('Folder not found');
    }
    final comics = folder == localAllFolderLabel
        ? manager.getAllComicsWithUpdatesInfo()
        : manager.getComicsWithUpdatesInfo(folder);
    final pending = comics
        .where(
          (comic) =>
              comic.type != ComicType.local &&
              (ignoreCheckTime ||
                  comic.lastCheckTime == null ||
                  DateTime.now().difference(comic.lastCheckTime!).inDays >= 1),
        )
        .toList();
    var current = 0;
    var errors = 0;
    var updated = 0;
    var baseline = 0;
    var unknown = 0;
    var newChapters = 0;
    stream.add(
      UpdateProgress(total: pending.length, current: 0, errors: 0, updated: 0),
    );
    await runFollowUpdateTasks(
      pending,
      sourceKey: (comic) => comic.sourceKey,
      scope: scope,
      run: (comic) async {
        final result = manager.isCurrentGeneration(generation)
            ? await refreshComic(
                comic.id,
                comic.type,
                fallbackAuthor: comic.author,
              )
            : ComicRefreshResult(
                ComicUpdateCheckStatus.unknown,
                'Favorites changed during refresh. Refresh again.',
              );
        current++;
        if (result.errorMessage != null) {
          errors++;
        } else {
          switch (result.status) {
            case ComicUpdateCheckStatus.updated:
              updated++;
              newChapters += result.newChapterCount;
              break;
            case ComicUpdateCheckStatus.baseline:
              baseline++;
              break;
            case ComicUpdateCheckStatus.unknown:
              unknown++;
              break;
            case ComicUpdateCheckStatus.unchanged:
              break;
          }
        }
        stream.add(
          UpdateProgress(
            total: pending.length,
            current: current,
            errors: errors,
            updated: updated,
            comic: comic,
            errorMessage: result.errorMessage,
            baseline: baseline,
            unknown: unknown,
            newChapters: newChapters,
            status: result.status,
          ),
        );
      },
    );
  } catch (e, s) {
    stream.addError(e, s);
  } finally {
    scope.dispose();
    onFinished();
    stream.close();
  }
}

Future<String> getUpdatedComicsAsJson(String folder) async {
  final comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  return jsonEncode(
    comics
        .where((c) => c.hasNewUpdate)
        .map(
          (c) => {
            'id': c.id,
            'name': c.name,
            'coverUrl': c.coverPath,
            'author': c.author,
            'type': c.type.sourceKey,
            'updateTime': c.updateTime,
            'tags': c.tags,
          },
        )
        .toList(),
  );
}

String buildRefreshSummary({
  required int total,
  required int updated,
  required int unchanged,
  required int baseline,
  required int unknown,
  required int errors,
  int newChapters = 0,
  String? firstError,
  String? prefixMessage,
}) {
  final messages = <String>[];
  if (prefixMessage != null && prefixMessage.isNotEmpty) {
    messages.add(prefixMessage);
  }
  if (total == 0) {
    if (messages.isEmpty) {
      messages.add("No comics to check".tl);
    }
    return messages.join('\n');
  }

  if (updated > 0) {
    if (newChapters > 0) {
      messages.add(
        "Updated @count comics (@chapters new chapters)".tlParams({
          'count': updated.toString(),
          'chapters': newChapters.toString(),
        }),
      );
    } else {
      messages.add(
        "Updated @count comics".tlParams({'count': updated.toString()}),
      );
    }
  }

  if (unchanged > 0) {
    messages.add(
      "@count comics unchanged".tlParams({'count': unchanged.toString()}),
    );
  }

  if (baseline > 0) {
    messages.add(
      "Baseline established for @count comics".tlParams({
        'count': baseline.toString(),
      }),
    );
  }

  if (unknown > 0) {
    messages.add(
      "Cannot determine updates for @count comics".tlParams({
        'count': unknown.toString(),
      }),
    );
  }

  if (errors > 0) {
    if (firstError != null && errors == 1) {
      messages.add(
        "Failed to refresh @count comics: @error".tlParams({
          'count': errors.toString(),
          'error': firstError.tl,
        }),
      );
    } else {
      messages.add(
        "Failed to refresh @count comics".tlParams({
          'count': errors.toString(),
        }),
      );
    }
  }

  if (messages.isEmpty) {
    messages.add("No updates found".tl);
  }

  return messages.join('\n');
}
