import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

void main() {
  late Directory tempDir;
  late String originalDataPath;
  late String originalCachePath;
  late bool originalMuted;
  late Map<String, dynamic> previousImplicit;
  late Map<String, dynamic> previousSettings;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('data-sync-test-');
    originalDataPath = Directory.systemTemp.path;
    originalCachePath = Directory.systemTemp.path;
    try {
      originalDataPath = App.dataPath;
    } catch (_) {}
    try {
      originalCachePath = App.cachePath;
    } catch (_) {}
    originalMuted = Log.isMuted;
    App.cachePath = tempDir.path;
    App.dataPath = tempDir.path;
    previousSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
    previousImplicit = Map<String, dynamic>.from(appdata.implicitData);

    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    Log.isMuted = true;
    appdata.implicitData.clear();
    appdata.implicitData['webdavSyncDirection'] = 'bidirectional';
    appdata.implicitData['webdavSyncTiming'] = 'manual';
    appdata.settings['webdav'] = ['https://example.com/dav', 'user', 'pass'];
  });

  tearDown(() async {
    if (DataSync.instance != null) await DataSync.instance!.waitForSync();
    await appdata.writeImplicitData();
    DataSync.resetForTesting();
    configureAppDataArchiveExtractorForTesting(null);
    Log.clear();
    Log.isMuted = originalMuted;
    App.cachePath = originalCachePath;
    App.dataPath = originalDataPath;
    appdata.implicitData.clear();
    appdata.implicitData.addAll(previousImplicit);
    (appdata.toJson()['settings'] as Map)
      ..clear()
      ..addAll(previousSettings);
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('DataSync.evaluateSyncAction', () {
    const currentTarget = 'https://example.com/dav#user';

    RemoteSnapshot makeSnapshot(
      String name,
      int day,
      int version, [
      String? etag,
    ]) {
      return RemoteSnapshot(
        file: dav.File(name: name, eTag: etag),
        name: name,
        day: day,
        version: version,
        eTag: etag,
      );
    }

    test('empty remote triggers upload of initial snapshot', () {
      final action = DataSync.evaluateSyncAction(
        localHasPending: false,
        localVersion: 0,
        latestRemote: null,
        baselineTarget: currentTarget,
        currentTarget: currentTarget,
        baselineFile: null,
        baselineVersion: null,
        baselineEtag: null,
        hasRemoteCollision: false,
      );
      expect(action, SyncAction.upload);
    });

    test('remote collision flags conflict', () {
      final latest = makeSnapshot('10-5.venera', 10, 5);
      final action = DataSync.evaluateSyncAction(
        localHasPending: false,
        localVersion: 0,
        latestRemote: latest,
        baselineTarget: currentTarget,
        currentTarget: currentTarget,
        baselineFile: null,
        baselineVersion: null,
        baselineEtag: null,
        hasRemoteCollision: true,
      );
      expect(action, SyncAction.conflict);
    });

    test('zero local version is not proof of an empty database', () {
      final latest = makeSnapshot('10-5.venera', 10, 5);
      final action = DataSync.evaluateSyncAction(
        localHasPending: false,
        localVersion: 0,
        latestRemote: latest,
        baselineTarget: null,
        currentTarget: currentTarget,
        baselineFile: null,
        baselineVersion: null,
        baselineEtag: null,
        hasRemoteCollision: false,
      );
      expect(action, SyncAction.conflict);
    });

    test(
      'unverified remote with modified local flags conflict to protect local data',
      () {
        final latest = makeSnapshot('10-5.venera', 10, 5);
        final action = DataSync.evaluateSyncAction(
          localHasPending: true,
          localVersion: 3,
          latestRemote: latest,
          baselineTarget: null,
          currentTarget: currentTarget,
          baselineFile: null,
          baselineVersion: null,
          baselineEtag: null,
          hasRemoteCollision: false,
        );
        expect(action, SyncAction.conflict);
      },
    );

    test('target mismatch treats baseline as unverified', () {
      final latest = makeSnapshot('10-5.venera', 10, 5);
      final action = DataSync.evaluateSyncAction(
        localHasPending: false,
        localVersion: 2,
        latestRemote: latest,
        baselineTarget: 'https://other.com/dav#otherUser',
        currentTarget: currentTarget,
        baselineFile: '10-2.venera',
        baselineVersion: 2,
        baselineEtag: null,
        hasRemoteCollision: false,
      );
      // Because target changed and localVersion > 0, it protects local by requiring conflict resolution
      expect(action, SyncAction.conflict);
    });

    test('trusted baseline: both sides modified flags conflict', () {
      final latest = makeSnapshot('10-6.venera', 10, 6);
      final action = DataSync.evaluateSyncAction(
        localHasPending: true,
        localVersion: 6,
        latestRemote: latest,
        baselineTarget: currentTarget,
        currentTarget: currentTarget,
        baselineFile: '10-5.venera',
        baselineVersion: 5,
        baselineEtag: 'tag1',
        hasRemoteCollision: false,
      );
      expect(action, SyncAction.conflict);
    });

    test('trusted baseline: only remote modified triggers download', () {
      final latest = makeSnapshot('10-6.venera', 10, 6);
      final action = DataSync.evaluateSyncAction(
        localHasPending: false,
        localVersion: 5,
        latestRemote: latest,
        baselineTarget: currentTarget,
        currentTarget: currentTarget,
        baselineFile: '10-5.venera',
        baselineVersion: 5,
        baselineEtag: 'tag1',
        hasRemoteCollision: false,
      );
      expect(action, SyncAction.download);
    });

    test('trusted baseline: remote ETag change triggers download', () {
      final latest = makeSnapshot('10-5.venera', 10, 5, 'newTag');
      final action = DataSync.evaluateSyncAction(
        localHasPending: false,
        localVersion: 5,
        latestRemote: latest,
        baselineTarget: currentTarget,
        currentTarget: currentTarget,
        baselineFile: '10-5.venera',
        baselineVersion: 5,
        baselineEtag: 'oldTag',
        hasRemoteCollision: false,
      );
      expect(action, SyncAction.download);
    });

    test('trusted baseline: only local modified triggers upload', () {
      final latest = makeSnapshot('10-5.venera', 10, 5, 'tag1');
      final action = DataSync.evaluateSyncAction(
        localHasPending: true,
        localVersion: 6,
        latestRemote: latest,
        baselineTarget: currentTarget,
        currentTarget: currentTarget,
        baselineFile: '10-5.venera',
        baselineVersion: 5,
        baselineEtag: 'tag1',
        hasRemoteCollision: false,
      );
      expect(action, SyncAction.upload);
    });

    test('trusted baseline: neither modified reports inSync', () {
      final latest = makeSnapshot('10-5.venera', 10, 5, 'tag1');
      final action = DataSync.evaluateSyncAction(
        localHasPending: false,
        localVersion: 5,
        latestRemote: latest,
        baselineTarget: currentTarget,
        currentTarget: currentTarget,
        baselineFile: '10-5.venera',
        baselineVersion: 5,
        baselineEtag: 'tag1',
        hasRemoteCollision: false,
      );
      expect(action, SyncAction.inSync);
    });
  });

  group('DataSync direction enforcement and conflict handling', () {
    test('uploadData is forbidden in downloadOnly direction', () async {
      appdata.implicitData['webdavSyncDirection'] = 'downloadOnly';
      final sync = DataSync();

      final result = await sync.uploadData();
      expect(result.error, isTrue);
      expect(result.errorMessage, contains('Action not allowed'));
    });

    test('downloadData is forbidden in uploadOnly direction', () async {
      appdata.implicitData['webdavSyncDirection'] = 'uploadOnly';
      final sync = DataSync();

      final result = await sync.downloadData();
      expect(result.error, isTrue);
      expect(result.errorMessage, contains('Action not allowed'));
    });

    test('resolveConflict adheres to direction restrictions', () async {
      appdata.implicitData['webdavSyncDirection'] = 'downloadOnly';
      final sync = DataSync();

      // Attempting keepLocal in downloadOnly mode is rejected
      final result = await sync.resolveConflict(keepLocal: true);
      expect(result.error, isTrue);
      expect(result.errorMessage, contains('Action not allowed'));
    });
  });

  group('Task concurrency and error propagation', () {
    test(
      'uploadData coalesces concurrent uploads into one pending task',
      () async {
        final uploads = <Completer<Res<bool>>>[];
        DataSync.debugUploadOverride = () {
          final completer = Completer<Res<bool>>();
          uploads.add(completer);
          return completer.future;
        };

        final sync = DataSync();
        final first = sync.uploadData();
        final second = sync.uploadData();
        final third = sync.uploadData();
        var waitCompleted = false;
        final waitFuture = sync.debugWaitForUploadBeforeClose().then((_) {
          waitCompleted = true;
        });

        expect(sync.isUploading, isTrue);
        expect(uploads, hasLength(1));
        expect(waitCompleted, isFalse);

        uploads.first.complete(const Res(true));
        await pumpEventQueue();

        expect(sync.isUploading, isTrue);
        expect(uploads, hasLength(2));
        expect(waitCompleted, isFalse);

        uploads[1].complete(const Res(true));
        final results = await Future.wait([first, second, third]);
        await waitFuture;

        expect(results.every((result) => result.success), isTrue);
        expect(uploads, hasLength(2));
        expect(sync.isUploading, isFalse);
        expect(waitCompleted, isTrue);
      },
    );

    test('downloadData waits for an active upload before starting', () async {
      final upload = Completer<Res<bool>>();
      var downloadCount = 0;
      DataSync.debugUploadOverride = () => upload.future;
      DataSync.debugDownloadOverride = () async {
        downloadCount++;
        return const Res(true);
      };

      final sync = DataSync();
      final uploadFuture = sync.uploadData();
      final downloadFuture = sync.downloadData();

      expect(sync.isUploading, isTrue);
      expect(downloadCount, 0);

      upload.complete(const Res(true));

      final downloadResult = await downloadFuture;
      final uploadResult = await uploadFuture;

      expect(uploadResult.success, isTrue);
      expect(downloadResult.success, isTrue);
      expect(downloadCount, 1);
      expect(sync.isUploading, isFalse);
      expect(sync.isDownloading, isFalse);
    });

    test('waitForDownload waits for a pending download task', () async {
      final upload = Completer<Res<bool>>();
      final download = Completer<Res<bool>>();
      var downloadStarted = false;
      DataSync.debugUploadOverride = () => upload.future;
      DataSync.debugDownloadOverride = () {
        downloadStarted = true;
        return download.future;
      };

      final sync = DataSync();
      final uploadFuture = sync.uploadData();
      final downloadFuture = sync.downloadData();
      var waitCompleted = false;
      final waitFuture = sync.waitForDownload().then((_) {
        waitCompleted = true;
      });

      expect(sync.isUploading, isTrue);
      expect(sync.isDownloading, isFalse);
      expect(downloadStarted, isFalse);
      expect(waitCompleted, isFalse);

      upload.complete(const Res(true));
      await pumpEventQueue();

      expect(downloadStarted, isTrue);
      expect(sync.isDownloading, isTrue);
      expect(waitCompleted, isFalse);

      download.complete(const Res(true));
      await Future.wait([uploadFuture, downloadFuture, waitFuture]);

      expect(waitCompleted, isTrue);
      expect(sync.isDownloading, isFalse);
    });

    test('uploadData records failed results in status snapshot', () async {
      DataSync.debugUploadOverride = () async {
        return const Res.error('upload failed');
      };

      final sync = DataSync();
      final result = await sync.uploadData();

      expect(result.error, isTrue);
      expect(result.errorMessage, 'upload failed');
      expect(sync.lastError, 'upload failed');
      expect(sync.statusSnapshot.lastError, 'upload failed');
      expect(sync.isUploading, isFalse);
    });

    test('downloadData converts thrown errors into failed results', () async {
      DataSync.debugDownloadOverride = () async {
        throw StateError('download failed');
      };

      final sync = DataSync();
      final result = await sync.downloadData();

      expect(result.error, isTrue);
      expect(result.errorMessage, contains('download failed'));
      expect(sync.lastError, result.errorMessage);
      expect(sync.isDownloading, isFalse);
    });

    test('mixed queued operations keep their own results', () async {
      final first = Completer<Res<bool>>();
      var uploads = 0;
      DataSync.debugUploadOverride = () async {
        uploads++;
        return uploads == 1 ? first.future : const Res.error('second upload');
      };
      DataSync.debugDownloadOverride = () async => const Res.error('download');
      final sync = DataSync();
      final a = sync.uploadData();
      final b = sync.downloadData();
      final c = sync.uploadData();
      first.complete(const Res(true));
      expect((await a).success, isTrue);
      expect((await b).errorMessage, 'download');
      expect((await c).errorMessage, 'second upload');
      expect(uploads, 2);
    });

    test(
      'configuration transfer is busy and queued calls recheck new direction',
      () async {
        final download = Completer<Res<bool>>();
        DataSync.debugDownloadOverride = () => download.future;
        var uploads = 0;
        DataSync.debugUploadOverride = () async {
          uploads++;
          return const Res(true);
        };
        final sync = DataSync();
        final configuring = sync.configure(
          config: ['https://other.example/dav', 'user', 'pass'],
          excludedFields: '',
          direction: SyncDirection.downloadOnly,
          timing: SyncTiming.realtime,
          minutes: 30,
          initialUpload: false,
        );
        expect(sync.isSyncing, isTrue);
        expect(sync.isDownloading, isTrue);
        final upload = sync.uploadData();
        var finished = false;
        final waiting = sync.waitForDownload().then((_) => finished = true);
        expect(finished, isFalse);
        download.complete(const Res(true));
        expect((await configuring).success, isTrue);
        expect((await upload).error, isTrue);
        await waiting;
        expect(uploads, 0);
        expect(sync.isSyncing, isFalse);
      },
    );

    test('edits during upload remain dirty', () async {
      final upload = Completer<Res<bool>>();
      DataSync.debugUploadOverride = () => upload.future;
      final sync = DataSync();
      final result = sync.uploadData();
      sync.onDataChanged();
      upload.complete(const Res(true));
      await result;
      expect(sync.hasPendingChanges, isTrue);
    });

    test(
      'configuration storage failure releases queue for a later retry',
      () async {
        final blocker = Directory('${App.dataPath}/appdata.json')..createSync();
        final sync = DataSync();
        Future<Res<bool>> save() => sync.configure(
          config: ['https://example.com/dav', 'user', 'pass'],
          excludedFields: '',
          direction: SyncDirection.bidirectional,
          timing: SyncTiming.manual,
          minutes: 30,
          initialUpload: true,
        );
        expect((await save()).error, isTrue);
        expect(sync.isSyncing, isFalse);
        blocker.deleteSync();
        expect((await save()).success, isTrue);
      },
    );

    test(
      'manual direction change clears an old conflict without transferring',
      () async {
        appdata.implicitData['webdavBaselineTarget'] =
            'https://example.com/dav#user';
        final sync = DataSync()
          ..debugSetConflict(remoteFile: '1-1.venera', remoteVersion: 1);
        final result = await sync.configure(
          config: ['https://example.com/dav', 'user', 'pass'],
          excludedFields: '',
          direction: SyncDirection.downloadOnly,
          timing: SyncTiming.manual,
          minutes: 30,
          initialUpload: false,
        );
        expect(result.success, isTrue);
        expect(sync.hasConflict, isFalse);
        expect(DataSync.direction, SyncDirection.downloadOnly);
      },
    );
  });

  group('real decisions with controlled WebDAV transfer boundaries', () {
    late _DavClient client;
    late _DavTransport transport;

    setUp(() {
      transport = _DavTransport();
      client = _DavClient(transport);
      DataSync.debugClientFactory = (_) => client;
      DataSync.debugExport = () async =>
          File('${App.cachePath}/export.venera')..writeAsStringSync('snapshot');
      DataSync.debugImport = (_, _) async {};
      appdata.settings['dataVersion'] = 0;
    });

    tearDown(() => client.c.close(force: true));

    test('unknown baseline protects version-zero local data', () async {
      client.files = [dav.File(name: '10-4.venera', eTag: '"a"')];
      final sync = DataSync();
      expect((await sync.syncNow()).error, isTrue);
      expect(sync.hasConflict, isTrue);
      expect(transport.requests, isEmpty);
    });

    test(
      'changed remote between decision and upload is never overwritten',
      () async {
        client.files = [dav.File(name: '10-4.venera', eTag: '"a"')];
        appdata.implicitData.addAll({
          'webdavBaselineTarget': 'https://example.com/dav#user',
          'webdavLastSyncedRemoteFile': '10-4.venera',
          'webdavLastSyncedRemoteVersion': 4,
          'webdavLastSyncedRemoteEtag': '"a"',
          'webdavSyncPending': true,
        });
        client.beforeList = (count) {
          if (count == 2) {
            client.files = [dav.File(name: '10-5.venera', eTag: '"b"')];
          }
        };
        final sync = DataSync();
        expect((await sync.syncNow()).error, isTrue);
        expect(sync.hasConflict, isTrue);
        expect(
          transport.requests.where((request) => request.method == 'PUT'),
          isEmpty,
        );
      },
    );

    test(
      'conditional PUT is streamed and does not contaminate OPTIONS',
      () async {
        transport.onPut = (name) {
          client.files.add(dav.File(name: name, eTag: '"uploaded"'));
        };
        final sync = DataSync();
        expect((await sync.syncNow()).success, isTrue);
        final options = transport.requests.singleWhere(
          (request) => request.method == 'OPTIONS',
        );
        final put = transport.requests.singleWhere(
          (request) => request.method == 'PUT',
        );
        expect(options.headers.containsKey('If-None-Match'), isFalse);
        expect(put.headers['If-None-Match'], '*');
        expect(put.headers['content-length'], 8);
        expect(transport.uploadedBytes, 8);
        expect(put.data, isA<Stream<List<int>>>());
        expect(sync.hasPendingChanges, isFalse);
      },
    );

    test(
      'HTTP 412 is an actionable conflict and keeps pending edits',
      () async {
        transport.putStatus = 412;
        final sync = DataSync()..onDataChanged();
        expect((await sync.uploadData()).error, isTrue);
        expect(sync.hasConflict, isTrue);
        expect(sync.hasPendingChanges, isTrue);
      },
    );

    test('keepRemote refuses two newest files with the same version', () async {
      client.files = [
        dav.File(name: '10-5.venera', eTag: '"a"'),
        dav.File(name: '11-5.venera', eTag: '"b"'),
      ];
      final sync = DataSync()
        ..debugSetConflict(remoteFile: '10-5.venera', remoteVersion: 5);
      expect((await sync.resolveConflict(keepLocal: false)).error, isTrue);
      expect(sync.hasConflict, isTrue);
      expect(transport.requests, isEmpty);
    });

    test(
      'local edit while GET waits prevents import and cleans temporary file',
      () async {
        client.files = [dav.File(name: '10-5.venera', eTag: '"a"')];
        transport.getGate = Completer<void>();
        var imports = 0;
        DataSync.debugImport = (_, _) async {
          imports++;
        };
        final sync = DataSync();
        final download = sync.downloadData(checkVersion: false);
        await transport.getStarted.future;
        sync.onDataChanged();
        transport.getGate!.complete();
        expect((await download).error, isTrue);
        expect(imports, 0);
        expect(sync.hasPendingChanges, isTrue);
        expect(File('${App.cachePath}/10-5.venera').existsSync(), isFalse);
      },
    );

    test(
      'local edit during archive extraction aborts before replacing databases',
      () async {
        client.files = [dav.File(name: '10-5.venera', eTag: '"a"')];
        DataSync.debugImport = null; // Exercise the real staged importer.
        final original = File('${App.dataPath}/history.db')
          ..writeAsStringSync('local history');
        final extracting = Completer<void>();
        final release = Completer<void>();
        configureAppDataArchiveExtractorForTesting((
          archive,
          destination,
        ) async {
          extracting.complete();
          await release.future;
          File(
            '${destination.path}/history.db',
          ).writeAsStringSync('remote history');
        });
        final sync = DataSync();
        final download = sync.downloadData(checkVersion: false);
        await extracting.future;
        sync.onDataChanged();
        release.complete();
        final result = await download;
        expect(result.error, isTrue);
        expect(
          result.errorMessage,
          contains('Local data changed during download'),
        );
        expect(sync.hasConflict, isTrue);
        expect(sync.hasPendingChanges, isTrue);
        expect(original.readAsStringSync(), 'local history');
        expect(
          Directory(
            App.dataPath,
          ).listSync().where((entry) => entry.path.contains('.import_backup_')),
          isEmpty,
        );
      },
    );

    test(
      'explicit download works without ETag but leaves baseline untrusted',
      () async {
        final previousHistory = HistoryManager.cache;
        final previousFavorites = LocalFavoritesManager.cache;
        HistoryManager.cache = null;
        LocalFavoritesManager.cache = null;
        final historyManager = HistoryManager();
        final favoritesManager = LocalFavoritesManager();
        var favoritesInitialized = false;
        try {
          await historyManager.init();
          await favoritesManager.init(reconcileReadingBinding: false);
          favoritesInitialized = true;
          try {
            client.files = [dav.File(name: '10-5.venera')];
            transport.getEtag = null;
            var imports = 0;
            final sync = DataSync();
            DataSync.debugImport = (_, _) async {
              imports++;
              sync.onDataChanged(); // Import-zone notification must not dirty data.
            };
            final result = await sync.downloadData(checkVersion: false);
            expect(result.success, isTrue, reason: result.errorMessage);
            expect(imports, 1);
            expect(sync.hasPendingChanges, isFalse);
            expect(appdata.implicitData['webdavLastSyncedRemoteEtag'], isNull);
            expect((await sync.syncNow()).error, isTrue);
          } finally {
            DataSync.resetForTesting();
          }
        } finally {
          try {
            if (favoritesInitialized) {
              await favoritesManager.debugWaitForHashedIdsRefresh();
              favoritesManager.close();
            }
          } finally {
            try {
              if (historyManager.isInitialized) {
                historyManager.close();
              }
            } finally {
              HistoryManager.cache = previousHistory;
              LocalFavoritesManager.cache = previousFavorites;
            }
          }
        }
      },
    );

    test('new endpoint configuration keeps successful new baseline', () async {
      appdata.implicitData['webdavBaselineTarget'] = 'old';
      appdata.implicitData['webdavLastSyncedRemoteFile'] = '1-1.venera';
      transport.onPut = (name) =>
          client.files.add(dav.File(name: name, eTag: '"new"'));
      final sync = DataSync();
      final result = await sync.configure(
        config: ['https://new.example/dav/', ' user ', 'pass'],
        excludedFields: '',
        direction: SyncDirection.uploadOnly,
        timing: SyncTiming.scheduled,
        minutes: 30,
        initialUpload: true,
      );
      expect(result.success, isTrue);
      expect(
        appdata.implicitData['webdavBaselineTarget'],
        'https://new.example/dav#user',
      );
      expect(
        appdata.implicitData['webdavLastSyncedRemoteFile'],
        client.files.single.name,
      );
      expect(appdata.implicitData['webdavLastSyncedRemoteEtag'], '"new"');
    });

    test('failed configuration restores old conflict and endpoint', () async {
      transport.putStatus = 412;
      final sync = DataSync()
        ..debugSetConflict(remoteFile: '1-1.venera', remoteVersion: 1);
      final result = await sync.configure(
        config: ['https://new.example/dav', 'new', 'pass'],
        excludedFields: 'language',
        direction: SyncDirection.uploadOnly,
        timing: SyncTiming.scheduled,
        minutes: 15,
        initialUpload: true,
      );
      expect(result.error, isTrue);
      expect(appdata.settings['webdav'], [
        'https://example.com/dav',
        'user',
        'pass',
      ]);
      expect(DataSync.timing, SyncTiming.manual);
      expect(sync.conflictRemoteFile, '1-1.venera');
      expect(sync.isSyncing, isFalse);
    });

    test(
      'cleanup uses conditional DELETE only for safe pre-upload candidates',
      () async {
        final day = DateTime.now().millisecondsSinceEpoch ~/ 86400000;
        client.files = [
          dav.File(name: '$day-4.venera', eTag: '"safe"'),
          dav.File(name: '$day-3.venera', eTag: '"collision-a"'),
          dav.File(name: '${day - 1}-3.venera', eTag: '"collision-b"'),
          dav.File(name: '$day-2.venera'),
        ];
        transport.onPut = (name) {
          client.files.addAll([
            dav.File(name: name, eTag: '"new"'),
            dav.File(name: '$day-1.venera', eTag: '"concurrent"'),
          ]);
        };
        expect((await DataSync().uploadData()).success, isTrue);
        final deletes = transport.requests
            .where((request) => request.method == 'DELETE')
            .toList();
        expect(deletes, hasLength(1));
        expect(deletes.single.uri.pathSegments.last, '$day-4.venera');
        expect(deletes.single.headers['If-Match'], '"safe"');
        expect(deletes.single.headers.containsKey('If-None-Match'), isFalse);
      },
    );

    test('weak upload validators never become a trusted baseline', () async {
      transport.onPut = (name) =>
          client.files.add(dav.File(name: name, eTag: 'W/"weak"'));
      final sync = DataSync();
      expect((await sync.uploadData()).success, isTrue);
      expect(appdata.implicitData['webdavLastSyncedRemoteEtag'], isNull);
      expect((await sync.syncNow()).error, isTrue);
      expect(sync.hasConflict, isTrue);
    });

    test('directories named like snapshots are excluded', () {
      expect(
        RemoteSnapshot.tryParse(dav.File(name: '10-5.venera', isDir: true)),
        isNull,
      );
    });

    test(
      'remote baseline mutation during PUT remains a conflict after upload',
      () async {
        client.files = [dav.File(name: '10-4.venera', eTag: '"old"')];
        appdata.settings['dataVersion'] = 20;
        appdata.implicitData.addAll({
          'webdavBaselineTarget': 'https://example.com/dav#user',
          'webdavLastSyncedRemoteFile': '10-4.venera',
          'webdavLastSyncedRemoteVersion': 4,
          'webdavLastSyncedRemoteEtag': '"old"',
          'webdavSyncPending': true,
        });
        transport.onPut = (name) {
          client.files = [
            dav.File(name: '10-4.venera', eTag: '"concurrent-change"'),
            dav.File(name: name, eTag: '"uploaded"'),
          ];
        };
        final sync = DataSync();
        expect((await sync.syncNow()).error, isTrue);
        expect(sync.hasConflict, isTrue);
        expect(sync.hasPendingChanges, isTrue);
        expect(
          appdata.implicitData['webdavLastSyncedRemoteFile'],
          '10-4.venera',
        );
        expect(
          transport.requests.where((request) => request.method == 'DELETE'),
          isEmpty,
        );
      },
    );
  });
}

class _DavClient extends dav.Client {
  _DavClient(_DavTransport transport)
    : super(
        uri: 'https://example.com/dav/',
        c: dav.WdDio(httpAdapter: transport),
        auth: dav.Auth(user: 'user', pwd: 'pass'),
      );

  List<dav.File> files = [];
  void Function(int)? beforeList;
  int lists = 0;

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async {
    beforeList?.call(++lists);
    return List.of(files);
  }
}

class _DavTransport implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  int putStatus = 201;
  int uploadedBytes = 0;
  String? getEtag = '"a"';
  void Function(String)? onPut;
  Completer<void>? getGate;
  final getStarted = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.method == 'PUT') {
      if (requestStream != null) {
        await for (final bytes in requestStream) {
          uploadedBytes += bytes.length;
        }
      }
      if (putStatus == 201) onPut?.call(options.uri.pathSegments.last);
      return ResponseBody.fromString('', putStatus);
    }
    if (options.method == 'GET') {
      if (!getStarted.isCompleted) getStarted.complete();
      await getGate?.future;
      return ResponseBody.fromString(
        'snapshot',
        200,
        headers: {
          if (getEtag != null) 'etag': [getEtag!],
        },
      );
    }
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}
