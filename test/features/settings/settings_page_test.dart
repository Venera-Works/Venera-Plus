import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

import '../../widget_test_io.dart';

class _EmptyWebDavLibraryOps implements WebDavLibraryOps {
  @override
  Future<void> test(WebDavLibraryConfig config) async {}

  @override
  Future<List<WebDavLibraryEntry>> readDir(
    WebDavLibraryConfig config,
    String remotePath,
  ) async => const [];

  @override
  Future<WebDavTextFile> readText(
    WebDavLibraryConfig config,
    String remotePath,
  ) async => const WebDavTextFile(content: '');

  @override
  Future<WebDavWriteResult> writeText(
    WebDavLibraryConfig config,
    String remotePath,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async => const WebDavWriteResult();
}

void _setupTestView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    try {
      // Run before binding.postTest, including when a widget assertion fails.
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

void main() {
  late Directory fallbackRoot;
  Directory? testRoot;
  late String originalDataPath;
  late String originalCachePath;
  late Map<String, dynamic> settingsSnapshot;
  late Map<String, dynamic> implicitDataSnapshot;

  setUpAll(() async {
    fallbackRoot = await Directory.systemTemp.createTemp(
      'venera-settings-fallback-',
    );
    // App's paths are late at process startup, so establish suite-owned
    // fallbacks rather than pretending an uninitialized value can be restored.
    // Accessing App also initializes appdata's write queue in this real zone.
    App.dataPath = fallbackRoot.path;
    App.cachePath = fallbackRoot.path;
  });

  tearDownAll(() async {
    await fallbackRoot.delete(recursive: true);
  });

  setUp(() async {
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    settingsSnapshot =
        jsonDecode(jsonEncode(appdata.toJson()['settings']))
            as Map<String, dynamic>;
    implicitDataSnapshot = Map<String, dynamic>.from(appdata.implicitData);
    final root = await Directory.systemTemp.createTemp('venera-settings-');
    testRoot = root;
    App.cachePath = (await Directory('${root.path}/cache').create()).path;
    App.dataPath = (await Directory('${root.path}/data').create()).path;
  });

  tearDown(() async {
    try {
      try {
        WebDavLibrarySource.resetCacheForTesting();
      } finally {
        CacheManager.resetForTesting();
      }
    } finally {
      appdata.settings.replaceAll(settingsSnapshot);
      appdata.implicitData = implicitDataSnapshot;
      App.dataPath = originalDataPath;
      App.cachePath = originalCachePath;
    }
    // These routes do not save on disposal. There are no queued writes or cache
    // scans to drain; a cleanup-only save would introduce unnecessary file I/O.
    final root = testRoot;
    testRoot = null;
    if (root != null && await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  testWidgets(
    'narrow layout initial destination opens detail and back returns to settings list',
    (tester) async {
      _setupTestView(tester, const Size(700, 1400));

      await tester.pumpWidget(
        const MaterialApp(
          home: SettingsPage(initialDestination: SettingsDestination.sources),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SourcesAndServicesSettings), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.byType(SourcesAndServicesSettings), findsNothing);
      expect(find.text('Sources and Services'), findsOneWidget);
      expect(find.byType(SettingsPage), findsOneWidget);
    },
  );

  testWidgets(
    'inactive root settings releases system back to the outer route',
    (tester) async {
      _setupTestView(tester, const Size(1000, 800));
      var settingsActive = true;
      StateSetter? updateSettings;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => StatefulBuilder(
                        builder: (context, setState) {
                          updateSettings = setState;
                          return SettingsPage(
                            isRoot: true,
                            isActive: settingsActive,
                          );
                        },
                      ),
                    ),
                  );
                },
                child: const Text('Open Settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sources and Services'));
      await tester.pumpAndSettle();
      expect(find.byType(SourcesAndServicesSettings), findsOneWidget);

      updateSettings!(() {
        settingsActive = false;
      });
      await tester.pumpAndSettle();

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsNothing);
      expect(find.text('Open Settings'), findsOneWidget);
    },
  );

