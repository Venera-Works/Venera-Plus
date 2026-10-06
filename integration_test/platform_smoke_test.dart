import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/app_runtime/init.dart';
import 'package:venera_plus/app_shell/home_page.dart';
import 'package:venera_plus/app_shell/main_page.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/main.dart';
import 'package:venera_plus/network/cookie_jar.dart';

const bool _isCiNativeSmoke = bool.fromEnvironment('CI_NATIVE_SMOKE');

String _resolveArtifactPath() {
  const artifactDirDefine = String.fromEnvironment('SMOKE_ARTIFACT_DIR');
  if (artifactDirDefine.isNotEmpty) {
    return '$artifactDirDefine/smoke_rendered_frame.png';
  }
  if (Platform.isAndroid) {
    return '/data/data/com.github.veneraworks.veneraplus/files/smoke_rendered_frame.png';
  }
  return 'build/smoke-artifacts/smoke_rendered_frame.png';
}

void main() {
  if (!_isCiNativeSmoke) {
    throw StateError(
      'Platform smoke tests require explicit --dart-define=CI_NATIVE_SMOKE=true '
      'on a disposable CI runner.',
    );
  }

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory suiteTempDir;
  late String originalDataPath;
  late String originalCachePath;

  setUpAll(() async {
    suiteTempDir = Directory.systemTemp.createTempSync(
      'venera_platform_smoke_',
    );
    await App.init();
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    App.dataPath = (Directory(
      '${suiteTempDir.path}/suite_data',
    )..createSync(recursive: true)).path;
    App.cachePath = (Directory(
      '${suiteTempDir.path}/suite_cache',
    )..createSync(recursive: true)).path;
    await appdata.init();
  });

  tearDownAll(() {
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    if (suiteTempDir.existsSync()) {
      try {
        suiteTempDir.deleteSync(recursive: true);
      } catch (_) {
        // Best effort cleanup on Windows runner.
      }
    }
  });

  group('SQLite Native Assets and Database Runtime Verification', () {
    test(
      'native assets load sqlite3 3.53.4 and enforce transaction rollback semantics',
      () {
        final version = sqlite3.version;
        expect(version.libVersion, '3.53.4');
        expect(version.versionNumber, 3053004);

        final memDb = sqlite3.openInMemory();
        try {
          final rows = memDb.select('SELECT sqlite_version() AS ver;');
          expect(rows, isNotEmpty);
          expect(rows.first['ver'], '3.53.4');

          memDb.execute(
            'CREATE TABLE tx_test (id INTEGER PRIMARY KEY, val TEXT NOT NULL);',
          );
          memDb.execute('BEGIN TRANSACTION;');
          memDb.execute('INSERT INTO tx_test (val) VALUES (?);', ['committed']);
          memDb.execute('COMMIT;');

          memDb.execute('BEGIN TRANSACTION;');
          memDb.execute('INSERT INTO tx_test (val) VALUES (?);', [
            'rolled_back',
          ]);
          expect(
            () => memDb.execute('INSERT INTO tx_test (val) VALUES (NULL);'),
            throwsA(isA<SqliteException>()),
          );
          memDb.execute('ROLLBACK;');

          final result = memDb.select('SELECT val FROM tx_test;');
          expect(result.length, 1);
          expect(result.first['val'], 'committed');
        } finally {
          memDb.close();
        }
      },
    );

    test(
      'sqlite3 executes queries and transactions in a background Isolate',
      () async {
        final isolateResult = await Isolate.run(() {
          final db = sqlite3.openInMemory();
          try {
            db.execute('''
            CREATE TABLE isolate_smoke (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              score INTEGER NOT NULL
            );
          ''');

            db.execute('BEGIN TRANSACTION;');
            final stmt = db.prepare(
              'INSERT INTO isolate_smoke (name, score) VALUES (?, ?);',
            );
            stmt.execute(['alpha', 100]);
            stmt.execute(['beta', 200]);
            stmt.close();
            db.execute('COMMIT;');

            final rows = db.select(
              'SELECT name, score FROM isolate_smoke ORDER BY id ASC;',
            );
            return rows
                .map(
                  (r) => {
                    'name': r['name'] as String,
                    'score': r['score'] as int,
                  },
                )
                .toList();
          } finally {
            db.close();
          }
        });

        expect(isolateResult.length, 2);
        expect(isolateResult[0], {'name': 'alpha', 'score': 100});
        expect(isolateResult[1], {'name': 'beta', 'score': 200});
      },
    );

    test(
      'migrates legacy schema database, writes transactions, and persists across reopen',
      () async {
        final testDir = Directory('${suiteTempDir.path}/migration_test')
          ..createSync(recursive: true);
        final dataDir = Directory('${testDir.path}/data')
          ..createSync(recursive: true);
        final cacheDir = Directory('${testDir.path}/cache')
          ..createSync(recursive: true);

        App.dataPath = dataDir.path;
        App.cachePath = cacheDir.path;

        // Seed legacy history table (missing read_duration_ms and chapter_group columns)
        final legacyHistoryDb = sqlite3.open('${dataDir.path}/history.db');
        legacyHistoryDb.execute('''
        CREATE TABLE history (
          id TEXT PRIMARY KEY,
          title TEXT,
          subtitle TEXT,
          cover TEXT,
          time INT,
          type INT,
          ep INT,
          page INT,
          readEpisode TEXT,
          max_page INT
        );
      ''');
        legacyHistoryDb.execute(
          '''
        INSERT INTO history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          [
            'legacy-comic-1',
            'Legacy Comic Title',
            'Legacy Author',
            'legacy_cover.jpg',
            1700000000000,
            ComicType.local.value,
            1,
            7,
            '1',
            25,
          ],
        );
        legacyHistoryDb.close();

        // Seed legacy local favorites table (missing translated_tags column in folder table)
        final legacyFavDb = sqlite3.open('${dataDir.path}/local_favorite.db');
        legacyFavDb.execute('''
        CREATE TABLE folder_order (
          folder_name TEXT PRIMARY KEY,
          order_value INT
        );
      ''');
        legacyFavDb.execute('''
        CREATE TABLE folder_sync (
          folder_name TEXT PRIMARY KEY,
          source_key TEXT,
          source_folder TEXT
        );
      ''');
        legacyFavDb.execute('''
        CREATE TABLE legacy_folder (
          id TEXT,
          name TEXT,
          author TEXT,
          type INT,
          tags TEXT,
          cover_path TEXT,
          time TEXT,
          display_order INT,
          PRIMARY KEY (id, type)
        );
      ''');
        legacyFavDb.execute(
          'INSERT INTO folder_order (folder_name, order_value) VALUES (?, ?);',
          ['legacy_folder', 0],
        );
        legacyFavDb.execute(
          '''
        INSERT INTO legacy_folder (id, name, author, type, tags, cover_path, time, display_order)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        ''',
          [
            'fav-target-1',
            'Legacy Fav Comic',
            'Fav Author',
            ComicType.local.value,
            'action,adventure',
            'cover_fav.jpg',
            DateTime.now().toIso8601String(),
            0,
          ],
        );
        legacyFavDb.close();

        // Initialize managers and verify legacy migration
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        final historyManager = HistoryManager();
        final favoritesManager = LocalFavoritesManager();

        await historyManager.init();
        await favoritesManager.init();

        final migratedHistory = historyManager.find(
          'legacy-comic-1',
          ComicType.local,
        );
        expect(migratedHistory, isNotNull);
        expect(migratedHistory!.title, 'Legacy Comic Title');
        expect(migratedHistory.page, 7);
        expect(migratedHistory.readDurationMs, 0);

        expect(favoritesManager.folderNames.contains('legacy_folder'), isTrue);
        final initialFavs = favoritesManager.getFolderComics('legacy_folder');
        expect(initialFavs.length, 1);
        expect(initialFavs.first.id, 'fav-target-1');
        expect(initialFavs.first.name, 'Legacy Fav Comic');

        // Write new records via real APIs
        final newHistory = History.fromMap({
          'type': ComicType.local.value,
          'id': 'active-comic-2',
          'title': 'Active Comic Two',
          'subtitle': 'Author Two',
          'cover': 'cover2.jpg',
          'time': DateTime.now().millisecondsSinceEpoch,
          'ep': 2,
          'page': 12,
          'max_page': 40,
          'readEpisode': <String>['1', '2'],
          'read_duration_ms': 0,
        });
        await historyManager.addHistoryAsync(newHistory);
        await historyManager.addReadDuration(
          newHistory,
          const Duration(milliseconds: 45000),
        );
        await historyManager.waitForAsyncWrites();

        favoritesManager.addComic(
          'legacy_folder',
          FavoriteItem(
            id: 'fav-target-2',
            name: 'Active Fav Two',
            coverPath: 'cover2.jpg',
            author: 'Author Two',
            type: ComicType.local,
            tags: ['fantasy', 'scifi'],
          ),
        );

        // Close managers properly
        await historyManager.waitForAsyncWrites();
        historyManager.close();

        await favoritesManager.debugWaitForHashedIdsRefresh();
        favoritesManager.close();

        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;

        // Reopen managers and assert persistence across reopen
        final reopenedHistory = HistoryManager();
        final reopenedFavorites = LocalFavoritesManager();

        await reopenedHistory.init();
        await reopenedFavorites.init();

        final reloadedLegacy = reopenedHistory.find(
          'legacy-comic-1',
          ComicType.local,
        );
        expect(reloadedLegacy, isNotNull);
        expect(reloadedLegacy!.title, 'Legacy Comic Title');

        final reloadedActive = reopenedHistory.find(
          'active-comic-2',
          ComicType.local,
        );
        expect(reloadedActive, isNotNull);
        expect(reloadedActive!.title, 'Active Comic Two');
        expect(reloadedActive.ep, 2);
        expect(reloadedActive.page, 12);
        expect(reloadedActive.readDurationMs, 45000);
        expect(reloadedActive.readEpisode, containsAll(['1', '2']));

        final reloadedFavs = reopenedFavorites.getFolderComics('legacy_folder');
        expect(reloadedFavs.length, 2);
        final favIds = reloadedFavs.map((e) => e.id).toSet();
        expect(favIds, containsAll(['fav-target-1', 'fav-target-2']));

        await reopenedHistory.waitForAsyncWrites();
        reopenedHistory.close();

        await reopenedFavorites.debugWaitForHashedIdsRefresh();
        reopenedFavorites.close();

        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
      },
    );

    test(
      'app_data_transfer backup and restore critical path via real native archive and cookie jar',
      () async {
        final transferTestDir = Directory('${suiteTempDir.path}/transfer_test')
          ..createSync(recursive: true);
        final sourceDataDir = Directory('${transferTestDir.path}/source_data')
          ..createSync(recursive: true);
        final sourceCacheDir = Directory('${transferTestDir.path}/source_cache')
          ..createSync(recursive: true);

        App.dataPath = sourceDataDir.path;
        App.cachePath = sourceCacheDir.path;

        // Ensure appdata.json exists
        final appdataFile = File('${sourceDataDir.path}/appdata.json');
        appdataFile.writeAsStringSync(
          jsonEncode({
            'settings': {'cacheSize': 1024},
            'searchHistory': <String>['test-query'],
          }),
        );

        // Create real cookie jar in source data directory using real SingleInstanceCookieJar factory
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
        final cookieJar = SingleInstanceCookieJar(
          '${sourceDataDir.path}/cookie.db',
        );
        cookieJar.saveFromResponse(Uri.parse('https://example.com/api'), [
          Cookie('session_id', 'smoke_session_token_123')
            ..domain = 'example.com'
            ..path = '/'
            ..httpOnly = true,
        ]);
        cookieJar.dispose();
        SingleInstanceCookieJar.instance = null;

        Directory(
          '${sourceDataDir.path}/comic_source',
        ).createSync(recursive: true);

        // Initialize managers and populate data for export
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        final historyManager = HistoryManager();
        final favoritesManager = LocalFavoritesManager();
        await historyManager.init();
        await favoritesManager.init();

        favoritesManager.createFolder('backup_folder');
        favoritesManager.addComic(
          'backup_folder',
          FavoriteItem(
            id: 'export-comic-1',
            name: 'Exported Comic Name',
            coverPath: 'exp_cover.jpg',
            author: 'Export Author',
            type: ComicType.local,
            tags: ['tag_alpha', 'tag_beta'],
          ),
        );

        final histItem = History.fromMap({
          'type': ComicType.local.value,
          'id': 'export-history-1',
          'title': 'Exported History Title',
          'subtitle': 'History Subtitle',
          'cover': 'hist_cover.jpg',
          'time': DateTime.now().millisecondsSinceEpoch,
          'ep': 3,
          'page': 15,
          'max_page': 60,
          'readEpisode': <String>['1', '2', '3'],
          'read_duration_ms': 0,
        });
        await historyManager.addHistoryAsync(histItem);
        await historyManager.addReadDuration(
          histItem,
          const Duration(milliseconds: 32000),
        );
        await historyManager.waitForAsyncWrites();

        // Perform real export via native zip_flutter in background Isolate
        final backupArchive = await exportAppData(false);
        expect(backupArchive.existsSync(), isTrue);
        expect(backupArchive.lengthSync(), greaterThan(0));

        // Close managers before restoring
        await historyManager.waitForAsyncWrites();
        historyManager.close();

        await favoritesManager.debugWaitForHashedIdsRefresh();
        favoritesManager.close();

        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;

        // Switch to fresh isolated target directory for restore
        final targetDataDir = Directory('${transferTestDir.path}/target_data')
          ..createSync(recursive: true);
        final targetCacheDir = Directory('${transferTestDir.path}/target_cache')
          ..createSync(recursive: true);
        App.dataPath = targetDataDir.path;
        App.cachePath = targetCacheDir.path;

        // Perform real import via native zip_flutter
        await importAppData(backupArchive);

        // Verify restored physical database files
        expect(File('${targetDataDir.path}/history.db').existsSync(), isTrue);
        expect(
          File('${targetDataDir.path}/local_favorite.db').existsSync(),
          isTrue,
        );
        expect(File('${targetDataDir.path}/cookie.db').existsSync(), isTrue);

        // Verify restored history content
        final restoredHistory = HistoryManager().find(
          'export-history-1',
          ComicType.local,
        );
        expect(restoredHistory, isNotNull);
        expect(restoredHistory!.title, 'Exported History Title');
        expect(restoredHistory.ep, 3);
        expect(restoredHistory.page, 15);
        expect(restoredHistory.readDurationMs, 32000);
        expect(restoredHistory.readEpisode, containsAll(['1', '2', '3']));

        // Verify restored favorite content
        expect(
          LocalFavoritesManager().folderNames.contains('backup_folder'),
          isTrue,
        );
        final restoredFavs = LocalFavoritesManager().getFolderComics(
          'backup_folder',
        );
        expect(restoredFavs.length, 1);
        expect(restoredFavs.first.id, 'export-comic-1');
        expect(restoredFavs.first.name, 'Exported Comic Name');
        expect(restoredFavs.first.tags, containsAll(['tag_alpha', 'tag_beta']));

        // Verify restored cookie content
        final restoredCookieJar =
            SingleInstanceCookieJar.instance ??
            SingleInstanceCookieJar('${targetDataDir.path}/cookie.db');
        final cookies = restoredCookieJar.loadForRequest(
          Uri.parse('https://example.com/api'),
        );
        expect(
          cookies.any(
            (c) =>
                c.name == 'session_id' && c.value == 'smoke_session_token_123',
          ),
          isTrue,
        );
        restoredCookieJar.dispose();
        SingleInstanceCookieJar.instance = null;

        // Cleanup
        await HistoryManager().waitForAsyncWrites();
        HistoryManager().close();
        await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
        LocalFavoritesManager().close();
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
      },
    );

    testWidgets(
      'renders real MyApp UI with production init and captures screenshot artifact',
      (tester) async {
        // Revert to disposable CI runner application directory for real UI smoke
        App.dataPath = originalDataPath;
        App.cachePath = originalCachePath;

        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;

        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;

        final testFrameworkOnError = FlutterError.onError;
        try {
          try {
            // Execute production init()
            await init();
          } finally {
            // Restore Flutter test framework error handler so uncaught
            // widget/runtime exceptions are not swallowed by the production logger
            // and live test assertions can observe or fail on real failures.
            FlutterError.onError = testFrameworkOnError;
          }

          appdata.implicitData['lastCheckUpdate'] =
              DateTime.now().millisecondsSinceEpoch;
          appdata.settings['language'] = 'en-US';
          appdata.settings['checkUpdateOnStart'] = false;
          appdata.settings['authorizationRequired'] = false;
          appdata.settings['initialPage'] = 0;

          // Seed a real synthetic history comic with empty cover to verify live UI rendering
          final smokeHistory = History.fromMap({
            'type': ComicType.local.value,
            'id': 'ui-smoke-comic',
            'title': 'UI Smoke History Comic',
            'subtitle': 'Smoke Subtitle',
            'cover': '',
            'time': DateTime.now().millisecondsSinceEpoch,
            'ep': 1,
            'page': 5,
            'max_page': 20,
            'readEpisode': <String>['1'],
            'read_duration_ms': 0,
          });
          await HistoryManager().addHistoryAsync(smokeHistory);
          await HistoryManager().addReadDuration(
            smokeHistory,
            const Duration(seconds: 10),
          );
          await HistoryManager().waitForAsyncWrites();

          final repaintKey = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(key: repaintKey, child: const MyApp()),
          );

          await tester.pump(const Duration(milliseconds: 500));

          expect(tester.takeException(), isNull);
          expect(find.byType(MyApp), findsOneWidget);
          expect(find.byType(MainPage), findsOneWidget);
          expect(find.byType(HomePage), findsOneWidget);
          expect(find.byType(HistorySummary), findsOneWidget);

          // Real home page HistorySummary uses SimpleComicTile which displays
          // only the cover thumbnail without comic title. Real users navigate
          // to HistoryPage to view titles and history entries.
          final historyEntryFinder = find.descendant(
            of: find.byType(HistorySummary),
            matching: find.text('History'.tl),
          );
          expect(historyEntryFinder, findsOneWidget);

          await tester.tap(historyEntryFinder);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));

          expect(find.byType(HistoryPage), findsOneWidget);

          final boundary =
              repaintKey.currentContext?.findRenderObject()
                  as RenderRepaintBoundary?;
          expect(boundary, isNotNull);

          final image = await boundary!.toImage(pixelRatio: 1.0);
          final byteData = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          expect(byteData, isNotNull);
          final pngBytes = byteData!.buffer.asUint8List();
          expect(pngBytes.isNotEmpty, isTrue);

          final artifactPath = _resolveArtifactPath();
          final artifactFile = File(artifactPath);
          artifactFile.parent.createSync(recursive: true);
          artifactFile.writeAsBytesSync(pngBytes);
          expect(artifactFile.existsSync(), isTrue);
          expect(artifactFile.lengthSync(), greaterThan(0));

          // Verify the seeded SQLite record's title rendered on HistoryPage
          expect(find.text('UI Smoke History Comic'), findsWidgets);
          expect(tester.takeException(), isNull);
        } finally {
          // Teardown: ensure test framework error handler is restored, unmount
          // widgets to cancel active listeners before closing managers, and
          // close database managers cleanly.
          FlutterError.onError = testFrameworkOnError;

          await tester.pumpWidget(const SizedBox());
          await tester.pump();

          await HistoryManager().waitForAsyncWrites();
          HistoryManager().close();

          await LocalFavoritesManager().debugWaitForHashedIdsRefresh();
          LocalFavoritesManager().close();

          HistoryManager.cache = null;
          LocalFavoritesManager.cache = null;
          SingleInstanceCookieJar.instance?.dispose();
          SingleInstanceCookieJar.instance = null;
        }
      },
    );
  });
}
