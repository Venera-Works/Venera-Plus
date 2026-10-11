import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:zip_flutter/zip_flutter.dart';

const bool _ciRequireNativeZip = bool.fromEnvironment(
  'CI_REQUIRE_NATIVE_ZIP',
  defaultValue: false,
);

String? _loadNativeZipFailure() {
  final libraryPath = Platform.isWindows
      ? 'zip_flutter.dll'
      : Platform.isLinux
      ? 'libzip_flutter.so'
      : 'zip_flutter.framework/zip_flutter';
  try {
    if (Platform.isWindows) {
      for (final buildDir in [
        'build/windows/x64/runner/Debug',
        'build/windows/x64/runner/Release',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/zip_flutter.dll').existsSync()) {
          DynamicLibrary.open('$build/zip_flutter.dll');
          break;
        }
      }
    } else if (Platform.isLinux) {
      for (final buildDir in [
        'build/linux/x64/debug/bundle/lib',
        'build/linux/x64/release/bundle/lib',
      ]) {
        final build = Directory(buildDir).absolute.path;
        if (File('$build/libzip_flutter.so').existsSync()) {
          DynamicLibrary.open('$build/libzip_flutter.so');
          break;
        }
      }
    }
    DynamicLibrary.open(libraryPath);
    return null;
  } catch (error) {
    return '$libraryPath: $error';
  }
}

final String? _nativeZipFailure = _loadNativeZipFailure();
var _nextArchiveId = 0;

Future<File> _createArchive(
  Directory root, {
  Map<String, String> textEntries = const {},
  Map<String, File> fileEntries = const {},
}) async {
  final archiveId = _nextArchiveId++;
  final inputDir = Directory(p.join(root.path, 'archive-input-$archiveId'))
    ..createSync(recursive: true);
  final archiveFile = File(p.join(root.path, 'archive-$archiveId.venera'));
  final entries = <List<String>>[];
  for (final entry in textEntries.entries) {
    final source = File(p.join(inputDir.path, entry.key));
    await source.parent.create(recursive: true);
    await source.writeAsString(entry.value);
    entries.add([entry.key, source.path]);
  }
  for (final entry in fileEntries.entries) {
    entries.add([entry.key, entry.value.path]);
  }
  final archivePath = archiveFile.path;
  await Isolate.run(() {
    final zipFile = ZipFile.open(archivePath);
    for (final entry in entries) {
      zipFile.addFile(entry[0], entry[1]);
    }
    zipFile.close();
  });
  return archiveFile;
}

Future<Directory> _extractArchive(File archive, Directory root) async {
  final extracted = Directory(
    p.join(root.path, 'extracted-${_nextArchiveId++}'),
  )..createSync(recursive: true);
  final archivePath = archive.path;
  final destinationPath = extracted.path;
  await Isolate.run(() {
    ZipFile.openAndExtract(archivePath, destinationPath);
  });
  return extracted;
}

void _addHistory(String id, String title) {
  HistoryManager().addHistory(
    History.fromMap({
      'type': ComicType.local.value,
      'id': id,
      'title': title,
      'subtitle': '',
      'cover': '',
      'time': DateTime.now().millisecondsSinceEpoch,
      'ep': 1,
      'page': 1,
      'max_page': 1,
      'readEpisode': <String>[],
      'read_duration_ms': 0,
    }),
  );
}

String? _historyTitle(String id) {
  final database = sqlite3.open(p.join(App.dataPath, 'history.db'));
  try {
    final rows = database.select(
      'SELECT title FROM history WHERE id = ? AND type = ?',
      [id, ComicType.local.value],
    );
    return rows.isEmpty ? null : rows.first['title'] as String?;
  } finally {
    database.dispose();
  }
}