  testWidgets(
    'wide layout handles nested route push, system pop, left back, and destination change',
    (tester) async {
      _setupTestView(tester, const Size(1000, 800));

      await tester.pumpWidget(
        const MaterialApp(home: SettingsPage(isRoot: true)),
      );
      await tester.pumpAndSettle();

      // Initially no content selected on wide layout
      expect(find.byType(SourcesAndServicesSettings), findsNothing);

      // Select Sources and Services
      await tester.tap(find.text('Sources and Services'));
      await tester.pumpAndSettle();
      expect(find.byType(SourcesAndServicesSettings), findsOneWidget);

      // Push nested ComicSourcePage within the right pane
      await tester.tap(find.text('Manage Comic Sources'));
      await tester.pumpAndSettle();
      expect(find.byType(ComicSourcePage), findsOneWidget);

      // Tap left settings Back button explicitly: pops ComicSourcePage, leaving Sources and Services visible
      final settingsBackFinder = find.byKey(const Key('settings-back-button'));
      await tester.tap(settingsBackFinder);
      await tester.pumpAndSettle();
      expect(find.byType(ComicSourcePage), findsNothing);
      expect(find.byType(SourcesAndServicesSettings), findsOneWidget);

      // Push nested ComicSourcePage again to test system back / hardware maybePop
      await tester.tap(find.text('Manage Comic Sources'));
      await tester.pumpAndSettle();
      expect(find.byType(ComicSourcePage), findsOneWidget);

      // Trigger system pop route
      final didPop = await tester.binding.handlePopRoute();
      expect(didPop, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(ComicSourcePage), findsNothing);
      expect(find.byType(SourcesAndServicesSettings), findsOneWidget);

      // Destination switch in wide layout changes content cleanly
      await tester.tap(find.text('Network'));
      await tester.pumpAndSettle();
      expect(find.byType(SourcesAndServicesSettings), findsNothing);
      expect(find.byType(NetworkSettings), findsOneWidget);

      // Tap left Back button: deselects active section
      await tester.tap(settingsBackFinder);
      await tester.pumpAndSettle();
      expect(find.byType(NetworkSettings), findsNothing);
    },
  );
  testWidgets(
    'WebDAV library saves enable once, preserve ordering and visibility, then clear and re-enable',
    (tester) async {
      _setupTestView(tester, const Size(1000, 1600));
      final manager = ComicSourceManager();
      manager.remove(WebDavLibrarySource.sourceKey);
      final fakeOps = _EmptyWebDavLibraryOps();
      void restoreTestOpsAfterConfigurationChange() {
        WebDavLibrarySource.contentVersion.removeListener(
          restoreTestOpsAfterConfigurationChange,
        );
        WebDavLibrarySource.ops = fakeOps;
      }

      addTearDown(() {
        registerShowMessageHandler((context, message) {});
        WebDavLibrarySource.contentVersion.removeListener(
          restoreTestOpsAfterConfigurationChange,
        );
        manager.remove(WebDavLibrarySource.sourceKey);
        WebDavLibrarySource.resetCacheForTesting();
        WebDavLibrarySource.resetOps();
      });
      appdata.settings['webdavComicLibrary'] = [];
      appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
      appdata.settings['explore_pages'] = [
        'manual browse first',
        'manual browse second',
      ];
      WebDavLibrarySource.ops = fakeOps;

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const Scaffold(body: SourcesAndServicesSettings()),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> openWebDavSettings() async {
        await tester.tap(find.text('WebDAV Comic Library').first);
        await tester.pumpAndSettle();
      }

      Future<void> tapSaveAndFinish() async {
        final saveButton = find.text('Save and sync');
        await tester.ensureVisible(saveButton);
        final saved = Completer<void>();
        registerShowMessageHandler((context, message) {
          if (message == 'Saved'.tl && !saved.isCompleted) {
            saved.complete();
          }
        });
        await tester.tap(saveButton);
        await runWidgetIo(tester, () => saved.future);
        await tester.pumpAndSettle();
        await runWidgetIo(tester, () async {
          await WebDavLibrarySource.synchronize(force: true);
          await appdata.saveData(false);
        });
        await tester.pumpAndSettle();
        expect(find.text('Save and sync'), findsNothing);
        expect(tester.takeException(), isNull);
      }

      Future<void> saveNewConfiguration(String url) async {
        await openWebDavSettings();
        final fields = find.byType(TextField);
        await tester.enterText(fields.at(0), url);
        await tester.enterText(fields.at(1), 'user');
        await tester.enterText(fields.at(2), 'pass');
        WebDavLibrarySource.ops = fakeOps;
        WebDavLibrarySource.contentVersion.addListener(
          restoreTestOpsAfterConfigurationChange,
        );
        await tapSaveAndFinish();
      }

      Future<void> saveCurrentConfiguration() async {
        await openWebDavSettings();
        await tapSaveAndFinish();
      }

      await saveNewConfiguration('https://example.com/dav');
      expect(manager.find(WebDavLibrarySource.sourceKey), isNotNull);
      expect(appdata.settings['explore_pages'], [
        'manual browse first',
        'manual browse second',
        WebDavLibrarySource.explorePageTitle,
      ]);

      appdata.settings['explore_pages'] = [
        'manual browse second',
        WebDavLibrarySource.explorePageTitle,
        'manual browse first',
      ];
      await saveCurrentConfiguration();
      expect(manager.find(WebDavLibrarySource.sourceKey), isNotNull);
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        WebDavLibrarySource.explorePageTitle,
        'manual browse first',
      ]);

      appdata.settings['explore_pages'] = [
        'manual browse second',
        'manual browse first',
      ];
      await saveCurrentConfiguration();
      expect(manager.find(WebDavLibrarySource.sourceKey), isNotNull);
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        'manual browse first',
      ]);

      appdata.settings['explore_pages'] = [
        'manual browse second',
        WebDavLibrarySource.explorePageTitle,
        'manual browse first',
      ];
      await openWebDavSettings();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), '');
      await tester.enterText(fields.at(1), '');
      await tester.enterText(fields.at(2), '');
      await tapSaveAndFinish();

      expect(manager.find(WebDavLibrarySource.sourceKey), isNull);
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        'manual browse first',
      ]);
      expect(appdata.settings['webdavComicLibrary'], isEmpty);

      await saveNewConfiguration('https://example.org/new');
      expect(manager.find(WebDavLibrarySource.sourceKey), isNotNull);
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        'manual browse first',
        WebDavLibrarySource.explorePageTitle,
      ]);
    },
  );
}
