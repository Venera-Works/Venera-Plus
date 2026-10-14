import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/discovery/explore_page.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import '../../widget_test_io.dart';

class _LibraryPickerRpc implements OpenListRpcClient {
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    if (method == 'list') {
      final path = request['path'];
      final entries = switch (path) {
        '/' => const [
          {'name': 'A', 'path': '/A/', 'isDirectory': true},
          {'name': 'B', 'path': '/B/', 'isDirectory': true},
        ],
        '/B/' => const [
          {'name': 'C', 'path': '/B/C/', 'isDirectory': true},
        ],
        _ => const [],
      };
      return {
        'data': {'entries': entries},
      };
    }
    return const {'data': {}};
  }
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
    'comic libraries create, edit, delete and recreate without changing manual page order',
    (tester) async {
      _setupTestView(tester, const Size(1000, 1600));
      final storage = RemoteStorageAccounts.instance;
      final manager = ComicSourceManager();
      final engines = <String, WebDavLibraryEngine>{};
      storage.configureOpenList(_LibraryPickerRpc());
      configureRuntimeComicSourcesProvider(() {
        final active = <String>{};
        final sources = <ComicSource>[];
        for (final library in storage.libraries) {
          final account = storage.account(library.accountId)!;
          active.add(library.sourceKey);
          final current = engines[library.sourceKey];
          final engine = current != null && current.matches(library, account)
              ? current
              : WebDavLibraryEngine(
                  library: library,
                  store: storage.storeFor(library.accountId),
                );
          if (!identical(engine, current)) current?.cancel();
          engines[library.sourceKey] = engine;
          sources.add(engine.create());
        }
        for (final key in engines.keys.toList()) {
          if (!active.contains(key)) engines.remove(key)?.cancel();
        }
        return sources;
      });
      addTearDown(() {
        configureRuntimeComicSourcesProvider(null);
        for (final key in engines.keys) {
          manager.remove(key);
        }
        for (final engine in engines.values) {
          engine.cancel();
        }
        WebDavLibraryEngines.cancelAll();
      });
      appdata.settings[remoteStorageAccountsSetting] = [];
      appdata.settings[remoteLibrariesSetting] = [];
      appdata.settings['explore_pages'] = [
        'manual browse second',
        'manual browse first',
      ];
      await runWidgetIo(
        tester,
        () => storage.save(
          const StorageAccount(
            id: 'drive-account',
            backend: StorageBackend.openlist,
            driver: 'GoogleDrive',
            name: 'Test Drive',
            authorization: {'access_token': 'test-token'},
          ),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SourcesAndServicesSettings())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Comic Libraries'));
      await tester.pumpAndSettle();

      Future<void> selectDirectories() async {
        await tester.tap(find.text('Recognition Directories'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text('..'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('B'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('C'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
      }

      Future<void> saveDialog() async {
        final saved = Completer<void>();
        void onSaved() {
          if (!saved.isCompleted) saved.complete();
        }

        storage.addListener(onSaved);
        try {
          await tester.tap(find.text('Save'));
          await runWidgetIo(tester, () => saved.future);
        } finally {
          storage.removeListener(onSaved);
        }
        await tester.pumpAndSettle();
      }

      Future<void> addLibrary(String name) async {
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), name);
        await selectDirectories();
        await saveDialog();
      }

      Future<void> reloadSources() =>
          runWidgetIo(tester, () => manager.reload());

      List<String> orderedSourceKeys() => ExplorePage.deriveOrderedSources(
        allSources: manager.all(),
        enabledExplorePages: (appdata.settings['explore_pages'] as List)
            .whereType<String>()
            .toList(),
        enabledCategories: const [],
      ).map((source) => source.key).toList();

      await addLibrary('Remote Comics');
      expect(storage.libraries, hasLength(1));
      final original = storage.libraries.single;
      await reloadSources();
      expect(manager.find(original.sourceKey), isNotNull);
      expect(orderedSourceKeys(), contains(original.sourceKey));
      expect(original.directories, ['/A/', '/B/C/']);
      expect(original.autoRefresh, isTrue);
      expect(original.refreshIntervalMinutes, 360);
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        'manual browse first',
        'Remote Comics',
      ]);

      await tester.tap(find.text('Remote Comics'));
      await tester.pumpAndSettle();
      await saveDialog();
      await reloadSources();
      expect(
        (appdata.settings['explore_pages'] as List).where(
          (page) => page == 'Remote Comics',
        ),
        hasLength(1),
      );
      expect(
        manager.all().where((source) => source.key == original.sourceKey),
        hasLength(1),
      );

      await tester.tap(find.text('Remote Comics'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Renamed Comics');
      await tester.tap(find.text('Every 6 hours'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Every hour').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await saveDialog();
      await reloadSources();

      expect(storage.libraries, hasLength(1));
      expect(storage.libraries.single.id, original.id);
      expect(storage.libraries.single.sourceKey, original.sourceKey);
      expect(storage.libraries.single.name, 'Renamed Comics');
      expect(storage.libraries.single.directories, ['/A/', '/B/C/']);
      expect(storage.libraries.single.autoRefresh, isFalse);
      expect(storage.libraries.single.refreshIntervalMinutes, 60);
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        'manual browse first',
        'Renamed Comics',
      ]);
      expect(manager.find(original.sourceKey), isNotNull);
      expect(orderedSourceKeys(), contains(original.sourceKey));

      appdata.settings['explore_pages'] = [
        'manual browse second',
        'manual browse first',
      ];
      await tester.tap(find.text('Renamed Comics'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Hidden Comics');
      await saveDialog();
      await reloadSources();
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        'manual browse first',
      ]);
      expect(manager.find(original.sourceKey), isNotNull);
      expect(orderedSourceKeys(), isNot(contains(original.sourceKey)));

      final removed = Completer<void>();
      void onRemoved() {
        if (!removed.isCompleted) removed.complete();
      }

      storage.addListener(onRemoved);
      try {
        await tester.tap(find.byIcon(Icons.delete_outline));
        await runWidgetIo(tester, () => removed.future);
      } finally {
        storage.removeListener(onRemoved);
      }
      await tester.pumpAndSettle();
      await reloadSources();
      expect(storage.libraries, isEmpty);
      expect(manager.find(original.sourceKey), isNull);

      await addLibrary('Replacement Comics');
      expect(storage.libraries, hasLength(1));
      expect(storage.libraries.single.name, 'Replacement Comics');
      expect(storage.libraries.single.sourceKey, isNot(original.sourceKey));
      await reloadSources();
      expect(manager.find(storage.libraries.single.sourceKey), isNotNull);
      expect(orderedSourceKeys(), contains(storage.libraries.single.sourceKey));
      expect(appdata.settings['explore_pages'], [
        'manual browse second',
        'manual browse first',
        'Replacement Comics',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
