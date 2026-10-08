import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

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
import 'source_files.dart';
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
    final sourceDirectory = Directory(path);
    if (!(await sourceDirectory.exists())) {
      await sourceDirectory.create();
    } else {
      await recoverInterruptedPublications(sourceDirectory);
      await for (var entity in sourceDirectory.list(followLinks: false)) {
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
      await recoverInterruptedPublications(directory);
      final files = await directory
          .list(followLinks: false)
          .where((entity) => entity is File && entity.path.endsWith('.js'))
          .toList();
      if (files.isNotEmpty) {
        configureComicSourceJsDataBridge();
        await JsEngine().ensureInit();
      }
      for (final entity in files) {
        final file = entity as File;
        final script = await file.readAsString();
        final probe = await ComicSourceParser.probeKey(script, file.path);
        final key = probe.key;
        if (!probe.isSuccess ||
            key == null ||
            loaded.any((source) => source.key == key)) {
          throw ComicSourceParseException(
            'Invalid or duplicate source identity: ${probe.failure?.name ?? "duplicate"}',
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

  static const _pageSettingKeys = [
    'explore_pages',
    'categories',
    'favorites',
    'searchSources',
  ];

  Map<String, dynamic> _snapshotPages() => _snapshotPageSettings();

  static Map<String, dynamic> _snapshotPageSettings() => {
    for (final key in _pageSettingKeys)
      key: appdata.settings[key] == null
          ? null
          : List.from(appdata.settings[key]),
  };

  void _restorePages(Map<String, dynamic> pages) {
    _applyPageSettings(pages);
  }

  static void _applyPageSettings(Map<String, dynamic> pages) {
    for (final entry in pages.entries) {
      appdata.settings[entry.key] = entry.value;
    }
  }

  Map<String, dynamic> _pagesAfterRegistration(ComicSource source) {
    final explorePages = List<dynamic>.from(
      appdata.settings['explore_pages'] ?? <String>[],
    );
    final categoryPages = List<dynamic>.from(
      appdata.settings['categories'] ?? <String>[],
    );
    final networkFavorites = List<dynamic>.from(
      appdata.settings['favorites'] ?? <String>[],
    );
    final searchValue = appdata.settings['searchSources'];
    final searchPages = searchValue == null
        ? _sources
              .where((item) => item.searchPageData != null)
              .map((item) => item.key)
              .toList()
        : List<dynamic>.from(searchValue);

    if (source.explorePages.isNotEmpty) {
      for (final page in source.explorePages) {
        if (!explorePages.contains(page.title)) explorePages.add(page.title);
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

    return {
      'explore_pages': explorePages.toSet().toList(),
      'categories': categoryPages.toSet().toList(),
      'favorites': networkFavorites.toSet().toList(),
      'searchSources': searchPages.toSet().toList(),
    };
  }

  bool _restorePagesIfUnchanged(
    Map<String, dynamic> original,
    Map<String, dynamic>? expected,
  ) {
    final current = _snapshotPages();
    if (_sameJsonValue(current, original)) return true;
    if (expected == null || !_sameJsonValue(current, expected)) return false;
    _restorePages(original);
    return true;
  }

  static bool _sameJsonValue(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_sameJsonValue(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (!_sameJsonValue(left[i], right[i])) return false;
      }
      return true;
    }
    return left == right;
  }

  Future<bool> _restoreOriginIfUnchanged(
    String key,
    SourceOrigin? original,
    SourceOrigin? expected,
    bool writeAttempted,
  ) async {
    final current = SourceRepositories.instance.originFor(key);
    if (_sameJsonValue(current?.toJson(), original?.toJson())) return true;
    if (!writeAttempted ||
        !_sameJsonValue(current?.toJson(), expected?.toJson())) {
      return false;
    }
    await SourceRepositories.instance.setOrigin(key, original);
    return _sameJsonValue(
      SourceRepositories.instance.originFor(key)?.toJson(),
      original?.toJson(),
    );
  }

  static void _verifySessionWriteTarget(
    File sessionFile, {
    required String? originalDigest,
    required Set<String> publicationWriteDigests,
    required String snapshot,
  }) {
    final currentDigest = sessionFile.existsSync()
        ? SourceFileMetadata.digest(sessionFile.readAsStringSync())
        : null;
    if (currentDigest != originalDigest &&
        (currentDigest == null ||
            !publicationWriteDigests.contains(currentDigest))) {
      throw const FileSystemException(
        'The source session changed during publication.',
      );
    }
    publicationWriteDigests.add(SourceFileMetadata.digest(snapshot));
  }

  Future<void> _restoreSessionAfterFailedInstall(
    File sessionFile, {
    required bool hadOriginalSession,
    required String? originalContent,
    required String? originalDigest,
    required String? newDigest,
    required bool writeAttempted,
  }) async {
    if (!await sessionFile.exists()) return;
    final currentDigest = SourceFileMetadata.digest(
      await sessionFile.readAsString(),
    );
    if (currentDigest == originalDigest && hadOriginalSession) return;
    if (!writeAttempted || newDigest == null || currentDigest != newDigest) {
      return;
    }
    if (!hadOriginalSession) {
      await sessionFile.delete();
      return;
    }
    final restoreDigest = originalDigest;
    if (originalContent == null ||
        restoreDigest == null ||
        restoreDigest != SourceFileMetadata.digest(originalContent)) {
      return;
    }
    final temporary = File(
      '${sessionFile.path}.${DateTime.now().microsecondsSinceEpoch}.restore',
    );
    if (await temporary.exists()) return;
    await temporary.writeAsString(originalContent, flush: true);
    if (SourceFileMetadata.digest(await temporary.readAsString()) !=
        restoreDigest) {
      throw const FileSystemException(
        'Source session restore verification failed',
      );
    }
    await _safeSameFsSwap(
      source: temporary,
      target: sessionFile,
      expectedSourceDigest: restoreDigest,
      expectedTargetDigest: newDigest,
    );
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
    final parser = ComicSourceParser();
    ComicSource? source;
    SourceOrigin? oldOrigin;
    File? sessionFile;
    String? originalSessionContent;
    String? originalSessionDigest;
    String? newSessionDigest;
    var sessionWriteExpected = false;
    Map<String, dynamic>? newPages;
    var hadOriginalSession = false;
    var sessionWriteAttempted = false;
    var originWriteAttempted = false;
    var settingsWriteStarted = false;
    try {
      fileName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9_.()-]'), '_');
      final originFilename = fileName.endsWith('.js')
          ? fileName
          : '$fileName.js';
      source = await parser.createAndParse(
        js,
        fileName,
        expectedKey: expectedKey,
        retainRollback: true,
        deferMetadata: true,
      );
      oldOrigin = SourceRepositories.instance.originFor(source.key);
      sessionFile = File(
        p.join(p.dirname(source.filePath), '${source.key}.data'),
      );
      hadOriginalSession = await sessionFile.exists();
      if (hadOriginalSession) {
        originalSessionContent = await sessionFile.readAsString();
        originalSessionDigest = SourceFileMetadata.digest(
          originalSessionContent,
        );
      }
      _sources.add(source);
      source.stageDataWrites();
      await _initializeSource(source);
      sessionWriteExpected = source.hasStagedDataWrite;
      newSessionDigest = sessionWriteExpected
          ? SourceFileMetadata.digest(jsonEncode(source.data))
          : null;
      newPages = _pagesAfterRegistration(source);
      _registerSourcePages(source);
      settingsWriteStarted = true;
      originWriteAttempted = true;
      await SourceRepositories.instance.setOrigin(source.key, origin);
      sessionWriteAttempted = true;
      if (sessionWriteExpected) {
        final publicationWriteDigests = <String>{};
        await source.commitDataWrites(
          beforeCommit: (snapshot) => _verifySessionWriteTarget(
            sessionFile!,
            originalDigest: originalSessionDigest,
            publicationWriteDigests: publicationWriteDigests,
            snapshot: snapshot,
          ),
        );
      } else {
        await source.commitDataWrites();
      }
      await SourceFileMetadata.recordValidated(
        Directory(p.dirname(source.filePath)),
        key: source.key,
        filename: p.basename(source.filePath),
        content: js,
        originFilename: originFilename,
      );
      parser.commit();
      notifyListeners();
      return source;
    } catch (error, stackTrace) {
      try {
        parser.rollback();
      } catch (_) {}
      if (source != null) {
        _sources.removeWhere((s) => s.key == source!.key);
        JsEngine().runCode(
          'delete ComicSource.sources[${jsonEncode(source.key)}];',
        );
        final sourceFile = File(source.filePath);
        try {
          if (await sourceFile.exists() &&
              SourceFileMetadata.digest(await sourceFile.readAsString()) ==
                  SourceFileMetadata.digest(js)) {
            await sourceFile.delete();
          }
        } catch (_) {}
        if (sessionFile != null) {
          try {
            await _restoreSessionAfterFailedInstall(
              sessionFile,
              hadOriginalSession: hadOriginalSession,
              originalContent: originalSessionContent,
              originalDigest: originalSessionDigest,
              newDigest: newSessionDigest,
              writeAttempted: sessionWriteAttempted,
            );
          } catch (_) {}
        }
        var pagesRestored = false;
        try {
          pagesRestored = _restorePagesIfUnchanged(oldPages, newPages);
        } catch (_) {}
        var originRestored = false;
        try {
          originRestored = await _restoreOriginIfUnchanged(
            source.key,
            oldOrigin,
            origin,
            originWriteAttempted,
          );
        } catch (_) {}
        if (settingsWriteStarted && pagesRestored && originRestored) {
          try {
            await appdata.saveData(false);
          } catch (_) {}
        }
      }
      notifyListeners();
      Error.throwWithStackTrace(error, stackTrace);
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

    final probe = await ComicSourceParser.probeKey(js);
    if (!probe.isSuccess || probe.key != source.key) {
      throw ComicSourceParseException(
        'Failed to probe replacement comic source: ${probe.failure?.name ?? "key mismatch"}',
      );
    }

    final parser = ComicSourceParser();
    final activeFile = File(source.filePath);
    final sourceDir = Directory(p.dirname(source.filePath));
    final journal = SourcePublicationJournal(sourceDir);
    if (await journal.read() != null) {
      throw const FileSystemException(
        'An earlier source publication still needs recovery.',
      );
    }

    await source.waitForDataWrites();
    final originalScript = await activeFile.readAsString();
    final originalDigest = SourceFileMetadata.digest(originalScript);
    final newDigest = SourceFileMetadata.digest(js);
    final oldPages = _snapshotPages();
    final oldOrigin = SourceRepositories.instance.originFor(source.key);
    final sessionFile = File(p.join(sourceDir.path, '${source.key}.data'));
    final hadOriginalSession = await sessionFile.exists();
    final originalSessionContent = hadOriginalSession
        ? await sessionFile.readAsString()
        : null;
    final originalSessionDigest = originalSessionContent == null
        ? null
        : SourceFileMetadata.digest(originalSessionContent);
    final publicationId = SourceFileMetadata.digest(
      '${source.key}_${DateTime.now().microsecondsSinceEpoch}_$newDigest',
    );
    final stageFile = File('${activeFile.path}.$publicationId.stage');
    final backupFile = File('${activeFile.path}.$publicationId.bak');
    final sessionBackupFile = hadOriginalSession
        ? File('${sessionFile.path}.$publicationId.bak')
        : null;
    var journalRecorded = false;
    String? newSessionDigest;
    var sessionWriteExpected = false;
    Map<String, dynamic>? newPages;
    var settingsWriteStarted = false;
    var originWriteAttempted = false;
    var sessionWriteAttempted = false;

    SourcePublicationJournalEntry journalEntry({
      required String? newSessionDigest,
      required bool sessionWriteExpected,
      required Map<String, dynamic>? newPages,
      required SourcePublicationStage stage,
    }) => SourcePublicationJournalEntry(
      publicationId: publicationId,
      key: source.key,
      targetPath: activeFile.path,
      stagePath: stageFile.path,
      backupPath: backupFile.path,
      sessionBackupPath: sessionBackupFile?.path,
      originalDigest: originalDigest,
      newDigest: newDigest,
      originalSessionDigest: originalSessionDigest,
      newSessionDigest: newSessionDigest,
      sessionWriteExpected: sessionWriteExpected,
      hadOriginalSession: hadOriginalSession,
      originalPages: oldPages,
      newPages: newPages,
      hadOriginalOrigin: oldOrigin != null,
      originalOrigin: oldOrigin?.toJson(),
      originChanges: origin != null,
      newOrigin: origin?.toJson(),
      stage: stage,
      timestamp: DateTime.now(),
    );

    try {
      if (await stageFile.exists() ||
          await backupFile.exists() ||
          (sessionBackupFile != null && await sessionBackupFile.exists())) {
        throw const FileSystemException(
          'A source publication artifact already exists.',
        );
      }

      await stageFile.writeAsString(js, flush: true);
      final stagedContent = await stageFile.readAsString();
      if (SourceFileMetadata.digest(stagedContent) != newDigest) {
        throw const FileSystemException('Staged script verification failed');
      }
      final stagedProbe = await ComicSourceParser.probeKey(
        stagedContent,
        stageFile.path,
      );
      if (!stagedProbe.isSuccess || stagedProbe.key != source.key) {
        throw const FileSystemException(
          'Staged script identity verification failed',
        );
      }

      await backupFile.writeAsString(originalScript, flush: true);
      if (SourceFileMetadata.digest(await backupFile.readAsString()) !=
          originalDigest) {
        throw const FileSystemException('Backup verification failed');
      }
      if (sessionBackupFile != null) {
        await sessionBackupFile.writeAsString(
          originalSessionContent!,
          flush: true,
        );
        if (SourceFileMetadata.digest(await sessionBackupFile.readAsString()) !=
            originalSessionDigest) {
          throw const FileSystemException('Session backup verification failed');
        }
      }

      await journal.record(
        journalEntry(
          newSessionDigest: null,
          sessionWriteExpected: false,
          newPages: null,
          stage: SourcePublicationStage.staged,
        ),
      );
      journalRecorded = true;

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

      sessionWriteExpected = replacement.hasStagedDataWrite;
      newSessionDigest = sessionWriteExpected
          ? SourceFileMetadata.digest(jsonEncode(replacement.data))
          : null;
      newPages = _pagesAfterRegistration(replacement);
      await journal.record(
        journalEntry(
          newSessionDigest: newSessionDigest,
          sessionWriteExpected: sessionWriteExpected,
          newPages: newPages,
          stage: SourcePublicationStage.staged,
        ),
      );

      if (SourceFileMetadata.digest(await activeFile.readAsString()) !=
          originalDigest) {
        throw const FileSystemException(
          'The installed source changed during publication.',
        );
      }
      await _safeSameFsSwap(
        source: stageFile,
        target: activeFile,
        expectedSourceDigest: newDigest,
        expectedTargetDigest: originalDigest,
      );
      if (SourceFileMetadata.digest(await activeFile.readAsString()) !=
          newDigest) {
        throw const FileSystemException(
          'Published script verification failed.',
        );
      }

      await journal.updateStage(SourcePublicationStage.renamed);
      _registerSourcePages(replacement);
      validate();
      settingsWriteStarted = true;
      if (origin != null) {
        originWriteAttempted = true;
        await SourceRepositories.instance.setOrigin(source.key, origin);
      } else {
        await appdata.saveData();
      }

      if (sessionWriteExpected) {
        final sessionExists = await sessionFile.exists();
        if (sessionExists != hadOriginalSession ||
            (sessionExists &&
                SourceFileMetadata.digest(await sessionFile.readAsString()) !=
                    originalSessionDigest)) {
          throw const FileSystemException(
            'The source session changed during publication.',
          );
        }
      }
      sessionWriteAttempted = true;
      if (sessionWriteExpected) {
        final publicationWriteDigests = <String>{};
        await replacement.commitDataWrites(
          beforeCommit: (snapshot) => _verifySessionWriteTarget(
            sessionFile,
            originalDigest: originalSessionDigest,
            publicationWriteDigests: publicationWriteDigests,
            snapshot: snapshot,
          ),
        );
      } else {
        await replacement.commitDataWrites();
      }
      await SourceFileMetadata.recordValidated(
        sourceDir,
        key: source.key,
        filename: p.basename(source.filePath),
        content: js,
        publicationId: publicationId,
      );

      parser.commit();
      clearSourceUpdate(source.key);
      await _cleanupPublicationArtifacts(
        stageFile: stageFile,
        backupFile: backupFile,
        sessionBackupFile: sessionBackupFile,
        newDigest: newDigest,
        originalDigest: originalDigest,
        originalSessionDigest: originalSessionDigest,
      );
      await journal.clear();
      notifyListeners();
    } catch (error, stackTrace) {
      _sources[index] = source;

      var rollbackComplete = true;
      try {
        parser.rollback();
      } catch (_) {
        rollbackComplete = false;
      }

      try {
        rollbackComplete &= await _recoverPublicationScript(
          targetFile: activeFile,
          backupFile: backupFile,
          key: source.key,
          originalDigest: originalDigest,
          newDigest: newDigest,
        );
      } catch (_) {
        rollbackComplete = false;
      }
      try {
        final sessionRestored = await _recoverPublicationSession(
          SourcePublicationJournalEntry(
            publicationId: publicationId,
            key: source.key,
            targetPath: activeFile.path,
            stagePath: stageFile.path,
            backupPath: backupFile.path,
            sessionBackupPath: sessionBackupFile?.path,
            originalDigest: originalDigest,
            newDigest: newDigest,
            originalSessionDigest: originalSessionDigest,
            newSessionDigest: newSessionDigest,
            sessionWriteExpected: sessionWriteExpected,
            hadOriginalSession: hadOriginalSession,
            originalPages: oldPages,
            newPages: newPages,
            hadOriginalOrigin: oldOrigin != null,
            originalOrigin: oldOrigin?.toJson(),
            originChanges: origin != null,
            newOrigin: origin?.toJson(),
            stage: SourcePublicationStage.staged,
            timestamp: DateTime.now(),
          ),
          sessionFile: sessionFile,
          sessionBackupFile: sessionBackupFile,
          writeAttempted: sessionWriteAttempted,
        );
        rollbackComplete &= sessionRestored;
      } catch (_) {
        rollbackComplete = false;
      }
      var pagesRestored = false;
      try {
        pagesRestored = _restorePagesIfUnchanged(oldPages, newPages);
        rollbackComplete &= pagesRestored;
      } catch (_) {
        rollbackComplete = false;
      }
      var originRestored = false;
      try {
        originRestored = await _restoreOriginIfUnchanged(
          source.key,
          oldOrigin,
          origin,
          originWriteAttempted,
        );
        rollbackComplete &= originRestored;
      } catch (_) {
        rollbackComplete = false;
      }
      if (settingsWriteStarted && pagesRestored && originRestored) {
        try {
          await appdata.saveData(false);
        } catch (_) {
          rollbackComplete = false;
        }
      }

      if (rollbackComplete || !journalRecorded) {
        await _cleanupPublicationArtifacts(
          stageFile: stageFile,
          backupFile: backupFile,
          sessionBackupFile: sessionBackupFile,
          newDigest: newDigest,
          originalDigest: originalDigest,
          originalSessionDigest: originalSessionDigest,
        );
        if (journalRecorded && rollbackComplete) {
          await journal.clear();
        }
      }
      notifyListeners();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Recovers any interrupted source publications or rollbacks before scanning.
  /// Uses durable journal proof to replay or roll back without overwriting manual edits.
  static Future<void> recoverInterruptedPublications(
    Directory directory,
  ) async {
    if (!await directory.exists()) return;

    final journal = SourcePublicationJournal(directory);
    final entry = await journal.read();
    if (entry == null) return;

    final targetFile = File(entry.targetPath);
    final backupFile = File(entry.backupPath);
    final stageFile = File(entry.stagePath);
    final sessionFile = File(p.join(directory.path, '${entry.key}.data'));
    final sessionBackupFile = entry.sessionBackupPath == null
        ? null
        : File(entry.sessionBackupPath!);
    final metadata = await SourceFileMetadata.read(directory);
    final hasCommitMarker =
        metadata[entry.key]?['publicationId'] == entry.publicationId;

    if (hasCommitMarker) {
      if (await targetFile.exists() &&
          SourceFileMetadata.digest(await targetFile.readAsString()) ==
              entry.newDigest) {
        await _cleanupPublicationArtifacts(
          stageFile: stageFile,
          backupFile: backupFile,
          sessionBackupFile: sessionBackupFile,
          newDigest: entry.newDigest,
          originalDigest: entry.originalDigest,
          originalSessionDigest: entry.originalSessionDigest,
        );
        await journal.clear();
      }
      return;
    }

    final scriptRestored = await _recoverPublicationScript(
      targetFile: targetFile,
      backupFile: backupFile,
      key: entry.key,
      originalDigest: entry.originalDigest,
      newDigest: entry.newDigest,
    );
    final sessionRestored = await _recoverPublicationSession(
      entry,
      sessionFile: sessionFile,
      sessionBackupFile: sessionBackupFile,
      writeAttempted: entry.sessionWriteExpected == true,
    );
    final pagesRestored = await _recoverPublicationPages(entry);
    final originRestored = await _recoverPublicationOrigin(entry);
    if (!scriptRestored ||
        !sessionRestored ||
        !pagesRestored ||
        !originRestored) {
      return;
    }

    await _cleanupPublicationArtifacts(
      stageFile: stageFile,
      backupFile: backupFile,
      sessionBackupFile: sessionBackupFile,
      newDigest: entry.newDigest,
      originalDigest: entry.originalDigest,
      originalSessionDigest: entry.originalSessionDigest,
    );
    await journal.clear();
  }

  static Future<bool> _recoverPublicationScript({
    required File targetFile,
    required File backupFile,
    required String key,
    required String? originalDigest,
    required String newDigest,
  }) async {
    if (originalDigest == null) return false;
    String? expectedTargetDigest;
    if (await targetFile.exists()) {
      final targetDigest = SourceFileMetadata.digest(
        await targetFile.readAsString(),
      );
      if (targetDigest == originalDigest) return true;
      if (targetDigest != newDigest) return false;
      expectedTargetDigest = targetDigest;
    }

    if (!await backupFile.exists()) return false;
    final backupContent = await backupFile.readAsString();
    if (SourceFileMetadata.digest(backupContent) != originalDigest) {
      return false;
    }
    final probe = await ComicSourceParser.probeKey(
      backupContent,
      backupFile.path,
    );
    if (!probe.isSuccess || probe.key != key) return false;

    try {
      await _safeSameFsSwap(
        source: backupFile,
        target: targetFile,
        expectedSourceDigest: originalDigest,
        expectedTargetDigest: expectedTargetDigest,
      );
    } catch (_) {
      return false;
    }
    if (!await targetFile.exists()) return false;
    final restoredContent = await targetFile.readAsString();
    if (SourceFileMetadata.digest(restoredContent) != originalDigest) {
      return false;
    }
    final restoredProbe = await ComicSourceParser.probeKey(
      restoredContent,
      targetFile.path,
    );
    return restoredProbe.isSuccess && restoredProbe.key == key;
  }

  static Future<bool> _recoverPublicationSession(
    SourcePublicationJournalEntry entry, {
    required File sessionFile,
    required File? sessionBackupFile,
    required bool writeAttempted,
  }) async {
    final exists = await sessionFile.exists();
    final currentDigest = exists
        ? SourceFileMetadata.digest(await sessionFile.readAsString())
        : null;
    if (entry.hadOriginalSession &&
        entry.originalSessionDigest != null &&
        currentDigest == entry.originalSessionDigest) {
      return true;
    }
    if (!entry.hadOriginalSession && !exists) return true;
    if (!writeAttempted ||
        entry.sessionWriteExpected != true ||
        entry.newSessionDigest == null ||
        currentDigest != entry.newSessionDigest) {
      return false;
    }

    if (!entry.hadOriginalSession) {
      await sessionFile.delete();
      return !await sessionFile.exists();
    }

    final originalSessionDigest = entry.originalSessionDigest;
    if (sessionBackupFile == null ||
        originalSessionDigest == null ||
        !await sessionBackupFile.exists()) {
      return false;
    }
    final originalSession = await sessionBackupFile.readAsString();
    if (SourceFileMetadata.digest(originalSession) != originalSessionDigest) {
      return false;
    }
    try {
      await _safeSameFsSwap(
        source: sessionBackupFile,
        target: sessionFile,
        expectedSourceDigest: originalSessionDigest,
        expectedTargetDigest: currentDigest,
      );
    } catch (_) {
      return false;
    }
    return await sessionFile.exists() &&
        SourceFileMetadata.digest(await sessionFile.readAsString()) ==
            entry.originalSessionDigest;
  }

  static Future<bool> _recoverPublicationPages(
    SourcePublicationJournalEntry entry,
  ) async {
    final original = entry.originalPages;
    if (original == null) {
      return entry.stage == SourcePublicationStage.staged;
    }
    final oldPages = Map<String, dynamic>.from(original);
    final current = _snapshotPageSettings();
    if (_sameJsonValue(current, oldPages)) return true;
    final newPagesValue = entry.newPages;
    if (newPagesValue == null) return false;
    final newPages = Map<String, dynamic>.from(newPagesValue);
    if (!_sameJsonValue(current, newPages)) return false;
    _applyPageSettings(oldPages);
    await appdata.saveData(false);
    return true;
  }

  static Future<bool> _recoverPublicationOrigin(
    SourcePublicationJournalEntry entry,
  ) async {
    final originChanges = entry.originChanges;
    if (originChanges == null) {
      return entry.stage == SourcePublicationStage.staged;
    }
    if (!originChanges) return true;

    final hadOriginalOrigin = entry.hadOriginalOrigin;
    if (hadOriginalOrigin == null ||
        (hadOriginalOrigin && entry.originalOrigin == null)) {
      return false;
    }
    final original = hadOriginalOrigin
        ? _sourceOriginFromRecord(entry.originalOrigin)
        : null;
    if (hadOriginalOrigin && original == null) return false;
    final current = SourceRepositories.instance.originFor(entry.key);
    if (_sameJsonValue(current?.toJson(), original?.toJson())) return true;
    final expected = _sourceOriginFromRecord(entry.newOrigin);
    if (!_sameJsonValue(current?.toJson(), expected?.toJson())) return false;
    await SourceRepositories.instance.setOrigin(entry.key, original);
    return _sameJsonValue(
      SourceRepositories.instance.originFor(entry.key)?.toJson(),
      original?.toJson(),
    );
  }

  static SourceOrigin? _sourceOriginFromRecord(Map<String, Object?>? record) {
    final kind = record?['kind'];
    if (kind is! String) return null;
    final repositoryId = record?['repositoryId'];
    final repositoryName = record?['repositoryName'];
    final url = record?['url'];
    return SourceOrigin(
      kind: kind,
      repositoryId: repositoryId is String ? repositoryId : null,
      repositoryName: repositoryName is String ? repositoryName : null,
      url: url is String ? url : null,
    );
  }

  static Future<void> _cleanupPublicationArtifacts({
    required File stageFile,
    required File backupFile,
    required File? sessionBackupFile,
    required String newDigest,
    required String? originalDigest,
    required String? originalSessionDigest,
  }) async {
    await _deleteFileIfDigestMatches(stageFile, newDigest);
    if (originalDigest != null) {
      await _deleteFileIfDigestMatches(backupFile, originalDigest);
    }
    if (sessionBackupFile != null && originalSessionDigest != null) {
      await _deleteFileIfDigestMatches(
        sessionBackupFile,
        originalSessionDigest,
      );
    }
  }

  static Future<void> _deleteFileIfDigestMatches(
    File file,
    String expectedDigest,
  ) async {
    try {
      if (await file.exists() &&
          SourceFileMetadata.digest(await file.readAsString()) ==
              expectedDigest) {
        await file.delete();
      }
    } catch (_) {
      // Unverified or locked artifacts remain available for manual recovery.
    }
  }

  /// Atomically replaces a same-directory file without a rename-to-old gap.
  static Future<void> _safeSameFsSwap({
    required File source,
    required File target,
    required String expectedSourceDigest,
    required String? expectedTargetDigest,
  }) => SourceFileMetadata.atomicReplace(
    source,
    target,
    beforeCommit: () {
      final currentSourceDigest = source.existsSync()
          ? SourceFileMetadata.digest(source.readAsStringSync())
          : null;
      final currentTargetDigest = target.existsSync()
          ? SourceFileMetadata.digest(target.readAsStringSync())
          : null;
      if (currentSourceDigest != expectedSourceDigest ||
          currentTargetDigest != expectedTargetDigest) {
        throw const FileSystemException(
          'A source publication file changed before atomic replacement.',
        );
      }
    },
  );

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
    for (final entry in _pagesAfterRegistration(source).entries) {
      appdata.settings[entry.key] = entry.value;
    }
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
