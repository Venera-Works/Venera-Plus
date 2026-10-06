import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/appdata.dart';

void _setupTestEnv(WidgetTester tester, String prefix, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final root = Directory.systemTemp.createTempSync('venera-settings-$prefix-');
  App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
  App.dataPath = (Directory('${root.path}/data')..createSync()).path;
  LocalManager().path = 'test-library';

  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    WebDavLibrarySource.resetCacheForTesting();
    CacheManager.resetForTesting();
    await appdata.saveData(false);
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });
}

void main() {
  testWidgets('comic library settings expose credential sync opt-in', (
    tester,
  ) async {
    _setupTestEnv(tester, 'credential-sync', const Size(700, 1400));
    appdata.settings['webdavComicLibrarySyncEnabled'] = false;
    addTearDown(
      () => appdata.settings['webdavComicLibrarySyncEnabled'] = false,
    );

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
      _setupTestEnv(tester, 'narrow-nav', const Size(700, 1400));

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
      _setupTestEnv(tester, 'wide-nav', const Size(1000, 800));

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
