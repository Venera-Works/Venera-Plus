import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

void main() {
  test(
    'startup preserves divergent replicas, manual repair retains intent, and restore fences stale recovery',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'data-sync-startup-recovery-',
      );
      var oldDataPath = Directory.systemTemp.path;
      var oldCachePath = Directory.systemTemp.path;
      try {
        oldDataPath = App.dataPath;
      } catch (_) {}
      try {
        oldCachePath = App.cachePath;
      } catch (_) {}
      final previousSettings = Map<String, dynamic>.from(
        appdata.toJson()['settings'],
      );
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      final oldMuted = Log.isMuted;
      final actor = 'device_startup_recovery_test';
      final endpoint = ['https://example.com/dav', 'user', 'password'];
      final endpointHash = MergeSyncCoordinator.computeEndpointHash(
        endpoint[0],
        endpoint[1],
      );
      final stateDir = Directory('${tempDir.path}/sync_state_$endpointHash');
      final otherDir = Directory('${tempDir.path}/other-replica');
      final recordKey = syncRecordKey('setting', ['startup-recovery-marker']);
      const privatePayload = 'PRIVATE_SYNC_PAYLOAD_SENTINEL';
      final localRecords = <String, Map<String, Object?>>{
        recordKey: {'value': privatePayload},
      };
      final releaseGates = <Completer<void>>[];

      try {
        DataSync.resetForTesting();
        App.dataPath = tempDir.path;
        App.cachePath = tempDir.path;
        Log.isMuted = true;
        appdata.settings['webdav'] = endpoint;
        appdata.implicitData
          ..clear()
          ..addAll({
            'syncDeviceId': actor,
            'webdavSyncDirection': 'downloadOnly',
            'webdavSyncTiming': 'realtime',
            'webdavSyncDeviceName': 'Startup Test Device',
            'webdavSyncPending': true,
          });

        final primary = MergeStore(stateDir, actor);
        await primary.load();
        await primary.capture({
          recordKey: {'value': privatePayload},
        });
        final originalId = primary.pendingBatchIds.single;
        final alternate = MergeStore(otherDir, actor);
        await alternate.load();
        await alternate.capture({
          recordKey: {'value': 'DIFFERENT_REPLICA_VALUE'},
        });

        final primaryDatabase = File('${stateDir.path}/merge_store.sqlite3');
        final backupDatabase = File('${stateDir.path}/merge_store.sqlite3.bak');
        if (await backupDatabase.exists()) await backupDatabase.delete();
        await File(
          '${otherDir.path}/merge_store.sqlite3',
        ).copy(backupDatabase.path);
        int revision(File databaseFile) {
          final database = sqlite3.open(databaseFile.path);
          try {
            final value =
                database
                        .select(
                          "SELECT value FROM merge_store_meta WHERE key = 'commitRevision';",
                        )
                        .single['value']
                    as String;
            return int.parse(value);
          } finally {
            database.close();
          }
        }

        // Two independently committed, valid replicas intentionally share a
        // revision while carrying different observed/outbox content.
        expect(revision(primaryDatabase), revision(backupDatabase));
        final primaryBefore = primaryDatabase.readAsBytesSync();
        final backupBefore = backupDatabase.readAsBytesSync();

        DataSync.debugDisableWindowCloseHandler = true;
        DataSync.debugStateDirFactory = (_) => stateDir;
        DataSync.debugExportRecords = () async =>
            cloneSyncRecords(localRecords);
        DataSync.debugApplyRecords = (records, {beforeCommit}) async {
          beforeCommit?.call();
          localRecords
            ..clear()
            ..addAll(cloneSyncRecords(records));
        };
        DataSync.debugClientFactory = (_) => _StartupRecoveryDavClient();
        final sync = DataSync();

        await expectLater(
          sync.waitForStartupMerge(),
          throwsA(isA<MergeStoreReplicaDivergenceException>()),
        );
        expect(sync.isReady, isFalse);
        expect(sync.lastError, contains('SYNC_STATE_DIVERGED'));
        expect(sync.statusSnapshot.lastError, contains('SYNC_STATE_DIVERGED'));
        expect(sync.lastError, isNot(contains(privatePayload)));
        expect(sync.statusSnapshot.lastError, isNot(contains(privatePayload)));
        expect(sync.hasPendingChanges, isTrue);

        for (var i = 0; i < 3; i++) {
          sync.checkForAutomaticSync();
          sync.onDataChanged();
          await Future<void>.delayed(Duration.zero);
        }
        expect(primaryDatabase.readAsBytesSync(), orderedEquals(primaryBefore));
        expect(backupDatabase.readAsBytesSync(), orderedEquals(backupBefore));
        expect(sync.hasPendingChanges, isTrue);

        // Repair only after preserving both divergent copies. Download-only
        // retry reloads the valid state without discarding its unuploaded intent.
        if (await backupDatabase.exists()) await backupDatabase.delete();
        await primaryDatabase.copy(backupDatabase.path);
        final retried = await sync.syncNow();
        expect(retried.success, isTrue, reason: retried.errorMessage);
        expect(sync.isReady, isTrue);
        expect(sync.coordinator!.store.pendingBatchIds, [originalId]);
        expect(sync.coordinator!.store.observed[recordKey], {
          'value': privatePayload,
        });
        expect(sync.hasPendingChanges, isTrue);
        expect(sync.lastError, isNull);
        // A startup recovery can be suspended in the exporter while a new
        // endpoint is configured. The stale future must not ready its
        // coordinator after a real export change/local restore notification.
        DataSync.resetForTesting();
        DataSync.debugDisableWindowCloseHandler = true;
        appdata.settings['webdav'] = endpoint;
        appdata.implicitData['webdavSyncTiming'] = 'manual';
        final exportStarted = Completer<void>();
        final releaseExport = Completer<void>();
        releaseGates.add(releaseExport);
        var exportCalls = 0;
        DataSync.debugStateDirFactory = (hash) =>
            Directory('${tempDir.path}/sync_state_$hash');
        DataSync.debugExportRecords = () async {
          if (exportCalls++ == 0) {
            exportStarted.complete();
            await releaseExport.future;
          }
          return cloneSyncRecords(localRecords);
        };
        DataSync.debugApplyRecords = (records, {beforeCommit}) async {
          beforeCommit?.call();
          localRecords
            ..clear()
            ..addAll(cloneSyncRecords(records));
        };
        DataSync.debugClientFactory = (_) => _StartupRecoveryDavClient();
        final switchedSync = DataSync();
        await exportStarted.future;

        const restoredPayload = 'RESTORED_LOCAL_RECORD';
        localRecords[recordKey] = {'value': restoredPayload};
        switchedSync.onDataChanged();
        const nextEndpoint = ['https://example.com/next', 'user', 'password'];
        final configured = await switchedSync.configure(
          config: nextEndpoint,
          excludedFields: '',
          direction: SyncDirection.uploadOnly,
          timing: SyncTiming.manual,
          minutes: 30,
        );
        expect(configured.success, isTrue, reason: configured.errorMessage);
        expect(switchedSync.isReady, isFalse);

        switchedSync.onLocalDataRestored();
        expect(appdata.implicitData['webdavSyncPending'], isTrue);
        releaseExport.complete();
        await switchedSync.waitForStartupMerge();

        final nextHash = MergeSyncCoordinator.computeEndpointHash(
          nextEndpoint[0],
          nextEndpoint[1],
        );
        expect(switchedSync.coordinator!.endpointHash, nextHash);
        expect(switchedSync.isReady, isTrue);
        expect(switchedSync.coordinator!.store.observed[recordKey], {
          'value': restoredPayload,
        });
        expect(switchedSync.hasPendingChanges, isTrue);
        final configuredState = MergeStore(
          switchedSync.coordinator!.stateDirectory,
          actor,
        );
        await configuredState.load();
        expect(configuredState.observed[recordKey], {'value': restoredPayload});
        expect(
          configuredState
              .pendingBatch(configuredState.pendingBatchIds.single)
              .document
              .materialize()[recordKey],
          {'value': restoredPayload},
        );
        // Restoring data during recovery of the same coordinator must force a
        // second durable load after the stale in-flight load completes.
        DataSync.resetForTesting();
        DataSync.debugDisableWindowCloseHandler = true;
        final restoreExportStarted = Completer<void>();
        final releaseRestoreExport = Completer<void>();
        releaseGates.add(releaseRestoreExport);
        var restoreExportCalls = 0;
        const sameEndpointPayload = 'SAME_ENDPOINT_RESTORED_RECORD';
        DataSync.debugStateDirFactory = (hash) =>
            Directory('${tempDir.path}/sync_state_$hash');
        DataSync.debugExportRecords = () async {
          if (restoreExportCalls++ == 0) {
            restoreExportStarted.complete();
            await releaseRestoreExport.future;
          }
          return cloneSyncRecords(localRecords);
        };
        DataSync.debugApplyRecords = (records, {beforeCommit}) async {
          beforeCommit?.call();
          localRecords
            ..clear()
            ..addAll(cloneSyncRecords(records));
        };
        DataSync.debugClientFactory = (_) => _StartupRecoveryDavClient();
        final restoreSync = DataSync();
        await restoreExportStarted.future;
        localRecords[recordKey] = {'value': sameEndpointPayload};
        restoreSync.onLocalDataRestored();
        releaseRestoreExport.complete();
        await restoreSync.waitForStartupMerge();
        expect(restoreSync.coordinator!.store.observed[recordKey], {
          'value': sameEndpointPayload,
        });
        final restoredState = MergeStore(
          restoreSync.coordinator!.stateDirectory,
          actor,
        );
        await restoredState.load();
        expect(restoredState.document.counterFor(actor), 2);
        expect(
          restoredState
              .pendingBatch(restoredState.pendingBatchIds.single)
              .document
              .materialize()[recordKey],
          {'value': sameEndpointPayload},
        );
        expect(restoreSync.hasPendingChanges, isTrue);
      } finally {
        for (final gate in releaseGates) {
          if (!gate.isCompleted) gate.complete();
        }
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
        App.dataPath = oldDataPath;
        App.cachePath = oldCachePath;
        Log.clear();
        Log.isMuted = oldMuted;
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      }
    },
  );
}

class _StartupRecoveryDavClient extends dav.Client {
  _StartupRecoveryDavClient()
    : super(
        uri: 'https://example.com/dav/',
        c: dav.WdDio(),
        auth: dav.Auth(user: 'user', pwd: 'password'),
      );

  @override
  Future<void> ping([CancelToken? cancelToken]) async {}

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async => const [];
}
