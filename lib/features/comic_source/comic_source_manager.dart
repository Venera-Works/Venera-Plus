import 'dart:convert';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/init.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/images.dart';

import 'category.dart';
import 'comic_type_bridge.dart';
import 'favorites.dart';
import 'image_loading.dart';
import 'js_bridge.dart';
import 'models.dart';
import 'normalization.dart';
import 'parser.dart';
import 'source.dart';
import 'source_repositories.dart';

typedef RuntimeComicSourcesProvider = Iterable<ComicSource> Function();

RuntimeComicSourcesProvider? _runtimeComicSourcesProvider;

void configureRuntimeComicSourcesProvider(
  RuntimeComicSourcesProvider? provider,
) {
  _runtimeComicSourcesProvider = provider;
}

@visibleForTesting
Map<String, Map<String, dynamic>>? debugNormalizeComicSourceSettings(
  dynamic value,
) {
  return normalizeComicSourceSettings(value);
}

@visibleForTesting
Map<String, dynamic>? debugNormalizeComicSourceLoadingConfig(dynamic value) {
  return normalizeComicSourceLoadingConfig(value);
}

@visibleForTesting
Map<String, dynamic>? debugNormalizeComicSourceStringKeyedMap(dynamic value) {
  return normalizeComicSourceStringKeyedMap(value);
}

@visibleForTesting
List<String>? debugNormalizeComicSourceStringList(dynamic value) {
  return normalizeComicSourceStringList(value);
}

@visibleForTesting
List<Comic>? debugNormalizeComicSourceComicList(
  dynamic value,
  String sourceKey,
) {
  return normalizeComicSourceComicList(value, sourceKey);
}

@visibleForTesting
Map<String, dynamic>? debugNormalizeComicSourceComicDetails(
  dynamic value,
  String sourceKey,
  String comicId,
) {
  return normalizeComicSourceComicDetails(value, sourceKey, comicId);
}

@visibleForTesting
({Map<String, dynamic> data, List<Comment> comments})?
debugNormalizeComicSourceCommentsResult(dynamic value) {
  return normalizeComicSourceCommentsResult(value);
}

@visibleForTesting
List<ArchiveInfo>? debugNormalizeComicSourceArchiveList(dynamic value) {
  return normalizeComicSourceArchiveList(value);
}

@visibleForTesting
String? debugNormalizeComicSourceArchiveDownloadUrl(dynamic value) {
  return normalizeComicSourceArchiveDownloadUrl(value);
}

class ComicSourceManager with ChangeNotifier, Init {
  final List<ComicSource> _sources = [];

  static ComicSourceManager? _instance;

  ComicSourceManager._create() {
    SourceRepositories.instance.addListener(() => updateAvailableUpdates({}));
    configureComicSourceRegistry(
      all: all,
      find: find,
      fromIntKey: fromIntKey,
      isEmpty: () => isEmpty,
    );
    configureComicTypeSourceKeyResolver();
    configureCategoryDataResolver(_findCategoryDataByKey);
    configureFavoriteDataResolver(_findFavoriteDataByKey);
  }

  factory ComicSourceManager() => _instance ??= ComicSourceManager._create();

  List<ComicSource> all() => List.from(_sources);

  ComicSource? find(String key) =>
      _sources.firstWhereOrNull((element) => element.key == key);

  ComicSource? fromIntKey(int key) =>
      _sources.firstWhereOrNull((element) => element.key.hashCode == key);

  CategoryData _findCategoryDataByKey(String key) {
    for (var source in all()) {
      if (source.categoryData?.key == key) {
        return source.categoryData!;
      }
    }
    throw "Unknown category key $key";
  }

  FavoriteData? _findFavoriteDataByKey(String key) {
    return find(key)?.favoriteData;
  }

