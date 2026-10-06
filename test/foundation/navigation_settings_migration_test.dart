import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';

void main() {
  late Directory fallbackDataDir;

  setUpAll(() {
    fallbackDataDir = Directory.systemTemp.createTempSync(
      'venera-nav-settings-fallback-',
    );
    App.dataPath = fallbackDataDir.path;
  });

  tearDownAll(() {
    if (fallbackDataDir.existsSync()) {
      fallbackDataDir.deleteSync(recursive: true);
    }
  });

  group('StartupPage identifier resolution and normalization', () {
    test(
      'StartupPage.fromId resolves stable IDs only and falls back to home',
      () {
        final stableExpectations = [
          ('home', StartupPage.home),
          ('library', StartupPage.library),
          ('library.favorites', StartupPage.favorites),
          ('discover.browse', StartupPage.browse),
          ('discover.categories', StartupPage.categories),
        ];

        for (final (id, expected) in stableExpectations) {
          expect(StartupPage.fromId(id), expected);
        }

        for (final invalid in ['unknown', '', 0, 1, 1.0, null, true]) {
          expect(StartupPage.fromId(invalid), StartupPage.home);
        }
      },
    );

    test(
      'normalizeStartupPage handles legacy integral boundaries, stable IDs, and fallbacks',
      () {
        // Use record pairs instead of a Map literal to preserve distinct int vs double entries (1 vs 1.0)
        final testCases = <(Object?, String)>[
          (0, 'home'),
          (1, 'library.favorites'),
          (2, 'discover.browse'),
          (3, 'discover.categories'),
          ('0', 'home'),
          ('1', 'library.favorites'),
          ('2', 'discover.browse'),
          ('3', 'discover.categories'),
          ('home', 'home'),
          ('library', 'library'),
          ('library.favorites', 'library.favorites'),
          ('discover.browse', 'discover.browse'),
          ('discover.categories', 'discover.categories'),
          (-1, 'home'),
          (4, 'home'),
          ('-1', 'home'),
          ('4', 'home'),
          ('explore', 'home'),
          ('', 'home'),
          (null, 'home'),
          (false, 'home'),
          // Dart == treats 1.0 == 1, but numeric migration is strictly integral 0-3
          (1.0, 'home'),
          (0.0, 'home'),
          (2.0, 'home'),
        ];

        for (final (input, expected) in testCases) {
          expect(
            normalizeStartupPage(input),
            expected,
            reason: 'Testing input: $input (${input.runtimeType})',
          );
        }
      },
    );

    test(
      'normalizeStartupPage is idempotent across canonical and legacy inputs',
      () {
        const sampleInputs = [
          0,
          1,
          2,
          3,
          '0',
          '1',
          '2',
          '3',
          'library',
          'library.favorites',
          'discover.browse',
          'discover.categories',
          'invalid',
          1.0,
          null,
        ];

        for (final input in sampleInputs) {
          final firstPass = normalizeStartupPage(input);
          final secondPass = normalizeStartupPage(firstPass);
          expect(secondPass, firstPass);
        }
      },
    );
  });

  group('Appdata Settings in-memory normalization and replacement', () {
    late Map<String, dynamic> cleanSettingsSnapshot;

    setUp(() {
      cleanSettingsSnapshot =
          jsonDecode(jsonEncode(appdata.toJson()['settings']))
              as Map<String, dynamic>;
    });

    tearDown(() {
      appdata.settings.replaceAll(cleanSettingsSnapshot);
    });

    test(
      'settings operator []= normalizes legacy values and invalid fallbacks',
      () {
        appdata.settings['initialPage'] = 1;
        expect(appdata.settings['initialPage'], 'library.favorites');

        appdata.settings['initialPage'] = '2';
        expect(appdata.settings['initialPage'], 'discover.browse');

        appdata.settings['initialPage'] = 'library';
        expect(appdata.settings['initialPage'], 'library');

        appdata.settings['initialPage'] = 1.0;
        expect(appdata.settings['initialPage'], 'home');

        appdata.settings['initialPage'] = 'corrupt-entry';
        expect(appdata.settings['initialPage'], 'home');
      },
    );

    test(
      'replaceAll normalizes initialPage while preserving all unrelated settings',
      () {
        final customSettings = Map<String, dynamic>.from(cleanSettingsSnapshot)
          ..['initialPage'] = 3
          ..['downloadThreads'] = 8
          ..['proxy'] = 'http://127.0.0.1:1080';

        appdata.settings.replaceAll(customSettings);

        expect(appdata.settings['initialPage'], 'discover.categories');
        expect(appdata.settings['downloadThreads'], 8);
        expect(appdata.settings['proxy'], 'http://127.0.0.1:1080');
        // Unrelated business settings preserved
        expect(
          appdata.settings['disableSyncFields'],
          cleanSettingsSnapshot['disableSyncFields'],
        );
      },
    );

    test('replaceAll defaults initialPage to home when omitted', () {
      final customSettings = Map<String, dynamic>.from(cleanSettingsSnapshot)
        ..remove('initialPage');

      appdata.settings.replaceAll(customSettings);

      expect(appdata.settings['initialPage'], 'home');
      expect(
        appdata.settings['downloadThreads'],
        cleanSettingsSnapshot['downloadThreads'],
      );
    });
  });

  group('Appdata disk load and sync migration', () {
    late Directory tempDir;
    late Map<String, dynamic> cleanSettingsSnapshot;
    late List<String> cleanSearchHistorySnapshot;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera-nav-disk-test-');
      App.dataPath = tempDir.path;
      cleanSettingsSnapshot =
          jsonDecode(jsonEncode(appdata.toJson()['settings']))
              as Map<String, dynamic>;
      cleanSearchHistorySnapshot = List<String>.from(appdata.searchHistory);
    });

    tearDown(() async {
      // 1. Drain pending queued disk writes before redirecting path
      await appdata.saveData(false);
      // 2. Restore in-memory settings and search history
      appdata.settings.replaceAll(cleanSettingsSnapshot);
      appdata.searchHistory = List<String>.from(cleanSearchHistorySnapshot);
      // 3. Reset App.dataPath to fallback before deleting tempDir
      App.dataPath = fallbackDataDir.path;
      // 4. Safely delete temporary directory
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'loads legacy int initialPage from disk, normalizes, and saves canonical ID',
      () async {
        final appDataFile = File(p.join(tempDir.path, 'appdata.json'));
        appDataFile.writeAsStringSync(
          jsonEncode({
            'settings': {
              ...cleanSettingsSnapshot,
              'initialPage': 1,
              'proxy': 'http://127.0.0.1:8888',
              'downloadThreads': 6,
            },
            'searchHistory': ['legacy-search'],
          }),
        );

        await appdata.loadDataForTesting(tempDir.path);

        expect(appdata.settings['initialPage'], 'library.favorites');
        expect(appdata.settings['proxy'], 'http://127.0.0.1:8888');
        expect(appdata.settings['downloadThreads'], 6);
        expect(appdata.searchHistory, ['legacy-search']);

        // Next save writes the canonical string ID
        await appdata.saveData(false);

        final persistedJson =
            jsonDecode(appDataFile.readAsStringSync()) as Map<String, dynamic>;
        final persistedSettings =
            persistedJson['settings'] as Map<String, dynamic>;
        expect(persistedSettings['initialPage'], 'library.favorites');
        expect(persistedSettings['proxy'], 'http://127.0.0.1:8888');
        expect(persistedSettings['downloadThreads'], 6);
      },
    );

    test(
      'loads legacy string initialPage "3" and normalizes to discover.categories',
      () async {
        final appDataFile = File(p.join(tempDir.path, 'appdata.json'));
        appDataFile.writeAsStringSync(
          jsonEncode({
            'settings': {...cleanSettingsSnapshot, 'initialPage': '3'},
            'searchHistory': [],
          }),
        );

        await appdata.loadDataForTesting(tempDir.path);

        expect(appdata.settings['initialPage'], 'discover.categories');
      },
    );

    test(
      'loads invalid initialPage and falls back to home without losing settings',
      () async {
        final appDataFile = File(p.join(tempDir.path, 'appdata.json'));
        appDataFile.writeAsStringSync(
          jsonEncode({
            'settings': {
              ...cleanSettingsSnapshot,
              'initialPage': 'corrupt_page_value',
              'proxy': 'http://127.0.0.1:9999',
            },
            'searchHistory': [],
          }),
        );

        await appdata.loadDataForTesting(tempDir.path);

        expect(appdata.settings['initialPage'], 'home');
        expect(appdata.settings['proxy'], 'http://127.0.0.1:9999');
      },
    );

    test(
      'syncData normalizes incoming legacy initialPage and persists canonical ID',
      () async {
        final appDataFile = File(p.join(tempDir.path, 'appdata.json'));
        final syncDataFile = File(p.join(tempDir.path, 'syncdata.json'));

        // Save baseline so target files exist in tempDir
        await appdata.saveData(false);

        await appdata.syncData({
          'settings': {'initialPage': 2, 'downloadThreads': 4},
          'searchHistory': ['synced-term'],
        });

        expect(appdata.settings['initialPage'], 'discover.browse');
        expect(appdata.settings['downloadThreads'], 4);
        expect(appdata.searchHistory, ['synced-term']);

        final savedAppData =
            jsonDecode(appDataFile.readAsStringSync()) as Map<String, dynamic>;
        final savedSyncData =
            jsonDecode(syncDataFile.readAsStringSync()) as Map<String, dynamic>;

        expect(savedAppData['settings']['initialPage'], 'discover.browse');
        expect(savedSyncData['settings']['initialPage'], 'discover.browse');
      },
    );
  });
}
