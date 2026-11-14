import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';
import '../../support/sqlite.dart';

const _account = StorageAccount(
  id: 'sync-cloud',
  backend: StorageBackend.openlist,
  driver: 'GoogleDrive',
  name: 'Sync cloud',
  authorization: {},
);

void main() {
  late Directory fallbackRoot;
  late Directory directory;
  late String previousDataPath;
  late String previousCachePath;
  late Map<String, dynamic> previousSettings;
  late Map<String, dynamic> previousImplicit;
  late _SyncRpc rpc;

  setUpAll(() async {
    // App paths are late until application startup. Keep a suite-owned fallback
    // so each test can snapshot and restore them safely.
    fallbackRoot = await Directory.systemTemp.createTemp(
      'venera-sync-transfer-fallback-',
    );
    App.dataPath = fallbackRoot.path;
    App.cachePath = fallbackRoot.path;
  });

  tearDownAll(() async {
    if (await fallbackRoot.exists()) {
      await fallbackRoot.delete(recursive: true);
    }
  });

  setUp(() {
    directory = Directory.systemTemp.createTempSync('venera-sync-transfer-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousSettings = Map<String, dynamic>.from(
      appdata.toJson()['settings'] as Map,
    );
    previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    Log.isMuted = true;
    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    rpc = _SyncRpc();
    RemoteStorageAccounts.instance.configureOpenList(rpc);
    appdata.settings.replaceAll({
      'dataVersion': 0,
      'webdav': const <String>[],
      remoteStorageAccountsSetting: [_account.toJson()],
      'syncRemoteLocation': const RemoteLocation(
        accountId: 'sync-cloud',
        directory: '/sync/',
      ).toJson(),
    });
    appdata.implicitData.clear();
    DataSync.debugSnapshotProducer = () async {
      final file = File('${directory.path}${Platform.pathSeparator}snapshot');
      await file.writeAsString('snapshot');
      return file;
    };
  });

  tearDown(() async {
    DataSync.resetForTesting();
    appdata.settings.replaceAll(previousSettings);
    appdata.implicitData
      ..clear()
      ..addAll(previousImplicit);
    // Await the queued write while the per-test paths still exist. This keeps a
    // completed test from writing into a later test's temporary directory.
    await appdata.saveData(false);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    Log.clear();
    Log.isMuted = false;
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'cloud upload retains ten snapshots after adding a thirteenth',
    () async {
      for (var day = 1; day <= 12; day++) {
        rpc.files.add('/sync/$day-1.venera');
      }

      final result = await DataSync().uploadData();

      expect(result.success, isTrue);
      expect(rpc.snapshotPaths, hasLength(10));
      expect(
        rpc.deleted,
        containsAll([
          '/sync/1-1.venera',
          '/sync/2-1.venera',
          '/sync/3-1.venera',
        ]),
      );
    },
  );

  test(
    'cloud upload removes every prior same-day snapshot before count cleanup',
    () async {
      final day = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
      // The next upload must have a distinct name so the retention code can
      // protect it while removing all older snapshots from the same day.
      appdata.settings['dataVersion'] = 3;
      rpc.files.addAll([
        '/sync/$day-1.venera',
        '/sync/$day-2.venera',
        '/sync/$day-3.venera',
        for (var oldDay = 1; oldDay <= 9; oldDay++) '/sync/$oldDay-1.venera',
      ]);

      final result = await DataSync().uploadData();

      expect(result.success, isTrue);
      expect(rpc.snapshotPaths, hasLength(10));
      expect(rpc.uploaded.single, startsWith('/sync/$day-4-'));
      expect(rpc.snapshotPaths, contains(rpc.uploaded.single));
      expect(
        rpc.deleted,
        containsAll([
          '/sync/$day-1.venera',
          '/sync/$day-2.venera',
          '/sync/$day-3.venera',
        ]),
      );
    },
  );

  test('failed cloud upload preserves every existing snapshot', () async {
    rpc.files.addAll(['/sync/1-1.venera', '/sync/2-1.venera']);
    rpc.failUpload = true;

    final result = await DataSync().uploadData();

    expect(result.error, isTrue);
    expect(appdata.settings['dataVersion'], 0);
    final saved = jsonDecode(
      await File('${directory.path}/appdata.json').readAsString(),
    );
    expect(saved['settings']['dataVersion'], 0);
    expect(rpc.deleted, isEmpty);
    expect(
      rpc.snapshotPaths,
      containsAll(['/sync/1-1.venera', '/sync/2-1.venera']),
    );
  });

  test('cloud download selects version ten after version nine', () async {
    rpc.files.addAll(['/sync/100-9.venera', '/sync/100-10.venera']);

    await DataSync().downloadData();

    expect(rpc.downloaded, ['/sync/100-10.venera']);
  });

  test(
    'switching targets invalidates an active preparation and pending work',
    () async {
      final producer = Completer<File>();
      DataSync.debugSnapshotProducer = () => producer.future;
      final sync = DataSync();
      final active = sync.uploadData();
      final pending = sync.downloadData();
      await Future<void>.delayed(Duration.zero);

      final configure = sync.configure(
        config: const [],
        remoteLocation: const RemoteLocation(
          accountId: 'sync-cloud',
          directory: '/new-target/',
        ),
        excludedFields: '',
        syncMode: DataSyncMode.manual,
        minutes: 30,
        initialUpload: false,
      );
      producer.complete(
        File('${directory.path}${Platform.pathSeparator}prepared')
          ..writeAsStringSync('snapshot'),
      );

      expect((await configure).success, isTrue);
      expect((await active).success, isTrue);
      expect((await pending).success, isTrue);
      expect(rpc.uploaded, isEmpty);
      expect(rpc.downloaded, isEmpty);
    },
  );

  test('switching targets cancels an active cloud transfer', () async {
    rpc.blockTransfer = true;
    final active = DataSync().uploadData();
    await rpc.transferStarted.future;

    final result = await DataSync().configure(
      config: const [],
      remoteLocation: const RemoteLocation(
        accountId: 'sync-cloud',
        directory: '/new-target/',
      ),
      excludedFields: '',
      syncMode: DataSyncMode.manual,
      minutes: 30,
      initialUpload: false,
    );

    expect(result.success, isTrue);
    expect(rpc.cancelled, isNotEmpty);
    expect((await active).error, isTrue);
  });

  for (final webDav in [false, true]) {
    group(
      webDav ? 'WebDAV snapshots' : 'cloud snapshots',
      () {
        late DataSync sync;

        setUp(() async {
          await HistoryManager().init();
          await LocalFavoritesManager().init();
          if (webDav) {
            appdata.settings.remove('syncRemoteLocation');
            appdata.settings['webdav'] = ['https://example.com/dav', '', ''];
            DataSync.debugClientFactory = (endpoint) {
              final client = endpoint.createClient();
              client.c.httpClientAdapter = _SyncDavAdapter(rpc);
              addTearDown(() => client.c.close(force: true));
              return client;
            };
          }
          configureAppDataArchiveExtractorForTesting((
            archive,
            destination,
          ) async {
            final settings = jsonDecode(await archive.readAsString());
            await File(
              '${destination.path}/appdata.json',
            ).writeAsString(jsonEncode({'settings': settings}));
          });
          sync = DataSync();
          configureHistoryDataChangedHandler(sync.onDataChanged);
        });

        tearDown(() async {
          DataSync.resetForTesting();
          configureHistoryDataChangedHandler(null);
          configureAppDataArchiveExtractorForTesting(null);
          await HistoryManager().waitForAsyncWrites();
          HistoryManager().close();
          LocalFavoritesManager().close();
          HistoryManager.cache = null;
          LocalFavoritesManager.cache = null;
        });

        test(
          'upload advances past the remote maximum despite a later local date',
          () async {
            rpc.files.addAll(['/sync/999999-2.venera', '/sync/1-20.venera']);

            expect((await sync.uploadData()).success, isTrue);

            expect(
              rpc.uploaded.single,
              matches(RegExp(r'/\d+-21-\d{20}-[0-9a-f]{32}\.venera$')),
            );
            expect(appdata.settings['dataVersion'], 21);
          },
        );

        test(
          'upload keeps concurrent equal and higher counters beyond ten backups',
          () async {
            rpc.onSnapshotUpload = (path) {
              final prefix = path.substring(0, path.lastIndexOf('-'));
              rpc.files.addAll([
                for (var peer = 0; peer < 11; peer++)
                  '$prefix-${peer.toString().padLeft(32, '0')}.venera',
                '/sync/1-2-peer.venera',
              ]);
            };

            expect((await sync.uploadData()).success, isTrue);

            expect(rpc.snapshotPaths, hasLength(13));
            expect(rpc.deleted, isEmpty);
          },
        );

        test(
          'failed upload restores the durable local counter and keeps pending edits',
          () async {
            appdata.settings['dataVersion'] = 5;
            rpc.files.add('/sync/1-20.venera');
            rpc.failUpload = true;
            sync.onDataChanged();

            expect((await sync.uploadData()).error, isTrue);

            expect(appdata.settings['dataVersion'], 5);
            final saved = jsonDecode(
              await File('${directory.path}/appdata.json').readAsString(),
            );
            expect(saved['settings']['dataVersion'], 5);
            expect(sync.hasPendingChanges, isTrue);
            expect(appdata.implicitData['webdavLastBackup'], isNull);
            expect(rpc.deleted, isEmpty);
          },
        );

        test(
          'failed cleanup retains a successful upload and its counter',
          () async {
            final day = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
            rpc.files.add('/sync/$day-1.venera');
            rpc.failDelete = true;

            expect((await sync.uploadData()).success, isTrue);

            expect(appdata.settings['dataVersion'], 2);
            expect(rpc.snapshotPaths, contains(rpc.uploaded.single));
          },
        );

        test('failed snapshot export restores the durable version', () async {
          appdata.settings['dataVersion'] = 5;
          rpc.files.add('/sync/1-20.venera');
          DataSync.debugSnapshotProducer = () async =>
              throw StateError('export failed');

          expect((await sync.uploadData()).error, isTrue);

          expect(appdata.settings['dataVersion'], 5);
          final saved = jsonDecode(
            await File('${directory.path}/appdata.json').readAsString(),
          );
          expect(saved['settings']['dataVersion'], 5);
          expect(rpc.uploaded, isEmpty);
        });

        test(
          'changes during snapshot preparation remain pending after upload',
          () async {
            final preparing = Completer<void>();
            final prepared = Completer<File>();
            DataSync.debugSnapshotProducer = () {
              preparing.complete();
              return prepared.future;
            };
            final upload = sync.uploadData();
            await preparing.future;
            sync.onDataChanged();
            prepared.complete(
              File('${directory.path}/prepared')..writeAsStringSync('snapshot'),
            );

            expect((await upload).success, isTrue);
            expect(sync.hasPendingChanges, isTrue);
          },
        );

        test(
          'automatic download imports an unknown equal counter without uploading',
          () async {
            appdata.settings['dataVersion'] = 7;
            appdata.settings['cacheSize'] = 2048;
            appdata.implicitData['webdavSyncMode'] = 'realtime';
            rpc.files.addAll(['/sync/999-6.venera', '/sync/1-7.venera']);
            rpc.downloadContent = jsonEncode({
              'dataVersion': 7,
              'cacheSize': 512,
            });

            expect((await sync.downloadData(force: false)).success, isTrue);

            expect(rpc.downloaded, ['/sync/1-7.venera']);
            expect(appdata.settings['cacheSize'], 512);
            expect(rpc.uploaded, isEmpty);
            expect(sync.hasPendingChanges, isFalse);
          },
        );

        test(
          'automatic download skips a known identity and imports changed legacy metadata',
          () async {
            rpc.files.add('/sync/1-7.venera');
            rpc.eTag = 'first';
            rpc.downloadContent = jsonEncode({
              'dataVersion': 7,
              'cacheSize': 512,
            });
            expect((await sync.downloadData(force: false)).success, isTrue);
            expect((await sync.downloadData(force: false)).success, isTrue);
            expect(rpc.downloaded, hasLength(1));

            rpc.eTag = 'second';
            rpc.downloadContent = jsonEncode({
              'dataVersion': 7,
              'cacheSize': 1024,
            });
            expect((await sync.downloadData(force: false)).success, isTrue);

            expect(rpc.downloaded, hasLength(2));
            expect(appdata.settings['cacheSize'], 1024);
          },
        );

        test(
          'automatic checks re-read legacy backups without trustworthy metadata',
          () async {
            rpc.files.add('/sync/1-7.venera');
            rpc.eTag = null;
            rpc.downloadContent = jsonEncode({
              'dataVersion': 7,
              'cacheSize': 512,
            });
            expect((await sync.downloadData(force: false)).success, isTrue);
            rpc.downloadContent = jsonEncode({
              'dataVersion': 7,
              'cacheSize': 1024,
            });

            expect((await sync.downloadData(force: false)).success, isTrue);

            expect(rpc.downloaded, hasLength(2));
            expect(appdata.settings['cacheSize'], 1024);
          },
        );

        test(
          'unique names skip known uploads and recognize a peer with the same counter',
          () async {
            expect((await sync.uploadData()).success, isTrue);
            expect((await sync.downloadData(force: false)).success, isTrue);
            expect(rpc.downloaded, isEmpty);
            const peer =
                '/sync/999999-1-99999999999999999999-ffffffffffffffffffffffffffffffff.venera';
            rpc.files.add(peer);
            rpc.downloadContent = jsonEncode({
              'dataVersion': 1,
              'cacheSize': 512,
            });

            expect((await sync.downloadData(force: false)).success, isTrue);
            expect((await sync.downloadData(force: false)).success, isTrue);

            expect(rpc.downloaded, [peer]);
            expect(appdata.settings['cacheSize'], 512);
          },
        );

        test(
          'explicit download restores an older snapshot and reapplies a known one',
          () async {
            appdata.settings['dataVersion'] = 20;
            rpc.files.add('/sync/1-7.venera');
            rpc.downloadContent = jsonEncode({
              'dataVersion': 7,
              'cacheSize': 512,
            });
            expect((await sync.downloadData(force: false)).success, isTrue);
            expect(rpc.downloaded, isEmpty);

            expect((await sync.downloadData()).success, isTrue);
            appdata.settings['cacheSize'] = 2048;
            expect((await sync.downloadData()).success, isTrue);

            expect(rpc.downloaded, hasLength(2));
            expect(appdata.settings['dataVersion'], 7);
            expect(appdata.settings['cacheSize'], 512);
          },
        );

        test(
          'failed import keeps the prior identity and can retry the same backup',
          () async {
            rpc.files.add('/sync/1-7.venera');
            rpc.downloadContent = 'invalid archive';
            expect((await sync.downloadData(force: false)).error, isTrue);
            expect(appdata.implicitData['webdavLastBackup'], isNull);
            rpc.downloadContent = jsonEncode({
              'dataVersion': 7,
              'cacheSize': 512,
            });

            expect((await sync.downloadData(force: false)).success, isTrue);

            expect(rpc.downloaded, hasLength(2));
            expect(appdata.settings['cacheSize'], 512);
          },
        );
      },
      skip: !isSqliteAvailable() ? 'SQLite not available' : false,
    );
  }
}

class _SyncRpc implements OpenListRpcClient {
  final files = <String>{};
  final contents = <String, String>{};
  final deleted = <String>[];
  final uploaded = <String>[];
  final downloaded = <String>[];
  final cancelled = <String>[];
  final transferStarted = Completer<void>();
  final _transferGate = Completer<void>();
  var failUpload = false;
  var failDelete = false;
  var blockTransfer = false;
  String? eTag = 'first';
  String downloadContent = 'not an archive';
  void Function(String path)? onSnapshotUpload;

  Iterable<String> get snapshotPaths => files.where(_isSnapshotPath);

  bool _isSnapshotPath(String path) =>
      path.startsWith('/sync/') &&
      !path.substring('/sync/'.length).contains('/') &&
      path.endsWith('.venera');

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    switch (method) {
      case 'list':
        final directory = request['path'] as String;
        return {
          'data': {
            'entries': [
              for (final path in files.where(
                (path) =>
                    path.startsWith(directory) &&
                    !path.substring(directory.length).contains('/'),
              ))
                {
                  'name': path.substring(path.lastIndexOf('/') + 1),
                  'path': path,
                  'isDirectory': false,
                  if (eTag != null) 'eTag': eTag,
                },
            ],
          },
        };
      case 'upload':
        if (failUpload) {
          return const {
            'error': {'code': 'failed', 'message': 'upload failed'},
          };
        }
        final path = request['path'] as String;
        files.add(path);
        if (_isSnapshotPath(path)) {
          uploaded.add(path);
          onSnapshotUpload?.call(path);
        } else {
          contents[path] = await File(
            request['localPath'] as String,
          ).readAsString();
        }
        if (blockTransfer && !transferStarted.isCompleted) {
          transferStarted.complete();
        }
        return const {'data': {}};
      case 'download':
        final path = request['path'] as String;
        if (_isSnapshotPath(path)) downloaded.add(path);
        await File(
          request['localPath'] as String,
        ).writeAsString(contents[path] ?? downloadContent);
        return const {'data': {}};
      case 'taskStatus':
        if (blockTransfer && !_transferGate.isCompleted) {
          await _transferGate.future;
        }
        return {
          'data': {'done': cancelled.isEmpty},
        };
      case 'delete':
        if (failDelete) {
          return const {
            'error': {'code': 'failed', 'message': 'delete failed'},
          };
        }
        final path = request['path'] as String;
        deleted.add(path);
        files.remove(path);
        return const {'data': {}};
      case 'cancel':
        cancelled.add(request['taskId'] as String);
        if (!_transferGate.isCompleted) {
          _transferGate.complete();
        }
        return const {'data': {}};
      case 'releaseTask':
      case 'mkdir':
        return const {'data': {}};
      default:
        return const {'data': {}};
    }
  }
}