  @override
  @protected
  Future<void> doInit() async {
    await SourceRepositories.instance.migrate();
    configureComicTypeSourceKeyResolver();
    configureComicSourceImageDownloader(
      thumbnailLoadingConfig: _getThumbnailLoadingConfig,
      thumbnailCover: _getThumbnailCover,
      comicImageLoadingConfig: _getComicImageLoadingConfig,
    );
    configureComicSourceJsDataBridge();
    await JsEngine().ensureInit();
    final loaded = <ComicSource>[];
    final path = "${App.dataPath}/comic_source";
    if (!(await Directory(path).exists())) {
      await Directory(path).create();
    } else {
      await for (var entity in Directory(path).list()) {
        if (entity is File && entity.path.endsWith(".js")) {
          try {
            var source = await ComicSourceParser().parse(
              await entity.readAsString(),
              entity.absolute.path,
            );
            _sources.add(source);
            loaded.add(source);
          } catch (e, s) {
            Log.error("ComicSource", "$e\n$s");
          }
        }
      }
    }
    final runtimeSources =
        _runtimeComicSourcesProvider?.call() ?? const <ComicSource>[];
    for (final source in runtimeSources) {
      if (find(source.key) == null) {
        _sources.add(source);
      }
    }
    // Register every source before invoking init. Network work in one source
    // must not hold up startup or prevent the other sources from initializing.
    for (final source in loaded) {
      unawaited(
        _initializeSource(source).catchError((Object error, StackTrace stack) {
          Log.error('ComicSource', '${source.name}: $error', stack);
        }),
      );
    }
  }

  Future<void> _mutationTail = Future.value();

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _mutationTail.then((_) => action());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> reload() => _mutate(_reloadSources);

  Future<void> _reloadSources() async {
    final previous = {for (final source in _sources) source.key: source};
    final loaded = <ComicSource>[];
    final parsers = <ComicSourceParser>[];
    final directory = Directory('${App.dataPath}/comic_source');
    try {
      // Keep the old registry usable throughout asynchronous disk reads.
      // Its pending saves and complete session maps survive replacement.
      for (final source in previous.values) {
        await source.loadData();
      }
      await directory.create(recursive: true);
      final files = await directory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.js'))
          .toList();
      if (files.isNotEmpty) {
        configureComicSourceJsDataBridge();
        await JsEngine().ensureInit();
      }
      for (final entity in files) {
        final file = entity as File;
        final script = await file.readAsString();
        final key = await ComicSourceParser.probeKey(script, file.path);
        if (key == null || loaded.any((source) => source.key == key)) {
          throw ComicSourceParseException(
            'Invalid or duplicate source identity',
          );
        }
        final parser = ComicSourceParser();
        parsers.add(parser);
        final source = await parser.parse(
          script,
          file.absolute.path,
          expectedKey: key,
          replacing: previous.containsKey(key),
          retainRollback: true,
        );
        final old = previous[key];
        if (old != null) source.shareSessionWith(old);
        loaded.add(source);
      }
      final runtimeSources =
          _runtimeComicSourcesProvider?.call() ?? const <ComicSource>[];
      for (final source in runtimeSources) {
        if (loaded.any((item) => item.key == source.key)) continue;
        final old = previous[source.key];
        if (old != null) source.shareSessionWith(old);
        loaded.add(source);
      }
      _sources
        ..clear()
        ..addAll(loaded);
      // Register every replacement before init can use another source.
      for (final source in loaded.where(
        (source) => source.filePath.isNotEmpty,
      )) {
        await _initializeSource(source);
        await source.waitForDataWrites();
      }
      for (final parser in parsers) {
        parser.commit();
      }
      for (final source in previous.values) {
        if (source.filePath.isNotEmpty &&
            !loaded.any((item) => item.key == source.key)) {
          JsEngine().runCode(
            'delete ComicSource.sources[${jsonEncode(source.key)}];',
          );
        }
      }
      notifyListeners();
    } catch (_) {
      for (final parser in parsers.reversed) {
        parser.rollback();
      }
      _sources
        ..clear()
        ..addAll(previous.values);
      rethrow;
    }
  }

  Future<void> reloadForDebug() => _mutate(() async {
    final errors = <String>[];
    for (final source in all().where((source) => source.filePath.isNotEmpty)) {
      try {
        await _replaceScript(
          source,
          await File(source.filePath).readAsString(),
          validate: () {},
        );
      } catch (error) {
        errors.add('${source.name}: $error');
      }
    }
    notifyListeners();
    if (errors.isNotEmpty) throw ComicSourceParseException(errors.join('\n'));
  });

