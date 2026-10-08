import 'dart:async';

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
import 'package:venera_plus/network/cookie_jar.dart';
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

@visibleForTesting
Future<void> initializeBangumiAfterDataSync({
  required Future<void> Function() waitForDownload,
  required Future<void> Function() Function() createInitializer,
  Future<void> Function()? waitForStartup,
}) async {
  if (waitForStartup != null) {
    await waitForStartup();
  }
  await waitForDownload();
  await createInitializer()();
}

@visibleForTesting
void startBangumiAfterDataSync({
  required Future<void> Function() waitForDownload,
  required Future<void> Function() Function() createInitializer,
  Future<void> Function()? waitForStartup,
}) {
  unawaited(
    initializeBangumiAfterDataSync(
      waitForStartup: waitForStartup,
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

Future<void> init() async {
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  configureComicTypeSourceKeyResolver();
  configureBangumiScopeResolver((sourceKey) {
    if (sourceKey != WebDavLibrarySource.sourceKey) return '';
    final config = WebDavLibraryConfig.fromSettings();
    return config.isValid ? config.libraryId : '';
  });
  WebDavLibrarySource.configureMetadataWriteGuard((
    libraryId,
    comicId,
    subjectId,
  ) {
    final binding = BangumiService().bindingFor(
      WebDavLibrarySource.sourceKey,
      comicId,
    );
    return binding?.scopeId == libraryId && binding?.subjectId == subjectId;
  });
  registerAppDataSettingsChangedHandler(
    () => refreshRuntimeAfterSettingsImport(
      resetWebDavLibrary: WebDavLibrarySource.onSettingsImported,
      reloadComicSources: () async {
        await ComicSourceManager().reload();
      },
      initializeBangumi: BangumiService().initialize,
      checkForAutomaticSync: WebDavLibrarySource.checkForAutomaticSync,
    ),
  );
  SyncPreferencesAdapter.registerSettingsImportedCallback(() async {
    WebDavLibrarySource.onSettingsImported();
    // Source/session refresh belongs to the adapter's post-journal phase.
    // Startup services must not run until conservative recovery is ready.
    if (DataSync.instance?.isReady != true) return;
    await BangumiService().initialize();
    WebDavLibrarySource.checkForAutomaticSync();
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
    if (sourceKey != WebDavLibrarySource.sourceKey) return;
    final service = BangumiService();
    final binding = service.bindingFor(sourceKey, comicId);
    if (binding?.scopeId != scopeId || binding?.subjectId != subject.id) return;
    final detailed = await service.getSubject(subject.id);
    final latestBinding = service.bindingFor(sourceKey, comicId);
    if (latestBinding?.scopeId != scopeId ||
        latestBinding?.subjectId != subject.id) {
      return;
    }
    await WebDavLibrarySource.writeMetadata(
      comicId,
      _metadataFromBangumiSubject(detailed),
      expectedLibraryId: scopeId,
      expectedSubjectId: subject.id,
    );
  });
  configureReaderChapterCompletedHandler(
    (event) => BangumiService().onChapterCompleted(
      sourceKey: event.sourceKey,
      comicId: event.comicId,
      chapterTitle: event.chapterTitle,
    ),
  );
  configureRuntimeComicSourcesProvider(
    () => WebDavLibraryConfig.fromSettings().isValid
        ? [WebDavLibrarySource.create()]
        : const [],
  );
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
      Rhttp.init(),
      App.initComponents([
        HistoryManager().init,
        LocalFavoritesManager().init,
        LocalManager().init,
      ]),
      SAFTaskWorker().init().wait(),
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  await _checkOldConfigs();
  final dataSync = DataSync();
  configureComicSourceDataSavedHandler(
    () async => dataSync.onDataChanged(domains: {'source', 'sourceSession'}),
  );
  startBangumiAfterDataSync(
    waitForStartup: dataSync.waitForStartupMerge,
    waitForDownload: dataSync.waitForDownload,
    createInitializer: () => () async {
      await BangumiService().initialize();
      WebDavLibrarySource.initializeMetadataRetry();
      WebDavLibrarySource.initializeAutoSync();
      if (BangumiService().isConnected &&
          appdata.settings['bangumiAutoMetadataScrapeEnabled'] == true) {
        unawaited(WebDavLibrarySource.synchronize());
      }
      FollowUpdatesService.initChecker();
    },
  );
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/Venera-Works/Venera-Plus/issues
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
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
  if (appdata.implicitData['webdavSyncDirection'] == null ||
      appdata.implicitData['webdavSyncTiming'] == null ||
      appdata.implicitData['webdavSyncIntervalMinutes'] == null ||
      appdata.implicitData.containsKey('webdavSyncMode') ||
      appdata.implicitData.containsKey('webdavAutoSync')) {
    var webdavConfig = appdata.settings['webdav'];
    var hasValidConfig =
        webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3;

    if (appdata.implicitData['webdavSyncDirection'] == null) {
      appdata.implicitData['webdavSyncDirection'] = 'bidirectional';
    }

    if (appdata.implicitData['webdavSyncTiming'] == null) {
      final oldMode = appdata.implicitData['webdavSyncMode'];
      if (oldMode == 'scheduled') {
        appdata.implicitData['webdavSyncTiming'] = 'scheduled';
      } else if (oldMode == 'realtime') {
        appdata.implicitData['webdavSyncTiming'] = 'realtime';
      } else if (oldMode == 'manual') {
        appdata.implicitData['webdavSyncTiming'] = 'manual';
      } else if (appdata.implicitData['webdavAutoSync'] == true) {
        appdata.implicitData['webdavSyncTiming'] = 'realtime';
      } else if (appdata.implicitData['webdavAutoSync'] == false) {
        appdata.implicitData['webdavSyncTiming'] = 'manual';
      } else {
        appdata.implicitData['webdavSyncTiming'] = hasValidConfig
            ? 'realtime'
            : 'manual';
      }
    }

    if (appdata.implicitData['webdavSyncIntervalMinutes'] == null) {
      appdata.implicitData['webdavSyncIntervalMinutes'] = 30;
    }

    appdata.implicitData.remove('webdavSyncMode');
    appdata.implicitData.remove('webdavAutoSync');
    await appdata.writeImplicitData();
  }
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
      await DataSync().waitForStartupMerge();
      await DataSync().waitForDownload();
      FollowUpdatesService.initChecker();
    }().wait(),
  );
}

void reloadComicSourcesForDebug() {
  ComicSourceManager().reload();
}