class _SyncDavAdapter implements HttpClientAdapter {
  _SyncDavAdapter(this.rpc);

  final _SyncRpc rpc;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    final path = options.uri.path;
    final logicalPath = path.replaceFirst('/dav/VeneraPlus/', '/sync/');
    if (path.contains('comic_updates')) {
      return ResponseBody.fromString(
        '',
        options.method == 'PROPFIND' ? 404 : 201,
      );
    }
    switch (options.method) {
      case 'PROPFIND':
        final entries = rpc.files.map((file) {
          final name = file.substring(file.lastIndexOf('/') + 1);
          final eTag = rpc.eTag == null
              ? ''
              : '<D:getetag>${rpc.eTag}</D:getetag>';
          return '<D:response><D:href>/dav/VeneraPlus/$name</D:href>'
              '<D:propstat><D:prop><D:resourcetype/>$eTag</D:prop>'
              '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';
        }).join();
        return ResponseBody.fromString(
          '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>/dav/VeneraPlus/</D:href><D:propstat><D:prop>'
          '<D:resourcetype><D:collection/></D:resourcetype></D:prop>'
          '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
          '$entries</D:multistatus>',
          207,
          headers: {
            'content-type': ['application/xml'],
          },
        );
      case 'PUT':
        if (rpc.failUpload) return ResponseBody.fromString('', 500);
        rpc.uploaded.add(logicalPath);
        rpc.files.add(logicalPath);
        rpc.onSnapshotUpload?.call(logicalPath);
        return ResponseBody.fromString('', 201);
      case 'GET':
        rpc.downloaded.add(logicalPath);
        return ResponseBody.fromString(rpc.downloadContent, 200);
      case 'DELETE':
        if (rpc.failDelete) return ResponseBody.fromString('', 500);
        rpc.deleted.add(logicalPath);
        rpc.files.remove(logicalPath);
        return ResponseBody.fromString('', 204);
      default:
        return ResponseBody.fromString('', 200);
    }
  }

  @override
  void close({bool force = false}) {}
}