  Future<void> reloadSource(ComicSource source) => _mutate(() async {
    await _replaceScript(
      source,
      await File(source.filePath).readAsString(),
      validate: () {},
    );
  });

  Future<void> _initializeSource(ComicSource source) async {
    await Future.sync(
      () => JsEngine().runCode('''(() => {
        const result = ComicSource.sources[${jsonEncode(source.key)}]?.init?.();
        return result && typeof result.then === 'function'
          ? result.then(() => undefined) : undefined;
      })()''', source.filePath),
    ).timeout(const Duration(seconds: 15));
  }

  Map<String, dynamic> _snapshotPages() => {
    for (final key in [
      'explore_pages',
      'categories',
      'favorites',
      'searchSources',
    ])
      key: appdata.settings[key] == null
          ? null
          : List.from(appdata.settings[key]),
  };

  void _restorePages(Map<String, dynamic> pages) {
    for (final entry in pages.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  }

  Future<ComicSource> installScript({
    required String js,
    required String fileName,
    required SourceOrigin origin,
    String? expectedKey,
    required void Function() beforeInstall,
  }) => _mutate(() async {
    beforeInstall();
    final oldPages = _snapshotPages();
    ComicSource? source;
    SourceOrigin? oldOrigin;
    final parser = ComicSourceParser();
    try {
      fileName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9_.()-]'), '_');
      source = await parser.createAndParse(
        js,
        fileName,
        expectedKey: expectedKey,
        retainRollback: true,
      );
      oldOrigin = SourceRepositories.instance.originFor(source.key);
      _sources.add(source);
      source.stageDataWrites();
      await _initializeSource(source);
      _registerSourcePages(source);
      await SourceRepositories.instance.setOrigin(source.key, origin);
      await source.commitDataWrites();
      parser.commit();
      notifyListeners();
      return source;
    } catch (_) {
      parser.rollback();
      if (source != null) {
        _sources.removeWhere((s) => s.key == source!.key);
        JsEngine().runCode(
          'delete ComicSource.sources[${jsonEncode(source.key)}];',
        );
        await File(source.filePath).deleteIfExists();
        _restorePages(oldPages);
        await SourceRepositories.instance.setOrigin(source.key, oldOrigin);
      }
      notifyListeners();
      rethrow;
    }
  });

  Future<void> replaceScript(
    ComicSource source,
    String js, {
    required void Function() validate,
    SourceOrigin? origin,
  }) => _mutate(
    () => _replaceScript(source, js, validate: validate, origin: origin),
  );

