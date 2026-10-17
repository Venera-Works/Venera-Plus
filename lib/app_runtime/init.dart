import 'dart:async';
import 'dart:convert';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/image_provider/cached_image.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/startup_timing.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:venera_plus/network/proxy.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/routing/app_links.dart';
import 'package:venera_plus/routing/handle_text_share.dart';
import 'package:venera_plus/foundation/opencc.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/reader/reader.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

final _remoteComicLibrarySources = <String, WebDavLibraryEngine>{};
String _remoteLibraryConfigurationSignature = '';

String _remoteLibrarySignature() => jsonEncode([
  for (final library in RemoteComicLibraryRegistry.read())
    [
      library.id,
      library.sourceKey,
      library.accountId,
      library.directories,
      library.name,
      library.autoRefresh,
      library.refreshIntervalMinutes,
      () {
        final account = RemoteStorageAccounts.instance.account(
          library.accountId,
        );
        return account == null
            ? null
            : [
                account.id,
                account.backend.name,
                account.driver,
                account.authorization,
              ];
      }(),
    ],
]);

List<ComicSource> _runtimeRemoteComicSources() {
  final libraries = RemoteComicLibraryRegistry.read();
  final active = <String>{};
  final result = <ComicSource>[];
  for (final library in libraries) {
    final account = RemoteStorageAccounts.instance.account(library.accountId);
    // A deleted or not-yet-authorized account must not make all sources fail
    // to reload. The library becomes visible again when its account returns.
    if (account == null || !account.isConfigured) continue;
    active.add(library.sourceKey);
    final current = _remoteComicLibrarySources[library.sourceKey];
    final source = current != null && current.matches(library, account)
        ? current
        : WebDavLibraryEngine(
            library: library,
            store: RemoteStorageAccounts.instance.storeFor(library.accountId),
          );
    if (!identical(source, current)) current?.cancel();
    _remoteComicLibrarySources[library.sourceKey] = source;
    WebDavLibraryEngines.replace(source);
    result.add(source.create());
  }
  for (final key in _remoteComicLibrarySources.keys.toList()) {
    if (!active.contains(key)) {
      _remoteComicLibrarySources.remove(key)?.cancel();
      WebDavLibraryEngines.remove(key);
    }
  }
  return result;
}

Future<void> _refreshRemoteComicLibrariesAfterSettingsImport() async {
  WebDavLibraryEngines.cancelAll();
  _remoteComicLibrarySources.clear();
  await ComicSourceManager().reload();
  WebDavLibraryEngines.checkAllAutomaticSync();
}

/// Runtime entry used by lifecycle callbacks; legacy static source timers are
/// intentionally not started by the app.
void checkRemoteComicLibrariesForAutomaticSync() =>
    WebDavLibraryEngines.checkAllAutomaticSync();

/// Releases remote-library timers before dropping active remote drivers.
Future<void> shutdownRemoteComicLibraryRuntime() async {
  WebDavLibraryEngines.cancelAll();
  _remoteComicLibrarySources.clear();
  try {
    await RemoteStorageAccounts.instance.close();
  } catch (error, stackTrace) {
    Log.error('OpenList close', error, stackTrace);
  }
}

void _watchRemoteLibraryConfiguration(RemoteStorageAccounts accounts) {
  _remoteLibraryConfigurationSignature = _remoteLibrarySignature();
  accounts.addListener(() {
    final signature = _remoteLibrarySignature();
    if (signature == _remoteLibraryConfigurationSignature) return;
    _remoteLibraryConfigurationSignature = signature;
    unawaited(ComicSourceManager().reload().wait());
  });
}

@visibleForTesting
Future<void> initializeBangumiAfterDataSync({
  required Future<void> Function() waitForDownload,
  required Future<void> Function() Function() createInitializer,
}) async {
  await waitForDownload();
  await createInitializer()();
}

@visibleForTesting
void startBangumiAfterDataSync({
  required Future<void> Function() waitForDownload,
  required Future<void> Function() Function() createInitializer,
}) {
  unawaited(
    initializeBangumiAfterDataSync(
      waitForDownload: waitForDownload,
      createInitializer: createInitializer,
    ).wait(),
  );
}

