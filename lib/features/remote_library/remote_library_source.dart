part of 'remote_library_engine.dart';

/// 旧单库调用的兼容入口。新漫画库直接使用各自的 Engine。
class RemoteLibrarySource {
  RemoteLibrarySource._();

  static const sourceKey = 'webdav_library';
  static const explorePageTitle = 'Remote Library';
  static const pageSize = 20;
  static const rootChapterId = '__root__';
  static const rootChapterTitle = 'Images';
  static RemoteLibraryEngine _legacyEngine = RemoteLibraryEngine._legacy();
  static RemoteLibraryOps _ops = _RemoteLibraryOps();
  static RemoteLibraryMetadataScraper? _metadataScraper;
  static bool Function()? _metadataScrapingEnabled;
  static String _metadataScraperVersion = _defaultScraperVersion;
  static RemoteLibraryMetadataWriteGuard? _metadataWriteGuard;
  static RemoteLibraryMetadataSubjectHandler? _metadataSubjectHandler;

  @visibleForTesting
  static int? discoveryDirectoryLimitOverride;
  @visibleForTesting
  static int Function() metadataNowProvider = () =>
      DateTime.now().millisecondsSinceEpoch;
  @visibleForTesting
  static RemoteReadScheduler Function()? archiveSchedulerFactory;
  @visibleForTesting
  static Dio Function()? archiveDioFactory;

  static bool get _canScrapeMetadata =>
      _metadataScraper != null &&
      (_metadataScrapingEnabled == null || _metadataScrapingEnabled!());
  static String get activeSourceKey => sourceKey;
  static String get currentLibraryId => _legacyEngine.libraryId;
  static ValueNotifier<int> get contentVersion => _legacyEngine.contentVersion;
  static ValueNotifier<RemoteLibrarySyncStatus> get syncStatus =>
      _legacyEngine.syncStatus;
  static ValueNotifier<int> get metadataPendingVersion =>
      _legacyEngine.metadataPendingVersion;
  static List<RemoteLibraryMetadataPendingStatus> get metadataPendingStatuses =>
      _legacyEngine.metadataPendingStatuses;
  static RemoteLibraryOps get ops => _ops;
  static set ops(RemoteLibraryOps value) {
    _ops = value;
    _legacyEngine._clearMemoryCaches();
  }

  static void configureMetadataScraper(
    RemoteLibraryMetadataScraper? scraper, {
    bool Function()? isEnabled,
    String scraperVersion = _defaultScraperVersion,
  }) {
    _metadataScraper = scraper;
    _metadataScrapingEnabled = isEnabled;
    _metadataScraperVersion = scraperVersion.trim().isEmpty
        ? _defaultScraperVersion
        : scraperVersion.trim();
  }

  static void configureMetadataSubjectHandler(
    RemoteLibraryMetadataSubjectHandler? handler,
  ) {
    _metadataSubjectHandler = handler;
  }

  static void configureMetadataWriteGuard(
    RemoteLibraryMetadataWriteGuard? guard,
  ) {
    _metadataWriteGuard = guard;
  }

  static void resetOps() {
    _ops = _RemoteLibraryOps();
    _legacyEngine._clearMemoryCaches();
  }

  static ComicSource create() => _legacyEngine.create();
  static Future<Res<bool>> testConnection(RemoteLibraryConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid remote comic library configuration');
    }
    try {
      await _ops.test(config);
      return const Res(true);
    } catch (error) {
      return Res.error(error.toString());
    }
  }

  static Future<Res<List<Comic>>> loadComics(int page) =>
      _legacyEngine.loadComics(page);
  static Future<Res<ComicDetails>> loadComicInfo(String id) =>
      _legacyEngine.loadComicInfo(id);
  static Future<Res<List<String>>> loadComicPages(String id, String? ep) =>
      _legacyEngine.loadComicPages(id, ep);
  static Future<Res<bool>> synchronize({bool force = false}) =>
      _legacyEngine.synchronize(force: force);
  static Future<Map<String, dynamic>> getImageLoadingConfig(
    String imageKey,
    String comicId,
    String epId, {
    ComicImageLoadTarget? target,
  }) => _legacyEngine.getImageLoadingConfig(
    imageKey,
    comicId,
    epId,
    target: target,
  );
  static Future<Map<String, dynamic>> getThumbnailLoadingConfig(
    String imageKey,
  ) => _legacyEngine.getThumbnailLoadingConfig(imageKey);
  static Future<void> writeMetadata(
    String id,
    ComicMetaData metadata, {
    String? expectedLibraryId,
    int? expectedSubjectId,
  }) => _legacyEngine.writeMetadata(
    id,
    metadata,
    expectedLibraryId: expectedLibraryId,
    expectedSubjectId: expectedSubjectId,
  );
  static Future<Res<RemoteLibraryMetadataScrapeResult>> retryMetadataScrape(
    String id,
  ) => _legacyEngine.retryMetadataScrape(id);
  static void initializeMetadataRetry() =>
      _legacyEngine.initializeMetadataRetry();
  static Future<void> retryPendingMetadata({bool force = false}) =>
      _legacyEngine.retryPendingMetadata(force: force);
  static void updateSyncStatusFromCache() =>
      unawaited(_legacyEngine._loadStatus());
  static void checkForAutomaticSync() => _legacyEngine.checkForAutomaticSync();
  static void initializeAutoSync() {
    updateSyncStatusFromCache();
    _legacyEngine._state.autoSyncTimer ??= Timer.periodic(
      const Duration(minutes: 15),
      (_) => checkForAutomaticSync(),
    );
    checkForAutomaticSync();
  }

  static Future<void> onConfigurationChanged(
    RemoteLibraryConfig previous,
  ) async {
    final old = _legacyEngine;
    await old.cancel();
    _legacyEngine = RemoteLibraryEngine._legacy();
    _ops = _RemoteLibraryOps();
    if (previous.isValid &&
        previous.cacheKey != _legacyEngine._config.cacheKey) {
      await RemoteLibraryRepository.instance.clear(previous.cacheKey);
    }
    await _legacyEngine._loadStatus();
    _legacyEngine._notifyContent(immediate: true);
    initializeMetadataRetry();
  }

  static Future<void> onSettingsImported() async {
    await _legacyEngine.cancel();
    _legacyEngine = RemoteLibraryEngine._legacy();
    _ops = _RemoteLibraryOps();
    await _legacyEngine._loadStatus();
    _legacyEngine._notifyContent(immediate: true);
    initializeMetadataRetry();
  }

  @visibleForTesting
  static Future<void> waitForBackgroundTasks() =>
      _legacyEngine.waitForBackgroundTasks();

  @visibleForTesting
  static Future<void> resetCacheForTesting() async {
    await _legacyEngine.cancel();
    await RemoteLibraryRepository.instance.resetForTesting();
    _legacyEngine = RemoteLibraryEngine._legacy();
    RemoteLibraryEngine._archiveAccounts.clear();
    _metadataWriteGuard = null;
    discoveryDirectoryLimitOverride = null;
    metadataNowProvider = () => DateTime.now().millisecondsSinceEpoch;
    appdata.implicitData.remove(_metadataPendingKey);
  }
}
