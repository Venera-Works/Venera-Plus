import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'package:flutter/foundation.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/remote_library/remote_library_repository.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/throttled_task_runner.dart';
import 'package:venera_plus/network/webdav.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'remote_archive_comic.dart';
import 'remote_comic_work.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

part 'remote_library_models.dart';
part 'remote_library_scanner.dart';
part 'remote_library_metadata.dart';
part 'remote_library_source.dart';

const _metadataFileName = 'metadata.json';
const _metadataChapterPrefix = '__cbz_range_';
const _maxDiscoveryDepth = 8;
const _maxDiscoveryDirectories = 2000;
const _maxMetadataMergeAttempts = 3;
const _maxMetadataRetryAttempts = 4;
const _defaultScraperVersion = '2';
const _metadataPendingKey = 'webdavMetadataPending';
const rootChapterId = '__root__';
const rootChapterTitle = 'Images';
const pageSize = 20;

class _RemoteLibraryEngineState {
  final snapshotCache = <String, _RemoteComicSnapshot>{};
  final snapshotInFlight = <String, Future<_RemoteComicSnapshot>>{};
  final snapshotContexts = <String, RemoteReadContext>{};
  final archiveReaders = <String, RemoteRangeReader>{};
  final archiveTokens = <CancelToken>{};
  final workVolumeLoads =
      <
        String,
        ({RemoteReadContext context, Future<RemoteArchiveComic> future})
      >{};
  final contentVersion = ValueNotifier<int>(0);
  final syncStatus = ValueNotifier<RemoteLibrarySyncStatus>(
    const RemoteLibrarySyncStatus(isSyncing: false, lastSuccessfulSync: 0),
  );
  _RemoteLibrarySyncRun? syncRun;
  int syncGeneration = 0;
  Timer? autoSyncTimer;
  Timer? contentTimer;
  int lastSuccessfulSync = 0;
  Map<String, String> failedRoots = {};
  final sortIndexes = <String, int>{};
  final statusLoads = <Future<void>>{};
  final snapshotQueries = <Future<void>>{};
  final snapshotWriteTails = <String, Future<void>>{};
  CancelToken scanToken = CancelToken();
  final lifetimeToken = CancelToken();
  bool disposed = false;
}

class RemoteLibraryEngine {
  RemoteLibraryEngine({required this.library, required RemoteFileStore store})
    : _store = store,
      _legacy = false {
    final legacy = library.sourceKey == RemoteLibrarySource.sourceKey
        ? RemoteLibraryConfig.fromSettings()
        : null;
    _configured = RemoteLibraryConfig.forRemoteLibrary(
      library,
      store,
      root: library.directories.first,
      legacyAnchor: legacy?.remotePath,
      legacyCacheKey: legacy?.cacheKey,
    );
  }

  RemoteLibraryEngine._legacy()
    : library = const RemoteLibrary(
        id: 'legacy',
        sourceKey: RemoteLibrarySource.sourceKey,
        accountId: 'legacy',
        directories: ['/'],
        name: 'Remote Library',
      ),
      _store = null,
      _legacy = true;

  final RemoteLibrary library;
  final RemoteFileStore? _store;
  final bool _legacy;
  RemoteLibraryConfig? _configured;
  final _state = _RemoteLibraryEngineState();
  final _cache = RemoteLibraryRepository.instance;
  late final _scanner = _RemoteLibraryScanner(this);
  late final _metadata = _RemoteLibraryMetadataPipeline(this);
  Timer? _autoRefreshTimer;

  // 同一账号的目录、元数据和 Range 请求共用一个调度器。
  static final _archiveAccounts =
      <String, ({RemoteReadScheduler scheduler, RemoteRangeCache cache})>{};

  RemoteLibraryConfig get _config =>
      _legacy ? RemoteLibraryConfig.fromSettings() : _configured!;
  RemoteLibraryOps get _activeOps =>
      _legacy ? RemoteLibrarySource._ops : const _RemoteFileStoreLibraryOps();
  String get _activeSourceKey => _config.configuredSourceKey;
  String get libraryId => _config.libraryId;
  ValueNotifier<int> get contentVersion => _state.contentVersion;
  ValueNotifier<RemoteLibrarySyncStatus> get syncStatus => _state.syncStatus;
  ValueNotifier<int> get metadataPendingVersion =>
      _metadata.metadataPendingVersion;
  List<RemoteLibraryMetadataPendingStatus> get metadataPendingStatuses =>
      _metadata.metadataPendingStatuses;
  Map<String, String> get failedRoots => Map.unmodifiable(_state.failedRoots);
  String? get statusMessage => failedRoots.isEmpty
      ? null
      : 'Failed directories: ${failedRoots.keys.join(', ')}';
  Map<String, _RemoteComicSnapshot> get _snapshotCache => _state.snapshotCache;
  Map<String, Future<_RemoteComicSnapshot>> get _snapshotInFlight =>
      _state.snapshotInFlight;

  ({RemoteReadScheduler scheduler, RemoteRangeCache cache}) _archiveAccount(
    RemoteLibraryConfig config,
  ) => _archiveAccounts.putIfAbsent(
    config.archiveAccountKey,
    () => (
      scheduler:
          RemoteLibrarySource.archiveSchedulerFactory?.call() ??
          RemoteReadScheduler(
            minInterval:
                config.remoteStore == null ||
                    config.remoteStore!.account.backend == StorageBackend.webdav
                ? Duration.zero
                : const Duration(milliseconds: 150),
          ),
      cache: RemoteRangeCache(),
    ),
  );

  RemoteLibraryConfig _configFor(String root) => _legacy
      ? _config
      : RemoteLibraryConfig.forRemoteLibrary(
          library,
          _store!,
          root: root,
          legacyAnchor: _config.legacyAnchor,
          legacyCacheKey: _config.legacyCacheKey,
        );

  void _ensureActive() {
    if (_state.disposed) throw StateError('Remote Library is closed');
  }

  Future<T> _withSnapshotLock<T>(String id, Future<T> Function() action) async {
    final previous = _state.snapshotWriteTails[id];
    final done = Completer<void>();
    _state.snapshotWriteTails[id] = done.future;
    try {
      if (previous != null) await previous;
      _ensureActive();
      return await action();
    } finally {
      done.complete();
      if (identical(_state.snapshotWriteTails[id], done.future)) {
        _state.snapshotWriteTails.remove(id);
      }
    }
  }

  Future<List<RemoteLibraryEntry>> _readDirectory(
    RemoteLibraryConfig config,
    String path, {
    bool refresh = false,
  }) => _archiveAccount(config).scheduler.run(
    () {
      _ensureActive();
      return _activeOps.readDir(config, path, refresh: refresh);
    },
    cancelToken:
        RemoteReadContext.current.priority == RemoteReadPriority.background
        ? _state.scanToken
        : _state.lifetimeToken,
  );

  Future<RemoteLibraryTextFile> _readText(
    RemoteLibraryConfig config,
    String path,
  ) => _archiveAccount(config).scheduler.run(
    () {
      _ensureActive();
      return _activeOps.readText(config, path);
    },
    cancelToken:
        RemoteReadContext.current.priority == RemoteReadPriority.background
        ? _state.scanToken
        : _state.lifetimeToken,
  );

