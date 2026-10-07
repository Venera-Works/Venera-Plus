import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/throttled_task_runner.dart';
import 'package:venera_plus/network/cache.dart';

const _updateConcurrency = 5;
const _updateThrottleEvery = 5;

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

class ComicRefreshResult extends ComicUpdateResult {
  final FavoriteItem? item;
  final String? updateTime;

  ComicRefreshResult(
    super.updated,
    super.errorMessage, {
    this.item,
    this.updateTime,
  });
}

final _activeComics =
    <
      (LocalFavoritesManager, int, String, String),
      Future<ComicRefreshResult>
    >{};

/// Loads fresh details once across overlapping local, automatic and remote
/// refreshes. Only memberships existing at request start are eligible for writes.
Future<ComicRefreshResult> refreshComic(
  Comic comic, {
  Future<void> Function(Duration duration)? retryDelay,
}) {
  final manager = LocalFavoritesManager();
  final key = (manager, manager.generation, comic.sourceKey, comic.id);
  final active = _activeComics[key];
  if (active != null) return active;
  final future = _refreshComic(comic, manager, retryDelay);
  _activeComics[key] = future;
  return future.whenComplete(() {
    if (identical(_activeComics[key], future)) _activeComics.remove(key);
  });
}

Future<ComicRefreshResult> _refreshComic(
  Comic comic,
  LocalFavoritesManager manager,
  Future<void> Function(Duration duration)? retryDelay,
) async {
  final type = comic is FavoriteItem
      ? comic.type
      : ComicType.fromKey(comic.sourceKey);
  if (type == ComicType.local) return ComicRefreshResult(false, null);
  final source = type.comicSource;
  if (source == null) {
    return ComicRefreshResult(false, 'Comic source not found');
  }
  final loader = source.loadComicInfo;
  if (loader == null) {
    return ComicRefreshResult(
      false,
      'Comic source does not support loading info',
    );
  }
  final generation = manager.generation;
  final readRevision = manager.readRevision(comic.id, type);
  final folders = manager.isCurrentGeneration(generation)
      ? manager.find(comic.id, type)
      : <String>[];
  final waitRetry = retryDelay ?? Future<void>.delayed;
  ComicDetails? details;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      details = (await loader(comic.id)).data;
      break;
    } catch (e, s) {
      Log.error('Check Updates', e, s);
      if (attempt == 2) return ComicRefreshResult(false, e.toString());
      await waitRetry(const Duration(seconds: 2));
    }
  }
  final info = details!;
  final tags = <String>[];
  for (final entry in info.tags.entries) {
    if (const ['author', 'artist', 'time'].contains(entry.key.toLowerCase())) {
      continue;
    }
    tags.addAll(entry.value.map((tag) => '${entry.key}:$tag'));
  }
  final item = FavoriteItem(
    id: comic.id,
    name: info.title,
    coverPath: info.cover,
    author:
        info.subTitle ??
        info.tags['author']?.firstOrNull ??
        comic.subtitle ??
        '',
    type: type,
    tags: tags,
  );
  final updateTime = info.findUpdateTime();
  var updated = false;
  if (folders.isNotEmpty && !manager.isCurrentGeneration(generation)) {
    return ComicRefreshResult(
      false,
      'Favorites changed during refresh. Refresh again.',
    );
  }
  final memberships = folders
      .where(
        (folder) =>
            manager.existsFolder(folder) &&
            manager.comicExists(folder, comic.id, type),
      )
      .toList();
  // Compare current persisted values, never the stale caller's snapshot.
  var unread = false;
  final wasRead = manager.readRevision(comic.id, type) != readRevision;
  var businessChanged = false;
  for (final folder in memberships) {
    final previous = manager.getComicWithUpdatesInfo(folder, comic.id, type);
    unread = unread || previous.hasNewUpdate;
    if (!wasRead &&
        updateTime != null &&
        previous.updateTime != null &&
        previous.updateTime != updateTime) {
      updated = true;
    }
    if (previous.name != item.name ||
        previous.author != item.author ||
        previous.coverPath != item.coverPath ||
        !listEquals(previous.tags, item.tags) ||
        (updateTime != null && previous.updateTime != updateTime)) {
      businessChanged = true;
    }
  }
  if (updated) businessChanged = true;
  if (businessChanged) {
    for (final folder in memberships) {
      manager.updateInfo(folder, item, false);
      if (updateTime != null) {
        manager.updateUpdateTime(
          folder,
          comic.id,
          type,
          updateTime,
          unread: unread || updated,
          markNew: !wasRead,
        );
      } else {
        manager.updateCheckTime(folder, comic.id, type);
      }
    }
    if (memberships.isNotEmpty) manager.notifyChanges();
  } else {
    for (final folder in memberships) {
      manager.updateCheckTime(folder, comic.id, type);
    }
  }
  return ComicRefreshResult(updated, null, item: item, updateTime: updateTime);
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo comic,
  String folder, {
  Future<void> Function(Duration duration)? retryDelay,
}) async {
  final manager = LocalFavoritesManager();
  if (manager.isCurrentGeneration(manager.generation) &&
      (!manager.existsFolder(folder) ||
          !manager.comicExists(folder, comic.id, comic.type))) {
    return ComicUpdateResult(
      false,
      'Favorites changed during refresh. Refresh again.',
    );
  }
  return refreshComic(comic, retryDelay: retryDelay);
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
  ]);
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
    stream.add(UpdateProgress(pending.length, 0, 0, 0));
    await runThrottledTasks(
      pending,
      concurrency: _updateConcurrency,
      throttleEvery: _updateThrottleEvery,
      run: (comic) async {
        final result = manager.isCurrentGeneration(generation)
            ? await refreshComic(comic)
            : ComicRefreshResult(
                false,
                'Favorites changed during refresh. Refresh again.',
              );
        current++;
        if (result.updated) updated++;
        if (result.errorMessage != null) errors++;
        stream.add(
          UpdateProgress(
            pending.length,
            current,
            errors,
            updated,
            comic,
            result.errorMessage,
          ),
        );
      },
    );
  } catch (e, s) {
    stream.addError(e, s);
  } finally {
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
