import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
    'backup recovery verifies own publications in both namespaces until migration completes',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'data-sync-namespace-recovery-',
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
      const actor = 'namespace_recovery_device';
      final key = syncRecordKey('setting', ['namespace-recovery']);
      final transport = _StartupRecoveryTransport();
      final client = _StartupRecoveryDavClient(transport);

      void mirrorCurrentNamespaceIntoLegacy() {
        final currentPrefix = '${MergeRemote.currentNamespace}/';
        final legacyPrefix = '${MergeRemote.legacyNamespace}/';
        for (final directory in transport.remoteDirs.toList()) {
          if (directory.startsWith(currentPrefix)) {
            transport.remoteDirs.add(
              '$legacyPrefix${directory.substring(currentPrefix.length)}',
            );
          }
        }
        for (final entry in transport.remoteFiles.entries.toList()) {
          if (!entry.key.startsWith(currentPrefix)) continue;
          final path =
              '$legacyPrefix${entry.key.substring(currentPrefix.length)}';
          transport.remoteFiles[path] = Uint8List.fromList(entry.value);
          final etag = transport.remoteEtags[entry.key];
          if (etag != null) transport.remoteEtags[path] = etag;
        }
      }

      Future<MergeStore> loadRecoveredStore(
        String name, {
        required bool migrationComplete,
      }) async {
        final directory = Directory('${tempDir.path}/$name');
        final original = MergeStore(directory, actor);
        await original.load();
        await original.capture({
          key: {'value': 'own publication'},
        });
        await original.save();
        if (migrationComplete) {
          await original.completeProgressProtocolMigration();
          await original.save();
        }
        final primaryDatabase = File('${directory.path}/merge_store.sqlite3');
        await primaryDatabase.copy('${directory.path}/merge_store.sqlite3.bak');
        await primaryDatabase.writeAsString('CORRUPT_PRIMARY_FOR_RECOVERY');

        final recovered = MergeStore(directory, actor);
        await recovered.load();
        expect(recovered.recoveredFromBackup, isTrue);
        expect(recovered.hasProgressProtocolMigration, migrationComplete);
        return recovered;
      }

      MergeSyncCoordinator coordinatorFor(
        MergeStore store,
        String directoryName,
      ) => MergeSyncCoordinator(
        endpointHash: directoryName,
        stateDirectory: store.directory,
        actor: actor,
        store: store,
        remote: MergeRemote(client, deviceName: 'Startup Recovery Device'),
        exportFavoritesOverride: () => {},
        applyFavoritesOverride: (_) {},
        exportHistoryOverride: () async => {},
        applyHistoryOverride: (_) {},
        exportPreferencesOverride: () async => {},
        applyPreferencesOverride: (_, {beforeCommit}) async {
          beforeCommit?.call();
        },
      );

      try {
        DataSync.resetForTesting();
        App.dataPath = tempDir.path;
        App.cachePath = tempDir.path;
        Log.isMuted = true;
        appdata.settings['webdav'] = [
          'https://example.com/dav',
          'user',
          'password',
        ];

        final publisherDirectory = Directory(
          '${tempDir.path}/publication-source',
        );
        final publisher = MergeStore(publisherDirectory, actor);
        await publisher.load();
        await publisher.capture({
          key: {'value': 'own publication'},
        });
        await MergeRemote(
          client,
          deviceName: 'Startup Recovery Device',
        ).upload(publisher.outbox.single);
        mirrorCurrentNamespaceIntoLegacy();

        final legacyPrefix = '${MergeRemote.legacyNamespace}/';
        final legacyFilesBefore = {
          for (final entry in transport.remoteFiles.entries)
            if (entry.key.startsWith(legacyPrefix))
              entry.key: Uint8List.fromList(entry.value),
        };
        final legacyDirectoriesBefore = transport.remoteDirs
            .where((path) => path.startsWith(legacyPrefix))
            .toSet();

        final pendingMigrationStore = await loadRecoveredStore(
          'migration-pending',
          migrationComplete: false,
        );
        final pendingCoordinator = coordinatorFor(
          pendingMigrationStore,
          'migration-pending',
        );
        transport.requests.clear();
        client.directoryReads.clear();
        await pendingCoordinator.reconcileBackupRecoveryIfNeeded();
        expect(pendingMigrationStore.document.counterFor(actor), 1);
        expect(pendingMigrationStore.hasProgressProtocolMigration, isFalse);
        expect(
          transport.requests.any(
            (request) =>
                request.method == 'GET' &&
                request.uri.path.contains('/$legacyPrefix'),
          ),
          isTrue,
        );
        expect(
          transport.requests.any(
            (request) =>
                request.method == 'GET' &&
                request.uri.path.contains('/${MergeRemote.currentNamespace}/'),
          ),
          isTrue,
        );
        expect(
          client.directoryReads,
          containsAll([
            MergeRemote.currentNamespace,
            MergeRemote.legacyNamespace,
          ]),
        );

        final migratedStore = await loadRecoveredStore(
          'migration-complete',
          migrationComplete: true,
        );
        final migratedCoordinator = coordinatorFor(
          migratedStore,
          'migration-complete',
        );
        transport.requests.clear();
        client.directoryReads.clear();
        await migratedCoordinator.reconcileBackupRecoveryIfNeeded();
        expect(migratedStore.document.counterFor(actor), 1);
        expect(migratedStore.hasProgressProtocolMigration, isTrue);
        expect(
          transport.requests.any(
            (request) =>
                request.method == 'GET' &&
                request.uri.path.contains('/$legacyPrefix'),
          ),
          isFalse,
        );
        expect(
          transport.requests.any(
            (request) =>
                request.method == 'GET' &&
                request.uri.path.contains('/${MergeRemote.currentNamespace}/'),
          ),
          isTrue,
        );
        expect(client.directoryReads, contains(MergeRemote.currentNamespace));
        expect(
          client.directoryReads,
          isNot(contains(MergeRemote.legacyNamespace)),
        );
        expect(
          transport.remoteFiles.keys
              .where((path) => path.startsWith(legacyPrefix))
              .toSet(),
          unorderedEquals(legacyFilesBefore.keys),
        );
        for (final entry in legacyFilesBefore.entries) {
          expect(transport.remoteFiles[entry.key], orderedEquals(entry.value));
        }
        expect(
          transport.remoteDirs
              .where((path) => path.startsWith(legacyPrefix))
              .toSet(),
          unorderedEquals(legacyDirectoriesBefore),
        );
        expect(
          transport.requests.where(
            (request) =>
                {'PUT', 'DELETE'}.contains(request.method) &&
                request.uri.path.contains('/$legacyPrefix'),
          ),
          isEmpty,
        );
      } finally {
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

  test(
    'startup preserves divergent replicas, manual repair retains intent, '
    'fences stale recovery, and serializes same-endpoint initialization',
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
        // Startup export holds the endpoint initialization boundary. Reusing
        // the same endpoint for configuration and a queued manual sync must
        // not initialize a competing Store from the pre-recovery view.
        DataSync.resetForTesting();
        DataSync.debugDisableWindowCloseHandler = true;
        appdata.settings['webdav'] = endpoint;
        appdata.implicitData['webdavSyncDirection'] = 'downloadOnly';
        appdata.implicitData['webdavSyncTiming'] = 'manual';
        appdata.implicitData['webdavSyncDeviceName'] = 'Startup Test Device';
        final serializedDirectory = Directory(
          '${tempDir.path}/serialized_sync_state_$endpointHash',
        );
        final configureReachedDirectory = Completer<void>();
        var stateDirectoryCalls = 0;
        DataSync.debugStateDirFactory = (_) {
          if (++stateDirectoryCalls == 2) {
            configureReachedDirectory.complete();
          }
          return serializedDirectory;
        };
        final serializedExportStarted = Completer<void>();
        final releaseSerializedExport = Completer<void>();
        releaseGates.add(releaseSerializedExport);
        var serializedExportCalls = 0;
        DataSync.debugExportRecords = () async {
          if (serializedExportCalls++ == 0) {
            serializedExportStarted.complete();
            await releaseSerializedExport.future;
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
        final serializedSync = DataSync();
        await serializedExportStarted.future;
        var configureFinished = false;
        final configureFuture = serializedSync.configure(
          config: endpoint,
          excludedFields: '',
          direction: SyncDirection.downloadOnly,
          timing: SyncTiming.manual,
          minutes: 30,
        );
        unawaited(
          configureFuture.then((_) {
            configureFinished = true;
          }),
        );
        await configureReachedDirectory.future;
        var manualSyncFinished = false;
        final manualSyncFuture = serializedSync.syncNow();
        unawaited(
          manualSyncFuture.then((_) {
            manualSyncFinished = true;
          }),
        );
        expect(configureFinished, isFalse);
        expect(manualSyncFinished, isFalse);
        releaseSerializedExport.complete();

        final serializedConfigured = await configureFuture;
        expect(
          serializedConfigured.success,
          isTrue,
          reason: serializedConfigured.errorMessage,
        );
        expect(appdata.settings['webdav'], endpoint);
        final manualResult = await manualSyncFuture;
        expect(manualResult.success, isTrue, reason: manualResult.errorMessage);
        await serializedSync.waitForStartupMerge();
        expect(serializedSync.isReady, isTrue);
        final serializedCoordinator = serializedSync.coordinator!;
        expect(serializedCoordinator.endpointHash, endpointHash);
        expect(serializedCoordinator.actor, actor);
        expect(
          serializedCoordinator.stateDirectory.path,
          serializedDirectory.path,
        );
        expect(
          appdata.implicitData['syncDeviceId'],
          serializedCoordinator.actor,
        );
        expect(serializedCoordinator.store.document.counterFor(actor), 1);
        expect(serializedCoordinator.store.pendingBatchIds, hasLength(1));
        final serializedBatch = serializedCoordinator.store.pendingBatch(
          serializedCoordinator.store.pendingBatchIds.single,
        );
        expect(serializedBatch.document.counterFor(actor), 1);
        expect(serializedBatch.document.materialize()[recordKey], {
          'value': sameEndpointPayload,
        });
        expect(serializedCoordinator.store.observed[recordKey], {
          'value': sameEndpointPayload,
        });
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
  _StartupRecoveryDavClient([_StartupRecoveryTransport? transport])
    : this._(transport ?? _StartupRecoveryTransport());

  _StartupRecoveryDavClient._(this.transport)
    : super(
        uri: 'https://example.com/dav/',
        c: dav.WdDio(httpAdapter: transport),
        auth: dav.Auth(user: 'user', pwd: 'password'),
      );

  final _StartupRecoveryTransport transport;
  final directoryReads = <String>[];

  @override
  Future<void> ping([CancelToken? cancelToken]) async {}

  @override
  Future<List<dav.File>> readDir(
    String path, [
    CancelToken? cancelToken,
  ]) async {
    final cleanPath = path.trim().replaceAll('\\', '/');
    directoryReads.add(cleanPath);
    final prefix = cleanPath.isEmpty || cleanPath == '/' ? '' : '$cleanPath/';
    final childDirectories = <String>{};
    final files = <dav.File>[];
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
      if (!entry.key.startsWith(prefix)) continue;
      final name = entry.key.substring(prefix.length);
      if (name.contains('/')) continue;
      files.add(
        dav.File(
          name: name,
          path: '/${entry.key}',
          isDir: false,
          size: entry.value.length,
          eTag: transport.remoteEtags[entry.key],
        ),
      );
    }
    return files;
  }
}

class _StartupRecoveryTransport implements HttpClientAdapter {
  final remoteFiles = <String, Uint8List>{};
  final remoteEtags = <String, String>{};
  final remoteDirs = <String>{};
  final requests = <RequestOptions>[];

  String _path(RequestOptions options) => Uri.decodeComponent(
    options.uri.path,
  ).replaceFirst(RegExp(r'^/dav/?'), '');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = _path(options);
    if (options.method == 'OPTIONS') {
      return ResponseBody.fromString('', 200);
    }
    if (options.method == 'MKCOL') {
      remoteDirs.add(path);
      return ResponseBody.fromString('', 201);
    }
    if (options.method == 'HEAD') {
      final bytes = remoteFiles[path];
      if (bytes == null) return ResponseBody.fromString('', 404);
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'etag': [remoteEtags[path] ?? '"${bytes.length}"'],
          'content-length': ['${bytes.length}'],
        },
      );
    }
    if (options.method == 'PUT') {
      if (remoteFiles.containsKey(path) &&
          options.headers['If-None-Match'] == '*') {
        await requestStream?.drain<void>();
        return ResponseBody.fromString('', 412);
      }
      final bytesBuilder = BytesBuilder();
      if (requestStream != null) {
        await for (final chunk in requestStream) {
          bytesBuilder.add(chunk);
        }
      } else if (options.data is List<int>) {
        bytesBuilder.add(options.data as List<int>);
      } else if (options.data is Stream<List<int>>) {
        await for (final chunk in options.data as Stream<List<int>>) {
          bytesBuilder.add(chunk);
        }
      }
      final bytes = bytesBuilder.takeBytes();
      final etag = '"${sha256.convert(bytes)}"';
      remoteFiles[path] = bytes;
      remoteEtags[path] = etag;
      return ResponseBody.fromString(
        '',
        201,
        headers: {
          'etag': [etag],
        },
      );
    }
    if (options.method == 'GET') {
      final bytes = remoteFiles[path];
      if (bytes == null) return ResponseBody.fromString('', 404);
      return ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          'etag': [remoteEtags[path] ?? '"${bytes.length}"'],
          'content-length': ['${bytes.length}'],
        },
      );
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
