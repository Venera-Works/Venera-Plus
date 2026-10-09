import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

void main() {
  late Directory tempDir;
  late String originalDataPath;
  late String originalCachePath;
  late bool originalMuted;
  late Map<String, dynamic> previousImplicit;
  late Map<String, dynamic> previousSettings;
  late Directory suiteDirectory;
  String? suiteOriginalDataPath;
  String? suiteOriginalCachePath;

  setUpAll(() {
    try {
      suiteOriginalDataPath = App.dataPath;
    } catch (_) {}
    try {
      suiteOriginalCachePath = App.cachePath;
    } catch (_) {}
    suiteDirectory = Directory.systemTemp.createTempSync('data-sync-suite-');
    App.dataPath = suiteDirectory.path;
    App.cachePath = suiteDirectory.path;
  });

  tearDownAll(() async {
    // This queue barrier must precede path restoration and directory deletion.
    await appdata.writeImplicitData();
    App.dataPath = suiteOriginalDataPath ?? Directory.systemTemp.path;
    App.cachePath = suiteOriginalCachePath ?? Directory.systemTemp.path;
    suiteDirectory.deleteSync(recursive: true);
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('data-sync-test-');
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    originalMuted = Log.isMuted;
    Log.isMuted = true;

    previousSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
    previousImplicit = Map<String, dynamic>.from(appdata.implicitData);

    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    DataSync.debugExportRecords = () async => {};
    DataSync.debugApplyRecords = (records, {beforeCommit}) async {
      beforeCommit?.call();
    };
    DataSync.debugClientFactory = (_) =>
        _VirtualDavClient(_VirtualWebDavTransport());
    appdata.settings['webdav'] = ['https://example.com/dav', 'user', 'pass'];
    appdata.implicitData.clear();
    appdata.implicitData['webdavSyncDirection'] = 'bidirectional';
    appdata.implicitData['webdavSyncTiming'] = 'manual';
    appdata.implicitData['syncDeviceId'] = 'test_device_1';
    appdata.implicitData['webdavSyncDeviceName'] = 'Test Device';
  });

  tearDown(() async {
    if (DataSync.instance != null) {
      await DataSync.instance!.waitForStartupMerge().catchError((_) {});
      await DataSync.instance!.waitForSync();
    }
    DataSync.resetForTesting();

    await appdata.writeImplicitData();
    appdata.implicitData
      ..clear()
      ..addAll(previousImplicit);
    (appdata.toJson()['settings'] as Map)
      ..clear()
      ..addAll(previousSettings);

    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    Log.isMuted = originalMuted;
    Log.clear();

    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('DataSync direction enforcement and task concurrency', () {
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

    test(
      'uploadData coalesces concurrent uploads into one pending task',
      () async {
        final uploads = <Completer<Res<bool>>>[];
        final firstStarted = Completer<void>();
        final secondStarted = Completer<void>();
        DataSync.debugUploadOverride = () {
          final completer = Completer<Res<bool>>();
          uploads.add(completer);
          (uploads.length == 1 ? firstStarted : secondStarted).complete();
          return completer.future;
        };

        final sync = DataSync();
        await sync.waitForStartupMerge();
        final first = sync.uploadData();
        final second = sync.uploadData();
        final third = sync.uploadData();
        var waitCompleted = false;
        final waitFuture = sync.debugWaitForUploadBeforeClose().then((_) {
          waitCompleted = true;
        });

        await firstStarted.future;
        expect(sync.isUploading, isTrue);
        expect(uploads, hasLength(1));
        expect(waitCompleted, isFalse);

        uploads.first.complete(const Res(true));
        await first;
        await secondStarted.future;

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
      await sync.waitForStartupMerge();
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
      final started = Completer<void>();
      DataSync.debugUploadOverride = () => upload.future;
      DataSync.debugDownloadOverride = () {
        downloadStarted = true;
        started.complete();
        return download.future;
      };

      final sync = DataSync();
      await sync.waitForStartupMerge();
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
      await uploadFuture;
      await started.future;

      expect(downloadStarted, isTrue);
      expect(sync.isDownloading, isTrue);
      expect(waitCompleted, isFalse);

      download.complete(const Res(true));
      await Future.wait([uploadFuture, downloadFuture, waitFuture]);

      expect(waitCompleted, isTrue);
      expect(sync.isDownloading, isFalse);
    });

    test(
      'waitForStartupMerge completes cleanly on unconfigured or finished startup',
      () async {
        final sync = DataSync();
        await expectLater(sync.waitForStartupMerge(), completes);
      },
    );

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

    test('edits during upload remain dirty', () async {
      final upload = Completer<Res<bool>>();
      final started = Completer<void>();
      DataSync.debugUploadOverride = () {
        started.complete();
        return upload.future;
      };
      final sync = DataSync();
      await sync.waitForStartupMerge();
      final result = sync.uploadData();
      await started.future;
      sync.onDataChanged();
      upload.complete(const Res(true));
      await result;
      expect(sync.hasPendingChanges, isTrue);
    });

    test(
      'configuration failure rolls back preferences and leaves dirty changes intact',
      () async {
        DataSync.debugClientFactory = (_) =>
            _VirtualDavClient(_VirtualWebDavTransport())
              ..pingFailure = StateError('connection failed');
        final sync = DataSync();
        final badResult = await sync.configure(
          config: [
            'https://invalid-host-that-fails.invalid/dav',
            'user',
            'pass',
          ],
          deviceName: 'Changed Device',
          excludedFields: '',
          direction: SyncDirection.bidirectional,
          timing: SyncTiming.manual,
          minutes: 30,
        );

        expect(badResult.error, isTrue);
        // Original config preserved
        expect(appdata.settings['webdav'], [
          'https://example.com/dav',
          'user',
          'pass',
        ]);
        expect(appdata.implicitData['webdavSyncDeviceName'], 'Test Device');
        expect(sync.isSyncing, isFalse);
      },
    );

    test(
      'configuration success updates timing, direction, and interval',
      () async {
        final transport = _VirtualWebDavTransport();
        final client = _VirtualDavClient(transport);
        DataSync.debugClientFactory = (_) => client;

        final sync = DataSync();
        final result = await sync.configure(
          config: ['https://example.com/dav', 'newuser', 'newpass'],
          excludedFields: '',
          direction: SyncDirection.downloadOnly,
          timing: SyncTiming.scheduled,
          minutes: 60,
          deviceName: 'My PC',
        );

        expect(result.success, isTrue);
        expect(DataSync.direction, SyncDirection.downloadOnly);
        expect(DataSync.timing, SyncTiming.scheduled);
        expect(DataSync.intervalMinutes, 60);
        final saved =
            jsonDecode(
                  await File(
                    '${tempDir.path}/implicitData.json',
                  ).readAsString(),
                )
                as Map;
        expect(saved['webdavSyncDeviceName'], 'My PC');
        expect(appdata.settings['webdav'], [
          'https://example.com/dav',
          'newuser',
          'newpass',
        ]);
      },
    );
  });

  group('DataSync and MergeSyncCoordinator end-to-end integration', () {
    late _VirtualWebDavTransport transport;
    late _VirtualDavClient client;
    late SyncRecords localRecords;

    setUp(() {
      transport = _VirtualWebDavTransport();
      client = _VirtualDavClient(transport);
      DataSync.debugClientFactory = (_) => client;

      localRecords = {
        syncRecordKey('setting', ['theme']): {'value': 'dark'},
        syncRecordKey('search', ['manga']): {'order': 0},
      };

      DataSync.debugExportRecords = () async => Map.from(localRecords);
      DataSync.debugApplyRecords = (records, {beforeCommit}) async {
        beforeCommit?.call();
        localRecords = Map.from(records);
      };
    });

    test(
      'local capture creates outbox batch and uploads in bidirectional sync',
      () async {
        final sync = DataSync();
        final result = await sync.syncNow();

        expect(result.success, isTrue);
        final remote = MergeRemote(client);
        final published = MergeDocument();
        for (final entry in await remote.list()) {
          published.merge((await remote.download(entry)).document);
        }
        expect(published.materialize(), localRecords);
        expect(sync.hasConflict, isFalse);
        expect(sync.statusSnapshot.conflictCount, 0);
      },
    );

    test(
      'sync retries a failed local transaction without restarting',
      () async {
        final sync = DataSync();
        final initial = await sync.syncNow();
        expect(initial.success, isTrue, reason: initial.errorMessage);
        final key = syncRecordKey('setting', ['theme']);
        localRecords[key] = {'value': 'light'};
        sync.onDataChanged(domains: {'setting'});
        final lock = sqlite3.open(
          '${sync.coordinator!.stateDirectory.path}/merge_store.sqlite3',
        );
        lock.execute('BEGIN EXCLUSIVE;');
        try {
          expect((await sync.syncNow()).error, isTrue);
        } finally {
          lock.execute('ROLLBACK;');
          lock.close();
        }
        final retried = await sync.syncNow();
        expect(retried.success, isTrue, reason: retried.errorMessage);
        final entries = await sync.coordinator!.remote.list();
        final published = await sync.coordinator!.remote.downloadLatestValid(
          sync.coordinator!.actor,
          entries,
        );
        expect(published!.document.materialize()[key], {'value': 'light'});
      },
    );

    test(
      'a settings edit reuses previously published history objects',
      () async {
        final theme = syncRecordKey('setting', ['theme']);
        for (var index = 0; index < 120; index++) {
          localRecords[syncRecordKey('history', ['comic-$index', 1])] = {
            'title': 'Comic $index',
            'readDurationMs': 0,
            'progress': {
              'ep': 2,
              'page': index + 1,
              'group': null,
              'time': 1000,
            },
          };
        }
        final expectedRecords = cloneSyncRecords(localRecords);
        final sync = DataSync();
        final initial = await sync.syncNow();
        expect(initial.success, isTrue, reason: initial.errorMessage);

        Future<SyncPackManifest> latestOwnManifest() async {
          final actor = sync.coordinator!.actor;
          final latest = (await MergeRemote(client).list())
              .where((entry) => entry.actor == actor)
              .reduce(
                (current, candidate) =>
                    candidate.counter > current.counter ? candidate : current,
              );
          final bytes = transport.remoteFiles[latest.filename];
          if (bytes == null) {
            throw StateError('Missing published manifest ${latest.filename}');
          }
          return SyncPackManifest.parse(bytes);
        }

        Map<String, Map<String, Object?>> historyReferences(
          SyncPackManifest manifest,
        ) => {
          for (final reference in manifest.objects)
            if (reference['domain'] == 'history')
              reference['path']! as String: reference,
        };

        final initialHistoryReferences = historyReferences(
          await latestOwnManifest(),
        );
        expect(
          initialHistoryReferences.values.fold<int>(
            0,
            (count, reference) => count + (reference['recordCount']! as int),
          ),
          120,
        );
        final oldHistoryPackFilenames = initialHistoryReferences.values
            .map((reference) => '${reference['packSha256']! as String}.pack')
            .toSet();

        transport.requests.clear();
        localRecords[theme] = {'value': 'light'};
        expectedRecords[theme] = {'value': 'light'};
        sync.onDataChanged(domains: {'setting'});
        final updated = await sync.syncNow();
        expect(updated.success, isTrue, reason: updated.errorMessage);

        final updatedHistoryReferences = historyReferences(
          await latestOwnManifest(),
        );
        expect(updatedHistoryReferences, initialHistoryReferences);
        expect(
          transport.requests.where(
            (request) =>
                request.method == 'PUT' &&
                request.uri.pathSegments.isNotEmpty &&
                oldHistoryPackFilenames.contains(request.uri.pathSegments.last),
          ),
          isEmpty,
        );

        final freshRemote = MergeRemote(client);
        final published = MergeDocument();
        for (final entry in await freshRemote.list()) {
          published.merge((await freshRemote.download(entry)).document);
        }
        final readBack = published.materialize();
        expect(readBack, expectedRecords);
        expect(readBack[theme], {'value': 'light'});
      },
    );

    test(
      'startup publishes full causal history without probing obsolete directories',
      () async {
        final hash = MergeSyncCoordinator.computeEndpointHash(
          'https://example.com/dav',
          'user',
        );
        final stateDirectory = Directory('${tempDir.path}/sync_state_$hash');
        final store = MergeStore(stateDirectory, 'test_device_1');
        await store.load();
        await store.capture(localRecords);
        final oldBatch = store.outbox.single;
        await store.acknowledge(oldBatch.id);

        final oldFiles = <String, Uint8List>{
          'VeneraPlus/sync-v4/Older Device/commits/1-obsolete.json':
              Uint8List.fromList(utf8.encode('old v4 state')),
          'VeneraPlus/sync-v5/Older Device/commits/1-obsolete.json':
              Uint8List.fromList(utf8.encode('old v5 state')),
        };
        transport.remoteDirs.addAll({
          'VeneraPlus',
          'VeneraPlus/sync-v4',
          'VeneraPlus/sync-v4/Older Device',
          'VeneraPlus/sync-v4/Older Device/commits',
          'VeneraPlus/sync-v5',
          'VeneraPlus/sync-v5/Older Device',
          'VeneraPlus/sync-v5/Older Device/commits',
        });
        transport.remoteFiles.addAll(oldFiles);
        appdata.implicitData
          ..['webdavSyncDeviceName'] = 'Test 東京 Device'
          ..['webdavSyncDirection'] = 'uploadOnly'
          ..['webdavSyncTiming'] = 'realtime';
        client.directoryReads.clear();

        final sync = DataSync();
        await sync.waitForStartupMerge();
        await sync.waitForSync();

        expect(sync.coordinator!.store.outbox, isEmpty);
        final remote = sync.coordinator!.remote;
        final ownEntries = (await remote.list())
            .where((entry) => entry.actor == 'test_device_1')
            .toList();
        expect(ownEntries, hasLength(1));
        expect(
          ownEntries.single.filename,
          startsWith('VeneraPlus/Test 東京 Device/commits/'),
        );
        expect(
          (await remote.download(ownEntries.single)).document.materialize(),
          localRecords,
        );
        for (final entry in oldFiles.entries) {
          expect(transport.remoteFiles[entry.key], entry.value);
        }
        expect(
          client.directoryReads.any(
            (path) =>
                path.toLowerCase().contains('sync-v4') ||
                path.toLowerCase().contains('sync-v5'),
          ),
          isFalse,
        );
        expect(
          transport.requests.any(
            (request) =>
                request.uri.path.contains('/sync-v4/') ||
                request.uri.path.contains('/sync-v5/'),
          ),
          isFalse,
        );

        final publishedCommits = transport.remoteFiles.keys
            .where((path) => path.contains('/commits/'))
            .toSet();
        transport.requests.clear();
        expect((await sync.syncNow()).success, isTrue);
        expect(
          transport.remoteFiles.keys
              .where((path) => path.contains('/commits/'))
              .toSet(),
          publishedCommits,
        );
        expect(
          transport.requests.where((request) => request.method == 'PUT'),
          isEmpty,
        );
      },
    );

    test(
      'restart preserves partial apply and a durable new user edit',
      () async {
        final hash = MergeSyncCoordinator.computeEndpointHash(
          'https://example.com/dav',
          'user',
        );
        final directory = Directory('${tempDir.path}/sync_state_$hash');
        final key = syncRecordKey('setting', ['theme']);
        final original = {
          key: <String, Object?>{'value': 'dark'},
        };
        final store = MergeStore(directory, 'test_device_1');
        await store.load();
        await store.capture(original);
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('other_device', {}, {
          key: {'value': 'remote'},
          syncRecordKey('search', ['remote search']): {'order': 0},
        });
        store.document.merge(remoteDoc);
        await store.stageApply(store.document.materialize());
        localRecords = {
          key: {'value': 'new user edit'},
          syncRecordKey('search', ['remote search']): {'order': 0},
        };

        final sync = DataSync();
        await sync.waitForStartupMerge();

        expect(localRecords[key], {'value': 'new user edit'});
        final candidates = sync.conflicts
            .firstWhere((conflict) => conflict.recordKey == key)
            .candidates
            .map((candidate) => candidate.value);
        expect(candidates, containsAll(['remote', 'new user edit']));
        expect(sync.coordinator!.store.pendingApply, isNull);
      },
    );

    test(
      'transfers protect concurrent local edits via generation check and re-capture',
      () async {
        final coordinator = MergeSyncCoordinator(
          endpointHash: 'hash1',
          stateDirectory: Directory('${tempDir.path}/state1'),
          actor: 'device_a',
          store: MergeStore(Directory('${tempDir.path}/state1'), 'device_a'),
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async => localRecords,
          applyPreferencesOverride: (records, {beforeCommit}) async {
            beforeCommit?.call();
            localRecords = Map.from(records);
          },
          getGenerationOverride: () => 0,
        );
        await coordinator.store.load();

        final syncResult = await coordinator.performSync(
          direction: SyncDirection.bidirectional,
        );
        expect(syncResult.success, isTrue);
        expect(coordinator.store.outbox, isEmpty);
      },
    );

    test(
      'beforeCommit detects concurrent modifications, rolls back staged journal and retries cleanly',
      () async {
        int generation = 0;
        var intercepted = 0;

        final coordinator = MergeSyncCoordinator(
          endpointHash: 'hash2',
          stateDirectory: Directory('${tempDir.path}/state2'),
          actor: 'device_b',
          store: MergeStore(Directory('${tempDir.path}/state2'), 'device_b'),
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async => localRecords,
          applyPreferencesOverride: (records, {beforeCommit}) async {
            if (intercepted < 2) {
              intercepted++;
              localRecords[syncRecordKey('search', ['new $intercepted'])] = {
                'order': intercepted,
              };
              generation++;
            }
            beforeCommit?.call();
            localRecords = Map.from(records);
          },
          getGenerationOverride: () => generation,
        );
        await coordinator.store.load();

        // Seed a remote file to trigger download & apply
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('device_c', {}, {
          syncRecordKey('setting', ['fontSize']): {'value': 16},
        });
        final remoteBatch = MergeBatch.create(
          actor: 'device_c',
          counter: 1,
          document: remoteDoc,
        );
        await coordinator.remote.upload(remoteBatch);

        final result = await coordinator.performSync(
          direction: SyncDirection.bidirectional,
        );
        expect(result.success, isTrue);
        expect(intercepted, 2);
        expect(
          localRecords.keys,
          containsAll([
            syncRecordKey('search', ['new 1']),
            syncRecordKey('search', ['new 2']),
          ]),
        );
        // Every aborted target, including the second one, must be retired.
        expect(coordinator.store.pendingApply, isNull);
      },
    );

    test('a selected remote candidate is applied and published', () async {
      final coordinator = MergeSyncCoordinator(
        endpointHash: 'hash3',
        stateDirectory: Directory('${tempDir.path}/state3'),
        actor: 'device_local',
        store: MergeStore(Directory('${tempDir.path}/state3'), 'device_local'),
        remote: MergeRemote(client),
        exportFavoritesOverride: () => {},
        exportHistoryOverride: () async => {},
        applyFavoritesOverride: (_) {},
        applyHistoryOverride: (_) {},
        exportPreferencesOverride: () async => localRecords,
        applyPreferencesOverride: (records, {beforeCommit}) async {
          beforeCommit?.call();
          localRecords = Map.from(records);
        },
        getGenerationOverride: () => 0,
      );
      await coordinator.store.load();

      // Device 1 writes setting A = 'apple'
      localRecords[syncRecordKey('setting', ['fruit'])] = {'value': 'apple'};
      await coordinator.store.capture(localRecords);

      // Device 2 writes setting A = 'banana'
      final doc2 = MergeDocument();
      doc2.captureLocal('device_remote', {}, {
        syncRecordKey('setting', ['fruit']): {'value': 'banana'},
      });

      // Merge doc2 into store
      coordinator.store.document.merge(doc2);

      expect(coordinator.hasConflict, isTrue);
      expect(coordinator.conflictCount, 1);
      final conflict = coordinator.conflicts.first;
      expect(conflict.field, 'value');
      expect(conflict.candidates, hasLength(2));

      final bananaCandidate = conflict.candidates.firstWhere(
        (c) => c.value == 'banana',
      );

      // Resolve choosing banana
      final resolveRes = await coordinator.resolveConflicts([
        MergeConflictResolution(
          recordKey: conflict.recordKey,
          field: conflict.field,
          candidateId: bananaCandidate.id,
        ),
      ], direction: SyncDirection.bidirectional);

      expect(resolveRes.success, isTrue);
      expect(coordinator.hasConflict, isFalse);
      expect(coordinator.conflictCount, 0);
      expect(localRecords[conflict.recordKey], {'value': 'banana'});
    });

    test(
      'downloadOnly direction merges remote checkpoints, resolves conflicts locally, but never uploads outbox',
      () async {
        appdata.implicitData['webdavSyncDirection'] = 'downloadOnly';

        // Remote publishes a checkpoint
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('device_cloud', {}, {
          syncRecordKey('setting', ['mode']): {'value': 'zen'},
        });
        final batch = MergeBatch.create(
          actor: 'device_cloud',
          counter: 1,
          document: remoteDoc,
        );
        final remote = MergeRemote(client);
        await remote.upload(batch);

        final sync = DataSync();
        final res = await sync.syncNow();

        expect(res.success, isTrue);
        expect(localRecords[syncRecordKey('setting', ['mode'])], {
          'value': 'zen',
        });
        // In downloadOnly, local outbox batches are never pushed
        expect(
          transport.remoteFiles.keys.where((k) => k.contains('test_device_1')),
          isEmpty,
        );
      },
    );

    test(
      'legacy migration reads seeds, merges into document, and enqueues full causal checkpoint',
      () async {
        final coordinator = MergeSyncCoordinator(
          endpointHash: 'hash_legacy',
          stateDirectory: Directory('${tempDir.path}/state_legacy'),
          actor: 'device_migrator',
          store: MergeStore(
            Directory('${tempDir.path}/state_legacy'),
            'device_migrator',
          ),
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async => localRecords,
          applyPreferencesOverride: (records, {beforeCommit}) async {
            beforeCommit?.call();
            localRecords = Map.from(records);
          },
          getGenerationOverride: () => 0,
        );
        await coordinator.store.load();

        // Marker initially absent
        final markerKey = 'legacyMigrationDone_hash_legacy';
        expect(appdata.implicitData[markerKey], isNull);

        // Perform migration (with empty legacy reader seeds)
        await coordinator.migrateLegacyIfNeeded();

        expect(appdata.implicitData[markerKey], isTrue);
      },
    );

    test(
      'corrupt or partial remote file does not block other valid checkpoints or actors',
      () async {
        final coordinator = MergeSyncCoordinator(
          endpointHash: 'hash_corrupt_test',
          stateDirectory: Directory('${tempDir.path}/state_corrupt'),
          actor: 'device_reader',
          store: MergeStore(
            Directory('${tempDir.path}/state_corrupt'),
            'device_reader',
          ),
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async => localRecords,
          applyPreferencesOverride: (records, {beforeCommit}) async {
            beforeCommit?.call();
            localRecords = Map.from(records);
          },
          getGenerationOverride: () => 0,
        );
        await coordinator.store.load();

        // 1. Upload a valid checkpoint for device_good
        final goodDoc = MergeDocument();
        goodDoc.captureLocal('device_good', {}, {
          syncRecordKey('setting', ['sound']): {'value': 'stereo'},
        });
        final goodBatch = MergeBatch.create(
          actor: 'device_good',
          counter: 1,
          document: goodDoc,
        );
        await coordinator.remote.upload(goodBatch);

        final badDoc = MergeDocument();
        badDoc.captureLocal('device_bad', {}, {
          syncRecordKey('setting', ['bad']): {'value': 'ignored'},
        });
        final badBatch = MergeBatch.create(
          actor: 'device_bad',
          counter: 1,
          document: badDoc,
        );
        final badFilename = await coordinator.remote.upload(badBatch);
        // Corrupt the v5 manifest after preserving its valid listed metadata.
        transport.remoteFiles[badFilename] = Uint8List.fromList(
          utf8.encode('{"corrupted": true'),
        );
        transport.remoteEtags[badFilename] = '"corrupted"';

        // 3. Perform sync
        final syncResult = await coordinator.performSync(
          direction: SyncDirection.bidirectional,
        );
        expect(syncResult.success, isTrue);

        // Good device record must be applied
        expect(localRecords[syncRecordKey('setting', ['sound'])], {
          'value': 'stereo',
        });
        // Bad file must NOT be marked received
        expect(coordinator.store.received.contains(badFilename), isFalse);
      },
    );

    test(
      'upload conflict triggers replacement checkpoint dominating intended batch',
      () async {
        final volumeKey = syncRecordKey('setting', ['volume']);
        localRecords[volumeKey] = {'value': 80};
        final coordinator = MergeSyncCoordinator(
          endpointHash: 'hash_conflict_rec',
          stateDirectory: Directory('${tempDir.path}/state_conflict_rec'),
          actor: 'device_conflicted',
          store: MergeStore(
            Directory('${tempDir.path}/state_conflict_rec'),
            'device_conflicted',
          ),
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async => localRecords,
          applyPreferencesOverride: (records, {beforeCommit}) async {
            beforeCommit?.call();
            localRecords = Map.from(records);
          },
          getGenerationOverride: () => 0,
        );
        await coordinator.store.load();

        // Stage an outbox batch
        await coordinator.store.capture({
          volumeKey: {'value': 80},
        });
        expect(coordinator.store.outbox, isNotEmpty);
        final initialBatch = coordinator.store.outbox.first;
        final snapshotDigest = SyncPackSnapshot.fromSnapshot(
          MergeSnapshot.fromBatch(initialBatch),
        ).digest;
        final targetRemotePath =
            'VeneraPlus/Device/commits/${initialBatch.counter}-$snapshotDigest.json';

        // Inject divergent content to simulate a 412 precondition conflict
        transport.remoteFiles[targetRemotePath] = Uint8List.fromList(
          utf8.encode('divergent content'),
        );

        final syncResult = await coordinator.performSync(
          direction: SyncDirection.uploadOnly,
        );
        expect(syncResult.success, isTrue);
        // All outbox batches (original + replacement) should be acknowledged
        expect(coordinator.store.outbox, isEmpty);
        final latestCandidates = await coordinator.remote.listLatest();
        final replacement = await coordinator.remote.downloadLatestValid(
          coordinator.actor,
          latestCandidates,
        );
        expect(replacement, isNotNull);
        final recovered = replacement!;
        expect(recovered.counter, greaterThan(initialBatch.counter));
        expect(recovered.document.dominates(initialBatch.document), isTrue);
        final recoveredRecords = recovered.document.materialize();
        expect(recoveredRecords[volumeKey], {'value': 80});
      },
    );

    test(
      'concurrent local edit during download preserves both candidates and does not overwrite remote with LWW',
      () async {
        int generation = 0;
        final comicKey = syncRecordKey('favorite', [
          'folder_1',
          'comic_123',
          '0',
        ]);

        // Device A starts with 'Original'
        localRecords = {
          comicKey: {'title': 'Original'},
        };

        // Remote has B's checkpoint with title: 'Bob'
        final docB = MergeDocument();
        docB.captureLocal('device_b', {}, {
          comicKey: {'title': 'Bob'},
        });
        final batchB = MergeBatch.create(
          actor: 'device_b',
          counter: 1,
          document: docB,
        );
        final remote = MergeRemote(client);
        await remote.upload(batchB);

        final coordinator = MergeSyncCoordinator(
          endpointHash: 'hash_concurrent_title',
          stateDirectory: Directory('${tempDir.path}/state_concurrent_title'),
          actor: 'device_a',
          store: MergeStore(
            Directory('${tempDir.path}/state_concurrent_title'),
            'device_a',
          ),
          remote: remote,
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async => localRecords,
          applyPreferencesOverride: (records, {beforeCommit}) async {
            beforeCommit?.call();
            localRecords = Map.from(records);
          },
          getGenerationOverride: () => generation,
        );
        await coordinator.store.load();
        await coordinator.store.capture(localRecords);

        // B's checkpoint returns from download, but BEFORE apply, user A edits title to 'Alice'
        transport.onDownloadHook = () {
          localRecords[comicKey] = {'title': 'Alice'};
          generation++;
        };

        final syncResult = await coordinator.performSync(
          direction: SyncDirection.bidirectional,
        );
        expect(syncResult.success, isTrue);

        // Title conflict must contain BOTH candidates ('Alice' and 'Bob')
        expect(coordinator.hasConflict, isTrue);
        final conflict = coordinator.conflicts.firstWhere(
          (c) => c.recordKey == comicKey && c.field == 'title',
        );
        expect(conflict.candidates, hasLength(2));
        final candidateValues = conflict.candidates.map((c) => c.value).toSet();
        expect(candidateValues, containsAll(['Alice', 'Bob']));
      },
    );
    test(
      'opt-out is invisible scope, not a credentials cloud deletion',
      () async {
        appdata.settings['backupWebdavSyncEnabled'] = false;
        final key = syncRecordKey('setting', ['backupWebdav']);
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('credentials_owner', {}, {
          key: {
            'value': ['https://backup.invalid', 'user', 'secret'],
          },
        });
        final remote = MergeRemote(client);
        await remote.upload(
          MergeBatch.create(
            actor: 'credentials_owner',
            counter: 1,
            document: remoteDoc,
          ),
        );
        final adapter = SyncPreferencesAdapter(dataPath: tempDir.path);
        DataSync.debugApplyRecords = (records, {beforeCommit}) async {
          beforeCommit?.call();
          localRecords = adapter.projectRecordsForLocalPolicy(records);
        };
        final sync = DataSync();
        expect((await sync.syncNow()).success, isTrue);
        expect(localRecords.containsKey(key), isFalse);
        expect((await sync.syncNow()).success, isTrue);
        expect(
          sync.coordinator!.store.document.materialize()[key],
          remoteDoc.materialize()[key],
        );
        expect(
          sync.conflicts.where((conflict) => conflict.recordKey == key),
          isEmpty,
        );
      },
    );

    test(
      'policy changed after observation never creates an excluded tombstone',
      () async {
        final key = syncRecordKey('setting', ['theme']);
        final sync = DataSync();
        await sync.waitForStartupMerge();
        appdata.settings['disableSyncFields'] = 'theme';
        localRecords.remove(key);
        expect((await sync.uploadData()).success, isTrue);
        expect(sync.coordinator!.store.document.materialize()[key], {
          'value': 'dark',
        });
      },
    );

    test(
      'settings and save entrance notify before staging can commit',
      () async {
        final sync = DataSync();
        await sync.waitForStartupMerge();
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('cloud_device', {}, {
          syncRecordKey('search', ['cloud']): {'order': 1},
        });
        await MergeRemote(client).upload(
          MergeBatch.create(
            actor: 'cloud_device',
            counter: 1,
            document: remoteDoc,
          ),
        );
        var intercepted = false;
        sync.coordinator!.applyPreferencesOverride =
            (records, {beforeCommit}) async {
              if (!intercepted) {
                intercepted = true;
                Zone.root.run(() {
                  appdata.settings['comicTileScale'] = 1.1;
                  localRecords[syncRecordKey('setting', ['comicTileScale'])] = {
                    'value': 1.1,
                  };
                  localRecords[syncRecordKey('search', ['new input'])] = {
                    'order': 0,
                  };
                  unawaited(appdata.saveData());
                });
              }
              beforeCommit?.call();
              localRecords = cloneSyncRecords(records);
            };
        expect((await sync.syncNow()).success, isTrue);
        expect(localRecords[syncRecordKey('setting', ['comicTileScale'])], {
          'value': 1.1,
        });
        expect(localRecords, contains(syncRecordKey('search', ['new input'])));
        expect(sync.coordinator!.store.pendingApply, isNull);
      },
    );

    test(
      'concurrent startup reloads a stale capture and preserves both devices intents across restart',
      () async {
        const actor = 'recovery_writer';
        final stateDir = Directory('${tempDir.path}/recovery_writer');
        final themeKey = syncRecordKey('setting', ['theme']);
        final queuedKey = syncRecordKey('search', ['durable queued search']);
        final exportStarted = Completer<void>();
        final releaseExport = Completer<void>();
        var interrupted = false;
        localRecords = {
          themeKey: {'value': 'dark'},
        };
        late MergeDocument priorIntent;
        final coordinator = MergeSyncCoordinator(
          endpointHash: 'recovery_writer',
          stateDirectory: stateDir,
          actor: actor,
          store: MergeStore(stateDir, actor),
          remote: MergeRemote(client, deviceName: 'Recovery Writer'),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async {
            if (!interrupted) {
              interrupted = true;
              exportStarted.complete();
              await releaseExport.future;
              final writer = MergeStore(stateDir, actor);
              await writer.load();
              await writer.capture({
                queuedKey: {'order': 0},
              });
              priorIntent = writer
                  .pendingBatch(writer.pendingBatchIds.single)
                  .document;
              localRecords[queuedKey] = {'order': 0};
            }
            return cloneSyncRecords(localRecords);
          },
          applyPreferencesOverride: (records, {beforeCommit}) async {
            beforeCommit?.call();
            localRecords = cloneSyncRecords(records);
          },
          getGenerationOverride: () => 0,
        );
        final first = coordinator.startupRecovery();
        await exportStarted.future;
        final overlapping = coordinator.startupRecovery();
        releaseExport.complete();
        await Future.wait([first, overlapping]);
        expect(coordinator.store.document.counterFor(actor), 2);
        expect(coordinator.store.observed, {
          themeKey: {'value': 'dark'},
          queuedKey: {'order': 0},
        });
        final queuedId = coordinator.store.pendingBatchIds.single;
        expect(
          coordinator.store
              .pendingBatch(queuedId)
              .document
              .dominates(priorIntent),
          isTrue,
        );
        await coordinator.startupRecovery();
        await coordinator.captureLocalChanges();
        expect(coordinator.store.pendingBatchIds, [queuedId]);
        expect(coordinator.store.document.counterFor(actor), 2);
        expect(
          (await coordinator.performSync(
            direction: SyncDirection.uploadOnly,
          )).success,
          isTrue,
        );

        final readerDir = Directory('${tempDir.path}/recovery_reader');
        var readerRecords = <String, Map<String, Object?>>{
          themeKey: {'value': 'other device edit'},
        };
        MergeSyncCoordinator makeReader() => MergeSyncCoordinator(
          endpointHash: 'recovery_reader',
          stateDirectory: readerDir,
          actor: 'recovery_reader',
          store: MergeStore(readerDir, 'recovery_reader'),
          remote: MergeRemote(client, deviceName: 'Recovery Reader'),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async =>
              cloneSyncRecords(readerRecords),
          applyPreferencesOverride: (records, {beforeCommit}) async {
            beforeCommit?.call();
            readerRecords = cloneSyncRecords(records);
          },
          getGenerationOverride: () => 0,
        );
        var reader = makeReader();
        await reader.startupRecovery();
        expect(
          (await reader.performSync(
            direction: SyncDirection.downloadOnly,
          )).success,
          isTrue,
        );
        expect(readerRecords[queuedKey], {'order': 0});
        reader = makeReader();
        await reader.startupRecovery();
        final themeConflict = reader.conflicts.firstWhere(
          (conflict) => conflict.recordKey == themeKey,
        );
        expect(
          themeConflict.candidates.map((candidate) => candidate.value),
          containsAll(['dark', 'other device edit']),
        );
        expect(reader.store.document.dominates(priorIntent), isTrue);
      },
    );

    for (final failure in ['missing', 'corrupt', 'http']) {
      test(
        'backup recovery retains pending intent and verification obligation after $failure Pack and restart',
        () async {
          const actor = 'backup_recovery_device';
          final stateDir = Directory(
            '${tempDir.path}/backup_recovery_$failure',
          );
          final localKey = syncRecordKey('setting', ['theme']);
          final remoteKey = syncRecordKey('search', ['own remote search']);
          localRecords = {
            localKey: {'value': 'durable local edit'},
          };
          final original = MergeStore(stateDir, actor);
          await original.load();
          await original.capture(localRecords);
          final originalId = original.pendingBatchIds.single;
          final originalIntent = original.pendingBatch(originalId).document;
          final remote = MergeRemote(client, deviceName: 'Backup Recovery');
          final earlier = originalIntent.clone()..setCounterFloor(actor, 5);
          final earlierPath = await remote.upload(
            MergeBatch.create(actor: actor, counter: 5, document: earlier),
          );
          final newest = originalIntent.clone()..setCounterFloor(actor, 12);
          newest.captureLocal(actor, localRecords, {
            ...localRecords,
            remoteKey: {'order': 0},
          });
          final newestPath = await remote.upload(
            MergeBatch.create(actor: actor, counter: 13, document: newest),
          );
          final earlierManifest = SyncPackManifest.parse(
            transport.remoteFiles[earlierPath]!,
          );
          final newestManifest = SyncPackManifest.parse(
            transport.remoteFiles[newestPath]!,
          );
          final packDigest = newestManifest.packs.keys.firstWhere(
            (digest) => !earlierManifest.packs.containsKey(digest),
          );
          final packPath =
              '${newestPath.substring(0, newestPath.indexOf('/commits/'))}'
              '/packs/$packDigest.pack';
          final intactPack = transport.remoteFiles[packPath]!;
          switch (failure) {
            case 'missing':
              transport.remoteFiles.remove(packPath);
            case 'corrupt':
              final broken = Uint8List.fromList(intactPack);
              broken[broken.length ~/ 2] ^= 0xff;
              transport.remoteFiles[packPath] = broken;
            case 'http':
              transport.downloadFailureStatuses[packPath] = 500;
          }
          await File(
            '${stateDir.path}/merge_store.sqlite3',
          ).writeAsString('CORRUPT_PRIMARY_FOR_RECOVERY');
          MergeSyncCoordinator makeCoordinator() => MergeSyncCoordinator(
            endpointHash: 'backup_recovery_$failure',
            stateDirectory: stateDir,
            actor: actor,
            store: MergeStore(stateDir, actor),
            remote: remote,
            exportFavoritesOverride: () => {},
            exportHistoryOverride: () async => {},
            applyFavoritesOverride: (_) {},
            applyHistoryOverride: (_) {},
            exportPreferencesOverride: () async =>
                cloneSyncRecords(localRecords),
            applyPreferencesOverride: (records, {beforeCommit}) async {
              beforeCommit?.call();
              localRecords = cloneSyncRecords(records);
            },
            getGenerationOverride: () => 0,
          );
          var coordinator = makeCoordinator();
          await expectLater(
            coordinator.startupRecovery(),
            throwsA(isA<MergeStoreRemoteRecoveryException>()),
          );
          expect(coordinator.store.document.counterFor(actor), 1);
          expect(coordinator.store.pendingBatchIds, [originalId]);
          expect(coordinator.store.received, isEmpty);
          final afterFailure = MergeStore(stateDir, actor);
          await afterFailure.load();
          expect(afterFailure.recoveredFromBackup, isTrue);
          await expectLater(
            afterFailure.capture(localRecords),
            throwsStateError,
          );
          expect(afterFailure.pendingBatchIds, [originalId]);
          expect(
            afterFailure.pendingBatch(originalId).document.toJson(),
            originalIntent.toJson(),
          );
          transport.remoteFiles[packPath] = intactPack;
          transport.downloadFailureStatuses.clear();
          localRecords[localKey] = {'value': 'new physical user edit'};
          coordinator = makeCoordinator();
          await coordinator.startupRecovery();
          expect(coordinator.store.document.counterFor(actor), 14);
          expect(coordinator.store.observed[localKey], {
            'value': 'new physical user edit',
          });
          final replacementId = coordinator.store.pendingBatchIds.single;
          expect(
            coordinator.store
                .pendingBatch(replacementId)
                .document
                .dominates(originalIntent),
            isTrue,
          );
          expect(coordinator.store.document.materialize()[remoteKey], {
            'order': 0,
          });
          await coordinator.startupRecovery();
          expect(coordinator.store.pendingBatchIds, [replacementId]);
          final verifiedRestart = MergeStore(stateDir, actor);
          await verifiedRestart.load();
          expect(verifiedRestart.recoveredFromBackup, isFalse);
          expect(verifiedRestart.document.counterFor(actor), 14);
        },
      );
    }

    for (final artifact in ['legacy', 'sqlite']) {
      test(
        '$artifact startup corruption fails safely without changing local intent',
        () async {
          final hash = MergeSyncCoordinator.computeEndpointHash(
            'https://example.com/dav',
            'user',
          );
          final directory = Directory('${tempDir.path}/sync_state_$hash');
          directory.createSync(recursive: true);
          final damagedFiles = artifact == 'legacy'
              ? [File('${directory.path}/state.json')]
              : [
                  File('${directory.path}/merge_store.sqlite3'),
                  File('${directory.path}/merge_store.sqlite3.bak'),
                ];
          for (final file in damagedFiles) {
            file.writeAsStringSync('PRIVATE-SYNC-STATE', flush: true);
          }
          final before = cloneSyncRecords(localRecords);
          final sync = DataSync();
          await expectLater(
            sync.waitForStartupMerge(),
            throwsA(isA<MergeStoreIntegrityException>()),
          );
          expect(sync.isReady, isFalse);
          expect(sync.lastError, startsWith('SYNC_STATE_INVALID:'));
          expect(sync.lastError, isNot(contains('PRIVATE-SYNC-STATE')));
          expect((await sync.syncNow()).error, isTrue);
          expect(localRecords, before);
          for (final file in damagedFiles) {
            expect(file.readAsStringSync(), 'PRIVATE-SYNC-STATE');
          }
          expect(
            transport.requests.where((request) => request.method == 'PUT'),
            isEmpty,
          );
        },
      );
    }
    test(
      'initial exporter failure rejects tasks while persistent, recovers after fix without reset',
      () async {
        var failExport = true;
        DataSync.debugExportRecords = () async {
          if (failExport) {
            throw StateError('Simulated exporter failure');
          }
          return Map.from(localRecords);
        };

        final sync = DataSync();
        await expectLater(sync.waitForStartupMerge(), throwsStateError);
        expect(sync.isReady, isFalse);
        expect(sync.lastError, contains('Simulated exporter failure'));
        expect(
          sync.statusSnapshot.lastError,
          contains('Simulated exporter failure'),
        );

        final rejectedResult = await sync.syncNow();
        expect(rejectedResult.error, isTrue);
        expect(
          rejectedResult.errorMessage,
          contains('Simulated exporter failure'),
        );
        expect(sync.isReady, isFalse);
        expect(sync.lastError, contains('Simulated exporter failure'));
        expect(
          sync.statusSnapshot.lastError,
          contains('Simulated exporter failure'),
        );
        expect(
          transport.requests.where((request) => request.method == 'PUT'),
          isEmpty,
        );

        failExport = false;

        final recoveredResult = await sync.syncNow();
        expect(recoveredResult.success, isTrue);
        expect(sync.isReady, isTrue);
        expect(sync.lastError, isNull);
        expect(sync.statusSnapshot.lastError, isNull);
        expect(sync.hasConflict, isFalse);
        expect(
          transport.requests.where((request) => request.method == 'PUT'),
          isNotEmpty,
        );
        final remote = MergeRemote(client);
        final published = MergeDocument();
        for (final entry in await remote.list()) {
          published.merge((await remote.download(entry)).document);
        }
        expect(published.materialize(), localRecords);
        await expectLater(sync.waitForStartupMerge(), completes);
      },
    );

    test(
      'invalid endpoint state leaves old configuration and business intact',
      () async {
        final sync = DataSync();
        await sync.waitForStartupMerge();
        final oldConfig = List<String>.from(appdata.settings['webdav']);
        final before = cloneSyncRecords(localRecords);
        final hash = MergeSyncCoordinator.computeEndpointHash(
          'https://new.invalid/dav',
          'other',
        );
        final directory = Directory('${tempDir.path}/sync_state_$hash');
        directory.createSync(recursive: true);
        File('${directory.path}/state.json').writeAsStringSync('{}');
        final result = await sync.configure(
          config: ['https://new.invalid/dav', 'other', 'password'],
          excludedFields: 'theme',
          direction: SyncDirection.bidirectional,
          timing: SyncTiming.realtime,
          minutes: 30,
        );
        expect(result.error, isTrue);
        expect(appdata.settings['webdav'], oldConfig);
        expect(localRecords, before);
        expect(sync.coordinator!.endpointHash, isNot(hash));
      },
    );

    test('actor identity is durable before it is returned', () async {
      appdata.implicitData.remove('syncDeviceId');
      final actor = await MergeSyncCoordinator.getOrCreateActorId();
      final json =
          jsonDecode(
                await File('${tempDir.path}/implicitData.json').readAsString(),
              )
              as Map;
      expect(json['syncDeviceId'], actor);
    });

    test('legacy read failure cannot mark migration complete', () async {
      final sync = DataSync();
      await sync.waitForStartupMerge();
      client.readDirFailure = StateError('legacy listing failed');
      await expectLater(
        sync.coordinator!.migrateLegacyIfNeeded(),
        throwsStateError,
      );
      final key = 'legacyMigrationDone_${sync.coordinator!.endpointHash}';
      expect(appdata.implicitData[key], isNot(true));
    });

    test(
      'configuration success and publication failure are separate outcomes',
      () async {
        final sync = DataSync();
        await sync.waitForStartupMerge();
        DataSync.debugSyncOverride = () async =>
            const Res.error('publish failed');
        final config = ['https://new.invalid/dav', 'other', 'password'];
        final configured = await sync.configure(
          config: config,
          excludedFields: '',
          direction: SyncDirection.bidirectional,
          timing: SyncTiming.realtime,
          minutes: 30,
        );
        expect(configured.success, isTrue);
        expect((await sync.waitForSync()).error, isTrue);
        expect(appdata.settings['webdav'], config);
        expect(sync.lastError, 'publish failed');
      },
    );

    test(
      'asynchronous export retries rather than adopting an ending generation',
      () async {
        final sync = DataSync();
        await sync.waitForStartupMerge();
        final key = syncRecordKey('search', ['during export']);
        var intercepted = false;
        var exports = 0;
        sync.coordinator!.exportPreferencesOverride = () async {
          exports++;
          final snapshot = cloneSyncRecords(localRecords);
          if (!intercepted) {
            intercepted = true;
            Zone.root.run(() {
              localRecords[key] = {'order': 0};
              sync.onDataChanged();
            });
            await Future<void>.delayed(Duration.zero);
          }
          return snapshot;
        };
        expect((await sync.uploadData()).success, isTrue);
        expect(exports, greaterThanOrEqualTo(2));
        expect(sync.coordinator!.store.document.materialize(), contains(key));
      },
    );

    test(
      'repeated staging edits abort explicitly without a stale apply target',
      () async {
        final sync = DataSync();
        await sync.waitForStartupMerge();
        final cloud = MergeDocument();
        cloud.captureLocal('cloud', {}, {
          syncRecordKey('search', ['cloud']): {'order': 0},
        });
        await MergeRemote(client).upload(
          MergeBatch.create(actor: 'cloud', counter: 1, document: cloud),
        );
        var attempts = 0;
        sync.coordinator!.applyPreferencesOverride =
            (records, {beforeCommit}) async {
              Zone.root.run(() {
                attempts++;
                localRecords[syncRecordKey('search', ['edit $attempts'])] = {
                  'order': attempts,
                };
                sync.onDataChanged();
              });
              beforeCommit?.call();
              fail('A stale guard must never reach business commit');
            };
        expect((await sync.syncNow()).error, isTrue);
        expect(attempts, 16);
        expect(sync.coordinator!.store.pendingApply, isNull);
        final reopened = MergeStore(
          sync.coordinator!.stateDirectory,
          sync.coordinator!.actor,
        );
        await reopened.load();
        expect(reopened.pendingApply, isNull);
      },
    );

    test(
      'first upload-only publishes legacy seeds without importing business data',
      () async {
        final bytes = utf8.encode(
          jsonEncode({
            'settings': {'theme': 'legacy'},
            'searchHistory': ['legacy-only'],
          }),
        );
        final archive = Archive()
          ..addFile(ArchiveFile('appdata.json', bytes.length, bytes));
        transport.remoteFiles['100-1.venera'] = Uint8List.fromList(
          ZipEncoder().encode(archive),
        );
        final before = cloneSyncRecords(localRecords);
        final sync = DataSync();
        expect((await sync.uploadData()).success, isTrue);
        expect(localRecords, before);
        final published = await MergeRemote(client).list();
        final cloud = MergeDocument();
        for (final entry in published) {
          cloud.merge((await MergeRemote(client).download(entry)).document);
        }
        final cloudRecords = cloud.materialize();
        expect(cloudRecords[syncRecordKey('search', ['legacy-only'])], {
          'order': 0,
        });
        expect(transport.remoteFiles, contains('100-1.venera'));
      },
    );
    test(
      'selected root backup is listed, merged once, and never rewritten',
      () async {
        Uint8List backupBytes(String searchTerm) {
          final bytes = utf8.encode(
            jsonEncode({
              'settings': <String, Object?>{},
              'searchHistory': [searchTerm],
            }),
          );
          final archive = Archive()
            ..addFile(ArchiveFile('appdata.json', bytes.length, bytes));
          return Uint8List.fromList(ZipEncoder().encode(archive));
        }

        final selectedBytes = backupBytes('selected-only');
        final newerBytes = backupBytes('newer-not-selected');
        final selectedSnapshot = Uint8List.fromList(selectedBytes);
        final newerSnapshot = Uint8List.fromList(newerBytes);
        transport.remoteFiles
          ..['100-1.venera'] = selectedBytes
          ..['101-2.venera'] = newerBytes;
        appdata.implicitData['webdavSyncDirection'] = 'uploadOnly';
        final before = cloneSyncRecords(localRecords);
        final sync = DataSync();
        await sync.waitForStartupMerge();

        final backups = await sync.listLegacyBackups();
        expect(backups.map((backup) => backup.name).toList(), [
          '101-2.venera',
          '100-1.venera',
        ]);
        final markerKey =
            'legacyMigrationDone_${sync.coordinator!.endpointHash}';
        expect(appdata.implicitData[markerKey], isNull);

        final firstImport = await sync.importLegacyBackup('100-1.venera');
        expect(firstImport.data, isTrue);
        expect(firstImport.success, isTrue, reason: firstImport.errorMessage);
        expect(localRecords, before);
        final selectedKey = syncRecordKey('search', ['selected-only']);
        final newerKey = syncRecordKey('search', ['newer-not-selected']);
        final store = sync.coordinator!.store;
        expect(store.document.materialize(), contains(selectedKey));
        expect(store.document.materialize(), isNot(contains(newerKey)));
        Map<String, int> seedCounters() => Map.fromEntries(
          store.document.vclock.entries.where(
            (entry) => entry.key.startsWith('legacy_seed_'),
          ),
        );
        final initialSeedCounters = seedCounters();
        expect(initialSeedCounters, isNotEmpty);
        final commitPaths = transport.remoteFiles.keys
            .where((path) => path.contains('/commits/'))
            .toSet();

        final causalState = store.document.toJson();
        transport.requests.clear();
        final duplicateImport = await sync.importLegacyBackup('100-1.venera');
        expect(
          duplicateImport.success,
          isTrue,
          reason: duplicateImport.errorMessage,
        );
        expect(duplicateImport.data, isFalse);
        expect(store.document.toJson(), causalState);
        expect(seedCounters(), initialSeedCounters);
        expect(
          transport.remoteFiles.keys
              .where((path) => path.contains('/commits/'))
              .toSet(),
          commitPaths,
        );
        expect(
          transport.requests.where((request) => request.method == 'PUT'),
          isEmpty,
        );
        expect(
          transport.remoteFiles['100-1.venera'],
          orderedEquals(selectedSnapshot),
        );
        expect(
          transport.remoteFiles['101-2.venera'],
          orderedEquals(newerSnapshot),
        );
        expect(appdata.implicitData[markerKey], isNull);
      },
    );

    test(
      'selected root backup applies locally in downloadOnly without PUT',
      () async {
        final bytes = utf8.encode(
          jsonEncode({
            'settings': <String, Object?>{},
            'searchHistory': ['download-only-root-seed'],
          }),
        );
        final archive = Archive()
          ..addFile(ArchiveFile('appdata.json', bytes.length, bytes));
        final backupBytes = Uint8List.fromList(ZipEncoder().encode(archive));
        transport.remoteFiles['100-1.venera'] = backupBytes;
        final backupSnapshot = Uint8List.fromList(backupBytes);
        appdata.implicitData['webdavSyncDirection'] = 'downloadOnly';
        final sync = DataSync();
        await sync.waitForStartupMerge();

        final result = await sync.importLegacyBackup('100-1.venera');

        expect(result.success, isTrue, reason: result.errorMessage);
        expect(
          localRecords,
          contains(syncRecordKey('search', ['download-only-root-seed'])),
        );
        expect(sync.coordinator!.store.outbox, isNotEmpty);
        expect(
          transport.requests.where((request) => request.method == 'PUT'),
          isEmpty,
        );
        expect(
          transport.remoteFiles['100-1.venera'],
          orderedEquals(backupSnapshot),
        );
      },
    );

    test(
      'restart local edits never observe downloaded but unapplied metadata',
      () async {
        final hash = MergeSyncCoordinator.computeEndpointHash(
          'https://example.com/dav',
          'user',
        );
        final directory = Directory('${tempDir.path}/sync_state_$hash');
        final key = syncRecordKey('setting', ['theme']);
        localRecords = {
          key: {'value': 'Original'},
        };
        final store = MergeStore(directory, 'test_device_1');
        await store.load();
        await store.capture(localRecords);
        final cloud = MergeDocument();
        cloud.captureLocal('other_device', {}, {
          key: {'value': 'Bob'},
        });
        store.document.merge(cloud);
        await store.markReceived('downloaded_checkpoint.json');
        // A crash before stageApply, followed by a real local edit.
        localRecords[key] = {'value': 'Alice'};
        final sync = DataSync();
        await sync.waitForStartupMerge();
        final values = sync.conflicts
            .firstWhere((conflict) => conflict.recordKey == key)
            .candidates
            .map((candidate) => candidate.value);
        expect(values, containsAll(['Alice', 'Bob']));
        expect(localRecords[key], {'value': 'Alice'});
      },
    );

    test(
      'multi-device sync with incomplete sources syncs favorites/history without deleting sources',
      () async {
        final favKey = syncRecordKey('folder', ['shared_fav']);
        final histKey = syncRecordKey('history', ['shared_comic']);
        final sourceKey = syncRecordKey('source', ['device_b_source']);

        // Device B publishes favorites, history, and a comic source
        final dirB = Directory('${tempDir.path}/state_device_b');
        final storeB = MergeStore(dirB, 'device_b');
        await storeB.load();
        await storeB.capture({
          favKey: {'name': 'Shared Favorites from B'},
          histKey: {'readDurationMs': 5000},
          sourceKey: {
            'script': {
              'filename': 'b_plugin.js',
              'content': 'console.log("b");',
            },
          },
        });
        final coordinatorB = MergeSyncCoordinator(
          endpointHash: 'hash_multidevice',
          stateDirectory: dirB,
          actor: 'device_b',
          store: storeB,
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {
            favKey: {'name': 'Shared Favorites from B'},
          },
          exportHistoryOverride: () async => {
            histKey: {'readDurationMs': 5000},
          },
          exportPreferencesOverride: () async => {
            sourceKey: {
              'script': {
                'filename': 'b_plugin.js',
                'content': 'console.log("b");',
              },
            },
          },
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          applyPreferencesOverride: (_, {beforeCommit}) async =>
              beforeCommit?.call(),
          getGenerationOverride: () => 0,
        );
        await coordinatorB.performSync(direction: SyncDirection.uploadOnly);

        // Device A (has missing/corrupted source; source domain unavailable)
        final dirA = Directory('${tempDir.path}/state_device_a');
        final storeA = MergeStore(dirA, 'device_a');
        await storeA.load();
        final localFavA = syncRecordKey('folder', ['fav_a']);
        final appliedOnA = <String, Map<String, Object?>>{};

        final coordinatorA = MergeSyncCoordinator(
          endpointHash: 'hash_multidevice',
          stateDirectory: dirA,
          actor: 'device_a',
          store: storeA,
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {
            localFavA: {'name': 'Fav A'},
          },
          exportHistoryOverride: () async => {},
          exportPreferencesOverride: () async => {
            // Device A returns empty sources
          },
          applyFavoritesOverride: (recs) {
            appliedOnA.addAll(recs);
          },
          applyHistoryOverride: (recs) {
            appliedOnA.addAll(recs);
          },
          applyPreferencesOverride: (recs, {beforeCommit}) async =>
              beforeCommit?.call(),
          getGenerationOverride: () => 0,
        );

        final resultA = await coordinatorA.performSync(
          direction: SyncDirection.bidirectional,
        );
        expect(resultA.success, isTrue);

        // Device A applied Favorites and History from Device B
        expect(appliedOnA.containsKey(favKey), isTrue);
        expect(appliedOnA.containsKey(histKey), isTrue);

        // Now Device B syncs again: Device A's sync did NOT cause Device B's source to be deleted
        await coordinatorB.performSync(direction: SyncDirection.bidirectional);
        expect(
          storeB.document.hasObservedFieldValue(sourceKey, 'script', {
            'filename': 'b_plugin.js',
            'content': 'console.log("b");',
          }),
          isTrue,
        );
      },
    );

    test(
      'explicit root imports clear only repaired archive source issues',
      () async {
        Uint8List backupBytes(String sessionFile) {
          final appdataBytes = utf8.encode(
            jsonEncode({
              'settings': <String, Object?>{},
              'searchHistory': <String>[],
            }),
          );
          final invalidSession = utf8.encode('{invalid session');
          final archive = Archive()
            ..addFile(
              ArchiveFile('appdata.json', appdataBytes.length, appdataBytes),
            )
            ..addFile(
              ArchiveFile(
                'comic_source/$sessionFile',
                invalidSession.length,
                invalidSession,
              ),
            );
          return Uint8List.fromList(ZipEncoder().encode(archive));
        }

        final selectedBytes = backupBytes('selected_source.data');
        final otherBytes = backupBytes('other_source.data');
        transport.remoteFiles
          ..['100-1.venera'] = selectedBytes
          ..['101-1.venera'] = otherBytes;
        final stateDir = Directory('${tempDir.path}/state_legacy_domain');
        final coordinator = MergeSyncCoordinator(
          endpointHash: 'hash_legacy_partial',
          stateDirectory: stateDir,
          actor: 'device_partial_migrator',
          store: MergeStore(stateDir, 'device_partial_migrator'),
          remote: MergeRemote(client),
          exportFavoritesOverride: () => {},
          exportHistoryOverride: () async => {},
          applyFavoritesOverride: (_) {},
          applyHistoryOverride: (_) {},
          exportPreferencesOverride: () async => {},
          applyPreferencesOverride: (records, {beforeCommit}) async =>
              beforeCommit?.call(),
          getGenerationOverride: () => 0,
        );
        await coordinator.store.load();
        await coordinator.startupRecovery();

        final markerKey = 'legacyMigrationDone_hash_legacy_partial';
        expect(await coordinator.migrateLegacyIfNeeded(), isFalse);
        expect(
          coordinator.sourceIssues.map((issue) => issue.archiveName),
          containsAll(['100-1.venera', '101-1.venera']),
        );
        expect(coordinator.unavailableDomains, contains('sourceSession'));
        expect(appdata.implicitData[markerKey], isNull);

        final selectedSha = sha256.convert(selectedBytes).toString();
        await LegacySyncReader.registerLegacyOverride(
          overrideDirectory: Directory('${stateDir.path}/legacy_overrides'),
          archiveSha256: selectedSha,
          entryFilename: 'selected_source.data',
          replacementContent: '{"session":"selected repair"}',
          expectedKey: 'selected_source',
        );
        expect(
          await coordinator.migrateLegacyIfNeeded(backupName: '100-1.venera'),
          isTrue,
        );
        expect(coordinator.sourceIssues.map((issue) => issue.archiveName), [
          '101-1.venera',
        ]);
        expect(coordinator.unavailableDomains, contains('sourceSession'));
        final selectedActor = 'legacy_seed_${selectedSha}_sourceSession';
        final selectedSessionKey = syncRecordKey('sourceSession', [
          'selected_source',
        ]);
        expect(
          coordinator.store.document.counterFor(selectedActor),
          greaterThan(0),
        );
        expect(
          coordinator.store.document.materialize(),
          contains(selectedSessionKey),
        );

        final otherSha = sha256.convert(otherBytes).toString();
        await LegacySyncReader.registerLegacyOverride(
          overrideDirectory: Directory('${stateDir.path}/legacy_overrides'),
          archiveSha256: otherSha,
          entryFilename: 'other_source.data',
          replacementContent: '{"session":"other repair"}',
          expectedKey: 'other_source',
        );
        expect(
          await coordinator.migrateLegacyIfNeeded(backupName: '101-1.venera'),
          isTrue,
        );
        expect(coordinator.sourceIssues, isEmpty);
        expect(coordinator.unavailableDomains, isEmpty);
        final otherActor = 'legacy_seed_${otherSha}_sourceSession';
        expect(
          coordinator.store.document.counterFor(otherActor),
          greaterThan(0),
        );
        expect(appdata.implicitData[markerKey], isNull);
        expect(
          transport.remoteFiles['100-1.venera'],
          orderedEquals(selectedBytes),
        );
        expect(
          transport.remoteFiles['101-1.venera'],
          orderedEquals(otherBytes),
        );
      },
    );
  });
}

class _VirtualDavClient extends dav.Client {
  _VirtualDavClient(this.transport)
    : super(
        uri: 'https://example.com/dav/',
        c: dav.WdDio(httpAdapter: transport),
        auth: dav.Auth(user: 'user', pwd: 'pass'),
      );

  final _VirtualWebDavTransport transport;
  final directoryReads = <String>[];
  Object? readDirFailure;
  Object? pingFailure;

  @override
  Future<void> ping([CancelToken? cancelToken]) async {
    if (pingFailure != null) throw pingFailure!;
  }

  @override
  Future<void> mkdirAll(String path, [CancelToken? cancelToken]) async {
    transport.remoteDirs.add(path);
  }

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async {
    final cleanPath = path.trim().replaceAll('\\', '/');
    directoryReads.add(cleanPath);
    if (readDirFailure != null) throw readDirFailure!;
    final prefix = (cleanPath == '/' || cleanPath.isEmpty) ? '' : '$cleanPath/';

    final files = <dav.File>[];
    final childDirectories = <String>{};
    for (final key in {
      ...transport.remoteDirs,
      ...transport.remoteFiles.keys,
    }) {
      if (!key.startsWith(prefix)) continue;
      final relative = key.substring(prefix.length);
      final separator = relative.indexOf('/');
      if (separator > 0) {
        childDirectories.add(relative.substring(0, separator));
      } else if (relative.isNotEmpty && transport.remoteDirs.contains(key)) {
        childDirectories.add(relative);
      }
    }
    for (final name in childDirectories) {
      files.add(dav.File(name: name, path: '/$prefix$name', isDir: true));
    }
    for (final entry in transport.remoteFiles.entries) {
      final key = entry.key;
      if (prefix.isEmpty || key.startsWith(prefix)) {
        final leaf = prefix.isEmpty ? key : key.substring(prefix.length);
        if (!leaf.contains('/')) {
          files.add(
            dav.File(
              name: leaf,
              path: '/$key',
              isDir: false,
              size: entry.value.length,
              eTag: transport.remoteEtags[key] ?? '"${entry.value.length}"',
            ),
          );
        }
      }
    }
    return files;
  }
}

class _VirtualWebDavTransport implements HttpClientAdapter {
  final remoteFiles = <String, Uint8List>{};
  final remoteEtags = <String, String>{};
  final remoteDirs = <String>{};
  final simulateFailurePaths = <String>{};
  final downloadFailureStatuses = <String, int>{};
  final requests = <RequestOptions>[];
  void Function()? onDownloadHook;
  void Function(String path)? onPutHook;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = Uri.decodeComponent(
      options.uri.path,
    ).replaceFirst(RegExp(r'^/dav/?'), '');

    if (options.method == 'OPTIONS' || options.method == 'HEAD') {
      return ResponseBody.fromString('', 200);
    }

    if (options.method == 'MKCOL') {
      remoteDirs.add(path);
      return ResponseBody.fromString('', 201);
    }

    if (options.method == 'PUT' && simulateFailurePaths.contains(path)) {
      await requestStream?.drain<void>();
      return ResponseBody.fromString('Server Error', 500);
    }
    if (options.method == 'PUT') {
      final existing = remoteFiles[path];
      if (existing != null && options.headers['If-None-Match'] == '*') {
        return ResponseBody.fromString('Precondition Failed', 412);
      }
      final expectedEtag = options.headers['If-Match'];
      if (expectedEtag != null && expectedEtag != remoteEtags[path]) {
        return ResponseBody.fromString('Precondition Failed', 412);
      }
      final bytesBuilder = BytesBuilder();
      if (requestStream != null) {
        await for (final chunk in requestStream) {
          bytesBuilder.add(chunk);
        }
      } else if (options.data is List<int>) {
        bytesBuilder.add(options.data as List<int>);
      } else if (options.data is Stream<List<int>>) {
        await for (final chunk in (options.data as Stream<List<int>>)) {
          bytesBuilder.add(chunk);
        }
      }
      final bytes = bytesBuilder.toBytes();
      final etag = '"${sha256.convert(bytes)}"';
      remoteFiles[path] = bytes;
      remoteEtags[path] = etag;
      onPutHook?.call(path);
      return ResponseBody.fromString(
        '',
        201,
        headers: {
          'etag': [etag],
        },
      );
    }

    if (options.method == 'GET') {
      final failureStatus = downloadFailureStatuses[path];
      if (failureStatus != null) {
        return ResponseBody.fromString('Download failure', failureStatus);
      }
      onDownloadHook?.call();
      final fileBytes = remoteFiles[path];
      if (fileBytes != null) {
        final etag = remoteEtags[path] ?? '"${fileBytes.length}"';
        return ResponseBody.fromBytes(
          fileBytes,
          200,
          headers: {
            'etag': [etag],
          },
        );
      }
      return ResponseBody.fromString('Not Found', 404);
    }

    if (options.method == 'DELETE') {
      remoteFiles.remove(path);
      remoteEtags.remove(path);
      return ResponseBody.fromString('', 204);
    }

    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}
