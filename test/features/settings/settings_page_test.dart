import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/appdata.dart';

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
    // These routes do not save on disposal, and the credential switch changes
    // only dialog state. There are no queued writes or cache scans to drain;
    // a cleanup-only save would introduce unnecessary asynchronous file I/O.
    final root = testRoot;
    testRoot = null;
    if (root != null && await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  testWidgets('comic library settings expose credential sync opt-in', (
    tester,
  ) async {
    _setupTestView(tester, const Size(700, 1400));
    appdata.settings['webdavComicLibrarySyncEnabled'] = false;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.8)),
          child: child!,
        ),
        home: const SettingsPage(),
      ),
    );
    await tester.tap(find.text('Sources and Services'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('WebDAV Comic Library'));
    await tester.tap(find.text('WebDAV Comic Library'));
    await tester.pumpAndSettle();

    final switchFinder = find.byKey(
      const Key('webdav-comic-library-config-sync-switch'),
    );
    expect(switchFinder, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
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
    'wide layout handles nested route push, system pop, left back, and destination change',
    (tester) async {
      _setupTestView(tester, const Size(1000, 800));

      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
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
}
