import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

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
      expect(rpc.snapshotPaths, contains('/sync/$day-4.venera'));
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
}

class _SyncRpc implements OpenListRpcClient {
  final files = <String>{};
  final deleted = <String>[];
  final uploaded = <String>[];
  final downloaded = <String>[];
  final cancelled = <String>[];
  final transferStarted = Completer<void>();
  final _transferGate = Completer<void>();
  var failUpload = false;
  var blockTransfer = false;

  Iterable<String> get snapshotPaths =>
      files.where((path) => path.endsWith('.venera'));

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    switch (method) {
      case 'list':
        return {
          'data': {
            'entries': [
              for (final path in files)
                {
                  'name': path.substring(path.lastIndexOf('/') + 1),
                  'path': path,
                  'isDirectory': false,
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
        uploaded.add(path);
        files.add(path);
        if (blockTransfer && !transferStarted.isCompleted) {
          transferStarted.complete();
        }
        return const {'data': {}};
      case 'download':
        downloaded.add(request['path'] as String);
        await File(
          request['localPath'] as String,
        ).writeAsString('not an archive');
        return const {'data': {}};
      case 'taskStatus':
        if (blockTransfer && !_transferGate.isCompleted) {
          await _transferGate.future;
        }
        return {
          'data': {'done': cancelled.isEmpty},
        };
      case 'delete':
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