@visibleForTesting
Future<void> refreshRuntimeAfterSettingsImport({
  required void Function() resetWebDavLibrary,
  required Future<void> Function() reloadComicSources,
  required Future<void> Function() initializeBangumi,
  required void Function() checkForAutomaticSync,
}) async {
  resetWebDavLibrary();
  await reloadComicSources();
  await initializeBangumi();
  checkForAutomaticSync();
}

ComicMetaData _metadataFromBangumiSubject(BangumiSubject subject) =>
    ComicMetaData(
      title: subject.metadataTitle,
      author: subject.authors.join(', '),
      description: subject.summary,
      tags: subject.tags,
      bangumiSubjectId: subject.id,
    );

@visibleForTesting
Future<ComicMetaData?> scrapeBangumiMetadataForWebDav(
  String directoryTitle, {
  BangumiService? service,
}) async {
  final bangumi = service ?? BangumiService();
  if (!bangumi.isConnected) {
    throw StateError('Bangumi is not connected');
  }
  final subject = await bangumi.matchSubjectForMetadata(directoryTitle);
  return subject == null ? null : _metadataFromBangumiSubject(subject);
}

Future<void> init({bool deferBackgroundTasks = false}) async {
  await StartupTiming.measure('App paths', App.init);
  await StartupTiming.measure('Settings', appdata.init);
  final remoteStorage = RemoteStorageAccounts.instance;
  remoteStorage.configureOpenList(
    EmbeddedOpenListRpc(),
    dataDir: '${App.dataPath}/openlist',
    proxy: await getProxy(),
  );
  await StartupTiming.measure('Storage migrations', () async {
    await RemoteComicLibraryRegistry.migrateLegacyWebDavLibrary();
    await remoteStorage.migrateLegacyWebDavLocations();
  });
  await StartupTiming.measure('Cookies', () async {
    await SingleInstanceCookieJar.createInstance();
  });
  configureComicTypeSourceKeyResolver();
  configureBangumiScopeResolver(
    (sourceKey) =>
        RemoteComicLibraryRegistry.findBySourceKey(sourceKey)?.id ?? '',
  );
  WebDavLibrarySource.configureMetadataWriteGuard((
    libraryId,
    comicId,
    subjectId,
  ) {
    final sourceKey = WebDavLibrarySource.activeSourceKey;
    final binding = BangumiService().bindingFor(sourceKey, comicId);
    return binding?.scopeId == libraryId && binding?.subjectId == subjectId;
  });
  registerAppDataSettingsChangedHandler(() async {
    await RemoteComicLibraryRegistry.migrateLegacyWebDavLibrary();
    await _refreshRemoteComicLibrariesAfterSettingsImport();
    await BangumiService().initialize();
  });
  WebDavLibrarySource.configureMetadataScraper(
    scrapeBangumiMetadataForWebDav,
    isEnabled: () =>
        BangumiService().isConnected &&
        appdata.settings['bangumiAutoMetadataScrapeEnabled'] == true,
  );
  configureBangumiBindingMetadataHandler(({
    required String scopeId,
    required String sourceKey,
    required String comicId,
    required BangumiSubject subject,
  }) async {
    final service = BangumiService();
    final binding = service.bindingFor(sourceKey, comicId);
    if (binding?.scopeId != scopeId || binding?.subjectId != subject.id) return;
    final detailed = await service.getSubject(subject.id);
    final latestBinding = service.bindingFor(sourceKey, comicId);
    if (latestBinding?.scopeId != scopeId ||
        latestBinding?.subjectId != subject.id) {
      return;
    }
    final source = _remoteComicLibrarySources[sourceKey];
    if (source == null || source.libraryId != scopeId) return;
    await source.writeMetadata(comicId, _metadataFromBangumiSubject(detailed));
  });
  configureReaderChapterCompletedHandler(
    (event) => BangumiService().onChapterCompleted(
      sourceKey: event.sourceKey,
      comicId: event.comicId,
      chapterTitle: event.chapterTitle,
    ),
  );
  configureRuntimeComicSourcesProvider(_runtimeRemoteComicSources);
  configureComicWidgets(
    comicPageBuilder:
        ({
          required String id,
          required String sourceKey,
          String? cover,
          String? title,
          int? heroID,
        }) => ComicPage(
          id: id,
          sourceKey: sourceKey,
          cover: cover,
          title: title,
          heroID: heroID,
        ),
    addFavorite: addFavorite,
    tileStateResolver: _resolveComicTileState,
    tileImageProviderResolver: _resolveComicTileImageProvider,
    addStateListener: (listener) {
      HistoryManager().addListener(listener);
      LocalFavoritesManager().addListener(listener);
    },
    removeStateListener: (listener) {
      HistoryManager().removeListener(listener);
      LocalFavoritesManager().removeListener(listener);
    },
    favoriteDisplayStateResolver: () => ComicFavoriteDisplayState(
      isGallery: isFavoriteGalleryMode(),
      galleryColumns: favoriteGalleryColumns(),
    ),
  );
  try {
    var futures = [
      StartupTiming.measure('HTTP runtime', Rhttp.init),
      App.initComponents([
        () => StartupTiming.measure('History database', HistoryManager().init),
        () => StartupTiming.measure(
          'Favorites database',
          LocalFavoritesManager().init,
        ),
        () => StartupTiming.measure('Local library', LocalManager().init),
      ]),
      SAFTaskWorker().init().wait(),
      StartupTiming.measure('Translations', AppTranslation.init),
      StartupTiming.measure('Tag translations', TagsTranslation.readData),
      StartupTiming.measure('JavaScript runtime', JsEngine().init),
      StartupTiming.measure('Comic sources', ComicSourceManager().init),
      StartupTiming.measure('Chinese conversion', OpenCC.init),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
    rethrow;
  }
  await _checkOldConfigs();
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  StartupTiming.mark('Local initialization complete');
  if (!deferBackgroundTasks) startBackgroundTasks();
}

bool _backgroundTasksStarted = false;

/// GUI startup calls this after the first app frame; headless startup calls it
/// directly. Every OpenList consumer shares the same initialization future.
void startBackgroundTasks() {
  if (_backgroundTasksStarted) return;
  _backgroundTasksStarted = true;
  final remoteStorage = RemoteStorageAccounts.instance;
  _watchRemoteLibraryConfiguration(remoteStorage);
  var proxySetting = appdata.settings['proxy'];
  appdata.settings.addListener(() {
    final current = appdata.settings['proxy'];
    if (current == proxySetting) return;
    proxySetting = current;
    unawaited(
      () async {
        await remoteStorage.updateProxy(await getProxy());
      }().wait(),
    );
  });
  if (remoteStorage.accounts.any(
    (account) => account.backend == StorageBackend.openlist,
  )) {
    unawaited(
      StartupTiming.measure('OpenList', () async {
        await remoteStorage.ensureInitialized();
        StartupTiming.mark('OpenList ready');
      }).wait(),
    );
  }
  final dataSync = DataSync();
  configureComicSourceDataSavedHandler(() async => dataSync.onDataChanged());
  startBangumiAfterDataSync(
    waitForDownload: dataSync.waitForDownload,
    createInitializer: () => () async {
      await BangumiService().initialize();
      WebDavLibraryEngines.initializeAllMetadataRetry();
      WebDavLibraryEngines.checkAllAutomaticSync();
      if (BangumiService().isConnected &&
          appdata.settings['bangumiAutoMetadataScrapeEnabled'] == true) {
        WebDavLibraryEngines.checkAllAutomaticSync();
      }
      FollowUpdatesService.initChecker();
    },
  );
  if (App.isAndroid) {
    unawaited(FlutterDisplayMode.setHighRefreshRate().wait());
  }
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/Venera-Works/Venera-Plus/issues
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

bool _appLinkHandlersStarted = false;

/// Subscribe after main navigation exists, including after startup auth.
void startAppLinkHandlers() {
  if (!App.isAndroid || _appLinkHandlersStarted) return;
  _appLinkHandlersStarted = true;
  handleLinks();
  handleTextShare();
}

ComicTileState _resolveComicTileState(Comic comic) {
  final type = _comicTypeOf(comic);
  final history = appdata.settings['showHistoryStatusOnTile']
      ? HistoryManager().find(comic.id, type)
      : null;
  return ComicTileState(
    isFavorite:
        appdata.settings['showFavoriteStatusOnTile'] &&
        LocalFavoritesManager().isExist(comic.id, type),
    historyPage: history?.page,
    historyMaxPage: history?.maxPage,
    hasNewUpdate:
        appdata.settings['showUpdateStatusOnTile'] &&
        type != ComicType.local &&
        LocalFavoritesManager().hasNewUpdate(comic.id, type),
  );
}

ComicType _comicTypeOf(Comic comic) {
  if (comic is FavoriteItem) return comic.type;
  if (comic is History) return comic.type;
  if (comic is LocalComic) return comic.comicType;
  return ComicType.fromKey(comic.sourceKey);
}

ImageProvider? _resolveComicTileImageProvider(Comic comic) {
  if (comic.cover.trim().isEmpty) return null;
  if (comic is LocalComic) return LocalComicImageProvider(comic);
  if (comic is History) return HistoryImageProvider(comic);
  if (comic.sourceKey == 'local') {
    final localComic = LocalManager().find(comic.id, ComicType.local);
    return localComic == null ? null : FileImage(localComic.coverFile);
  }
  return CachedImageProvider(
    comic.cover,
    sourceKey: comic.sourceKey,
    cid: comic.id,
    fallback: comic is FavoriteItem
        ? () => _loadLocalCoverFallback(comic.sourceKey, comic.id)
        : null,
  );
}

Future<Uint8List?> _loadLocalCoverFallback(String sourceKey, String id) async {
  final localComic = LocalManager().find(id, ComicType.fromKey(sourceKey));
  if (localComic == null) return null;
  final file = localComic.coverFile;
  if (!await file.exists()) return null;
  final data = await file.readAsBytes();
  return data.isEmpty ? null : data;
}

Future<void> _checkOldConfigs() async {
  final implicit = appdata.implicitData;
  final timing = implicit['webdavSyncTiming'];
  final config = appdata.settings['webdav'];
  final configured =
      config is List &&
      config.length == 3 &&
      config.whereType<String>().length == 3 &&
      (config[0] as String).isNotEmpty;
  var changed = false;

  if (!implicit.containsKey('webdavSyncMode')) {
    final mapped = switch (timing) {
      'realtime' => DataSyncMode.realtime.name,
      'scheduled' => DataSyncMode.scheduled.name,
      'manual' => DataSyncMode.manual.name,
      _ =>
        implicit['webdavAutoSync'] == true
            ? DataSyncMode.realtime.name
            : implicit['webdavAutoSync'] == false
            ? DataSyncMode.manual.name
            : configured
            ? DataSyncMode.realtime.name
            : DataSyncMode.manual.name,
    };
    implicit['webdavSyncMode'] = mapped;
    changed = true;
  }
  if (!implicit.containsKey('webdavAutoSync')) {
    implicit['webdavAutoSync'] =
        implicit['webdavSyncMode'] != DataSyncMode.manual.name;
    changed = true;
  }
  if (implicit['webdavSyncIntervalMinutes'] is! int) {
    implicit['webdavSyncIntervalMinutes'] = 30;
    changed = true;
  }
  if (timing != null || implicit.containsKey('webdavSyncDirection')) {
    if (configured) {
      implicit['webdavSyncPending'] = true;
    }
    implicit.remove('webdavSyncTiming');
    implicit.remove('webdavSyncDirection');
    changed = true;
  }
  if (changed) await appdata.writeImplicitData();
}

@visibleForTesting
Future<void> checkOldConfigsForTesting() => _checkOldConfigs();

Future<void> _checkAppUpdates() async {
  var lastCheck = appdata.implicitData['lastCheckUpdate'] ?? 0;
  var now = DateTime.now().millisecondsSinceEpoch;
  if (now - lastCheck < 24 * 60 * 60 * 1000) {
    return;
  }
  appdata.implicitData['lastCheckUpdate'] = now;
  appdata.writeImplicitData();
  ComicSourcePage.checkComicSourceUpdate();
  if (appdata.settings['checkUpdateOnStart']) {
    await checkUpdateUi(false, true);
  }
}

void checkUpdates() {
  _checkAppUpdates();
  unawaited(
    () async {
      await DataSync().waitForDownload();
      FollowUpdatesService.initChecker();
    }().wait(),
  );
}

void reloadComicSourcesForDebug() {
  ComicSourceManager().reload();
}