  Future<void> _replaceScript(
    ComicSource source,
    String js, {
    required void Function() validate,
    SourceOrigin? origin,
  }) async {
    validate();
    final index = _sources.indexWhere((item) => item.key == source.key);
    if (index < 0 || _sources[index].filePath != source.filePath) {
      throw ComicSourceParseException('The source is no longer installed.');
    }
    source = _sources[index];
    final parser = ComicSourceParser();
    final originalScript = await File(source.filePath).readAsString();
    final oldPages = _snapshotPages();
    final oldOrigin = SourceRepositories.instance.originFor(source.key);
    var changedSettings = false;
    var wroteOrigin = false;
    var wroteScript = false;
    try {
      final replacement = await parser.parse(
        js,
        source.filePath,
        expectedKey: source.key,
        replacing: true,
        retainRollback: true,
      );
      replacement.data = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(source.data)),
      );
      replacement.stageDataWrites();
      _sources[index] = replacement;
      await _initializeSource(replacement);
      final temporary = File('${source.filePath}.update');
      try {
        await temporary.writeAsString(js, flush: true);
        await temporary.rename(source.filePath);
        wroteScript = true;
      } finally {
        await temporary.deleteIfExists();
      }
      _registerSourcePages(replacement);
      validate();
      changedSettings = true;
      if (origin != null) {
        await SourceRepositories.instance.setOrigin(source.key, origin);
        wroteOrigin = true;
      } else {
        await appdata.saveData();
      }
      await replacement.commitDataWrites();
      parser.commit();
      clearSourceUpdate(source.key);
      notifyListeners();
    } catch (_) {
      _sources[index] = source;
      parser.rollback();
      if (wroteScript) {
        await File(source.filePath).writeAsString(originalScript, flush: true);
      }
      _restorePages(oldPages);
      if (changedSettings) {
        if (origin != null) {
          final currentOrigin = SourceRepositories.instance.originFor(
            source.key,
          );
          if (wroteOrigin &&
              currentOrigin?.kind == origin.kind &&
              currentOrigin?.repositoryId == origin.repositoryId &&
              currentOrigin?.repositoryName == origin.repositoryName &&
              currentOrigin?.url == origin.url) {
            await SourceRepositories.instance.setOrigin(source.key, oldOrigin);
          }
        } else {
          await appdata.saveData(false);
        }
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> uninstallScript(ComicSource source) => _mutate(() async {
    await File(source.filePath).deleteIfExists();
    remove(source.key);
    JsEngine().runCode(
      'delete ComicSource.sources[${jsonEncode(source.key)}];',
    );
    await SourceRepositories.instance.setOrigin(source.key, null);
  });

  void add(ComicSource source) {
    _sources.add(source);
    notifyListeners();
  }

  void remove(String key) {
    _sources.removeWhere((element) => element.key == key);
    notifyListeners();
  }

  void _registerSourcePages(ComicSource source) {
    var explorePages = appdata.settings['explore_pages'] ?? <String>[];
    var categoryPages = appdata.settings['categories'] ?? <String>[];
    var networkFavorites = appdata.settings['favorites'] ?? <String>[];
    final searchPages =
        appdata.settings['searchSources'] ??
        _sources
            .where((item) => item.searchPageData != null)
            .map((item) => item.key)
            .toList();

    if (source.explorePages.isNotEmpty) {
      for (var page in source.explorePages) {
        if (!explorePages.contains(page.title)) {
          explorePages.add(page.title);
        }
      }
    }
    if (source.categoryData != null &&
        !categoryPages.contains(source.categoryData!.key)) {
      categoryPages.add(source.categoryData!.key);
    }
    if (source.favoriteData != null &&
        !networkFavorites.contains(source.favoriteData!.key)) {
      networkFavorites.add(source.favoriteData!.key);
    }
    if (source.searchPageData != null && !searchPages.contains(source.key)) {
      searchPages.add(source.key);
    }

    appdata.settings['explore_pages'] = explorePages.toSet().toList();
    appdata.settings['categories'] = categoryPages.toSet().toList();
    appdata.settings['favorites'] = networkFavorites.toSet().toList();
    appdata.settings['searchSources'] = searchPages.toSet().toList();
  }

  bool get isEmpty => _sources.isEmpty;

  Map<String, dynamic> _getThumbnailLoadingConfig(
    String sourceKey,
    String url,
  ) {
    final comicSource = find(sourceKey);
    return comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
  }

  Future<String?> _getThumbnailCover(String sourceKey, String cid) async {
    final comicSource = find(sourceKey);
    if (comicSource?.loadComicInfo == null) {
      return null;
    }
    final comicInfo = await comicSource!.loadComicInfo!(cid);
    return comicInfo.data.cover;
  }

  Future<Map<String, dynamic>> _getComicImageLoadingConfig(
    String sourceKey,
    String imageKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) async {
    final comicSource = find(sourceKey);
    return await comicSource?.getImageLoadingConfig?.call(
          imageKey,
          cid,
          eid,
          target: target,
        ) ??
        {};
  }

  /// Key is the source key, value is the version.
  final _availableUpdates = <String, String>{};

  void updateAvailableUpdates(Map<String, String> updates) {
    _availableUpdates.clear();
    _availableUpdates.addAll(updates);
    notifyListeners();
  }

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  void clearSourceUpdate(String key) {
    _availableUpdates.remove(key);
    notifyListeners();
  }

  void notifyStateChange() {
    notifyListeners();
  }
}