void main() {
  group(
    'App data transfer with native ZIP',
    () {
      late Directory root;
      late String previousDataPath;
      late String previousCachePath;
      late Directory fallbackRoot;
      late Map<String, dynamic> previousSettings;
      late Map<String, dynamic> previousImplicit;
      late Map<String, dynamic> previousAppData;
      late HistoryManager? previousHistory;
      late LocalFavoritesManager? previousFavorites;
      late SingleInstanceCookieJar? previousCookieJar;
      var initialDataPath = Directory.systemTemp.path;
      var initialCachePath = Directory.systemTemp.path;

      setUpAll(() {
        if (_ciRequireNativeZip && _nativeZipFailure != null) {
          fail(
            'CI_REQUIRE_NATIVE_ZIP=true requires zip_flutter native library, '
            'but it failed to load: $_nativeZipFailure',
          );
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
        App.dataPath = (Directory(
          p.join(fallbackRoot.path, 'data'),
        )..createSync()).path;
        App.cachePath = (Directory(
          p.join(fallbackRoot.path, 'cache'),
        )..createSync()).path;
      });

      tearDownAll(() {
        App.dataPath = initialDataPath;
        App.cachePath = initialCachePath;
        if (fallbackRoot.existsSync()) {
          fallbackRoot.deleteSync(recursive: true);
        }
      });

      setUp(() async {
        previousSettings = Map<String, dynamic>.from(
          appdata.toJson()['settings'],
        );
        previousAppData =
            jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
        previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
        previousDataPath = App.dataPath;
        previousCachePath = App.cachePath;
        previousHistory = HistoryManager.cache;
        previousFavorites = LocalFavoritesManager.cache;
        previousCookieJar = SingleInstanceCookieJar.instance;

        root = Directory.systemTemp.createTempSync('venera-app-data-transfer-');
        final dataDir = Directory(p.join(root.path, 'data'))..createSync();
        final cacheDir = Directory(p.join(root.path, 'cache'))..createSync();
        App.dataPath = dataDir.path;
        App.cachePath = cacheDir.path;
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        SingleInstanceCookieJar.instance = null;

        await HistoryManager().init();
        await LocalFavoritesManager().init();
        SingleInstanceCookieJar.instance = SingleInstanceCookieJar(
          p.join(App.dataPath, 'cookie.db'),
        );
        Directory(p.join(App.dataPath, 'comic_source')).createSync();
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['dataVersion'] = 0;
        appdata.setFullSearchHistory([]);
        await appdata.saveData(false);
        DataSync.resetForTesting();
        DataSync.debugDisableWindowCloseHandler = true;
        registerAppDataSettingsChangedHandler(null);
      });

      tearDown(() async {
        DataSync.resetForTesting();
        registerAppDataSettingsChangedHandler(null);
        final history = HistoryManager.cache;
        if (history != null) {
          await history.waitForAsyncWrites();
          if (history.isInitialized) history.close();
        }
        HistoryManager.cache = previousHistory;

        final favorites = LocalFavoritesManager.cache;
        if (favorites != null) {
          await favorites.waitForPendingReads();
          favorites.close();
        }
        LocalFavoritesManager.cache = previousFavorites;

        final cookieJar = SingleInstanceCookieJar.instance;
        if (cookieJar != null && !identical(cookieJar, previousCookieJar)) {
          cookieJar.dispose();
        }
        SingleInstanceCookieJar.instance = previousCookieJar;

        await appdata.writeImplicitData();
        appdata.settings.replaceAll(
          Map<String, dynamic>.from(previousAppData['settings'] as Map),
        );
        await appdata.syncData(previousAppData);
        appdata.settings.replaceAll(previousSettings);
        appdata.implicitData
          ..clear()
          ..addAll(previousImplicit);
        App.dataPath = previousDataPath;
        App.cachePath = previousCachePath;
        if (root.existsSync()) root.deleteSync(recursive: true);
      });

      test(
        'exports original ZIP entries and restores the exported data',
        () async {
          _addHistory('export-history', 'Exported history');
          final favorites = LocalFavoritesManager();
          favorites.createFolder('exported-folder');
          favorites.addComic(
            'exported-folder',
            FavoriteItem(
              id: 'export-favorite',
              name: 'Exported favorite',
              coverPath: 'cover.jpg',
              author: 'author',
              type: ComicType.local,
              tags: const ['exported'],
            ),
          );
          appdata.settings['cacheSize'] = 512;
          appdata.searchHistory = ['exported search'];
          await appdata.saveData(false);
          File(
            p.join(App.dataPath, 'comic_source', 'readme.txt'),
          ).writeAsStringSync('exported source file');
          SingleInstanceCookieJar.instance!.saveFromResponse(
            Uri.parse('https://example.com/'),
            [Cookie('session', 'exported-cookie')..path = '/'],
          );

          final archive = await exportAppData(false);
          expect(archive.existsSync(), isTrue);
          expect(archive.path.endsWith('.venera'), isTrue);
          final extracted = await _extractArchive(archive, root);
          final entries = Directory(extracted.path)
              .listSync(recursive: true)
              .whereType<File>()
              .map(
                (file) => p
                    .relative(file.path, from: extracted.path)
                    .replaceAll(Platform.pathSeparator, '/'),
              )
              .toSet();
          expect(
            entries,
            unorderedEquals({
              'appdata.json',
              'history.db',
              'local_favorite.db',
              'cookie.db',
              'comic_source/readme.txt',
            }),
          );
          expect(
            File(
              p.join(extracted.path, 'comic_source', 'readme.txt'),
            ).readAsStringSync(),
            'exported source file',
          );
          expect(
            (jsonDecode(
                  File(
                    p.join(extracted.path, 'appdata.json'),
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>)['settings']['cacheSize'],
            512,
          );

          _addHistory('later-history', 'Later history');
          favorites.createFolder('later-folder');
          appdata.settings['cacheSize'] = 2048;
          appdata.searchHistory = ['later search'];
          await appdata.saveData(false);
          File(
            p.join(App.dataPath, 'comic_source', 'readme.txt'),
          ).writeAsStringSync('later source file');
          SingleInstanceCookieJar.instance!.saveFromResponse(
            Uri.parse('https://example.com/'),
            [Cookie('later', 'later-cookie')..path = '/'],
          );

          await importAppData(archive);

          expect(_historyTitle('export-history'), 'Exported history');
          expect(_historyTitle('later-history'), isNull);
          expect(
            LocalFavoritesManager().folderNames,
            contains('exported-folder'),
          );
          expect(
            LocalFavoritesManager().folderNames,
            isNot(contains('later-folder')),
          );
          expect(
            LocalFavoritesManager()
                .getFolderComics('exported-folder')
                .single
                .id,
            'export-favorite',
          );
          expect(appdata.settings['cacheSize'], 512);
          expect(appdata.searchHistory, ['exported search']);
          expect(
            File(
              p.join(App.dataPath, 'comic_source', 'readme.txt'),
            ).readAsStringSync(),
            'exported source file',
          );
          final cookies = SingleInstanceCookieJar.instance!.loadForRequest(
            Uri.parse('https://example.com/'),
          );
          expect(cookies.map((cookie) => cookie.name), contains('session'));
          expect(
            cookies.map((cookie) => cookie.name),
            isNot(contains('later')),
          );
        },
      );

      test(
        'imports original settings while preserving six device fields and user exclusions',
        () async {
          appdata.settings['proxy'] = 'local-proxy';
          appdata.settings['authorizationRequired'] = true;
          appdata.settings['customImageProcessing'] = {'local': true};
          appdata.settings['webdav'] = ['local-webdav'];
          appdata.settings['disableSyncFields'] = 'cacheSize, localOnly';
          appdata.settings['deviceId'] = 'local-device';
          appdata.settings['localOnly'] = 'local-value';
          appdata.settings['cacheSize'] = 2048;
          final searchHistory = List.generate(60, (index) => 'search-$index');
          final archive = await _createArchive(
            root,
            textEntries: {
              'appdata.json': jsonEncode({
                'settings': {
                  'proxy': 'remote-proxy',
                  'authorizationRequired': false,
                  'customImageProcessing': {'remote': true},
                  'webdav': ['remote-webdav'],
                  'disableSyncFields': 'remote-exclusions',
                  'deviceId': 'remote-device',
                  'cacheSize': 512,
                  'localOnly': 'remote-value',
                  'dataVersion': 42,
                  'extensionSetting': {'accepted': true},
                },
                'searchHistory': searchHistory,
              }),
            },
          );
          var notificationCount = 0;
          registerAppDataSettingsChangedHandler(() async {
            notificationCount++;
            final persisted =
                jsonDecode(
                      await File(
                        p.join(App.dataPath, 'appdata.json'),
                      ).readAsString(),
                    )
                    as Map<String, dynamic>;
            expect(persisted['settings']['cacheSize'], 2048);
            expect(persisted['settings']['extensionSetting'], {
              'accepted': true,
            });
          });

          await importAppData(archive);

          expect(notificationCount, 1);
          expect(appdata.settings['proxy'], 'local-proxy');
          expect(appdata.settings['authorizationRequired'], isTrue);
          expect(appdata.settings['customImageProcessing'], {'local': true});
          expect(appdata.settings['webdav'], ['local-webdav']);
          expect(appdata.settings['disableSyncFields'], 'cacheSize, localOnly');
          expect(appdata.settings['deviceId'], 'local-device');
          expect(appdata.settings['cacheSize'], 2048);
          expect(appdata.settings['localOnly'], 'local-value');
          expect(appdata.settings['dataVersion'], 42);
          expect(appdata.settings['extensionSetting'], {'accepted': true});
          expect(appdata.fullSearchHistory, searchHistory);
          expect(appdata.searchHistory, searchHistory.take(50).toList());
          expect(
            Directory(p.join(App.cachePath, 'temp_data')).existsSync(),
            isFalse,
          );
        },
      );

      test(
        'checkVersion skips backups no newer than the installed data version',
        () async {
          appdata.settings['dataVersion'] = 7;
          appdata.settings['cacheSize'] = 1024;
          _addHistory('current-history', 'Current history');
          await HistoryManager().waitForAsyncWrites();
          final archive = await _createArchive(
            root,
            textEntries: {
              'appdata.json': jsonEncode({
                'settings': {'dataVersion': 7, 'cacheSize': 512},
                'searchHistory': ['old backup'],
              }),
            },
            fileEntries: {
              'history.db': File(p.join(App.dataPath, 'history.db')),
            },
          );
          _addHistory('after-backup', 'Added after backup');
          appdata.settings['cacheSize'] = 2048;
          appdata.searchHistory = ['current search'];
          var notificationCount = 0;
          registerAppDataSettingsChangedHandler(() => notificationCount++);

          await importAppData(archive, checkVersion: true);

          expect(notificationCount, 0);
          expect(appdata.settings['cacheSize'], 2048);
          expect(appdata.searchHistory, ['current search']);
          expect(_historyTitle('current-history'), isNotNull);
          expect(_historyTitle('after-backup'), isNotNull);
          expect(
            Directory(p.join(App.cachePath, 'temp_data')).existsSync(),
            isFalse,
          );
        },
      );

      test(
        'WebDAV writes VeneraPlus snapshots, creates the directory and retains ten',
        () async {
          final server = await _SyncWebDav.start();
          addTearDown(server.close);
          final clients = <dav.Client>[];
          DataSync.debugClientFactory = (endpoint) {
            final client = endpoint.createClient();
            client.c.httpClientAdapter = IOHttpClientAdapter();
            clients.add(client);
            return client;
          };
          addTearDown(() {
            for (final client in clients) {
              client.c.close(force: true);
            }
          });
          appdata.settings['webdav'] = [server.url, '', ''];
          appdata.settings['cacheSize'] = 2048;
          appdata.settings['webdavComicLibrary'] = ['fixed-library'];
          appdata.settings['disableSyncFields'] =
              'cacheSize, webdavComicLibrary';
          await appdata.saveData(false);
          final day = (DateTime.now().millisecondsSinceEpoch ~/ 86400000)
              .toString();
          server.rootFiles['$day-0.venera'] = Uint8List(1);
          server.rootFiles['999999-999.venera'] = Uint8List(1);

          final sync = DataSync();
          expect((await sync.uploadData()).success, isTrue);
          expect(server.syncDirectoryExists, isTrue);
          expect(
            server.requests.where(
              (request) => request == 'MKCOL /dav/VeneraPlus/',
            ),
            hasLength(1),
          );
          expect(server.requests, contains('PROPFIND /dav/VeneraPlus/'));
          final firstName = server.snapshotNames.single;
          expect(firstName, matches(RegExp(r'^\d+-1\.venera$')));
          final extracted = await _extractServerSnapshot(
            server,
            firstName,
            root,
          );
          final syncSettings =
              jsonDecode(
                    File(
                      p.join(extracted.path, 'appdata.json'),
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>;
          expect(syncSettings['settings'].containsKey('cacheSize'), isFalse);
          expect(syncSettings['settings']['dataVersion'], 1);
          expect(appdata.settings['dataVersion'], 1);
          expect(syncSettings['settings']['webdavComicLibrary'], [
            'fixed-library',
          ]);

          expect((await sync.uploadData()).success, isTrue);
          expect(server.snapshotNames, hasLength(1));
          expect(server.snapshotNames.single, endsWith('-2.venera'));
          expect(
            server.requests.where(
              (request) => request == 'MKCOL /dav/VeneraPlus/',
            ),
            hasLength(1),
          );
          expect(
            server.requests.where((request) => request.startsWith('DELETE ')),
            isNotEmpty,
          );

          server.files.remove(server.snapshotNames.single);
          for (var day = 0; day < 10; day++) {
            server.files['$day-1.venera'] = Uint8List(1);
          }
          server.files['keep.txt'] = Uint8List(1);
          expect((await sync.uploadData()).success, isTrue);
          expect(server.snapshotNames, hasLength(10));
          expect(server.files.containsKey('0-1.venera'), isFalse);
          expect(server.files.containsKey('keep.txt'), isTrue);
          expect(server.rootFiles.containsKey('$day-0.venera'), isTrue);
          expect(server.rootFiles.containsKey('999999-999.venera'), isTrue);
          expect(
            server.requests.where((request) => request.startsWith('DELETE ')),
            everyElement(startsWith('DELETE /dav/VeneraPlus/')),
          );
        },
      );

      test(
        'WebDAV skips equal snapshots and downloads newer snapshots without upload loop',
        () async {
          final server = await _SyncWebDav.start();
          addTearDown(server.close);
          final clients = <dav.Client>[];
          DataSync.debugClientFactory = (endpoint) {
            final client = endpoint.createClient();
            client.c.httpClientAdapter = IOHttpClientAdapter();
            clients.add(client);
            return client;
          };
          addTearDown(() {
            for (final client in clients) {
              client.c.close(force: true);
            }
          });
          appdata.settings['webdav'] = [server.url, '', ''];
          appdata.settings['dataVersion'] = 7;
          await appdata.saveData(false);
          server.syncDirectoryExists = true;
          server.files['999-7.venera'] = Uint8List(1);
          server.rootFiles['999999-999.venera'] = Uint8List(1);

          final sync = DataSync();
          appdata.implicitData['webdavSyncMode'] = DataSyncMode.realtime.name;
          expect((await sync.downloadData()).success, isTrue);
          expect(
            server.requests.where((request) => request.startsWith('GET ')),
            isEmpty,
          );

          appdata.settings['dataVersion'] = 8;
          appdata.settings['cacheSize'] = 512;
          await appdata.saveData(false);
          final incoming = await exportAppData();
          appdata.settings['dataVersion'] = 7;
          appdata.settings['cacheSize'] = 2048;
          await appdata.saveData(false);
          _addHistory('local-only', 'Must be replaced');
          await HistoryManager().waitForAsyncWrites();
          server.files['999-8.venera'] = Uint8List.fromList(
            await incoming.readAsBytes(),
          );
          await incoming.delete();
          server.requests.clear();
          expect((await sync.downloadData()).success, isTrue);
          expect(
            server.requests.where((request) => request.startsWith('GET ')),
            hasLength(1),
          );
          expect(
            server.requests.where((request) => request.startsWith('GET ')),
            contains('GET /dav/VeneraPlus/999-8.venera'),
          );
          expect(
            server.requests.where((request) => request.startsWith('PUT ')),
            isEmpty,
          );
          expect(appdata.settings['dataVersion'], 8);
          expect(appdata.settings['cacheSize'], 512);
          expect(_historyTitle('local-only'), isNull);
          expect(sync.hasPendingChanges, isFalse);
          expect(server.rootFiles.containsKey('999999-999.venera'), isTrue);
        },
      );

      test(
        'imports original picadata history without replacing existing history',
        () async {
          _addHistory('existing-history', 'Keep existing history');
          await HistoryManager().waitForAsyncWrites();
          final originalDatabase = File(p.join(root.path, 'pica-history.db'));
          final database = sqlite3.open(originalDatabase.path);
          try {
            database.execute(
              'CREATE TABLE history(type INTEGER,target TEXT,max_page INTEGER,'
              'ep INTEGER,page INTEGER,time INTEGER,title TEXT,subtitle TEXT,cover TEXT)',
            );
            database.execute(
              "INSERT INTO history VALUES (0, 'pica-book', 10, 2, 3, "
              "1700000000000, 'Original PICA history', '', '')",
            );
            database.execute(
              'CREATE TABLE image_favorites(id TEXT,page INTEGER,ep INTEGER,title TEXT)',
            );
          } finally {
            database.close();
          }
          final archive = await _createArchive(
            root,
            fileEntries: {'history.db': originalDatabase},
          );
          final picaArchive = await archive.rename(
            p.join(root.path, 'original.picadata'),
          );

          await importPicaData(picaArchive);
          await HistoryManager().waitForAsyncWrites();

          final imported = HistoryManager().find(
            'pica-book',
            ComicType('picacg'.hashCode),
          );
          expect(imported?.title, 'Original PICA history');
          expect(imported?.ep, 2);
          expect(imported?.page, 3);
          expect(imported?.readEpisode, {'2'});
          expect(_historyTitle('existing-history'), 'Keep existing history');
        },
      );

      test(
        'rolls back an earlier history replacement after a later appdata failure',
        () async {
          appdata.settings['cacheSize'] = 1024;
          await appdata.syncData({
            'settings': <String, dynamic>{},
            'searchHistory': ['before-backup'],
            'nextSearchHistoryOrder': -42,
          });
          _addHistory('from-backup', 'Backup history');
          await HistoryManager().waitForAsyncWrites();
          final archive = await _createArchive(
            root,
            textEntries: {
              'appdata.json': jsonEncode({
                'settings': {'cacheSize': 512, 'rollbackExtension': true},
                'searchHistory': ['from-backup'],
                'nextSearchHistoryOrder': 'invalid',
              }),
            },
            fileEntries: {
              'history.db': File(p.join(App.dataPath, 'history.db')),
            },
          );
          _addHistory('after-backup', 'Local history');
          var replacedHistoryObserved = false;
          void historyListener() {
            replacedHistoryObserved |=
                HistoryManager().find('after-backup', ComicType.local) == null;
          }

          HistoryManager().addListener(historyListener);
          addTearDown(() => HistoryManager().removeListener(historyListener));
          var notificationCount = 0;
          registerAppDataSettingsChangedHandler(() {
            notificationCount++;
            throw StateError('observer failed');
          });

          await expectLater(importAppData(archive), throwsFormatException);

          expect(notificationCount, 0);
          expect(replacedHistoryObserved, isTrue);
          expect(_historyTitle('from-backup'), 'Backup history');
          expect(_historyTitle('after-backup'), 'Local history');
          expect(appdata.settings['cacheSize'], 1024);
          expect(appdata.settings['rollbackExtension'], isNull);
          expect(appdata.fullSearchHistory, ['before-backup']);
          expect(appdata.toJson()['nextSearchHistoryOrder'], -42);
          expect(
            Directory(p.join(App.cachePath, 'temp_data')).existsSync(),
            isFalse,
          );
        },
      );
    },
    skip: _nativeZipFailure != null && !_ciRequireNativeZip
        ? 'zip_flutter native library unavailable: $_nativeZipFailure'
        : null,
  );
}

Future<Directory> _extractServerSnapshot(
  _SyncWebDav server,
  String name,
  Directory root,
) async {
  final archive = File(p.join(root.path, name))
    ..writeAsBytesSync(server.files[name]!);
  return _extractArchive(archive, root);
}

class _SyncWebDav {
  _SyncWebDav(this.server);

  final HttpServer server;
  final files = <String, Uint8List>{};
  final rootFiles = <String, Uint8List>{};
  final requests = <String>[];
  var syncDirectoryExists = false;

  String get url => 'http://127.0.0.1:${server.port}/dav';

  Iterable<String> get snapshotNames =>
      files.keys.where((name) => name.endsWith('.venera'));

  static Future<_SyncWebDav> start() async {
    final fixture = _SyncWebDav(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    return fixture;
  }

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    final body = await request.fold<BytesBuilder>(
      BytesBuilder(),
      (buffer, chunk) => buffer..add(chunk),
    );
    const root = '/dav/';
    const syncDirectory = '/dav/VeneraPlus/';
    if (path == syncDirectory || path == '/dav/VeneraPlus') {
      if (request.method == 'MKCOL') {
        request.response.statusCode = syncDirectoryExists
            ? HttpStatus.forbidden
            : HttpStatus.created;
        syncDirectoryExists = true;
      } else if (request.method == 'PROPFIND') {
        if (!syncDirectoryExists) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          _writeDirectoryResponse(request.response, files, syncDirectory);
        }
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
    } else if (path.startsWith(syncDirectory)) {
      _handleFile(request, body.toBytes(), path, syncDirectory, files);
    } else if (path == root || path == '/dav') {
      if (request.method == 'PROPFIND') {
        _writeDirectoryResponse(request.response, rootFiles, root);
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
    } else if (path.startsWith(root)) {
      _handleFile(request, body.toBytes(), path, root, rootFiles);
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  }

  void _handleFile(
    HttpRequest request,
    Uint8List body,
    String path,
    String directory,
    Map<String, Uint8List> directoryFiles,
  ) {
    final name = Uri.decodeComponent(path.substring(directory.length));
    switch (request.method) {
      case 'OPTIONS':
        request.response.statusCode = HttpStatus.ok;
        break;
      case 'PUT':
        directoryFiles[name] = body;
        request.response.statusCode = HttpStatus.created;
        break;
      case 'GET':
        final bytes = directoryFiles[name];
        if (bytes == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.add(bytes);
        }
        break;
      case 'DELETE':
        directoryFiles.remove(name);
        request.response.statusCode = HttpStatus.noContent;
        break;
      default:
        request.response.statusCode = HttpStatus.methodNotAllowed;
    }
  }

  void _writeDirectoryResponse(
    HttpResponse response,
    Map<String, Uint8List> directoryFiles,
    String directory,
  ) {
    response.statusCode = HttpStatus.multiStatus;
    response.headers.contentType = ContentType('application', 'xml');
    response.write(_directoryResponse(directoryFiles, directory));
  }

  String _directoryResponse(
    Map<String, Uint8List> directoryFiles,
    String directory,
  ) {
    final entries = directoryFiles.keys
        .map(
          (name) =>
              '''
<D:response><D:href>$directory${Uri.encodeComponent(name)}</D:href>
<D:propstat><D:prop><D:resourcetype/></D:prop>
<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>''',
        )
        .join();
    return '''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:"><D:response>
<D:href>$directory</D:href>
<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
$entries</D:multistatus>''';
  }
}