  Future<RemoteLibraryWriteResult> _writeText(
    RemoteLibraryConfig config,
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
    int? expectedGeneration,
  }) => _archiveAccount(config).scheduler.run(
    () {
      _ensureActive();
      if (expectedGeneration != null &&
          expectedGeneration != _state.syncGeneration) {
        throw const _RemoteSynchronizationObsoleteException();
      }
      return _activeOps.writeText(
        config,
        path,
        content,
        createOnly: createOnly,
        ifMatch: ifMatch,
        ifUnmodifiedSince: ifUnmodifiedSince,
      );
    },
    cancelToken:
        RemoteReadContext.current.priority == RemoteReadPriority.background
        ? _state.scanToken
        : _state.lifetimeToken,
  );

  String _configurationIdentity(RemoteLibraryConfig config) =>
      jsonEncode([config.cacheKey, config.connectionKey, config.directories]);

  bool _isSynchronizationCurrent(_RemoteLibrarySyncRun run) =>
      !_state.disposed &&
      run.generation == _state.syncGeneration &&
      run.configurationIdentity == _configurationIdentity(_config);

  void _throwIfSynchronizationObsolete(_RemoteLibrarySyncRun run) {
    if (!_isSynchronizationCurrent(run)) {
      throw const _RemoteSynchronizationObsoleteException();
    }
  }

  void _notifyContent({bool immediate = false}) {
    if (_state.disposed) return;
    if (immediate) {
      _state.contentTimer?.cancel();
      _state.contentTimer = null;
      contentVersion.value++;
      return;
    }
    _state.contentTimer ??= Timer(const Duration(milliseconds: 200), () {
      _state.contentTimer = null;
      if (!_state.disposed) contentVersion.value++;
    });
  }

  void _clearMemoryCaches() {
    for (final token in _state.archiveTokens.toList()) {
      token.cancel('Remote Library closed');
    }
    _state.archiveTokens.clear();
    _state.archiveReaders.clear();
    _snapshotCache.clear();
    _snapshotInFlight.clear();
    _state.snapshotContexts.clear();
    _state.workVolumeLoads.clear();
  }

  void _notifyMetadataSubject(
    RemoteLibraryConfig config,
    String comicId,
    int? subjectId,
  ) {
    final handler = RemoteLibrarySource._metadataSubjectHandler;
    if (handler == null ||
        subjectId == null ||
        subjectId <= 0 ||
        _state.disposed) {
      return;
    }
    unawaited(
      Future.sync(
        () => handler(
          scopeId: config.libraryId,
          sourceKey: _activeSourceKey,
          comicId: comicId,
          subjectId: subjectId,
        ),
      ).catchError((Object error, StackTrace stackTrace) {
        Log.error('Remote Library metadata binding', error, stackTrace);
      }),
    );
  }

  Future<void> _loadStatus() {
    if (_state.disposed) return Future<void>.value();
    late final Future<void> task;
    task = _readStatus().whenComplete(() => _state.statusLoads.remove(task));
    _state.statusLoads.add(task);
    return task;
  }

  Future<void> _readStatus() async {
    final config = _config;
    if (!config.isValid || _state.disposed) return;
    final last = await _cache.lastSuccessfulSync(config.cacheKey);
    if (_state.disposed) return;
    final failures = await _cache.rootFailures(config.cacheKey);
    if (_state.disposed) return;
    _state.lastSuccessfulSync = last;
    _state.failedRoots = failures;
    if (!syncStatus.value.isSyncing) {
      syncStatus.value = RemoteLibrarySyncStatus(
        isSyncing: false,
        lastSuccessfulSync: last,
      );
    }
  }

  bool matches(RemoteLibrary other, StorageAccount account) =>
      library.id == other.id &&
      library.accountId == other.accountId &&
      library.name == other.name &&
      listEquals(library.directories, other.directories) &&
      library.autoRefresh == other.autoRefresh &&
      library.refreshIntervalMinutes == other.refreshIntervalMinutes &&
      _store?.account.backend == account.backend &&
      _store?.account.driver == account.driver &&
      jsonEncode(_store?.account.authorization) ==
          jsonEncode(account.authorization);

  Future<void>? _closing;

  Future<void> cancel() => _closing ??= _cancel();

  Future<void> _cancel() async {
    _state.disposed = true;
    _state.syncGeneration++;
    _state.scanToken.cancel('Remote Library closed');
    _state.lifetimeToken.cancel('Remote Library closed');
    _state.contentTimer?.cancel();
    _state.autoSyncTimer?.cancel();
    _autoRefreshTimer?.cancel();
    final scanning = _state.syncRun?.complete;
    final snapshots = _snapshotInFlight.values.toList();
    final volumes = _state.workVolumeLoads.values
        .map((load) => load.future)
        .toList();
    _clearMemoryCaches();
    final closingMetadata = _metadata.cancel();
    final store = _store;
    if (store != null) {
      await store.cancelAll().catchError((Object error, StackTrace stackTrace) {
        Log.warning('Remote Library cancellation', '$error\n$stackTrace');
      });
      RemoteStorageAccounts.instance.release(store);
    }
    await closingMetadata;
    await Future.wait([
      if (scanning != null) scanning.then<void>((_) {}),
      ..._state.statusLoads,
      ..._state.snapshotQueries,
      for (final snapshot in snapshots)
        snapshot.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      for (final volume in volumes)
        volume.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
    await Future.wait(_state.snapshotWriteTails.values.toList());
  }

  void initializeAutoRefresh() {
    _autoRefreshTimer?.cancel();
    if (!library.autoRefresh || _legacy) return;
    final interval = Duration(
      minutes: library.refreshIntervalMinutes.clamp(5, 24 * 60),
    );
    _autoRefreshTimer = Timer.periodic(
      interval,
      (_) => unawaited(synchronize()),
    );
  }

  void checkForAutomaticSync() {
    if (_state.disposed) return;
    final enabled = _legacy
        ? appdata.settings['webdavComicLibraryAutoSync'] == true
        : library.autoRefresh;
    if (!enabled || !_config.isValid) return;
    final interval = _legacy
        ? (appdata.settings['webdavComicLibrarySyncIntervalMinutes'] as num?)
                  ?.toInt() ??
              360
        : library.refreshIntervalMinutes;
    final elapsed =
        DateTime.now().millisecondsSinceEpoch - _state.lastSuccessfulSync;
    if (_state.lastSuccessfulSync == 0 ||
        elapsed >= Duration(minutes: interval).inMilliseconds) {
      unawaited(synchronize());
    }
  }

  void initializeMetadataRetry() => _metadata.initializeMetadataRetry();
  Future<void> retryPendingMetadata({bool force = false}) =>
      _metadata.retryPendingMetadata(force: force);
  Future<void> writeMetadata(
    String id,
    ComicMetaData metadata, {
    String? expectedLibraryId,
    int? expectedSubjectId,
  }) => _metadata.writeMetadata(
    id,
    metadata,
    expectedLibraryId: expectedLibraryId,
    expectedSubjectId: expectedSubjectId,
  );
  Future<Res<RemoteLibraryMetadataScrapeResult>> retryMetadataScrape(
    String id,
  ) => _metadata.retryMetadataScrape(id);
  @visibleForTesting
  Future<void> waitForBackgroundTasks() => _metadata.waitForIdle();

  Future<Res<bool>> synchronize({bool force = false}) =>
      _scanner.synchronize(force: force);

  Future<Res<List<Comic>>> loadComics(int page) async {
    final config = _config;
    if (!config.isValid) {
      return const Res.error('Invalid remote comic library configuration');
    }
    try {
      if (page < 1) return const Res([], subData: 1);
      if (!await _cache.hasDirectoryIndex(config.cacheKey)) {
        final result = await _scanner.start().indexReady;
        if (result.error) return Res.error(result.errorMessage!);
      }
      final roots = config.remoteLibrary?.directories;
      final count = await _cache.count(config.cacheKey, roots: roots);
      final maxPage = count == 0 ? 1 : (count + pageSize - 1) ~/ pageSize;
      if (page > maxPage) return Res([], subData: maxPage);
      final rows = await _cache.page(
        config.cacheKey,
        page: page,
        pageSize: pageSize,
        roots: roots,
      );
      return Res([
        for (final comic in rows)
          Comic(
            comic.title,
            comic.cover,
            comic.id,
            null,
            comic.tags,
            '',
            _activeSourceKey,
            null,
            null,
          ),
      ], subData: maxPage);
    } catch (error) {
      return Res.error(error.toString());
    }
  }

  ComicSource create() {
    initializeAutoRefresh();
    unawaited(_loadStatus());
    return ComicSource(
      _legacy ? 'Remote Library' : library.name,
      _activeSourceKey,
      null,
      null,
      null,
      null,
      [
        ExplorePageData(
          _legacy ? 'Remote Library' : library.name,
          ExplorePageType.multiPageComicList,
          loadComics,
          null,
          null,
          null,
          changeListenable: contentVersion,
          statusMessage: () => statusMessage,
          onRefresh: () async {
            await synchronize(force: true);
          },
        ),
      ],
      null,
      null,
      loadComicInfo,
      null,
      loadComicPages,
      getImageLoadingConfig,
      getThumbnailLoadingConfig,
      '',
      '',
      '',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  String _archivePath(RemoteLibraryConfig config, String id) =>
      id.startsWith('/')
      ? id
      : config.childFilePath(config.legacyAnchor ?? config.remotePath, id);

  bool _isArchiveId(String id) => !id.endsWith('/') && isRemoteComicArchive(id);

  ({String directory, String fileName, String title}) _metadataTarget(
    RemoteLibraryConfig config,
    String id,
  ) {
    if (id.startsWith(remoteComicWorkPrefix)) {
      final location = RemoteComicWork.location(id);
      return (
        directory: location.directory,
        fileName: location.family == null
            ? _metadataFileName
            : '${location.family}.metadata.json',
        title: location.family ?? _directoryName(location.directory),
      );
    }
    if (_isArchiveId(id)) {
      final path = _archivePath(config, id);
      final slash = path.lastIndexOf('/');
      return (
        directory: path.substring(0, slash + 1),
        fileName: '${path.substring(slash + 1)}.metadata.json',
        title: comicFileStem(path),
      );
    }
    return (
      directory: config.childDirectoryPath(id),
      fileName: _metadataFileName,
      title: _directoryName(id),
    );
  }

  String _stableComicPath(RemoteLibraryConfig config, String id) {
    if (id.startsWith(remoteComicWorkPrefix)) return id;
    if (config.remoteLibrary == null) return id;
    final fullPath = _isArchiveId(id)
        ? _archivePath(config, id)
        : id.startsWith('/')
        ? normalizeWebDavDirectoryPath(id, fallback: '/')
        : config.childDirectoryPathFrom(config.remotePath, id);
    final anchor = config.legacyAnchor;
    if (anchor == null) return fullPath;
    if (fullPath.startsWith(anchor)) {
      return fullPath.substring(anchor.length).replaceFirst(RegExp(r'/$'), '');
    }
    return fullPath;
  }

  Future<Res<ComicDetails>> loadComicInfo(String id) async {
    final config = _config;
    if (!config.isValid) {
      return const Res.error('Invalid remote comic library configuration');
    }
    try {
      final snapshot = await _loadSnapshot(config, id);
      _notifyMetadataSubject(config, id, snapshot.bangumiSubjectId);
      final archiveDisplay = snapshot.archive == null
          ? null
          : _archiveChapterDisplay(snapshot.archive!);
      return Res(
        ComicDetails.fromJson({
          'title': snapshot.title,
          'subtitle': null,
          'cover': snapshot.cover,
          'description': snapshot.description,
          'tags': snapshot.detailTags,
          'chapters':
              snapshot.work?.chapters ??
              archiveDisplay?.titles ??
              (snapshot.chapters.length == 1 &&
                      snapshot.chapters.containsKey(rootChapterId)
                  ? null
                  : snapshot.chapters),
          'chapterGroups': archiveDisplay?.groups,
          'chapterPageCounts':
              snapshot.work?.pageCounts ?? snapshot.archive?.chapterPageCounts,
          'sourceKey': _activeSourceKey,
          'comicId': id,
          'externalIds': {
            if (snapshot.bangumiSubjectId != null)
              'bangumi': snapshot.bangumiSubjectId.toString(),
          },
          'thumbnails': null,
          'recommend': null,
          'isFavorite': false,
          'subId': null,
          'likesCount': null,
          'isLiked': null,
          'commentCount': null,
          'uploader': null,
          'uploadTime': null,
          'updateTime': null,
          'url': null,
          'maxPage': snapshot.pageCount,
        }),
      );
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  ({Map<String, String> titles, Map<String, String> groups})
  _archiveChapterDisplay(RemoteArchiveComic archive) {
    final titles = Map<String, String>.from(archive.chapterTitles);
    if (archive.metadata?.chapters?.isNotEmpty == true) {
      return (titles: titles, groups: const {});
    }
    final rootTitle = titles[rootChapterId];
    if (rootTitle == 'Full book' || rootTitle == 'Images') {
      titles[rootChapterId] = rootTitle!.tl;
    }
    final groups = <String, String>{};
    for (final entry in titles.entries) {
      if (!entry.key.startsWith('dir:')) continue;
      final slash = entry.value.lastIndexOf('/');
      if (slash > 0) groups[entry.key] = entry.value.substring(0, slash);
    }
    if (groups.isEmpty) return (titles: titles, groups: const {});
    for (final id in titles.keys) {
      groups.putIfAbsent(id, () => 'Other chapters'.tl);
    }
    final grouped = <String, List<String>>{};
    for (final id in titles.keys) {
      grouped.putIfAbsent(groups[id]!, () => []).add(id);
    }
    if (!listEquals(
      grouped.values.expand((ids) => ids).toList(),
      titles.keys.toList(),
    )) {
      return (titles: titles, groups: const {});
    }
    return (titles: titles, groups: groups);
  }

  Future<Res<List<String>>> loadComicPages(String id, String? ep) async {
    final config = _config;
    if (!config.isValid) {
      return const Res.error('Invalid remote comic library configuration');
    }
    try {
      if (id.startsWith(remoteComicWorkPrefix)) {
        final snapshot = await _loadSnapshot(config, id);
        final work = snapshot.work!;
        final volume = work.volume(ep ?? work.volumes.first.id);
        if (volume == null) {
          return const Res.error('Comic volume is unavailable');
        }
        final archive = await _loadWorkVolume(config, snapshot, volume.id);
        final pages = archive.isPdf
            ? [
                for (var page = 1; page <= archive.pdfPageCount!; page++)
                  'pdf:$page',
              ]
            : archive.epubPages ??
                  archive.chapterImages.values
                      .expand((pages) => pages)
                      .toList();
        if (pages.isEmpty) {
          return const Res.error('No images found in the comic volume');
        }
        return Res([for (final page in pages) work.imageKey(volume, page)]);
      }
      if (_isArchiveId(id)) {
        final snapshot = await _loadSnapshot(config, id);
        final archive = snapshot.archive!;
        final chapter =
            ep ??
            (archive.chapters.length == 1
                ? archive.chapters.keys.single
                : rootChapterId);
        final images = archive.chapterImages[chapter];
        if (images == null || images.isEmpty) {
          return const Res.error('No images found in the archive chapter');
        }
        return Res(images.map(archive.imageKey).toList());
      }
      final comicPath = config.childDirectoryPath(id);
      if (ep != null &&
          ep != rootChapterId &&
          !ep.startsWith(_metadataChapterPrefix)) {
        final path = config.childDirectoryPathFrom(comicPath, ep);
        final memoryKey = jsonEncode([config.cacheKey, id]);
        var snapshot = _snapshotCache[memoryKey];
        if (snapshot == null) {
          final cached = await _cache.find(config.cacheKey, id);
          if (cached?.isReady == true) {
            snapshot = _RemoteComicSnapshot.fromJson(cached!.snapshot!);
            _snapshotCache[memoryKey] = snapshot;
          }
        }
        final cachedImages = snapshot?.chapterImages[ep];
        if (cachedImages != null) {
          return Res([
            for (final name in cachedImages) config.childFilePath(path, name),
          ]);
        }
        final entries = List<RemoteLibraryEntry>.from(
          await _readDirectory(config, path),
        );
        final files = _imageEntries(entries)
            .where((entry) => !isNamedComicCover(entry.name))
            .map((entry) => config.childFilePath(path, entry.name))
            .toList();
        if (files.isEmpty) {
          return const Res.error('No images found in the remote chapter');
        }
        return Res(files);
      }

      final snapshot = await _loadSnapshot(config, id);
      final metadataChapter = ep == null ? null : snapshot.metadataChapters[ep];
      if (metadataChapter != null) {
        final files = snapshot.rootImages
            .sublist(metadataChapter.start - 1, metadataChapter.end)
            .map((entry) => config.childFilePath(comicPath, entry.name))
            .toList();
        return Res(files);
      }
      if (ep?.startsWith(_metadataChapterPrefix) == true) {
        return const Res.error('Invalid Remote Library metadata chapter');
      }
      if (ep == null || ep == rootChapterId) {
        final files = snapshot.rootImages
            .map((entry) => config.childFilePath(comicPath, entry.name))
            .toList();
        if (files.isEmpty) {
          return const Res.error('No images found in the remote chapter');
        }
        return Res(files);
      }
      return const Res.error('No images found in the remote chapter');
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  Future<_RemoteComicSnapshot> _loadSnapshot(
    RemoteLibraryConfig config,
    String id, {
    bool forceRefresh = false,
    bool summaryOnly = false,
    bool background = false,
    bool forceMetadataScrape = false,
    RemoteLibraryRemoteDirectory? remoteDirectory,
    RemoteLibraryEntry? archiveFile,
    RemoteComicWork? work,
    CancelToken? cancelToken,
    List<RemoteLibraryEntry>? rootEntries,
    Map<String, List<RemoteLibraryEntry>>? childEntries,
    _RemoteLibrarySyncRun? syncRun,
  }) {
    _ensureActive();
    final query = _loadSnapshotQuery(
      config,
      id,
      forceRefresh: forceRefresh,
      summaryOnly: summaryOnly,
      background: background,
      forceMetadataScrape: forceMetadataScrape,
      remoteDirectory: remoteDirectory,
      archiveFile: archiveFile,
      work: work,
      cancelToken: cancelToken,
      rootEntries: rootEntries,
      childEntries: childEntries,
      syncRun: syncRun,
    );
    late final Future<void> tracked;
    tracked = query
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _state.snapshotQueries.remove(tracked));
    _state.snapshotQueries.add(tracked);
    return query;
  }

  Future<_RemoteComicSnapshot> _loadSnapshotQuery(
    RemoteLibraryConfig config,
    String id, {
    bool forceRefresh = false,
    bool summaryOnly = false,
    bool background = false,
    bool forceMetadataScrape = false,
    RemoteLibraryRemoteDirectory? remoteDirectory,
    RemoteLibraryEntry? archiveFile,
    RemoteComicWork? work,
    CancelToken? cancelToken,
    List<RemoteLibraryEntry>? rootEntries,
    Map<String, List<RemoteLibraryEntry>>? childEntries,
    _RemoteLibrarySyncRun? syncRun,
  }) async {
    final memoryKey = jsonEncode([config.cacheKey, id]);
    if (!forceRefresh) {
      final memoryCached = _snapshotCache[memoryKey];
      if (memoryCached != null &&
          (summaryOnly || memoryCached.chaptersInspected)) {
        return memoryCached;
      }
      final diskCached = await _cache.find(config.cacheKey, id);
      _ensureActive();
      final completedDuringRead = _snapshotCache[memoryKey];
      if (completedDuringRead != null &&
          (summaryOnly || completedDuringRead.chaptersInspected)) {
        return completedDuringRead;
      }
      if (diskCached?.isReady == true) {
        final snapshot = _RemoteComicSnapshot.fromJson(diskCached!.snapshot!);
        _snapshotCache[memoryKey] = snapshot;
        if (summaryOnly || snapshot.chaptersInspected) return snapshot;
      }
    }

    final inFlight = _snapshotInFlight[memoryKey];
    if (inFlight != null) {
      _state.snapshotContexts[memoryKey]?.promote(
        RemoteReadContext.current.priority,
      );
      _RemoteComicSnapshot? snapshot;
      try {
        snapshot = await inFlight;
        _ensureActive();
      } catch (error) {
        final retryArchive =
            !_state.disposed &&
            cancelToken?.isCancelled != true &&
            (error is _RemoteSynchronizationObsoleteException ||
                _isArchiveId(id) &&
                    (forceRefresh ||
                        error is DioException && CancelToken.isCancel(error)));
        if (!retryArchive) rethrow;
      }
      if (!forceRefresh &&
          snapshot != null &&
          (summaryOnly || snapshot.chaptersInspected)) {
        return snapshot;
      }
      if (identical(_snapshotInFlight[memoryKey], inFlight)) {
        _snapshotInFlight.remove(memoryKey);
        _state.snapshotContexts.remove(memoryKey);
      }
      return _loadSnapshot(
        config,
        id,
        forceRefresh: forceRefresh,
        summaryOnly: summaryOnly,
        background: background,
        remoteDirectory: remoteDirectory,
        rootEntries: rootEntries,
        childEntries: childEntries,
        forceMetadataScrape: forceMetadataScrape,
        archiveFile: archiveFile,
        work: work,
        cancelToken: cancelToken,
        syncRun: syncRun,
      );
    }
    _ensureActive();
    final context = RemoteReadContext.current;
    _state.snapshotContexts[memoryKey] = context;
    final future = context.run(() async {
      final existing = await _cache.find(config.cacheKey, id);
      _ensureActive();
      final previousSnapshot = existing?.snapshot == null
          ? null
          : _RemoteComicSnapshot.fromJson(existing!.snapshot!);
      var aggregate = work ?? previousSnapshot?.work;
      var workEntries = rootEntries;
      if (aggregate == null && id.startsWith(remoteComicWorkPrefix)) {
        final restored = await _restoreWork(config, id);
        aggregate = restored.work;
        workEntries = restored.entries;
      }
      final snapshot = aggregate != null
          ? await _buildWorkSnapshot(
              config,
              aggregate,
              previousSnapshot: previousSnapshot,
              forceMetadataScrape: forceMetadataScrape,
              rootEntries: workEntries,
              syncRun: syncRun,
            )
          : _isArchiveId(id)
          ? await _buildArchiveSnapshot(
              config,
              id,
              summaryOnly: summaryOnly,
              forceMetadataScrape: forceMetadataScrape,
              previousSnapshot: previousSnapshot,
              file: archiveFile,
              rootEntries: rootEntries,
              cancelToken: cancelToken,
              syncRun: syncRun,
            )
          : await _buildSnapshot(
              config,
              id,
              rootEntries: rootEntries,
              childEntries: childEntries,
              previousSnapshot: previousSnapshot,
              summaryOnly: summaryOnly,
              forceMetadataScrape: forceMetadataScrape,
              syncRun: syncRun,
            );
      if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
      if (!background) await _metadata.flushSnapshots();
      return _withSnapshotLock(id, () async {
        _ensureActive();
        if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
        var published = snapshot;
        final current = _snapshotCache[memoryKey];
        final currentWork = current?.work;
        if (snapshot.work != null && currentWork != null) {
          snapshot.work!.retainIndexes(currentWork);
          final sameVolumes = listEquals(
            snapshot.work!.volumes
                .map(
                  (volume) => (
                    volume.id,
                    volume.archive.size,
                    volume.archive.eTag,
                    volume.archive.modifiedAt,
                  ),
                )
                .toList(),
            currentWork.volumes
                .map(
                  (volume) => (
                    volume.id,
                    volume.archive.size,
                    volume.archive.eTag,
                    volume.archive.modifiedAt,
                  ),
                )
                .toList(),
          );
          if (sameVolumes) {
            published = _RemoteComicSnapshot.fromJson(
              snapshot.toJson(),
              retainedWork: currentWork,
            );
          }
        }
        final cachedComic = RemoteLibraryCachedComic(
          id: id,
          sortIndex:
              _state.sortIndexes[id] ??
              existing?.sortIndex ??
              remoteDirectory?.sortIndex ??
              0,
          title: published.title,
          author: published.author,
          tags: published.tags,
          cover: published.cover,
          snapshot: published.toJson(),
          remoteETag: remoteDirectory?.eTag ?? existing?.remoteETag,
          remoteModifiedAt:
              remoteDirectory?.modifiedAt ?? existing?.remoteModifiedAt,
        );
        _snapshotCache[memoryKey] = published;
        if (background && syncRun != null) {
          _metadata.bufferSnapshot(config, cachedComic, syncRun);
        } else {
          await _cache.upsertSnapshot(config.cacheKey, cachedComic);
        }
        _ensureActive();
        if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
        if (!background && !forceMetadataScrape) {
          _metadata.enqueueScrape(config, id, published, run: syncRun);
        }
        return published;
      });
    });
    _snapshotInFlight[memoryKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_snapshotInFlight[memoryKey], future)) {
        _snapshotInFlight.remove(memoryKey);
        _state.snapshotContexts.remove(memoryKey);
      }
    }
  }

  RemoteRangeReader _archiveReader(
    RemoteLibraryConfig config,
    RemoteArchiveComic archive,
  ) {
    final key = jsonEncode([config.cacheKey, archive.path, archive.version]);
    final account = _archiveAccount(config);
    return _state.archiveReaders.putIfAbsent(
      key,
      () => RemoteRangeReader(
        size: archive.size,
        scheduler: account.scheduler,
        cache: account.cache,
        cacheKey: jsonEncode([archive.path, archive.version]),
        link: () async => config.remoteStore != null
            ? config.remoteStore!.link(archive.path)
            : RemoteLink(
                url: config.fileUrl(archive.path),
                headers: config.authHeaders,
              ),
        dio: RemoteLibrarySource.archiveDioFactory?.call(),
      ),
    );
  }

  List<RemoteLibraryEntry> _archiveFiles(List<RemoteLibraryEntry> entries) =>
      entries
          .where(
            (entry) =>
                !entry.isDirectory &&
                !isIgnoredComicStorageEntry(entry.name) &&
                isRemoteComicArchive(entry.name),
          )
          .toList()
        ..sort((a, b) => compareComicFileNames(a.name, b.name));

  RemoteComicVolume _archiveVolume(
    RemoteLibraryConfig config,
    RemoteLibraryEntry file,
    String parent, {
    String edition = '',
  }) {
    final name = RemoteComicVolumeName.parse(file.name);
    return RemoteComicVolume(
      archive: RemoteArchiveComic(
        path: config.childFilePath(
          config.childDirectoryPath(parent),
          file.name,
        ),
        size: file.size ?? 0,
        eTag: file.eTag,
        modifiedAt: file.modifiedAt,
      ),
      title: name.title,
      edition: edition,
    );
  }

  Future<({RemoteComicWork work, List<RemoteLibraryEntry> entries})>
  _restoreWork(RemoteLibraryConfig config, String id) async {
    final location = RemoteComicWork.location(id);
    final directory = config.childDirectoryPath(location.directory);
    final entries = await _readDirectory(config, directory);
    final family = location.family;
    final familyKey = family == null ? null : remoteComicSeriesKey(family);
    final children = family == null
        ? _sortedDirectories(entries)
        : const <RemoteLibraryEntry>[];
    if (family == null && !_hasMetadataFile(entries)) {
      children.removeWhere(
        (child) => !isRemoteComicEditionDirectory(child.name),
      );
    }
    final volumes = <RemoteComicVolume>[];
    for (final file in _archiveFiles(entries)) {
      if (familyKey != null) {
        final name = RemoteComicVolumeName.parse(file.name);
        final series = name.series.isEmpty
            ? _directoryName(directory)
            : name.series;
        if (!name.numbered || remoteComicSeriesKey(series) != familyKey) {
          continue;
        }
      }
      volumes.add(
        _archiveVolume(
          config,
          file,
          directory,
          edition: children.isEmpty ? '' : _directoryName(directory),
        ),
      );
    }
    for (final child in children) {
      final childDirectory = config.childDirectoryPathFrom(
        directory,
        child.name,
      );
      final childEntries = await _readDirectory(config, childDirectory);
      for (final file in _archiveFiles(childEntries)) {
        volumes.add(
          _archiveVolume(config, file, childDirectory, edition: child.name),
        );
      }
    }
    if (volumes.isEmpty) {
      throw const FormatException('Comic volumes are unavailable');
    }
    return (
      work: RemoteComicWork(
        directory: directory,
        title: family ?? _directoryName(directory),
        family: family,
        volumes: separateRemoteComicEditions(volumes),
      ),
      entries: entries,
    );
  }

  Future<_RemoteComicSnapshot> _buildWorkSnapshot(
    RemoteLibraryConfig config,
    RemoteComicWork work, {
    _RemoteComicSnapshot? previousSnapshot,
    bool forceMetadataScrape = false,
    List<RemoteLibraryEntry>? rootEntries,
    _RemoteLibrarySyncRun? syncRun,
  }) async {
    work.retainIndexes(previousSnapshot?.work);
    final entries =
        rootEntries ??
        await _readDirectory(
          config,
          work.directory,
          refresh: syncRun?.refresh ?? false,
        );
    if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
    final inherited = work.volumes
        .map((volume) => volume.archive.metadata)
        .whereType<ComicMetaData>()
        .firstOrNull;
    var metadata = await _metadata._readMetadata(
      config,
      work.directory,
      entries,
      fileName: work.metadataFileName,
      fallback: ComicMetaData(
        title: work.title,
        author: inherited?.author ?? '',
        tags: inherited?.tags ?? const [],
        description: inherited?.description ?? '',
      ),
    );
    if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
    var metadataPresent = _hasMetadataFile(
      entries,
      fileName: work.metadataFileName,
    );
    var status = metadataPresent
        ? 'notNeeded'
        : previousSnapshot?.metadataScrapeStatus ?? 'pending';
    var scraperVersion = metadataPresent
        ? ''
        : previousSnapshot?.metadataScraperVersion ?? '';
    var attemptedAt = previousSnapshot?.metadataScrapeAttemptedAt;
    var retryAt = previousSnapshot?.metadataScrapeRetryAt;
    var error = previousSnapshot?.metadataScrapeError;
    if (forceMetadataScrape &&
        _metadata._shouldAttemptMetadataScrape(
          previousSnapshot: previousSnapshot,
          metadataFilePresent: metadataPresent,
          scraperVersion: RemoteLibrarySource._metadataScraperVersion,
          now: RemoteLibrarySource.metadataNowProvider(),
          automaticScrapingEnabled: RemoteLibrarySource._canScrapeMetadata,
          forceMetadataScrape: forceMetadataScrape,
        )) {
      final workDirectoryName = _directoryName(work.directory);
      final fileNames = <String>{
        for (final volume in work.volumes) ...[
          _directoryName(volume.archive.path),
          if (volume.archive.index case final index?)
            for (final entry in index.entries) _directoryName(entry.name),
          if (volume.archive.epubPages case final pages?)
            for (final page in pages) _directoryName(page),
        ],
      }.toList(growable: false);
      final authors = _metadata._metadataAuthors([
        inherited?.author,
        for (final volume in work.volumes) ...[
          volume.archive.metadata?.author,
          volume.archive.embeddedMetadata?.author,
        ],
      ]);
      final scraped = await _metadata._scrapeMissingMetadata(
        config,
        work.id,
        work.directory,
        pageCount: null,
        fileName: work.metadataFileName,
        input: RemoteLibraryMetadataInput(
          title: work.title,
          directoryTitle: workDirectoryName.isEmpty ? null : workDirectoryName,
          fileNames: fileNames,
          authors: authors,
        ),
        syncRun: syncRun,
        forceMetadataScrape: forceMetadataScrape,
      );
      metadata = scraped.metadata ?? metadata;
      metadataPresent = scraped.filePresent;
      status = scraped.status;
      scraperVersion = RemoteLibrarySource._metadataScraperVersion;
      attemptedAt = scraped.attemptedAt;
      retryAt = scraped.retryAt;
      error = scraped.error;
    }
    final namedCover = _findNamedCover(entries);
    return _RemoteComicSnapshot(
      work: work,
      title: metadata?.title ?? work.title,
      author: metadata?.author ?? inherited?.author ?? '',
      description: metadata?.description ?? inherited?.description ?? '',
      tags: metadata?.tags ?? inherited?.tags ?? const [],
      cover: namedCover == null
          ? work.imageKey(work.volumes.first)
          : config.childFilePath(work.directory, namedCover.name),
      chapters: {for (final volume in work.volumes) volume.id: volume.title},
      chapterImages: const {},
      metadataChapters: const {},
      rootImages: const [],
      bangumiSubjectId: metadata?.bangumiSubjectId,
      metadataFilePresent: metadataPresent,
      metadataScrapeStatus: status,
      metadataScraperVersion: scraperVersion,
      metadataScrapeAttemptedAt: attemptedAt,
      metadataScrapeRetryAt: retryAt,
      metadataScrapeError: error,
    );
  }

  Future<RemoteArchiveComic> _loadWorkVolume(
    RemoteLibraryConfig config,
    _RemoteComicSnapshot snapshot,
    String volumeId, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final work = snapshot.work!;
    final volume = work.volume(volumeId);
    if (volume == null) {
      throw const FormatException('Comic volume is unavailable');
    }
    if (volume.archive.isInspected) return volume.archive;
    final state = _state;
    final key = jsonEncode([config.cacheKey, work.id, volumeId]);
    final pending = state.workVolumeLoads[key];
    if (pending != null) {
      pending.context.promote(RemoteReadContext.current.priority);
      try {
        return await (cancelToken == null
            ? pending.future
            : Future.any([
                pending.future,
                cancelToken.whenCancel.then<RemoteArchiveComic>(
                  (error) => throw error,
                ),
              ]));
      } on DioException catch (error) {
        if (!CancelToken.isCancel(error) ||
            cancelToken?.isCancelled == true ||
            state.disposed) {
          rethrow;
        }
        if (state.workVolumeLoads[key]?.future == pending.future) {
          state.workVolumeLoads.remove(key);
        }
        return _loadWorkVolume(
          config,
          snapshot,
          volumeId,
          cancelToken: cancelToken,
        );
      }
    }
    final context = RemoteReadContext.current;
    final future = context.run(() async {
      final member = await _buildArchiveSnapshot(
        config,
        volumeId,
        summaryOnly: false,
        scrapeMetadata: false,
        previousArchive: volume.archive,
        cancelToken: cancelToken,
      );
      _ensureActive();
      await _metadata.flushSnapshots();
      return _withSnapshotLock(work.id, () async {
        _ensureActive();
        final memoryKey = jsonEncode([config.cacheKey, work.id]);
        final cached = (await _cache.find(config.cacheKey, work.id))!;
        _ensureActive();
        final current = _snapshotCache[memoryKey];
        if (!identical(current?.work, work)) {
          throw const FormatException(
            'Comic volumes changed. Reopen the comic',
          );
        }
        volume.archive = member.archive!;
        await _cache.upsertSnapshot(
          config.cacheKey,
          RemoteLibraryCachedComic(
            id: work.id,
            sortIndex: _state.sortIndexes[work.id] ?? cached.sortIndex,
            title: current!.title,
            author: current.author,
            tags: current.tags,
            cover: current.cover,
            snapshot: current.toJson(),
            remoteETag: cached.remoteETag,
            remoteModifiedAt: cached.remoteModifiedAt,
          ),
        );
        return volume.archive;
      });
    });
    final load = (context: context, future: future);
    state.workVolumeLoads[key] = load;
    try {
      return await future;
    } finally {
      if (state.workVolumeLoads[key]?.future == future) {
        state.workVolumeLoads.remove(key);
      }
    }
  }

  Future<_RemoteComicSnapshot> _buildArchiveSnapshot(
    RemoteLibraryConfig config,
    String id, {
    required bool summaryOnly,
    bool scrapeMetadata = true,
    bool forceMetadataScrape = false,
    _RemoteComicSnapshot? previousSnapshot,
    RemoteLibraryEntry? file,
    RemoteArchiveComic? previousArchive,
    List<RemoteLibraryEntry>? rootEntries,
    CancelToken? cancelToken,
    _RemoteLibrarySyncRun? syncRun,
  }) async {
    final path = _archivePath(config, id);
    final target = _metadataTarget(config, id);
    final previous = previousArchive ?? previousSnapshot?.archive;
    var siblings = rootEntries;
    if (!summaryOnly) {
      if (config.remoteStore != null) {
        final state = _state;
        _ensureActive();
        final token = cancelToken ?? state.lifetimeToken;
        state.archiveTokens.add(token);
        final RemoteEntry entry;
        try {
          entry = await _archiveAccount(config).scheduler.run(() {
            if (state.disposed) throw StateError('Remote Library is closed');
            return config.remoteStore!.stat(path);
          }, cancelToken: token);
        } finally {
          state.archiveTokens.remove(token);
        }
        file = RemoteLibraryEntry(
          name: entry.name,
          isDirectory: false,
          size: entry.size,
          eTag: entry.eTag,
          modifiedAt: entry.modifiedAt,
        );
      } else {
        siblings ??= await _readDirectory(
          config,
          target.directory,
          refresh: syncRun?.refresh ?? false,
        );
        file = siblings.firstWhere(
          (entry) => !entry.isDirectory && entry.name == _directoryName(path),
        );
      }
    }
    final size = file?.size ?? previous?.size ?? 0;
    var archive =
        previous != null &&
            (summaryOnly && file == null ||
                previous.matches(
                  size: size,
                  eTag: file?.eTag,
                  modifiedAt: file?.modifiedAt,
                ))
        ? previous
        : RemoteArchiveComic(
            path: path,
            size: size,
            eTag: file?.eTag,
            modifiedAt: file?.modifiedAt,
          );
    archive = archive.withMetadata(null);
    if (!summaryOnly && !archive.isInspected) {
      if (size <= 0) {
        throw const FormatException('Remote archive file size is unavailable');
      }
      _ensureActive();
      final state = _state;
      final token = cancelToken ?? state.lifetimeToken;
      state.archiveTokens.add(token);
      try {
        if (token.isCancelled) throw token.cancelError!;
        if (state.disposed) throw StateError('Remote Library is closed');
        final reader = _archiveReader(config, archive);
        archive = await archive.inspect(
          (offset, length) => reader.read(offset, length, cancelToken: token),
          cancelToken: token,
        );
        if (token.isCancelled) throw token.cancelError!;
      } finally {
        state.archiveTokens.remove(token);
      }
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    _metadata._ensureMetadataContextActive();
    siblings ??= await _readDirectory(
      config,
      target.directory,
      refresh: syncRun?.refresh ?? false,
    );
    if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
    final sidecarPresent = _hasMetadataFile(
      siblings,
      fileName: target.fileName,
    );
    final sidecar = await _metadata._readMetadata(
      config,
      target.directory,
      siblings,
      fileName: target.fileName,
      pageCount: archive.pageCount,
      fallback:
          archive.embeddedMetadata ??
          ComicMetaData(title: target.title, author: '', tags: const []),
    );
    if (sidecar != null) archive = archive.withMetadata(sidecar);
    var metadataPresent = sidecarPresent || archive.embeddedMetadata != null;
    var status = metadataPresent
        ? 'notNeeded'
        : (previousSnapshot?.metadataScrapeStatus ?? 'pending');
    var scraperVersion = metadataPresent
        ? ''
        : (previousSnapshot?.metadataScraperVersion ?? '');
    int? attemptedAt = previousSnapshot?.metadataScrapeAttemptedAt;
    int? retryAt = previousSnapshot?.metadataScrapeRetryAt;
    String? error = previousSnapshot?.metadataScrapeError;
    if (scrapeMetadata &&
        forceMetadataScrape &&
        !summaryOnly &&
        _metadata._shouldAttemptMetadataScrape(
          previousSnapshot:
              previousSnapshot?.metadataFilePresent == true && !metadataPresent
              ? null
              : previousSnapshot,
          metadataFilePresent: metadataPresent,
          scraperVersion: RemoteLibrarySource._metadataScraperVersion,
          now: RemoteLibrarySource.metadataNowProvider(),
          automaticScrapingEnabled: RemoteLibrarySource._canScrapeMetadata,
          forceMetadataScrape: forceMetadataScrape,
        )) {
      final archiveDirectoryName = _directoryName(target.directory);
      final fileNames = <String>{
        _directoryName(path),
        if (archive.index case final index?)
          for (final entry in index.entries)
            if (!_isIgnoredEntry(entry.name)) _directoryName(entry.name),
        if (archive.epubPages case final pages?)
          for (final page in pages) _directoryName(page),
      }.toList(growable: false);
      final authors = _metadata._metadataAuthors([
        archive.embeddedMetadata?.author,
        archive.metadata?.author,
      ]);
      final scraped = await _metadata._scrapeMissingMetadata(
        config,
        id,
        target.directory,
        pageCount: archive.pageCount,
        fileName: target.fileName,
        input: RemoteLibraryMetadataInput(
          title: target.title,
          directoryTitle: archiveDirectoryName.isEmpty
              ? null
              : archiveDirectoryName,
          fileNames: fileNames,
          authors: authors,
        ),
        syncRun: syncRun,
        forceMetadataScrape: forceMetadataScrape,
      );
      if (scraped.metadata != null) {
        archive = archive.withMetadata(scraped.metadata);
      }
      metadataPresent = scraped.filePresent;
      status = scraped.status;
      scraperVersion = RemoteLibrarySource._metadataScraperVersion;
      attemptedAt = scraped.attemptedAt;
      retryAt = scraped.retryAt;
      error = scraped.error;
    }
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    _metadata._ensureMetadataContextActive();
    final meta = archive.metadata;
    return _RemoteComicSnapshot(
      archive: archive,
      title: archive.title,
      author: meta?.author ?? '',
      description: meta?.description ?? '',
      tags: meta?.tags ?? const [],
      cover: archive.imageKey(),
      chapters: archive.chapters,
      chaptersInspected: archive.isInspected,
      chapterImages: archive.chapterImages,
      metadataChapters: const {},
      rootImages: const [],
      bangumiSubjectId: meta?.bangumiSubjectId,
      metadataFilePresent: metadataPresent,
      metadataScrapeStatus: status,
      metadataScraperVersion: scraperVersion,
      metadataScrapeAttemptedAt: attemptedAt,
      metadataScrapeRetryAt: retryAt,
      metadataScrapeError: error,
    );
  }

  Future<Uint8List> _loadArchiveImage(
    String imageKey,
    CancelToken token,
  ) async {
    final config = _config;
    late final RemoteArchiveComic archive;
    late final ({String path, String version, String? entry}) key;
    if (imageKey.startsWith(remoteComicWorkImagePrefix)) {
      final workKey = RemoteComicWork.parseImageKey(imageKey);
      final snapshot = await _loadSnapshot(
        config,
        workKey.work,
        cancelToken: token,
      );
      archive = await _loadWorkVolume(
        config,
        snapshot,
        workKey.volume,
        cancelToken: token,
      );
      key = RemoteArchiveComic.parseImageKey(
        workKey.image ?? archive.imageKey(),
      )!;
    } else {
      key = RemoteArchiveComic.parseImageKey(imageKey)!;
      final path = key.path;
      final anchor = config.legacyAnchor ?? config.remotePath;
      final id = config.remoteLibrary != null && config.legacyAnchor == null
          ? path
          : path.startsWith(anchor)
          ? path.substring(anchor.length)
          : path;
      final snapshot = await _loadSnapshot(config, id, cancelToken: token);
      final indexed = snapshot.archive;
      if (indexed == null) {
        throw const FormatException('Remote archive is unavailable');
      }
      archive = indexed;
    }
    if (token.isCancelled) throw token.cancelError!;
    if (!archive.isInspected ||
        (key.entry != null && key.version != archive.version)) {
      throw const FormatException(
        'Remote archive changed. Refresh the comic library',
      );
    }
    final entryName = key.entry ?? archive.coverEntry;
    final state = _state;
    if (state.disposed) throw StateError('Remote Library is closed');
    state.archiveTokens.add(token);
    try {
      final reader = _archiveReader(config, archive);
      if (archive.isPdf) {
        final match = RegExp(
          r'^pdf:([1-9][0-9]*)$',
        ).firstMatch(entryName ?? '');
        final page = int.tryParse(match?.group(1) ?? '');
        if (page == null || page > archive.pdfPageCount!) {
          throw const FormatException('PDF page is missing');
        }
        return await RemotePdfReader.renderPage(
          size: archive.size,
          read: (offset, length) =>
              reader.read(offset, length, cancelToken: token),
          sourceName: 'remote-pdf:${archive.version}',
          pageNumber: page,
          expectedPageCount: archive.pdfPageCount,
          cancelToken: token,
        );
      }
      final entry = archive.index!.entries.firstWhereOrNull(
        (entry) => entry.name == entryName,
      );
      if (entry == null) {
        throw const FormatException('Archive image entry is missing');
      }
      return await archive.index!.readEntry(
        entry,
        (offset, length) => reader.read(offset, length, cancelToken: token),
      );
    } finally {
      state.archiveTokens.remove(token);
    }
  }

  Future<_RemoteComicSnapshot> _buildSnapshot(
    RemoteLibraryConfig config,
    String id, {
    List<RemoteLibraryEntry>? rootEntries,
    Map<String, List<RemoteLibraryEntry>>? childEntries,
    _RemoteComicSnapshot? previousSnapshot,
    bool summaryOnly = false,
    bool forceMetadataScrape = false,
    _RemoteLibrarySyncRun? syncRun,
  }) async {
    final comicPath = config.childDirectoryPath(id);
    final entries = List<RemoteLibraryEntry>.from(
      rootEntries ??
          await _readDirectory(
            config,
            comicPath,
            refresh: syncRun?.refresh ?? false,
          ),
    );
    if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
    final rootImages = _imageEntries(
      entries,
    ).where((entry) => !isNamedComicCover(entry.name)).toList();
    final directories =
        entries
            .where((entry) => entry.isDirectory)
            .where((entry) => !_isIgnoredEntry(entry.name))
            .toList()
          ..sort((a, b) => compareComicFileNames(a.name, b.name));
    var metadataFilePresent = _hasMetadataFile(entries);
    var metadataScrapeStatus = metadataFilePresent
        ? 'notNeeded'
        : (previousSnapshot?.metadataScrapeStatus ?? 'pending');
    var metadataScraperVersion = metadataFilePresent
        ? ''
        : (previousSnapshot?.metadataScraperVersion ?? '');
    int? metadataScrapeAttemptedAt =
        previousSnapshot?.metadataScrapeAttemptedAt;
    int? metadataScrapeRetryAt = previousSnapshot?.metadataScrapeRetryAt;
    String? metadataScrapeError = previousSnapshot?.metadataScrapeError;
    var metadata = await _metadata._readMetadata(
      config,
      comicPath,
      entries,
      pageCount: directories.isEmpty ? rootImages.length : null,
    );
    if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);

    final inspectedChapterEntries = <String, List<RemoteLibraryEntry>>{
      ...?childEntries,
    };

    final metadataChapters = <String, ComicChapter>{};
    final chapterMap = <String, String>{};
    var chaptersInspected = true;
    final namedCover = _findNamedCover(entries);
    String? coverPath = namedCover == null
        ? null
        : config.childFilePath(comicPath, namedCover.name);
    if (rootImages.isNotEmpty) {
      coverPath ??= config.childFilePath(comicPath, rootImages.first.name);
    }
    if (directories.isNotEmpty) {
      for (final directory in directories) {
        var chapterEntries = inspectedChapterEntries[directory.name];
        if (chapterEntries == null) {
          if (summaryOnly && coverPath != null) {
            chaptersInspected = false;
            continue;
          }
          final chapterPath = config.childDirectoryPathFrom(
            comicPath,
            directory.name,
          );
          try {
            chapterEntries = List<RemoteLibraryEntry>.from(
              await _readDirectory(
                config,
                chapterPath,
                refresh: syncRun?.refresh ?? false,
              ),
            );
            if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
            inspectedChapterEntries[directory.name] = chapterEntries;
          } on _RemoteSynchronizationObsoleteException {
            rethrow;
          } catch (e) {
            if (syncRun != null) rethrow;
            Log.warning(
              'Remote Library',
              'Failed to inspect chapter directory at $chapterPath: $e',
            );
          }
        }
        final hasReadablePages =
            chapterEntries != null &&
            _imageEntries(
              chapterEntries,
            ).any((entry) => !isNamedComicCover(entry.name));
        if (hasReadablePages) {
          chapterMap[directory.name] = directory.name;
          if (coverPath == null) {
            final coverEntry =
                _findNamedCover(chapterEntries) ??
                _imageEntries(
                  chapterEntries,
                ).firstWhere((entry) => !isNamedComicCover(entry.name));
            coverPath = config.childFilePath(
              config.childDirectoryPathFrom(comicPath, directory.name),
              coverEntry.name,
            );
          }
        }
      }
      if (rootImages.isNotEmpty) {
        chapterMap[rootChapterId] = rootChapterTitle;
      }
    }

    final shouldScrape =
        forceMetadataScrape &&
        chaptersInspected &&
        _metadata._shouldAttemptMetadataScrape(
          previousSnapshot: previousSnapshot,
          metadataFilePresent: metadataFilePresent,
          scraperVersion: RemoteLibrarySource._metadataScraperVersion,
          now: RemoteLibrarySource.metadataNowProvider(),
          automaticScrapingEnabled: RemoteLibrarySource._canScrapeMetadata,
          forceMetadataScrape: forceMetadataScrape,
        );
    if (shouldScrape) {
      if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
      final dirName = _directoryName(id);
      final fileNames = <String>{
        for (final entry in entries)
          if (!entry.isDirectory && !_isIgnoredEntry(entry.name)) entry.name,
        for (final dir in directories) dir.name,
        for (final chapterEntries in inspectedChapterEntries.values)
          for (final entry in chapterEntries)
            if (!entry.isDirectory && !_isIgnoredEntry(entry.name)) entry.name,
      }.toList(growable: false);
      final authors = _metadata._metadataAuthors([
        previousSnapshot?.author,
        metadata?.author,
      ]);
      final scraped = await _metadata._scrapeMissingMetadata(
        config,
        id,
        comicPath,
        pageCount: directories.isEmpty ? rootImages.length : null,
        input: RemoteLibraryMetadataInput(
          title: dirName,
          directoryTitle: dirName.isEmpty ? null : dirName,
          fileNames: fileNames,
          authors: authors,
        ),
        syncRun: syncRun,
        forceMetadataScrape: forceMetadataScrape,
      );
      if (syncRun != null) _throwIfSynchronizationObsolete(syncRun);
      metadata = scraped.metadata ?? metadata;
      metadataFilePresent = scraped.filePresent;
      metadataScrapeStatus = scraped.status;
      metadataScraperVersion = RemoteLibrarySource._metadataScraperVersion;
      metadataScrapeAttemptedAt = scraped.attemptedAt;
      metadataScrapeRetryAt = scraped.retryAt;
      metadataScrapeError = scraped.error;
    }

    if (directories.isEmpty && metadata?.chapters?.isNotEmpty == true) {
      for (var index = 0; index < metadata!.chapters!.length; index++) {
        final chapter = metadata.chapters![index];
        final chapterId = '$_metadataChapterPrefix$index';
        metadataChapters[chapterId] = chapter;
        chapterMap[chapterId] = chapter.title;
      }
    } else if (directories.isEmpty && rootImages.isNotEmpty) {
      chapterMap[rootChapterId] = rootChapterTitle;
    }
    if (chapterMap.isEmpty && chaptersInspected) {
      throw const FormatException(
        'No images found in the remote comic directory',
      );
    }

    final metadataTitle = metadata?.title.trim() ?? '';
    return _RemoteComicSnapshot(
      title: metadataTitle.isEmpty ? _directoryName(id) : metadataTitle,
      author: metadata?.author ?? '',
      tags: metadata?.tags ?? const [],
      description: metadata?.description ?? '',
      cover: coverPath ?? '',
      chapters: chapterMap,
      chaptersInspected: chaptersInspected,
      chapterImages: {
        for (final entry in inspectedChapterEntries.entries)
          if (chapterMap.containsKey(entry.key))
            entry.key: _imageEntries(entry.value)
                .where((image) => !isNamedComicCover(image.name))
                .map((image) => image.name)
                .toList(),
      },
      metadataChapters: metadataChapters,
      rootImages: rootImages,
      bangumiSubjectId: metadata?.bangumiSubjectId,
      metadataFilePresent: metadataFilePresent,
      metadataScrapeStatus: metadataScrapeStatus,
      metadataScraperVersion: metadataScraperVersion,
      metadataScrapeAttemptedAt: metadataScrapeAttemptedAt,
      metadataScrapeRetryAt: metadataScrapeRetryAt,
      metadataScrapeError: metadataScrapeError,
    );
  }

  Future<Map<String, dynamic>> getImageLoadingConfig(
    String imageKey,
    String comicId,
    String epId, {
    ComicImageLoadTarget? target,
  }) async {
    final config = _config;
    if (imageKey.startsWith(remoteArchiveImagePrefix) ||
        imageKey.startsWith(remoteComicWorkImagePrefix)) {
      Future<Uint8List> loadBytes(CancelToken token) {
        final priority = RemoteReadContext.current;
        return priority.run(() => _loadArchiveImage(imageKey, token));
      }

      return {'loadBytes': loadBytes};
    }
    if (config.remoteStore != null) {
      final link = await config.remoteStore!.link(imageKey);
      return {'url': link.url, 'headers': link.headers};
    }
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }

  Future<Map<String, dynamic>> getThumbnailLoadingConfig(
    String imageKey,
  ) async {
    final config = _config;
    if (imageKey.startsWith(remoteArchiveImagePrefix) ||
        imageKey.startsWith(remoteComicWorkImagePrefix)) {
      Future<Uint8List> loadBytes(CancelToken token) {
        final priority = RemoteReadContext.current;
        return priority.run(() => _loadArchiveImage(imageKey, token));
      }

      return {'loadBytes': loadBytes};
    }
    if (imageKey.startsWith('cover.')) {
      return {'headers': config.authHeaders};
    }
    if (config.remoteStore != null) {
      final link = await config.remoteStore!.link(imageKey);
      return {'url': link.url, 'headers': link.headers};
    }
    return {'url': config.fileUrl(imageKey), 'headers': config.authHeaders};
  }
}

class RemoteLibraryEngines {
  RemoteLibraryEngines._();

  static final _bySourceKey = <String, RemoteLibraryEngine>{};

  static RemoteLibraryEngine? find(String sourceKey) => _bySourceKey[sourceKey];

  static Future<void> refreshAll() async {
    for (final engine in _bySourceKey.values) {
      await engine.synchronize();
    }
  }

  static void checkAllAutomaticSync() {
    for (final engine in _bySourceKey.values) {
      engine.checkForAutomaticSync();
    }
  }

  static void initializeAllMetadataRetry() {
    for (final engine in _bySourceKey.values) {
      engine.initializeMetadataRetry();
    }
  }

  static final _closing = <Future<void>>{};

  static Future<void> cancelAll() async {
    final engines = _bySourceKey.values.toList();
    _bySourceKey.clear();
    await Future.wait([
      for (final engine in engines) engine.cancel(),
      ..._closing,
    ]);
  }

  static Future<void> close() async {
    await cancelAll();
    await RemoteLibrarySource._legacyEngine.cancel();
    await RemoteLibraryRepository.instance.close();
  }

  static void replace(RemoteLibraryEngine engine) {
    final old = _bySourceKey[engine.library.sourceKey];
    if (!identical(old, engine) && old != null) _close(old);
    _bySourceKey[engine.library.sourceKey] = engine;
  }

  static void remove(String sourceKey) {
    final engine = _bySourceKey.remove(sourceKey);
    if (engine != null) _close(engine);
  }

  static void _close(RemoteLibraryEngine engine) {
    final closing = engine.cancel();
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));
  }
}

List<RemoteLibraryEntry> _sortedDirectories(List<RemoteLibraryEntry> entries) {
  return entries
      .where((entry) => entry.isDirectory)
      .where((entry) => !_isIgnoredEntry(entry.name))
      .toList()
    ..sort((a, b) => compareComicFileNames(a.name, b.name));
}

bool _hasMetadataFile(
  List<RemoteLibraryEntry> entries, {
  String fileName = _metadataFileName,
}) {
  return entries.any(
    (entry) =>
        !entry.isDirectory &&
        entry.name.toLowerCase() == fileName.toLowerCase(),
  );
}

String _joinRelativeDirectoryPath(String parent, String name) {
  return parent.isEmpty ? name : '$parent/$name';
}

String _directoryName(String id) {
  final normalized = id.endsWith('/') ? id.substring(0, id.length - 1) : id;
  final separator = normalized.lastIndexOf('/');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

List<RemoteLibraryEntry> _imageEntries(List<RemoteLibraryEntry> entries) {
  return sortedComicImageEntries(
    entries.where((entry) => !entry.isDirectory),
    nameOf: (entry) => entry.name,
  );
}

RemoteLibraryEntry? _findNamedCover(List<RemoteLibraryEntry> entries) {
  return findNamedComicCover(
    _imageEntries(entries),
    nameOf: (entry) => entry.name,
  );
}

bool _isIgnoredEntry(String name) {
  return isIgnoredComicStorageEntry(name) || isComicArchiveFileName(name);
}
