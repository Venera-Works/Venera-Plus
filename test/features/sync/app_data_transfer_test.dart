import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/js_engine.dart';

const bool _ciRequireQuickJs = bool.fromEnvironment(
  'CI_REQUIRE_QUICKJS',
  defaultValue: false,
);
void main() {
  late Directory root;
  late String previousDataPath;
  late String previousCachePath;
  late Directory fallbackRoot;
  late Map<String, dynamic> previousSettings;
  late Map<String, dynamic> previousImplicit;
  late List<String> previousSearchHistory;
  late LocalFavoritesManager? previousFavorites;
  var initialDataPath = Directory.systemTemp.path;
  var initialCachePath = Directory.systemTemp.path;
  var nativeAvailable = false;
  Object? nativeLoadError;

  setUpAll(() {
    try {
      if (Platform.isWindows) {
        final build = Directory(
          'build/windows/x64/runner/Release',
        ).absolute.path;
        if (File('$build/flutter_windows.dll').existsSync()) {
          DynamicLibrary.open('$build/flutter_windows.dll');
          DynamicLibrary.open('$build/flutter_qjs_plugin.dll');
        }
      }
      DynamicLibrary.open(
        Platform.isWindows
            ? 'flutter_qjs_plugin.dll'
            : Platform.isLinux
            ? 'libflutter_qjs_plugin.so'
            : 'flutter_qjs.framework/flutter_qjs',
      );
      nativeAvailable = true;
    } catch (e) {
      nativeAvailable = false;
      nativeLoadError = e;
    }
    final initJs = File('assets/init.js');
    if (initJs.existsSync()) {
      JsEngine.cacheJsInit(initJs.readAsBytesSync());
    }
    try {
      initialDataPath = App.dataPath;
    } catch (_) {}
    try {
      initialCachePath = App.cachePath;
    } catch (_) {}
    fallbackRoot = Directory.systemTemp.createTempSync(
      'venera-app-data-transfer-fallback-',
    );
    App.dataPath = (Directory('${fallbackRoot.path}/data')..createSync()).path;
    App.cachePath = (Directory(
      '${fallbackRoot.path}/cache',
    )..createSync()).path;
  });

  tearDownAll(() {
    App.dataPath = initialDataPath;
    App.cachePath = initialCachePath;
    if (fallbackRoot.existsSync()) fallbackRoot.deleteSync(recursive: true);
  });

  setUp(() async {
    previousSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
    previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    previousSearchHistory = List.of(appdata.searchHistory);
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    root = Directory.systemTemp.createTempSync('venera-app-data-transfer-');
    final dataDir = Directory('${root.path}/data')..createSync();
    final cacheDir = Directory('${root.path}/cache')..createSync();
    App.dataPath = dataDir.path;
    App.cachePath = cacheDir.path;
    previousFavorites = LocalFavoritesManager.cache;
    LocalFavoritesManager.cache = null;
    await LocalFavoritesManager().init();
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['cacheSize'] = 2048;
    registerAppDataSettingsChangedHandler(null);
    configureAppDataArchiveExtractorForTesting((archive, destination) async {
      await archive.copy('${destination.path}/appdata.json');
    });
  });

  tearDown(() async {
    configureAppDataArchiveExtractorForTesting(null);
    registerAppDataSettingsChangedHandler(null);
    final favorites = LocalFavoritesManager.cache;
    if (favorites != null) {
      await favorites.waitForPendingReads();
      favorites.close();
    }
    LocalFavoritesManager.cache = previousFavorites;
    await appdata.writeImplicitData();
    appdata.settings.replaceAll(previousSettings);
    appdata.implicitData
      ..clear()
      ..addAll(previousImplicit);
    appdata.searchHistory = previousSearchHistory;
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'notifies settings change only after imported settings are persisted',
    () async {
      final archive = _createArchive(root, {
        'settings': {'cacheSize': 1024},
        'searchHistory': <String>[],
      });
      var callbackCount = 0;
      registerAppDataSettingsChangedHandler(() {
        callbackCount++;
        final persisted =
            jsonDecode(File('${App.dataPath}/appdata.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(persisted['settings']['cacheSize'], 1024);
      });

      await importAppData(archive);

      expect(callbackCount, 1);
      expect(appdata.settings['cacheSize'], 1024);
    },
  );

  test(
    'does not notify settings change when imported appdata is invalid',
    () async {
      final archive = _createArchive(root, {
        'settings': 'invalid',
        'searchHistory': <String>[],
      });
      var callbackCount = 0;
      registerAppDataSettingsChangedHandler(() {
        callbackCount++;
      });

      await expectLater(importAppData(archive), throwsFormatException);

      expect(callbackCount, 0);
    },
  );

  test(
    'staged invalid database rolls back files and reading settings',
    () async {
      const folder = 'preserved-reading-folder';
      final manager = LocalFavoritesManager();
      manager.createFolder(folder);
      appdata.settings['readingFolder'] = folder;
      final original = FavoriteItem(
        id: 'preserved-item',
        name: 'Preserved Favorite',
        coverPath: 'preserved-cover.jpg',
        author: 'Original Author',
        type: ComicType.local,
        tags: const ['original'],
      );
      manager.addComic(folder, original);
      final previousBinding = appdata.settings['readingFolder'];
      final folders = manager.folderNames.toList();
      configureAppDataArchiveExtractorForTesting((archive, destination) async {
        File(
          '${destination.path}/local_favorite.db',
        ).writeAsStringSync('not sqlite');
        File('${destination.path}/appdata.json').writeAsStringSync(
          jsonEncode({
            'settings': {'cacheSize': 512, 'readingFolder': 'remote'},
          }),
        );
      });
      final archive = _createArchive(root, {});
      await expectLater(importAppData(archive), throwsA(anything));
      final restored = LocalFavoritesManager();
      expect(appdata.settings['cacheSize'], 2048);
      expect(appdata.settings['readingFolder'], previousBinding);
      expect(restored.readingFolder, folder);
      expect(restored.folderNames, folders);
      expect(restored.comicExists(folder, original.id, original.type), isTrue);
      expect(
        restored.getComic(folder, original.id, original.type).name,
        original.name,
      );
    },
  );

  test(
    'archive restore rejects unsafe comic source scripts before business commit and leaves live files intact',
    () async {
      if (_ciRequireQuickJs && !nativeAvailable) {
        fail(
          'CI_REQUIRE_QUICKJS=true requires QuickJS native library, but it failed to load: $nativeLoadError',
        );
      }
      var beforeCommitCalled = false;
      configureAppDataArchiveExtractorForTesting((archive, destination) async {
        final sourceDir = Directory('${destination.path}/comic_source')
          ..createSync();
        File('${sourceDir.path}/unsafe.js').writeAsStringSync('''
class UnsafeSource extends ComicSource {
  key = "unsafe_key";
  constructor() {
    super();
    sendMessage({method: "http", url: "https://evil.test"});
  }
}
''');
        File('${destination.path}/appdata.json').writeAsStringSync(
          jsonEncode({
            'settings': {'cacheSize': 512},
          }),
        );
      });

      final archive = _createArchive(root, {});
      await expectLater(
        importAppData(archive, beforeCommit: () => beforeCommitCalled = true),
        throwsA(isA<FormatException>()),
      );

      expect(beforeCommitCalled, isFalse);
      expect(appdata.settings['cacheSize'], 2048);
      expect(Directory('${App.dataPath}/comic_source').existsSync(), isFalse);
    },
    skip: nativeAvailable
        ? false
        : (_ciRequireQuickJs
              ? false
              : 'QuickJS native library unavailable; run with platform build DLLs on PATH.'),
  );

  test(
    'archive restore rejects duplicate comic source identities across archive files',
    () async {
      if (_ciRequireQuickJs && !nativeAvailable) {
        fail(
          'CI_REQUIRE_QUICKJS=true requires QuickJS native library, but it failed to load: $nativeLoadError',
        );
      }
      var beforeCommitCalled = false;
      configureAppDataArchiveExtractorForTesting((archive, destination) async {
        final sourceDir = Directory('${destination.path}/comic_source')
          ..createSync();
        File('${sourceDir.path}/first.js').writeAsStringSync('''
class DupA extends ComicSource {
  key = "same_key";
}
''');
        File('${sourceDir.path}/second.js').writeAsStringSync('''
class DupB extends ComicSource {
  key = "same_key";
}
''');
        File('${destination.path}/appdata.json').writeAsStringSync(
          jsonEncode({
            'settings': {'cacheSize': 512},
          }),
        );
      });

      final archive = _createArchive(root, {});
      await expectLater(
        importAppData(archive, beforeCommit: () => beforeCommitCalled = true),
        throwsA(isA<FormatException>()),
      );

      expect(beforeCommitCalled, isFalse);
      expect(appdata.settings['cacheSize'], 2048);
    },
    skip: nativeAvailable
        ? false
        : (_ciRequireQuickJs
              ? false
              : 'QuickJS native library unavailable; run with platform build DLLs on PATH.'),
  );

  test('archive restore rejects malformed sidecar metadata', () async {
    var beforeCommitCalled = false;
    configureAppDataArchiveExtractorForTesting((archive, destination) async {
      final sourceDir = Directory('${destination.path}/comic_source')
        ..createSync();
      File(
        '${sourceDir.path}/.sync_source_names.json',
      ).writeAsStringSync('corrupt json {');
      File('${destination.path}/appdata.json').writeAsStringSync(
        jsonEncode({
          'settings': {'cacheSize': 512},
        }),
      );
    });

    final archive = _createArchive(root, {});
    await expectLater(
      importAppData(archive, beforeCommit: () => beforeCommitCalled = true),
      throwsA(anything),
    );

    expect(beforeCommitCalled, isFalse);
    expect(appdata.settings['cacheSize'], 2048);
  });
}

File _createArchive(Directory root, Map<String, dynamic> appData) {
  return File('${root.path}/remote.venera')
    ..writeAsStringSync(jsonEncode(appData));
}
