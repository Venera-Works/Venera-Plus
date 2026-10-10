import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';

import '../../foundation/sync_records.dart';
import 'merge_engine.dart';
import 'merge_snapshot.dart';
import 'merge_store_error.dart';
import 'sync_initialization_diagnostics.dart';

/// Normalized, close-after-use SQLite persistence backing [MergeStore].
///
/// The durable representation is split into record rows, causal metadata rows,
/// and immutable snapshot object references. No connection escapes an operation,
/// which also ensures Windows can replace/restore the database between commits.
class MergeStoreDatabase {
  final MergeSnapshotEncodingCache _snapshotEncodingCache =
      MergeSnapshotEncodingCache();
  final Directory directory;
  final String instanceId = SyncInitializationDiagnostics.nextInstanceId(
    'database',
  );
  final String actor;

  static final RegExp _safeBatchIdPattern = RegExp(r'^[0-9a-f]{64}$');
  Map<(String, String, String), String> _persistedRows = {};
  final Map<String, String> _persistedMeta = {};
  final Set<String> _persistedReceived = {};
  final Set<String> _persistedOutboxIds = {};
  final Map<String, (String, int)> _persistedOutboxIdentities = {};
  final Map<String, String> _persistedOutboxFingerprints = {};
  final Map<String, Set<String>> _persistedOutboxChangedRecords = {};
  int _persistedRevision = 0;
  int _persistedOwnCounter = 0;
  String? _persistedStateFingerprint;
  bool _persistedFingerprintStored = false;
  bool _loaded = false;
  bool _databaseExists = false;
  SyncInitializationDiagnostics? _diagnostics;
  int? _lastDiskMainRevision;
  int? _lastDiskReplicaRevision;

  MergeStoreDatabase(this.directory, this.actor);

  File get _databaseFile => File('${directory.path}/merge_store.sqlite3');
  File get _recoveryMarkerFile => File('${_databaseFile.path}.reconcile');
  File get _backupFile => File('${_databaseFile.path}.bak');
  Future<void> _writeCounterRecoveryMarker() async {
    if (await _exists(_recoveryMarkerFile)) return;
    await _recoveryMarkerFile.writeAsString(
      'counter-reconciliation-required\n',
      flush: true,
    );
  }

  Future<void> _clearCounterRecoveryMarker() async {
    if (await _exists(_recoveryMarkerFile)) {
      await _recoveryMarkerFile.delete();
    }
  }

  Future<MergeStoreDatabaseState?> load({
    SyncInitializationDiagnostics? diagnostics,
  }) async {
    final context =
        diagnostics ??
        SyncInitializationDiagnostics(
          trigger: 'merge_store_database.load',
          actor: actor,
          stateDirectory: directory.path,
        );
    _diagnostics = context;
    _lastDiskMainRevision = null;
    _lastDiskReplicaRevision = null;
    if (context.logger != null) {
      context.record('load.begin', values: _loadDiagnosticValues(null));
    }
    try {
      final state = await _loadState();
      if (context.logger != null) {
        context.record(
          state == null ? 'load.empty' : 'load.existing',
          values: _loadDiagnosticValues(state),
        );
      }
      return state;
    } catch (error, stackTrace) {
      if (context.logger != null) {
        context.record(
          'load.error',
          values: {
            ..._diagnosticIdentityMetadata(),
            'errorType': error.runtimeType.toString(),
            if (error is MergeStoreStateException) 'errorCode': error.code,
          },
        );
      }
      Error.throwWithStackTrace(_withDiagnosticMetadata(error), stackTrace);
    }
  }

  Future<MergeStoreDatabaseState?> _loadState() async {
    _loaded = false;
    _databaseExists = false;
    _persistedRows.clear();
    _persistedMeta.clear();
    _persistedReceived.clear();
    _persistedOutboxChangedRecords.clear();
    _persistedOutboxIds.clear();
    _persistedOutboxIdentities.clear();
    _persistedOutboxFingerprints.clear();
    _persistedRevision = 0;
    _persistedOwnCounter = 0;
    _persistedStateFingerprint = null;
    _persistedFingerprintStored = false;
    await directory.create(recursive: true);
    var recoveryMarkerExists = await _exists(_recoveryMarkerFile);
    final primaryExists = await _exists(_databaseFile);
    final backupExists = await _exists(_backupFile);
    if (!backupExists) {
      for (final suffix in ['.bak-journal', '.bak-wal', '.bak-shm']) {
        if (await _exists(File('${_databaseFile.path}$suffix'))) {
          throw MergeStoreIntegrityException(
            metadata: {
              'phase': 'load',
              'reason': 'incomplete_sqlite_replica',
              'actor': actor,
            },
          );
        }
      }
    }
    if (!primaryExists && !backupExists) {
      if (recoveryMarkerExists) {
        throw MergeStoreIntegrityException(
          metadata: {
            'phase': 'load',
            'reason': 'recovery_marker_without_database',
          },
        );
      }
      for (final suffix in [
        '.tmp',
        '.restore.tmp',
        '.bak.tmp',
        '-journal',
        '-wal',
        '-shm',
        '.bak-journal',
        '.bak-wal',
        '.bak-shm',
      ]) {
        if (await _exists(File('${_databaseFile.path}$suffix'))) {
          throw MergeStoreIntegrityException(
            metadata: {
              'phase': 'load',
              'reason': 'incomplete_sqlite_state',
              'actor': actor,
            },
          );
        }
      }
      _loaded = false;
      _databaseExists = false;
      _persistedRevision = 0;
      return null;
    }

    MergeStoreDatabaseState? primaryState;
    Object? primaryError;
    if (primaryExists) {
      try {
        primaryState = _readDatabase(_databaseFile, recoveredFromBackup: false);
      } on _DatabaseActorMismatch {
        rethrow;
      } catch (error) {
        primaryError = error;
      }
    }

    MergeStoreDatabaseState? backupState;
    Object? backupError;
    if (backupExists) {
      try {
        backupState = _readDatabase(_backupFile, recoveredFromBackup: false);
      } on _DatabaseActorMismatch {
        rethrow;
      } catch (error) {
        backupError = error;
      }
    }
    _lastDiskMainRevision = primaryState?.commitRevision;
    _lastDiskReplicaRevision = backupState?.commitRevision;
    var primaryUninitialized = !primaryExists;
    var backupUninitialized = !backupExists;
    if (primaryState == null && primaryExists) {
      primaryUninitialized = _isUninitializedDatabase(_databaseFile);
      if (primaryUninitialized) primaryError = null;
    }
    if (backupState == null && backupExists) {
      backupUninitialized = _isUninitializedDatabase(_backupFile);
      if (backupUninitialized) backupError = null;
    }
    if (primaryUninitialized && backupUninitialized && recoveryMarkerExists) {
      throw MergeStoreIntegrityException(
        metadata: {
          'phase': 'load',
          'reason': 'recovery_marker_without_database',
          'actor': actor,
        },
      );
    }
    if (primaryUninitialized && backupUninitialized) {
      for (final suffix in [
        '.tmp',
        '.restore.tmp',
        '.bak.tmp',
        '-journal',
        '-wal',
        '-shm',
        '.bak-journal',
        '.bak-wal',
        '.bak-shm',
      ]) {
        if (await _exists(File('${_databaseFile.path}$suffix'))) {
          throw MergeStoreIntegrityException(
            metadata: {
              'phase': 'load',
              'reason': 'incomplete_sqlite_state',
              'actor': actor,
            },
          );
        }
      }
      _loaded = false;
      _databaseExists = false;
      _persistedRevision = 0;
      return null;
    }
    if (primaryState != null &&
        backupState != null &&
        primaryState.commitRevision == backupState.commitRevision &&
        !_sameCriticalState(primaryState, backupState)) {
      throw MergeStoreReplicaDivergenceException(
        metadata: _divergenceMetadata(
          phase: 'load',
          loadedRevision: null,
          mainRevision: primaryState.commitRevision,
          replicaRevision: backupState.commitRevision,
          mainOwnCounter: primaryState.document.counterFor(actor),
          replicaOwnCounter: backupState.document.counterFor(actor),
          mainOutboxIds: primaryState.outboxIds,
          replicaOutboxIds: backupState.outboxIds,
          reason: 'same_revision_different_state',
        ),
      );
    }
    late final MergeStoreDatabaseState? recoveryCandidate;
    if (primaryState == null) {
      recoveryCandidate = backupState;
    } else if (backupState == null ||
        backupState.commitRevision <= primaryState.commitRevision) {
      recoveryCandidate = primaryState;
    } else {
      recoveryCandidate = backupState;
    }
    if (recoveryCandidate != null &&
        !_hasValidStoredFingerprint(recoveryCandidate)) {
      throw MergeStoreIntegrityException(
        metadata: _divergenceMetadata(
          phase: 'load',
          loadedRevision: null,
          mainRevision: primaryState?.commitRevision,
          replicaRevision: backupState?.commitRevision,
          mainOwnCounter: primaryState?.document.counterFor(actor) ?? 0,
          replicaOwnCounter: backupState?.document.counterFor(actor) ?? 0,
          mainOutboxIds: primaryState?.outboxIds ?? const <String>[],
          replicaOutboxIds: backupState?.outboxIds ?? const <String>[],
          reason: 'state_fingerprint_mismatch',
        ),
      );
    }

    var didCopyStateFile = false;
    var selectedFromBackup = false;
    late MergeStoreDatabaseState selectedState;
    if (primaryState == null) {
      if (backupState == null) {
        throw MergeStoreIntegrityException(
          metadata: {
            'phase': 'load',
            'reason': 'no_valid_replica',
            'actor': actor,
            'primaryErrorType':
                primaryError?.runtimeType.toString() ?? 'missing',
            'backupErrorType': backupError?.runtimeType.toString() ?? 'missing',
          },
        );
      }
      await _writeCounterRecoveryMarker();
      recoveryMarkerExists = true;
      await _restorePrimaryFromBackup();
      didCopyStateFile = true;
      selectedFromBackup = true;
      selectedState = backupState.withRecovery(true);
    } else if (backupState == null) {
      await _repairBackupFromPrimary();
      didCopyStateFile = true;
      selectedState = primaryState;
    } else if (backupState.commitRevision > primaryState.commitRevision) {
      await _writeCounterRecoveryMarker();
      recoveryMarkerExists = true;
      await _restorePrimaryFromBackup();
      didCopyStateFile = true;
      selectedFromBackup = true;
      selectedState = backupState.withRecovery(true);
    } else {
      if (backupState.commitRevision < primaryState.commitRevision) {
        await _repairBackupFromPrimary();
        didCopyStateFile = true;
      }
      selectedState = primaryState;
    }

    if (didCopyStateFile) {
      final finalPrimaryState = _readDatabase(
        _databaseFile,
        recoveredFromBackup: false,
      );
      final finalBackupState = _readDatabase(
        _backupFile,
        recoveredFromBackup: false,
      );
      _lastDiskMainRevision = finalPrimaryState.commitRevision;
      _lastDiskReplicaRevision = finalBackupState.commitRevision;
      if (finalPrimaryState.commitRevision != finalBackupState.commitRevision) {
        throw MergeStoreStaleStateException(
          metadata: _divergenceMetadata(
            phase: 'postCopy',
            loadedRevision: null,
            mainRevision: finalPrimaryState.commitRevision,
            replicaRevision: finalBackupState.commitRevision,
            mainOwnCounter: finalPrimaryState.document.counterFor(actor),
            replicaOwnCounter: finalBackupState.document.counterFor(actor),
            mainOutboxIds: finalPrimaryState.outboxIds,
            replicaOutboxIds: finalBackupState.outboxIds,
            reason: 'revision_changed_during_copy',
          ),
        );
      }
      if (!_sameCriticalState(finalPrimaryState, finalBackupState)) {
        throw MergeStoreReplicaDivergenceException(
          metadata: _divergenceMetadata(
            phase: 'postCopy',
            loadedRevision: null,
            mainRevision: finalPrimaryState.commitRevision,
            replicaRevision: finalBackupState.commitRevision,
            mainOwnCounter: finalPrimaryState.document.counterFor(actor),
            replicaOwnCounter: finalBackupState.document.counterFor(actor),
            mainOutboxIds: finalPrimaryState.outboxIds,
            replicaOutboxIds: finalBackupState.outboxIds,
            reason: 'same_revision_different_state',
          ),
        );
      }
      if (!_hasValidStoredFingerprint(finalPrimaryState)) {
        throw MergeStoreIntegrityException(
          metadata: _divergenceMetadata(
            phase: 'postCopy',
            loadedRevision: null,
            mainRevision: finalPrimaryState.commitRevision,
            replicaRevision: finalBackupState.commitRevision,
            mainOwnCounter: finalPrimaryState.document.counterFor(actor),
            replicaOwnCounter: finalBackupState.document.counterFor(actor),
            mainOutboxIds: finalPrimaryState.outboxIds,
            replicaOutboxIds: finalBackupState.outboxIds,
            reason: 'state_fingerprint_mismatch',
          ),
        );
      }
      selectedState = finalPrimaryState.withRecovery(selectedFromBackup);
    }

    final state = recoveryMarkerExists
        ? selectedState.withRecovery(true)
        : selectedState;
    _activateState(state);
    return state;
  }

  Map<String, Object?> _loadDiagnosticValues(MergeStoreDatabaseState? state) =>
      {
        ..._diagnosticIdentityMetadata(),
        'loadedRevision': state?.commitRevision,
        'diskMainRevision': _lastDiskMainRevision,
        'diskReplicaRevision': _lastDiskReplicaRevision,
        'ownCounter': state?.document.counterFor(actor) ?? 0,
        'outboxCount': state?.outboxIds.length ?? 0,
      };

  Map<String, Object?> _diagnosticIdentityMetadata() => {
    'databaseInstanceId': instanceId,
    if (_diagnostics != null) 'loadAttemptId': _diagnostics!.loadAttemptId,
  };

  Object _withDiagnosticMetadata(Object error) {
    if (error is! MergeStoreStateException) return error;
    final metadata = {...error.metadata, ..._diagnosticIdentityMetadata()};
    if (error is MergeOutboxCounterConflictException) {
      return MergeOutboxCounterConflictException(
        actor: error.actor,
        counter: error.counter,
        existingBatchId: error.existingBatchId,
        incomingBatchId: error.incomingBatchId,
        metadata: metadata,
      );
    }
    if (error is MergeStoreStaleStateException) {
      return MergeStoreStaleStateException(metadata: metadata);
    }
    if (error is MergeStoreReplicaDivergenceException) {
      return MergeStoreReplicaDivergenceException(metadata: metadata);
    }
    if (error is MergeStoreIntegrityException) {
      return MergeStoreIntegrityException(metadata: metadata);
    }
    return MergeStoreStateException(
      error.code,
      error.message,
      metadata: metadata,
      recoverable: error.recoverable,
    );
  }

  void _recordCommit(
    String phase, {
    required int loadedRevision,
    required int? diskMainRevision,
    required int? diskReplicaRevision,
    required int ownCounter,
    required int outboxCount,
  }) {
    if (_diagnostics?.logger == null) return;
    _diagnostics?.record(
      phase,
      values: {
        ..._diagnosticIdentityMetadata(),
        'loadedRevision': loadedRevision,
        'diskMainRevision': diskMainRevision,
        'diskReplicaRevision': diskReplicaRevision,
        'ownCounter': ownCounter,
        'outboxCount': outboxCount,
      },
    );
  }

  bool _isUninitializedDatabase(File file) {
    Database? database;
    var transactionOpen = false;
    try {
      database = sqlite3.open(file.path);
      database.execute('PRAGMA busy_timeout = 5000;');
      database.execute('BEGIN;');
      transactionOpen = true;
      final integrity = database.select('PRAGMA integrity_check;');
      if (integrity.length != 1 || integrity.single.values.first != 'ok') {
        return false;
      }
      final userVersion = database
          .select('PRAGMA user_version;')
          .single
          .values
          .first;
      if (userVersion != 0 && userVersion != 1) return false;
      const knownTables = {
        'merge_store_meta',
        'merge_document_records',
        'merge_document_vclock',
        'merge_document_event_digests',
        'merge_business_records',
        'merge_received',
        'merge_outbox',
        'merge_snapshot_objects',
        'merge_outbox_objects',
        'merge_outbox_changed_records',
        'merge_checkpoint_inventory',
      };
      for (final row in database.select('''
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%';
        ''')) {
        final table = row['name'] as String;
        if (!knownTables.contains(table) ||
            database.select('SELECT 1 FROM $table LIMIT 1;').isNotEmpty) {
          return false;
        }
      }
      database.execute('COMMIT;');
      transactionOpen = false;
      return true;
    } catch (_) {
      return false;
    } finally {
      if (transactionOpen) {
        try {
          database!.execute('ROLLBACK;');
        } catch (_) {}
      }
      try {
        database?.close();
      } catch (_) {}
    }
  }

  void _activateState(MergeStoreDatabaseState state) {
    _persistedRows
      ..clear()
      ..addAll(state.persistedRows);
    _persistedMeta
      ..clear()
      ..addAll(state.persistedMeta);
    _persistedReceived
      ..clear()
      ..addAll(state.received);
    _persistedOutboxIds
      ..clear()
      ..addAll(state.outboxIds);
    _persistedOutboxIdentities
      ..clear()
      ..addAll(state.outboxIdentities);
    _persistedOutboxFingerprints
      ..clear()
      ..addAll(state.outboxFingerprints);
    _persistedOutboxChangedRecords
      ..clear()
      ..addAll(state.outboxChangedRecords);
    _persistedRevision = state.commitRevision;
    _persistedOwnCounter = state.document.counterFor(actor);
    _persistedStateFingerprint = state.commitFingerprint;
    _persistedFingerprintStored = state.hasCommitFingerprint;
    _databaseExists = true;
    _loaded = true;
  }

  MergeBatch pendingBatch(String id, {required MergeDocument currentDocument}) {
    _ensureLoaded();
    final database = sqlite3.open(_databaseFile.path);
    try {
      database.execute('PRAGMA busy_timeout = 5000;');
      database.execute('BEGIN;');
      _assertOutboxReadCurrent(database);
      final rows = database.select(
        'SELECT actor, counter, manifest FROM merge_outbox WHERE batch_id = ?;',
        [id],
      );
      if (rows.length != 1) {
        throw StateError('No pending merge batch with id "$id"');
      }
      final row = rows.single;
      final actor = row['actor'] as String;
      final counter = row['counter'] as int;
      final manifest = _asBytes(row['manifest']);
      final objectRows = database.select(
        '''
        SELECT objects.path, objects.content
        FROM merge_outbox_objects AS refs
        JOIN merge_snapshot_objects AS objects ON objects.path = refs.path
        WHERE refs.batch_id = ?;
        ''',
        [id],
      );
      final objects = <String, Uint8List>{};
      for (final objectRow in objectRows) {
        final path = objectRow['path'] as String;
        if (objects.containsKey(path)) {
          throw const FormatException('Duplicate outbox object reference');
        }
        objects[path] = _asBytes(objectRow['content']);
      }
      final batch = MergeSnapshot.decode(manifest, objects);
      if (batch.id != id ||
          batch.actor != actor ||
          actor != this.actor ||
          batch.counter != counter ||
          batch.document.counterFor(actor) != counter ||
          counter > currentDocument.counterFor(actor)) {
        throw const FormatException('Invalid persisted outbox snapshot');
      }
      return batch;
    } finally {
      database.close();
    }
  }

  MergeSnapshot pendingSnapshot(String id) {
    _ensureLoaded();
    final database = sqlite3.open(_databaseFile.path);
    try {
      database.execute('PRAGMA busy_timeout = 5000;');
      database.execute('BEGIN;');
      _assertOutboxReadCurrent(database);
      final rows = database.select(
        'SELECT actor, counter, manifest FROM merge_outbox WHERE batch_id = ?;',
        [id],
      );
      if (rows.length != 1) {
        throw StateError('No pending merge batch with id "$id"');
      }
      final row = rows.single;
      final batchActor = row['actor'] as String;
      final counter = row['counter'] as int;
      final manifest = _asBytes(row['manifest']);
      final objectRows = database.select(
        '''
        SELECT objects.path, objects.content
        FROM merge_outbox_objects AS refs
        JOIN merge_snapshot_objects AS objects ON objects.path = refs.path
        WHERE refs.batch_id = ?;
        ''',
        [id],
      );
      final objects = <String, Uint8List>{};
      for (final objectRow in objectRows) {
        final path = objectRow['path'] as String;
        if (objects.containsKey(path)) {
          throw const FormatException('Duplicate outbox object reference');
        }
        objects[path] = _asBytes(objectRow['content']);
      }
      final snapshot = MergeSnapshot.fromEncoded(manifest, objects);
      if (batchActor != actor ||
          snapshot.manifest['batchId'] != id ||
          snapshot.manifest['actor'] != batchActor ||
          snapshot.manifest['counter'] != counter) {
        throw const FormatException('Invalid persisted outbox snapshot');
      }
      return snapshot;
    } finally {
      database.close();
    }
  }

  void _assertOutboxReadCurrent(Database database) {
    final revision = _committedRevisionIfPresent(database, schema: 'main');
    if (revision == _persistedRevision) return;
    final metadata = <String, Object?>{
      'phase': 'outbox_read',
      'reason': 'revision_changed',
      'loadedRevision': _persistedRevision,
      'mainRevision': revision,
      'replicaRevision': null,
      'ownCounter': _persistedOwnCounter,
      'outboxCount': _persistedOutboxIds.length,
      ..._diagnosticIdentityMetadata(),
    };
    if (_diagnostics?.logger != null) {
      _diagnostics!.record(
        'outbox.stale',
        values: {
          ...metadata,
          'diskMainRevision': revision,
          'diskReplicaRevision': null,
        },
      );
    }
    throw MergeStoreStaleStateException(metadata: metadata);
  }

  Future<Map<String, MergeSnapshot>> commit({
    required MergeDocument document,
    required MergeDocument localObservation,
    required SyncRecords observed,
    required Set<String> received,
    required List<String> outboxIds,
    required Map<String, MergeBatch> newOutboxBatches,
    required Map<String, Set<String>> outboxChangedRecords,
    required SyncRecords? pendingApply,
    required Set<String> pendingUnavailableDomains,
    required bool initialized,
    Map<String, Map<String, String>> localEdits = const {},
    bool? hasCompletedSync,
    bool? counterReconciliationRequired,
  }) async {
    _diagnostics ??= SyncInitializationDiagnostics(
      trigger: 'merge_store_database.commit',
      actor: actor,
      stateDirectory: directory.path,
    );
    if (_loaded && !_databaseExists) {
      throw StateError('Invalid SQLite store lifecycle');
    }
    final loadedRevision = _persistedRevision;
    final firstCommit = !_databaseExists;
    if (counterReconciliationRequired == true) {
      await directory.create(recursive: true);
      await _writeCounterRecoveryMarker();
    }
    final nextRows = _encodeRows(
      {'document': document, 'localObservation': localObservation},
      observed,
      pendingApply,
      localEdits,
    );
    final nextReceived = Set<String>.of(received);
    final nextCompletedSync =
        hasCompletedSync ??
        (_persistedMeta['hasCompletedSync'] == '1' ||
            (!_persistedMeta.containsKey('hasCompletedSync') &&
                _databaseExists &&
                nextReceived.isNotEmpty));
    final nextMeta = <String, String>{
      'actor': actor,
      'initialized': initialized ? '1' : '0',
      'hasCompletedSync': nextCompletedSync ? '1' : '0',
      'hasPendingApply': pendingApply == null ? '0' : '1',
      'pendingUnavailableDomains': canonicalSyncJson(
        pendingUnavailableDomains.toList()..sort(),
      ),
      'legacyStateMigrated': '1',
      'outboxDeltasVersion': '1',
      'commitRevision': '$_persistedRevision',
    };
    final nextOutboxIds = List<String>.of(outboxIds);
    if (nextOutboxIds.toSet().length != nextOutboxIds.length) {
      throw const FormatException('Duplicate pending outbox id');
    }
    final desiredOutbox = nextOutboxIds.toSet();
    final removedOutbox = _persistedOutboxIds.difference(desiredOutbox);
    final addedOutbox = desiredOutbox.difference(_persistedOutboxIds);
    if (outboxChangedRecords.keys.any((id) => !desiredOutbox.contains(id))) {
      throw const FormatException(
        'Changed-record metadata has no outbox batch',
      );
    }
    for (final entry in newOutboxBatches.entries) {
      final batch = entry.value;
      if (entry.key != batch.id ||
          !_isSafeBatchId(batch.id) ||
          !desiredOutbox.contains(entry.key) ||
          batch.actor != actor ||
          batch.counter <= 0 ||
          batch.document.counterFor(actor) != batch.counter) {
        throw MergeStoreIntegrityException(
          metadata: {
            'phase': 'commit',
            'reason': 'invalid_new_batch_identity',
            'actor': actor,
            'counter': batch.counter,
            if (_isSafeBatchId(batch.id)) 'batchId': batch.id,
          },
        );
      }
      if (!addedOutbox.contains(entry.key)) {
        try {
          batch.validateIdentity();
        } on FormatException {
          throw MergeStoreIntegrityException(
            metadata: {
              'phase': 'commit',
              'reason': 'invalid_new_batch_identity',
              'actor': actor,
              'counter': batch.counter,
              if (_isSafeBatchId(batch.id)) 'batchId': batch.id,
            },
          );
        }
      }
    }
    final nextOutboxChangedRecords = <String, Set<String>>{};
    for (final entry in outboxChangedRecords.entries) {
      for (final key in entry.value) {
        _validateRecordKey(key);
      }
      if (entry.value.isNotEmpty) {
        nextOutboxChangedRecords[entry.key] = Set<String>.of(entry.value);
      }
    }
    final changedOutboxDeltas =
        <String>{
              ..._persistedOutboxChangedRecords.keys,
              ...nextOutboxChangedRecords.keys,
            }
            .where(
              (id) => !_sameSet(
                _persistedOutboxChangedRecords[id] ?? const <String>{},
                nextOutboxChangedRecords[id] ?? const <String>{},
              ),
            )
            .toSet();
    final rowsAreUnchanged = _sameRowValues(_persistedRows, nextRows);
    final persistedMetaWithoutFingerprint = Map<String, String>.of(
      _persistedMeta,
    )..remove('commitFingerprint');
    final stateChanged =
        !_databaseExists ||
        !rowsAreUnchanged ||
        !_sameMap(persistedMetaWithoutFingerprint, nextMeta) ||
        !_sameSet(_persistedReceived, nextReceived) ||
        removedOutbox.isNotEmpty ||
        changedOutboxDeltas.isNotEmpty ||
        addedOutbox.isNotEmpty;
    final clearRecoveryMarker =
        counterReconciliationRequired == false &&
        await _exists(_recoveryMarkerFile);
    if (!stateChanged && !clearRecoveryMarker) {
      _recordCommit(
        'commit.begin',
        loadedRevision: loadedRevision,
        diskMainRevision: _lastDiskMainRevision,
        diskReplicaRevision: _lastDiskReplicaRevision,
        ownCounter: document.counterFor(actor),
        outboxCount: desiredOutbox.length,
      );
      _recordCommit(
        'commit.success',
        loadedRevision: loadedRevision,
        diskMainRevision: _lastDiskMainRevision,
        diskReplicaRevision: _lastDiskReplicaRevision,
        ownCounter: document.counterFor(actor),
        outboxCount: desiredOutbox.length,
      );
      return const <String, MergeSnapshot>{};
    }
    final nextRowFingerprints = rowsAreUnchanged
        ? _persistedRows
        : <(String, String, String), String>{
            for (final entry in nextRows.entries)
              entry.key: _rowFingerprint(entry.value),
          };
    for (final id in addedOutbox) {
      if (!newOutboxBatches.containsKey(id)) {
        throw MergeStoreIntegrityException(
          metadata: {
            'phase': 'commit',
            'reason': 'missing_new_batch',
            'actor': actor,
            if (_isSafeBatchId(id)) 'batchId': id,
          },
        );
      }
    }
    final nextRevision = _persistedRevision + (stateChanged ? 1 : 0);
    nextMeta['commitRevision'] = '$nextRevision';
    final nextOutboxSnapshots = <String, MergeSnapshot>{};
    final nextOutboxIdentities = Map<String, (String, int)>.of(
      _persistedOutboxIdentities,
    )..removeWhere((id, _) => removedOutbox.contains(id));
    final nextOutboxFingerprints = Map<String, String>.of(
      _persistedOutboxFingerprints,
    )..removeWhere((id, _) => removedOutbox.contains(id));
    String? nextStateFingerprint = _persistedStateFingerprint;

    final backupExistedBeforeAttach = await _exists(_backupFile);
    Database? database;
    int? diskMainRevision;
    int? diskReplicaRevision;
    try {
      database = sqlite3.open(_databaseFile.path);
      database.execute('PRAGMA busy_timeout = 5000;');
      database.execute('ATTACH DATABASE ? AS replica;', [_backupFile.path]);
      database.execute('PRAGMA main.journal_mode = DELETE;');
      database.execute('PRAGMA replica.journal_mode = DELETE;');
      database.execute('PRAGMA main.synchronous = FULL;');
      database.execute('PRAGMA replica.synchronous = FULL;');
      database.execute('PRAGMA foreign_keys = ON;');
      database.execute('BEGIN IMMEDIATE;');
      try {
        if (!_databaseExists) {
          diskMainRevision = _committedRevisionIfPresent(
            database,
            schema: 'main',
          );
          diskReplicaRevision = _committedRevisionIfPresent(
            database,
            schema: 'replica',
          );
          if (diskMainRevision != null || diskReplicaRevision != null) {
            _recordCommit(
              'commit.begin',
              loadedRevision: loadedRevision,
              diskMainRevision: diskMainRevision,
              diskReplicaRevision: diskReplicaRevision,
              ownCounter: document.counterFor(actor),
              outboxCount: desiredOutbox.length,
            );
            throw MergeStoreStaleStateException(
              metadata: _freshInitializationMetadata(
                database,
                mainRevision: diskMainRevision,
                replicaRevision: diskReplicaRevision,
                desiredOutboxIds: desiredOutbox,
                removedOutboxIds: removedOutbox,
                addedOutboxIds: addedOutbox,
                ownCounter: document.counterFor(actor),
              ),
            );
          }
        }
        _ensureSchema(database, schema: 'main');
        _ensureSchema(database, schema: 'replica');
        final mainView = _readCommitView(database, schema: 'main');
        final replicaView = _readCommitView(database, schema: 'replica');
        diskMainRevision = mainView.revision;
        diskReplicaRevision = replicaView.revision;
        _recordCommit(
          'commit.begin',
          loadedRevision: loadedRevision,
          diskMainRevision: diskMainRevision,
          diskReplicaRevision: diskReplicaRevision,
          ownCounter: document.counterFor(actor),
          outboxCount: desiredOutbox.length,
        );
        if (_databaseExists) {
          _assertCommitViews(
            database,
            mainView,
            replicaView,
            ownCounter: document.counterFor(actor),
            desiredOutboxIds: desiredOutbox,
            removedOutboxIds: removedOutbox,
            addedOutboxIds: addedOutbox,
          );
        } else if (!_isEmptyCommitView(mainView) ||
            !_isEmptyCommitView(replicaView)) {
          throw MergeStoreStaleStateException(
            metadata: _divergenceMetadata(
              phase: 'freshInitialization',
              loadedRevision: null,
              mainRevision: mainView.revision,
              replicaRevision: replicaView.revision,
              mainOwnCounter: mainView.ownCounter,
              replicaOwnCounter: replicaView.ownCounter,
              ownCounter: document.counterFor(actor),
              mainOutboxIds: mainView.outboxIdentities.keys,
              replicaOutboxIds: replicaView.outboxIdentities.keys,
              reason: 'fresh_store_not_empty',
              desiredOutboxIds: desiredOutbox,
              removedOutboxIds: removedOutbox,
              addedOutboxIds: addedOutbox,
            ),
          );
        }
        final ownCounter = document.counterFor(actor);
        if (ownCounter < mainView.ownCounter ||
            ownCounter < replicaView.ownCounter) {
          throw MergeStoreStaleStateException(
            metadata: _divergenceMetadata(
              phase: 'commit',
              loadedRevision: _persistedRevision,
              mainRevision: mainView.revision,
              replicaRevision: replicaView.revision,
              mainOwnCounter: mainView.ownCounter,
              replicaOwnCounter: replicaView.ownCounter,
              mainOutboxIds: mainView.outboxIdentities.keys,
              replicaOutboxIds: replicaView.outboxIdentities.keys,
              desiredOutboxIds: desiredOutbox,
              removedOutboxIds: removedOutbox,
              addedOutboxIds: addedOutbox,
              ownCounter: ownCounter,
              reason: 'candidate_counter_regressed',
            ),
          );
        }
        _assertOutboxSlots(
          mainView.outboxIdentities,
          newOutboxBatches,
          addedOutbox,
          mainRevision: mainView.revision,
          replicaRevision: replicaView.revision,
          ownCounter: document.counterFor(actor),
          mainOwnCounter: mainView.ownCounter,
          replicaOwnCounter: replicaView.ownCounter,
          desiredOutboxIds: desiredOutbox,
          removedOutboxIds: removedOutbox,
        );
        for (final batch in newOutboxBatches.values) {
          _validateBatchCausalCompatibility(
            batch,
            document: document,
            localObservation: localObservation,
            phase: 'commit',
          );
        }
        for (final id in addedOutbox) {
          final batch = newOutboxBatches[id]!;
          try {
            nextOutboxSnapshots[id] = MergeSnapshot.fromBatch(
              batch,
              encodingCache: _snapshotEncodingCache,
            );
          } on FormatException {
            throw MergeStoreIntegrityException(
              metadata: {
                'phase': 'commit',
                'reason': 'invalid_new_batch_identity',
                'actor': actor,
                'counter': batch.counter,
                if (_isSafeBatchId(batch.id)) 'batchId': batch.id,
              },
            );
          }
        }
        for (final id in addedOutbox) {
          final batch = newOutboxBatches[id]!;
          final snapshot = nextOutboxSnapshots[id]!;
          nextOutboxIdentities[id] = (batch.actor, batch.counter);
          nextOutboxFingerprints[id] = _outboxFingerprint(
            id: id,
            batchActor: batch.actor,
            counter: batch.counter,
            manifestDigest: sha256
                .convert(snapshot.serializeManifest())
                .toString(),
            objectFingerprints: {
              for (final entry in snapshot.objects.entries)
                entry.key: sha256.convert(entry.value).toString(),
            },
          );
        }
        if (stateChanged) {
          nextStateFingerprint = _stateFingerprint(
            rows: nextRowFingerprints,
            meta: nextMeta,
            received: nextReceived,
            outboxIdentities: nextOutboxIdentities,
            outboxFingerprints: nextOutboxFingerprints,
            outboxChangedRecords: nextOutboxChangedRecords,
          );
          nextMeta['commitFingerprint'] = nextStateFingerprint;
        }
        if (stateChanged) {
          for (final schema in ['main', 'replica']) {
            if (_persistedMeta.containsKey('checkpointMigrationComplete')) {
              database.execute(
                'DROP TABLE IF EXISTS $schema.merge_checkpoint_inventory;',
              );
            }
            _applyRowDiff(
              database,
              nextRows,
              schema: schema,
              fingerprints: nextRowFingerprints,
            );
            _applyMetaDiff(database, nextMeta, schema: schema);
            _applyReceivedDiff(database, nextReceived, schema: schema);
            _applyOutboxChanges(
              database,
              schema: schema,
              removed: removedOutbox,
              added: addedOutbox,
              newBatches: newOutboxBatches,
              deltaChanges: changedOutboxDeltas,
              changedRecords: nextOutboxChangedRecords,
              newSnapshots: nextOutboxSnapshots,
            );
          }
        }
        database.execute('COMMIT;');
      } catch (error, stackTrace) {
        try {
          database.execute('ROLLBACK;');
        } on Object {
          // Preserve the transaction's original failure.
        }
        try {
          database.close();
        } on Object {
          // Preserve the transaction's original failure.
        }
        database = null;
        if (!backupExistedBeforeAttach) {
          try {
            if (await _exists(_backupFile) && await _backupFile.length() == 0) {
              await _backupFile.delete();
            }
          } on Object {
            // Preserve the transaction's original failure.
          }
        }
        final enrichedError = _withDiagnosticMetadata(error);
        if (error is MergeStoreStaleStateException) {
          _recordCommit(
            'commit.stale',
            loadedRevision: loadedRevision,
            diskMainRevision: diskMainRevision,
            diskReplicaRevision: diskReplicaRevision,
            ownCounter: document.counterFor(actor),
            outboxCount: desiredOutbox.length,
          );
        }
        Error.throwWithStackTrace(enrichedError, stackTrace);
      }
    } finally {
      database?.close();
    }

    if (clearRecoveryMarker) {
      try {
        await _clearCounterRecoveryMarker();
      } on Object {
        _loaded = false;
        rethrow;
      }
    }
    if (!stateChanged) {
      _recordCommit(
        'commit.success',
        loadedRevision: loadedRevision,
        diskMainRevision: diskMainRevision,
        diskReplicaRevision: diskReplicaRevision,
        ownCounter: document.counterFor(actor),
        outboxCount: desiredOutbox.length,
      );
      return const <String, MergeSnapshot>{};
    }

    _persistedRows = nextRowFingerprints;
    _persistedMeta
      ..clear()
      ..addAll(nextMeta);
    _persistedReceived
      ..clear()
      ..addAll(nextReceived);
    _persistedOutboxIds
      ..clear()
      ..addAll(desiredOutbox);
    _persistedOutboxIdentities
      ..clear()
      ..addAll(nextOutboxIdentities);
    _persistedOutboxFingerprints
      ..clear()
      ..addAll(nextOutboxFingerprints);
    _persistedOutboxChangedRecords
      ..clear()
      ..addAll(nextOutboxChangedRecords);
    _persistedRevision = nextRevision;
    _persistedOwnCounter = document.counterFor(actor);
    _persistedStateFingerprint = nextStateFingerprint;
    _persistedFingerprintStored = true;
    _databaseExists = true;
    _loaded = true;
    _lastDiskMainRevision = nextRevision;
    _lastDiskReplicaRevision = nextRevision;
    if (firstCommit) {
      _recordCommit(
        'commit.first',
        loadedRevision: loadedRevision,
        diskMainRevision: nextRevision,
        diskReplicaRevision: nextRevision,
        ownCounter: document.counterFor(actor),
        outboxCount: desiredOutbox.length,
      );
    }
    _recordCommit(
      'commit.success',
      loadedRevision: loadedRevision,
      diskMainRevision: nextRevision,
      diskReplicaRevision: nextRevision,
      ownCounter: document.counterFor(actor),
      outboxCount: desiredOutbox.length,
    );
    return Map.unmodifiable(nextOutboxSnapshots);
  }

  MergeStoreDatabaseState _readDatabase(
    File file, {
    required bool recoveredFromBackup,
  }) {
    Database? database;
    try {
      database = sqlite3.open(file.path);
      database.execute('PRAGMA busy_timeout = 5000;');
      database.execute('BEGIN;');
      final integrity = database.select('PRAGMA integrity_check;');
      if (integrity.length != 1 || integrity.single.values.first != 'ok') {
        throw const FormatException('SQLite integrity check failed');
      }
      final version = database
          .select('PRAGMA user_version;')
          .single
          .values
          .first;
      if (version != 1) {
        throw FormatException(
          'Unsupported merge SQLite schema version: $version',
        );
      }
      final meta = <String, String>{};
      for (final row in database.select(
        'SELECT key, value FROM merge_store_meta;',
      )) {
        final key = row['key'] as String;
        if (meta.containsKey(key)) {
          throw const FormatException('Duplicate store metadata');
        }
        meta[key] = row['value'] as String;
      }
      const requiredMeta = {
        'actor',
        'initialized',
        'hasPendingApply',
        'pendingUnavailableDomains',
        'legacyStateMigrated',
        'outboxDeltasVersion',
        'commitRevision',
      };
      const allowedMeta = {
        ...requiredMeta,
        'hasCompletedSync',
        'checkpointMigrationComplete',
        'commitFingerprint',
      };
      if (!meta.keys.toSet().containsAll(requiredMeta) ||
          !allowedMeta.containsAll(meta.keys)) {
        throw const FormatException('Invalid merge SQLite metadata');
      }
      if (meta['actor'] != actor) {
        throw _DatabaseActorMismatch(
          actor,
          meta['actor']!,
          metadata: _diagnosticIdentityMetadata(),
        );
      }
      if (!{'0', '1'}.contains(meta['initialized']) ||
          !{'0', '1'}.contains(meta['hasPendingApply']) ||
          meta['legacyStateMigrated'] != '1' ||
          meta['outboxDeltasVersion'] != '1' ||
          (meta.containsKey('hasCompletedSync') &&
              !{'0', '1'}.contains(meta['hasCompletedSync'])) ||
          (meta.containsKey('checkpointMigrationComplete') &&
              !{'0', '1'}.contains(meta['checkpointMigrationComplete']))) {
        throw const FormatException('Invalid merge SQLite metadata values');
      }
      final commitRevision = int.tryParse(meta['commitRevision']!);
      if (commitRevision == null ||
          commitRevision <= 0 ||
          '$commitRevision' != meta['commitRevision']) {
        throw const FormatException('Invalid merge commit revision');
      }
      final storedCommitFingerprint = meta['commitFingerprint'];
      final rows = <(String, String, String), String>{};
      final documents = <String, MergeDocument>{};
      for (final scope in ['document', 'localObservation']) {
        final vclock = <String, Object?>{};
        final eventDigests = <String, Object?>{};
        final records = <String, Object?>{};
        for (final row in database.select(
          'SELECT actor, counter FROM merge_document_vclock WHERE scope = ?;',
          [scope],
        )) {
          final actor = row['actor'] as String;
          final counter = row['counter'] as int;
          if (actor.isEmpty || counter < 0 || vclock.containsKey(actor)) {
            throw const FormatException('Invalid document counter row');
          }
          vclock[actor] = counter;
          rows[('vclock', scope, actor)] = _rowFingerprint('$counter');
        }
        for (final row in database.select(
          'SELECT dot, digest FROM merge_document_event_digests WHERE scope = ?;',
          [scope],
        )) {
          final dot = row['dot'] as String;
          final digest = row['digest'] as String;
          if (eventDigests.containsKey(dot)) {
            throw const FormatException('Duplicate document event digest');
          }
          eventDigests[dot] = digest;
          rows[('event', scope, dot)] = _rowFingerprint(digest);
        }
        for (final row in database.select(
          'SELECT record_key, value_json FROM merge_document_records WHERE scope = ?;',
          [scope],
        )) {
          final key = row['record_key'] as String;
          final encoded = row['value_json'] as String;
          final value = _decodeCanonicalObject(encoded);
          if (records.containsKey(key)) {
            throw const FormatException('Duplicate document record row');
          }
          records[key] = value;
          rows[('doc', scope, key)] = _rowFingerprint(encoded);
        }
        final rawDocument = <String, Object?>{
          'schema': 3,
          'vclock': vclock,
          'eventDigests': eventDigests,
          'records': records,
        };
        final document = MergeDocument.fromJson(rawDocument);
        if (!syncValuesEqual(rawDocument, document.toJson())) {
          throw const FormatException(
            'Noncanonical or incomplete SQLite merge document',
          );
        }
        documents[scope] = document;
      }
      final document = documents['document']!;
      final localObservation = documents['localObservation']!;
      if (!document.dominates(localObservation)) {
        throw const FormatException(
          'Invalid local business causal observation',
        );
      }
      final recordsByKind = <String, SyncRecords>{
        'observed': <String, Map<String, Object?>>{},
        'pendingApply': <String, Map<String, Object?>>{},
      };
      final localEdits = <String, Map<String, String>>{};
      final documentJson = document.toJson();
      final documentEventDigests = (documentJson['eventDigests'] as Map)
          .cast<String, String>();
      for (final row in database.select(
        'SELECT kind, record_key, value_json FROM merge_business_records;',
      )) {
        final kind = row['kind'] as String;
        final key = row['record_key'] as String;
        final encoded = row['value_json'] as String;
        _validateRecordKey(key);
        final value = _decodeCanonicalObject(encoded);
        if (kind == 'localEdits') {
          if (value.isEmpty || localEdits.containsKey(key)) {
            throw const FormatException('Invalid local edit metadata row');
          }
          final fields = <String, String>{};
          for (final entry in value.entries) {
            if (entry.key.isEmpty || entry.value is! String) {
              throw const FormatException('Invalid local edit metadata');
            }
            final id = entry.value as String;
            final dot = MergeDot.parse(id);
            if (dot.actor != actor ||
                dot.counter > document.counterFor(actor) ||
                !documentEventDigests.containsKey(id) ||
                !_hasLocalEditCandidate(documentJson, key, entry.key, id)) {
              throw const FormatException('Invalid local edit candidate');
            }
            fields[entry.key] = id;
          }
          localEdits[key] = fields;
          rows[('localEdits', '', key)] = _rowFingerprint(encoded);
          continue;
        }
        final recordSet = recordsByKind[kind];
        if (recordSet == null || recordSet.containsKey(key)) {
          throw const FormatException('Invalid business record row');
        }
        _validateJson(value);
        recordSet[key] = value;
        rows[(kind, '', key)] = _rowFingerprint(encoded);
      }
      final observed = recordsByKind['observed']!;
      final pendingRecords = recordsByKind['pendingApply']!;
      final pendingApply = meta['hasPendingApply'] == '1'
          ? pendingRecords
          : null;
      if (meta['initialized'] == '0' && observed.isNotEmpty) {
        throw const FormatException(
          'Uninitialized state has an observed baseline',
        );
      }
      if (pendingApply == null && pendingRecords.isNotEmpty) {
        throw const FormatException('Unexpected pending apply records');
      }
      final pendingUnavailableDomains = _decodeDomains(
        meta['pendingUnavailableDomains']!,
      );
      if (pendingApply == null && pendingUnavailableDomains.isNotEmpty) {
        throw const FormatException('Pending domains without a pending apply');
      }
      final received = <String>{};
      for (final row in database.select(
        'SELECT filename FROM merge_received;',
      )) {
        final filename = row['filename'] as String;
        if (filename.isEmpty || !received.add(filename)) {
          throw const FormatException('Invalid or duplicate received filename');
        }
      }
      final outboxIds = <String>[];
      final outboxIdSet = <String>{};
      final outboxCounters = <int>{};
      final outboxIdentities = <String, (String, int)>{};
      final outboxFingerprints = <String, String>{};
      for (final row in database.select('''
        SELECT batch_id, actor, counter, manifest
        FROM merge_outbox
        ORDER BY counter ASC, batch_id ASC;
        ''')) {
        final id = row['batch_id'] as String;
        final batchActor = row['actor'] as String;
        final counter = row['counter'] as int;
        final manifest = _asBytes(row['manifest']);
        if (!_isSafeBatchId(id) ||
            batchActor != actor ||
            counter <= 0 ||
            counter > document.counterFor(batchActor) ||
            !outboxCounters.add(counter) ||
            !outboxIdSet.add(id)) {
          throw const FormatException('Invalid durable outbox metadata');
        }
        final objectRows = database.select(
          '''
          SELECT refs.path, objects.content
          FROM merge_outbox_objects AS refs
          LEFT JOIN merge_snapshot_objects AS objects ON objects.path = refs.path
          WHERE refs.batch_id = ?
          ORDER BY refs.path ASC;
          ''',
          [id],
        );
        final objects = <String, Uint8List>{};
        final objectFingerprints = <String, String>{};
        for (final objectRow in objectRows) {
          final path = objectRow['path'] as String;
          final content = objectRow['content'];
          if (path.isEmpty || content == null || objects.containsKey(path)) {
            throw const FormatException('Invalid outbox snapshot object ref');
          }
          final bytes = _asBytes(content);
          objects[path] = bytes;
          objectFingerprints[path] = sha256.convert(bytes).toString();
        }
        final batch = MergeSnapshot.decode(manifest, objects);
        if (batch.id != id ||
            batch.actor != batchActor ||
            batch.counter != counter ||
            batch.document.counterFor(actor) != counter) {
          throw const FormatException('Invalid persisted outbox identity');
        }
        try {
          batch.document.validateEventIdentities(document);
          batch.document.validateEventIdentities(localObservation);
        } on FormatException {
          throw const FormatException(
            'Persisted outbox conflicts with local causal identity',
          );
        }
        outboxIds.add(id);
        outboxIdentities[id] = (batchActor, counter);
        outboxFingerprints[id] = _outboxFingerprint(
          id: id,
          batchActor: batchActor,
          counter: counter,
          manifestDigest: sha256.convert(manifest).toString(),
          objectFingerprints: objectFingerprints,
        );
      }
      final outboxChangedRecords = <String, Set<String>>{};
      for (final row in database.select(
        'SELECT batch_id, record_key FROM merge_outbox_changed_records;',
      )) {
        final batchId = row['batch_id'] as String;
        final key = row['record_key'] as String;
        if (!outboxIdSet.contains(batchId)) {
          throw const FormatException('Orphaned changed-record metadata');
        }
        _validateRecordKey(key);
        if (!outboxChangedRecords
            .putIfAbsent(batchId, () => <String>{})
            .add(key)) {
          throw const FormatException('Duplicate changed-record metadata');
        }
      }
      for (final row in database.select(
        'SELECT batch_id, path FROM merge_outbox_objects;',
      )) {
        if (!outboxIdSet.contains(row['batch_id'] as String) ||
            (row['path'] as String).isEmpty) {
          throw const FormatException('Orphaned outbox object reference');
        }
      }
      if (database.select('''
            SELECT 1 FROM merge_snapshot_objects AS objects
            WHERE NOT EXISTS (
              SELECT 1 FROM merge_outbox_objects AS refs
              WHERE refs.path = objects.path
            )
            LIMIT 1;
          ''').isNotEmpty) {
        throw const FormatException('Unreferenced snapshot object');
      }
      final stateFingerprint = _stateFingerprint(
        rows: rows,
        meta: meta,
        received: received,
        outboxIdentities: outboxIdentities,
        outboxFingerprints: outboxFingerprints,
        outboxChangedRecords: outboxChangedRecords,
      );
      final state = MergeStoreDatabaseState(
        document: document,
        localObservation: localObservation,
        observed: observed,
        received: received,
        outboxIds: outboxIds,
        outboxIdentities: outboxIdentities,
        outboxFingerprints: outboxFingerprints,
        outboxChangedRecords: outboxChangedRecords,
        pendingApply: pendingApply,
        pendingUnavailableDomains: pendingUnavailableDomains,
        initialized: meta['initialized'] == '1',
        hasCompletedSync:
            meta['hasCompletedSync'] == '1' ||
            (!meta.containsKey('hasCompletedSync') && received.isNotEmpty),
        localEdits: localEdits,
        recoveredFromBackup: recoveredFromBackup,
        persistedRows: rows,
        persistedMeta: meta,
        commitRevision: commitRevision,
        commitFingerprint: stateFingerprint,
        hasCommitFingerprint: storedCommitFingerprint != null,
      );
      database.execute('COMMIT;');
      return state;
    } catch (error, stackTrace) {
      if (database != null) {
        try {
          database.execute('ROLLBACK;');
        } on Object {
          // Preserve the read operation's original failure.
        }
      }
      try {
        database?.close();
      } on Object {
        // Preserve the read operation's original failure.
      }
      database = null;
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      database?.close();
    }
  }

  void _ensureSchema(Database database, {required String schema}) {
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_store_meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_document_records (
        scope TEXT NOT NULL,
        record_key TEXT NOT NULL,
        value_json TEXT NOT NULL,
        PRIMARY KEY (scope, record_key)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_document_vclock (
        scope TEXT NOT NULL,
        actor TEXT NOT NULL,
        counter INTEGER NOT NULL,
        PRIMARY KEY (scope, actor)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_document_event_digests (
        scope TEXT NOT NULL,
        dot TEXT NOT NULL,
        digest TEXT NOT NULL,
        PRIMARY KEY (scope, dot)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_business_records (
        kind TEXT NOT NULL,
        record_key TEXT NOT NULL,
        value_json TEXT NOT NULL,
        PRIMARY KEY (kind, record_key)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_received (
        filename TEXT PRIMARY KEY NOT NULL
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_outbox (
        batch_id TEXT PRIMARY KEY NOT NULL,
        actor TEXT NOT NULL,
        counter INTEGER NOT NULL,
        manifest BLOB NOT NULL,
        UNIQUE (actor, counter)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_snapshot_objects (
        path TEXT PRIMARY KEY NOT NULL,
        content BLOB NOT NULL
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_outbox_objects (
        batch_id TEXT NOT NULL,
        path TEXT NOT NULL,
        PRIMARY KEY (batch_id, path),
        FOREIGN KEY (batch_id) REFERENCES merge_outbox(batch_id) ON DELETE CASCADE,
        FOREIGN KEY (path) REFERENCES merge_snapshot_objects(path)
      );
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS $schema.merge_outbox_changed_records (
        batch_id TEXT NOT NULL,
        record_key TEXT NOT NULL,
        PRIMARY KEY (batch_id, record_key),
        FOREIGN KEY (batch_id) REFERENCES merge_outbox(batch_id) ON DELETE CASCADE
      );
    ''');
    database.execute('PRAGMA $schema.user_version = 1;');
    final storedActor = database.select(
      "SELECT value FROM $schema.merge_store_meta WHERE key = 'actor';",
    );
    if (storedActor.isNotEmpty && storedActor.single['value'] != actor) {
      throw _DatabaseActorMismatch(
        actor,
        storedActor.single['value'] as String,
        metadata: _diagnosticIdentityMetadata(),
      );
    }
  }

  _DatabaseCommitView _readCommitView(
    Database database, {
    required String schema,
  }) {
    final meta = <String, String>{
      for (final row in database.select(
        'SELECT key, value FROM $schema.merge_store_meta;',
      ))
        row['key'] as String: row['value'] as String,
    };
    if (meta['actor'] != null && meta['actor'] != actor) {
      throw _DatabaseActorMismatch(
        actor,
        meta['actor']!,
        metadata: _diagnosticIdentityMetadata(),
      );
    }
    final rawRevision = meta['commitRevision'];
    final revision = int.tryParse(rawRevision ?? '');
    final canonicalRevision =
        revision != null && revision > 0 && '$revision' == rawRevision
        ? revision
        : null;
    final ownCounterRows = database.select(
      '''
      SELECT counter FROM $schema.merge_document_vclock
      WHERE scope = 'document' AND actor = ?;
      ''',
      [actor],
    );
    final identities = <String, (String, int)>{};
    for (final row in database.select('''
      SELECT batch_id, actor, counter FROM $schema.merge_outbox
      ORDER BY batch_id ASC;
      ''')) {
      identities[row['batch_id'] as String] = (
        row['actor'] as String,
        row['counter'] as int,
      );
    }
    final hasDurableData = database.select('''
          SELECT 1
          WHERE EXISTS (SELECT 1 FROM $schema.merge_store_meta)
             OR EXISTS (SELECT 1 FROM $schema.merge_document_vclock)
             OR EXISTS (SELECT 1 FROM $schema.merge_document_event_digests)
             OR EXISTS (SELECT 1 FROM $schema.merge_document_records)
             OR EXISTS (SELECT 1 FROM $schema.merge_business_records)
             OR EXISTS (SELECT 1 FROM $schema.merge_received)
             OR EXISTS (SELECT 1 FROM $schema.merge_outbox)
             OR EXISTS (SELECT 1 FROM $schema.merge_outbox_objects)
             OR EXISTS (SELECT 1 FROM $schema.merge_snapshot_objects)
             OR EXISTS (SELECT 1 FROM $schema.merge_outbox_changed_records);
        ''').isNotEmpty;
    return _DatabaseCommitView(
      revision: canonicalRevision,
      ownCounter: ownCounterRows.isEmpty
          ? 0
          : ownCounterRows.single['counter'] as int,
      meta: meta,
      outboxIdentities: identities,
      hasDurableData: hasDurableData,
    );
  }

  void _assertCommitViews(
    Database database,
    _DatabaseCommitView main,
    _DatabaseCommitView replica, {
    required int ownCounter,
    required Set<String> desiredOutboxIds,
    required Set<String> removedOutboxIds,
    required Set<String> addedOutboxIds,
  }) {
    if (main.revision == replica.revision &&
        _hasReplicaStateDifference(database)) {
      throw MergeStoreReplicaDivergenceException(
        metadata: _divergenceMetadata(
          phase: 'commit',
          loadedRevision: _persistedRevision,
          mainRevision: main.revision,
          replicaRevision: replica.revision,
          mainOwnCounter: main.ownCounter,
          replicaOwnCounter: replica.ownCounter,
          ownCounter: ownCounter,
          mainOutboxIds: main.outboxIdentities.keys,
          replicaOutboxIds: replica.outboxIdentities.keys,
          desiredOutboxIds: desiredOutboxIds,
          removedOutboxIds: removedOutboxIds,
          addedOutboxIds: addedOutboxIds,
          reason: 'same_revision_different_state',
        ),
      );
    }
    if (main.revision != replica.revision ||
        main.revision != _persistedRevision ||
        replica.revision != _persistedRevision) {
      throw MergeStoreStaleStateException(
        metadata: _divergenceMetadata(
          phase: 'commit',
          loadedRevision: _persistedRevision,
          mainRevision: main.revision,
          replicaRevision: replica.revision,
          mainOwnCounter: main.ownCounter,
          replicaOwnCounter: replica.ownCounter,
          ownCounter: ownCounter,
          mainOutboxIds: main.outboxIdentities.keys,
          replicaOutboxIds: replica.outboxIdentities.keys,
          desiredOutboxIds: desiredOutboxIds,
          removedOutboxIds: removedOutboxIds,
          addedOutboxIds: addedOutboxIds,
          reason: 'revision_changed',
        ),
      );
    }
    final legacyStateChanged =
        !_persistedFingerprintStored &&
        (!_matchesLoadedTables(database, schema: 'main') ||
            !_matchesLoadedTables(database, schema: 'replica'));
    if (!_matchesLoadedView(main) ||
        !_matchesLoadedView(replica) ||
        legacyStateChanged) {
      throw MergeStoreStaleStateException(
        metadata: _divergenceMetadata(
          phase: 'commit',
          loadedRevision: _persistedRevision,
          mainRevision: main.revision,
          replicaRevision: replica.revision,
          mainOwnCounter: main.ownCounter,
          replicaOwnCounter: replica.ownCounter,
          ownCounter: ownCounter,
          mainOutboxIds: main.outboxIdentities.keys,
          replicaOutboxIds: replica.outboxIdentities.keys,
          desiredOutboxIds: desiredOutboxIds,
          removedOutboxIds: removedOutboxIds,
          addedOutboxIds: addedOutboxIds,
          reason: 'durable_state_changed',
        ),
      );
    }
  }

  bool _hasReplicaStateDifference(Database database) => database.select('''
        SELECT 1
        WHERE EXISTS (
          SELECT 1 FROM main.merge_store_meta AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_store_meta AS r
            WHERE r.key = m.key AND r.value IS m.value
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_store_meta AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_store_meta AS m
            WHERE m.key = r.key AND m.value IS r.value
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_document_vclock AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_document_vclock AS r
            WHERE r.scope = m.scope AND r.actor = m.actor
              AND r.counter IS m.counter
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_document_vclock AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_document_vclock AS m
            WHERE m.scope = r.scope AND m.actor = r.actor
              AND m.counter IS r.counter
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_document_event_digests AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_document_event_digests AS r
            WHERE r.scope = m.scope AND r.dot = m.dot
              AND r.digest IS m.digest
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_document_event_digests AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_document_event_digests AS m
            WHERE m.scope = r.scope AND m.dot = r.dot
              AND m.digest IS r.digest
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_document_records AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_document_records AS r
            WHERE r.scope = m.scope AND r.record_key = m.record_key
              AND r.value_json IS m.value_json
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_document_records AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_document_records AS m
            WHERE m.scope = r.scope AND m.record_key = r.record_key
              AND m.value_json IS r.value_json
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_business_records AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_business_records AS r
            WHERE r.kind = m.kind AND r.record_key = m.record_key
              AND r.value_json IS m.value_json
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_business_records AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_business_records AS m
            WHERE m.kind = r.kind AND m.record_key = r.record_key
              AND m.value_json IS r.value_json
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_received AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_received AS r
            WHERE r.filename = m.filename
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_received AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_received AS m
            WHERE m.filename = r.filename
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_outbox AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_outbox AS r
            WHERE r.batch_id = m.batch_id AND r.actor IS m.actor
              AND r.counter IS m.counter AND r.manifest IS m.manifest
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_outbox AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_outbox AS m
            WHERE m.batch_id = r.batch_id AND m.actor IS r.actor
              AND m.counter IS r.counter AND m.manifest IS r.manifest
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_outbox_objects AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_outbox_objects AS r
            WHERE r.batch_id = m.batch_id AND r.path = m.path
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_outbox_objects AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_outbox_objects AS m
            WHERE m.batch_id = r.batch_id AND m.path = r.path
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_snapshot_objects AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_snapshot_objects AS r
            WHERE r.path = m.path AND r.content IS m.content
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_snapshot_objects AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_snapshot_objects AS m
            WHERE m.path = r.path AND m.content IS r.content
          )
        )
        OR EXISTS (
          SELECT 1 FROM main.merge_outbox_changed_records AS m
          WHERE NOT EXISTS (
            SELECT 1 FROM replica.merge_outbox_changed_records AS r
            WHERE r.batch_id = m.batch_id AND r.record_key = m.record_key
          )
        )
        OR EXISTS (
          SELECT 1 FROM replica.merge_outbox_changed_records AS r
          WHERE NOT EXISTS (
            SELECT 1 FROM main.merge_outbox_changed_records AS m
            WHERE m.batch_id = r.batch_id AND m.record_key = r.record_key
          )
        )
        LIMIT 1;
      ''').isNotEmpty;

  void _assertOutboxSlots(
    Map<String, (String, int)> persistedIdentities,
    Map<String, MergeBatch> proposedBatches,
    Set<String> addedIds, {
    required int? mainRevision,
    required int? replicaRevision,
    required int ownCounter,
    required int mainOwnCounter,
    required int replicaOwnCounter,
    required Set<String> desiredOutboxIds,
    required Set<String> removedOutboxIds,
  }) {
    for (final entry in proposedBatches.entries) {
      final persisted = persistedIdentities[entry.key];
      final batch = entry.value;
      if (persisted != null && persisted != (batch.actor, batch.counter)) {
        throw MergeStoreIntegrityException(
          metadata: {
            'phase': 'commit',
            'reason': 'persisted_batch_identity_changed',
            'actor': actor,
            'counter': batch.counter,
            if (_isSafeBatchId(batch.id)) 'batchId': batch.id,
          },
        );
      }
    }
    final slotOwners = <(String, int), String>{
      for (final entry in persistedIdentities.entries) entry.value: entry.key,
    };
    for (final id in addedIds.toList()..sort()) {
      final batch = proposedBatches[id]!;
      final slot = (batch.actor, batch.counter);
      final existingId = slotOwners[slot];
      if (existingId != null && existingId != id) {
        throw MergeOutboxCounterConflictException(
          actor: batch.actor,
          counter: batch.counter,
          existingBatchId: existingId,
          incomingBatchId: id,
          metadata: {
            'phase': 'commit',
            'loadedRevision': _persistedRevision,
            'mainRevision': mainRevision,
            'replicaRevision': replicaRevision,
            'ownCounter': ownCounter,
            'mainOwnCounter': mainOwnCounter,
            'replicaOwnCounter': replicaOwnCounter,
            'persistedOutboxIds': _safeBatchIds(
              _persistedOutboxIdentities.keys,
            ),
            'desiredOutboxIds': _safeBatchIds(desiredOutboxIds),
            'removedOutboxIds': _safeBatchIds(removedOutboxIds),
            'addedOutboxIds': _safeBatchIds(addedIds),
          },
        );
      }
      slotOwners[slot] = id;
    }
  }

  void _validateBatchCausalCompatibility(
    MergeBatch batch, {
    required MergeDocument document,
    required MergeDocument localObservation,
    required String phase,
  }) {
    try {
      batch.document.validateEventIdentities(document);
      batch.document.validateEventIdentities(localObservation);
    } on FormatException {
      throw MergeStoreIntegrityException(
        metadata: {
          'phase': phase,
          'reason': 'outbox_event_identity_conflict',
          'actor': batch.actor,
          'counter': batch.counter,
          if (_isSafeBatchId(batch.id)) 'batchId': batch.id,
        },
      );
    }
  }

  int? _committedRevisionIfPresent(
    Database database, {
    required String schema,
  }) {
    if (!_hasTable(database, schema: schema, table: 'merge_store_meta')) {
      return null;
    }
    final metadata = <String, String>{
      for (final row in database.select('''
        SELECT key, value FROM $schema.merge_store_meta
        WHERE key IN ('actor', 'commitRevision');
        '''))
        row['key'] as String: row['value'] as String,
    };
    final storedActor = metadata['actor'];
    if (storedActor != null && storedActor != actor) {
      throw _DatabaseActorMismatch(
        actor,
        storedActor,
        metadata: _diagnosticIdentityMetadata(),
      );
    }
    final rawRevision = metadata['commitRevision'];
    final revision = int.tryParse(rawRevision ?? '');
    if (storedActor != actor ||
        revision == null ||
        revision <= 0 ||
        '$revision' != rawRevision) {
      return null;
    }
    return revision;
  }

  Map<String, Object?> _freshInitializationMetadata(
    Database database, {
    required int? mainRevision,
    required int? replicaRevision,
    required int ownCounter,
    required Set<String> desiredOutboxIds,
    required Set<String> removedOutboxIds,
    required Set<String> addedOutboxIds,
  }) => _divergenceMetadata(
    phase: 'freshInitialization',
    loadedRevision: null,
    mainRevision: mainRevision,
    replicaRevision: replicaRevision,
    mainOwnCounter: _readOwnCounter(database, schema: 'main'),
    ownCounter: ownCounter,
    replicaOwnCounter: _readOwnCounter(database, schema: 'replica'),
    mainOutboxIds: _readOutboxIds(database, schema: 'main'),
    replicaOutboxIds: _readOutboxIds(database, schema: 'replica'),
    desiredOutboxIds: desiredOutboxIds,
    removedOutboxIds: removedOutboxIds,
    addedOutboxIds: addedOutboxIds,
    reason: 'durable_store_appeared',
  );

  int _readOwnCounter(Database database, {required String schema}) {
    if (!_hasTable(database, schema: schema, table: 'merge_document_vclock')) {
      return 0;
    }
    final rows = database.select(
      '''
      SELECT counter FROM $schema.merge_document_vclock
      WHERE scope = 'document' AND actor = ?;
      ''',
      [actor],
    );
    return rows.isEmpty ? 0 : rows.single['counter'] as int;
  }

  List<String> _readOutboxIds(Database database, {required String schema}) {
    if (!_hasTable(database, schema: schema, table: 'merge_outbox')) {
      return const <String>[];
    }
    return [
      for (final row in database.select(
        'SELECT batch_id FROM $schema.merge_outbox ORDER BY batch_id;',
      ))
        row['batch_id'] as String,
    ];
  }

  bool _hasTable(
    Database database, {
    required String schema,
    required String table,
  }) => database.select(
    'SELECT 1 FROM $schema.sqlite_master WHERE type = ? AND name = ?;',
    ['table', table],
  ).isNotEmpty;

  bool _isEmptyCommitView(_DatabaseCommitView view) =>
      view.revision == null && !view.hasDurableData;

  bool _matchesLoadedView(_DatabaseCommitView view) =>
      view.revision == _persistedRevision &&
      view.ownCounter == _persistedOwnCounter &&
      _sameMap(view.meta, _persistedMeta) &&
      _sameMap(view.outboxIdentities, _persistedOutboxIdentities) &&
      _sameSet(view.outboxIdentities.keys.toSet(), _persistedOutboxIds) &&
      view.meta['commitFingerprint'] ==
          (_persistedFingerprintStored ? _persistedStateFingerprint : null);

  bool _matchesLoadedTables(Database database, {required String schema}) {
    try {
      final meta = <String, String>{
        for (final row in database.select(
          'SELECT key, value FROM $schema.merge_store_meta;',
        ))
          row['key'] as String: row['value'] as String,
      };
      if (!_sameMap(meta, _persistedMeta)) return false;

      var rowCount = 0;
      bool rowMatches(String kind, String scope, String key, String value) {
        rowCount++;
        return _persistedRows[(kind, scope, key)] == _rowFingerprint(value);
      }

      for (final row in database.select(
        'SELECT scope, actor, counter FROM $schema.merge_document_vclock;',
      )) {
        final scope = row['scope'] as String;
        final actor = row['actor'] as String;
        final counter = row['counter'] as int;
        if (!rowMatches('vclock', scope, actor, '$counter')) return false;
      }
      for (final row in database.select(
        'SELECT scope, dot, digest FROM $schema.merge_document_event_digests;',
      )) {
        if (!rowMatches(
          'event',
          row['scope'] as String,
          row['dot'] as String,
          row['digest'] as String,
        )) {
          return false;
        }
      }
      for (final row in database.select(
        'SELECT scope, record_key, value_json FROM $schema.merge_document_records;',
      )) {
        if (!rowMatches(
          'doc',
          row['scope'] as String,
          row['record_key'] as String,
          row['value_json'] as String,
        )) {
          return false;
        }
      }
      for (final row in database.select(
        'SELECT kind, record_key, value_json FROM $schema.merge_business_records;',
      )) {
        if (!rowMatches(
          row['kind'] as String,
          '',
          row['record_key'] as String,
          row['value_json'] as String,
        )) {
          return false;
        }
      }
      if (rowCount != _persistedRows.length) return false;

      var receivedCount = 0;
      for (final row in database.select(
        'SELECT filename FROM $schema.merge_received;',
      )) {
        receivedCount++;
        if (!_persistedReceived.contains(row['filename'] as String)) {
          return false;
        }
      }
      if (receivedCount != _persistedReceived.length) return false;

      var outboxCount = 0;
      for (final row in database.select('''
        SELECT batch_id, actor, counter, manifest
        FROM $schema.merge_outbox
        ORDER BY batch_id ASC;
        ''')) {
        final id = row['batch_id'] as String;
        final batchActor = row['actor'] as String;
        final counter = row['counter'] as int;
        final manifest = row['manifest'];
        if (manifest is! List<int> ||
            _persistedOutboxIdentities[id] != (batchActor, counter)) {
          return false;
        }
        outboxCount++;
        final objectRows = database.select(
          '''
          SELECT refs.path, objects.content
          FROM $schema.merge_outbox_objects AS refs
          LEFT JOIN $schema.merge_snapshot_objects AS objects
            ON objects.path = refs.path
          WHERE refs.batch_id = ?
          ORDER BY refs.path ASC;
          ''',
          [id],
        );
        final objectFingerprints = <String, String>{};
        for (final objectRow in objectRows) {
          final path = objectRow['path'] as String;
          final content = objectRow['content'];
          if (path.isEmpty ||
              content is! List<int> ||
              objectFingerprints.containsKey(path)) {
            return false;
          }
          objectFingerprints[path] = sha256.convert(content).toString();
        }
        final fingerprint = _outboxFingerprint(
          id: id,
          batchActor: batchActor,
          counter: counter,
          manifestDigest: sha256.convert(manifest).toString(),
          objectFingerprints: objectFingerprints,
        );
        if (_persistedOutboxFingerprints[id] != fingerprint) return false;
      }
      if (outboxCount != _persistedOutboxIdentities.length) return false;

      var changedRecordCount = 0;
      for (final row in database.select(
        'SELECT batch_id, record_key FROM $schema.merge_outbox_changed_records;',
      )) {
        final batchId = row['batch_id'] as String;
        final key = row['record_key'] as String;
        changedRecordCount++;
        if (!(_persistedOutboxChangedRecords[batchId]?.contains(key) ??
            false)) {
          return false;
        }
      }
      final expectedChangedRecordCount = _persistedOutboxChangedRecords.values
          .fold<int>(0, (total, keys) => total + keys.length);
      if (changedRecordCount != expectedChangedRecordCount ||
          database.select('''
                SELECT 1 FROM $schema.merge_outbox_objects AS refs
                WHERE NOT EXISTS (
                  SELECT 1 FROM $schema.merge_outbox AS batches
                  WHERE batches.batch_id = refs.batch_id
                )
                LIMIT 1;
              ''').isNotEmpty ||
          database.select('''
                SELECT 1 FROM $schema.merge_snapshot_objects AS objects
                WHERE NOT EXISTS (
                  SELECT 1 FROM $schema.merge_outbox_objects AS refs
                  WHERE refs.path = objects.path
                )
                LIMIT 1;
              ''').isNotEmpty) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _isSafeBatchId(String id) => _safeBatchIdPattern.hasMatch(id);

  List<String> _safeBatchIds(Iterable<String> ids) {
    final safeIds = [
      for (final id in ids)
        if (_isSafeBatchId(id)) id,
    ]..sort();
    return safeIds;
  }

  Map<String, Object?> _divergenceMetadata({
    required String phase,
    required int? loadedRevision,
    required int? mainRevision,
    required int? replicaRevision,
    required int mainOwnCounter,
    required int replicaOwnCounter,
    Iterable<String> mainOutboxIds = const <String>[],
    Iterable<String> replicaOutboxIds = const <String>[],
    Iterable<String> desiredOutboxIds = const <String>[],
    Iterable<String> removedOutboxIds = const <String>[],
    Iterable<String> addedOutboxIds = const <String>[],
    required String reason,
    int? ownCounter,
  }) => {
    ..._diagnosticIdentityMetadata(),
    'phase': phase,
    'reason': reason,
    'actor': actor,
    'loadedRevision': ?loadedRevision,
    'diskMainRevision': ?mainRevision,
    'diskReplicaRevision': ?replicaRevision,
    'mainRevision': ?mainRevision,
    if (loadedRevision != null) 'loadedOwnCounter': _persistedOwnCounter,
    'ownCounter': ?ownCounter,
    'replicaRevision': ?replicaRevision,
    'mainOwnCounter': mainOwnCounter,
    'replicaOwnCounter': replicaOwnCounter,
    'mainOutboxIds': _safeBatchIds(mainOutboxIds),
    'replicaOutboxIds': _safeBatchIds(replicaOutboxIds),
    'persistedOutboxIds': _safeBatchIds(_persistedOutboxIdentities.keys),
    'desiredOutboxIds': _safeBatchIds(desiredOutboxIds),
    'removedOutboxIds': _safeBatchIds(removedOutboxIds),
    'addedOutboxIds': _safeBatchIds(addedOutboxIds),
  };

  Map<(String, String, String), String> _encodeRows(
    Map<String, MergeDocument> documents,
    SyncRecords observed,
    SyncRecords? pendingApply,
    Map<String, Map<String, String>> localEdits,
  ) {
    final result = <(String, String, String), String>{};
    final document = documents['document']!;
    final docJson = document.toJson();
    for (final entry in documents.entries) {
      final json = entry.key == 'document' ? docJson : entry.value.toJson();
      final scope = entry.key;
      final vclock = (json['vclock'] as Map).cast<String, Object?>();
      for (final counter in vclock.entries) {
        result[('vclock', scope, counter.key)] = '${counter.value}';
      }
      final eventDigests = (json['eventDigests'] as Map)
          .cast<String, Object?>();
      for (final event in eventDigests.entries) {
        result[('event', scope, event.key)] = event.value as String;
      }
      final records = (json['records'] as Map).cast<String, Object?>();
      for (final record in records.entries) {
        result[('doc', scope, record.key)] = canonicalSyncJson(record.value);
      }
    }
    final eventDigests = (docJson['eventDigests'] as Map)
        .cast<String, String>();
    for (final entry in localEdits.entries) {
      _validateRecordKey(entry.key);
      if (entry.value.isEmpty) continue;
      for (final fieldEntry in entry.value.entries) {
        if (fieldEntry.key.isEmpty) {
          throw const FormatException('Invalid local edit field');
        }
        final dot = MergeDot.parse(fieldEntry.value);
        if (dot.actor != actor ||
            dot.counter > document.counterFor(actor) ||
            !eventDigests.containsKey(fieldEntry.value) ||
            !_hasLocalEditCandidate(
              docJson,
              entry.key,
              fieldEntry.key,
              fieldEntry.value,
            )) {
          throw const FormatException('Invalid local edit candidate');
        }
      }
      result[('localEdits', '', entry.key)] = canonicalSyncJson(entry.value);
    }
    for (final entry in observed.entries) {
      result[('observed', '', entry.key)] = canonicalSyncJson(entry.value);
    }
    if (pendingApply != null) {
      for (final entry in pendingApply.entries) {
        result[('pendingApply', '', entry.key)] = canonicalSyncJson(
          entry.value,
        );
      }
    }
    return result;
  }

  void _applyRowDiff(
    Database database,
    Map<(String, String, String), String> next, {
    required String schema,
    required Map<(String, String, String), String> fingerprints,
  }) {
    for (final entry in _persistedRows.entries) {
      if (next.containsKey(entry.key)) continue;
      final (kind, scope, key) = entry.key;
      switch (kind) {
        case 'doc':
          database.execute(
            'DELETE FROM $schema.merge_document_records WHERE scope = ? AND record_key = ?;',
            [scope, key],
          );
          break;
        case 'vclock':
          database.execute(
            'DELETE FROM $schema.merge_document_vclock WHERE scope = ? AND actor = ?;',
            [scope, key],
          );
          break;
        case 'event':
          database.execute(
            'DELETE FROM $schema.merge_document_event_digests WHERE scope = ? AND dot = ?;',
            [scope, key],
          );
          break;
        case 'observed':
        case 'pendingApply':
        case 'localEdits':
          database.execute(
            'DELETE FROM $schema.merge_business_records WHERE kind = ? AND record_key = ?;',
            [kind, key],
          );
          break;
      }
    }
    for (final entry in next.entries) {
      if (_persistedRows[entry.key] == fingerprints[entry.key]) continue;
      final (kind, scope, key) = entry.key;
      switch (kind) {
        case 'doc':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_document_records(scope, record_key, value_json)
            VALUES (?, ?, ?);
            ''',
            [scope, key, entry.value],
          );
          break;
        case 'vclock':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_document_vclock(scope, actor, counter)
            VALUES (?, ?, ?);
            ''',
            [scope, key, int.parse(entry.value)],
          );
          break;
        case 'event':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_document_event_digests(scope, dot, digest)
            VALUES (?, ?, ?);
            ''',
            [scope, key, entry.value],
          );
          break;
        case 'observed':
        case 'pendingApply':
        case 'localEdits':
          database.execute(
            '''
            INSERT OR REPLACE INTO $schema.merge_business_records(kind, record_key, value_json)
            VALUES (?, ?, ?);
            ''',
            [kind, key, entry.value],
          );
          break;
      }
    }
  }

  void _applyMetaDiff(
    Database database,
    Map<String, String> next, {
    required String schema,
  }) {
    for (final entry in next.entries) {
      if (_persistedMeta[entry.key] == entry.value) continue;
      database.execute(
        'INSERT OR REPLACE INTO $schema.merge_store_meta(key, value) VALUES (?, ?);',
        [entry.key, entry.value],
      );
    }
    for (final key in _persistedMeta.keys) {
      if (!next.containsKey(key)) {
        database.execute(
          'DELETE FROM $schema.merge_store_meta WHERE key = ?;',
          [key],
        );
      }
    }
  }

  void _applyReceivedDiff(
    Database database,
    Set<String> next, {
    required String schema,
  }) {
    for (final filename in _persistedReceived.difference(next)) {
      database.execute(
        'DELETE FROM $schema.merge_received WHERE filename = ?;',
        [filename],
      );
    }
    for (final filename in next.difference(_persistedReceived)) {
      database.execute(
        'INSERT INTO $schema.merge_received(filename) VALUES (?);',
        [filename],
      );
    }
  }

  void _applyOutboxChanges(
    Database database, {
    required String schema,
    required Set<String> removed,
    required Set<String> added,
    required Map<String, MergeBatch> newBatches,
    required Set<String> deltaChanges,
    required Map<String, Set<String>> changedRecords,
    required Map<String, MergeSnapshot> newSnapshots,
  }) {
    for (final id in removed) {
      database.execute(
        'DELETE FROM $schema.merge_outbox_objects WHERE batch_id = ?;',
        [id],
      );
      database.execute(
        'DELETE FROM $schema.merge_outbox_changed_records WHERE batch_id = ?;',
        [id],
      );
      database.execute('DELETE FROM $schema.merge_outbox WHERE batch_id = ?;', [
        id,
      ]);
    }
    for (final id in added) {
      final batch = newBatches[id]!;
      final snapshot = newSnapshots[id]!;
      final manifest = snapshot.serializeManifest();
      database.execute(
        '''
        INSERT INTO $schema.merge_outbox(batch_id, actor, counter, manifest)
        VALUES (?, ?, ?, ?);
        ''',
        [batch.id, batch.actor, batch.counter, manifest],
      );
      for (final entry in snapshot.objects.entries) {
        final prior = database.select(
          'SELECT content FROM $schema.merge_snapshot_objects WHERE path = ?;',
          [entry.key],
        );
        if (prior.isNotEmpty &&
            !_bytesEqual(_asBytes(prior.single['content']), entry.value)) {
          throw const FormatException(
            'Snapshot object path has conflicting content',
          );
        }
        if (prior.isEmpty) {
          database.execute(
            'INSERT INTO $schema.merge_snapshot_objects(path, content) VALUES (?, ?);',
            [entry.key, entry.value],
          );
        }
        database.execute(
          'INSERT INTO $schema.merge_outbox_objects(batch_id, path) VALUES (?, ?);',
          [id, entry.key],
        );
      }
    }
    for (final id in deltaChanges.difference(removed)) {
      database.execute(
        'DELETE FROM $schema.merge_outbox_changed_records WHERE batch_id = ?;',
        [id],
      );
      for (final key in changedRecords[id] ?? const <String>{}) {
        database.execute(
          'INSERT INTO $schema.merge_outbox_changed_records(batch_id, record_key) VALUES (?, ?);',
          [id, key],
        );
      }
    }
    if (removed.isNotEmpty) {
      database.execute('''
        DELETE FROM $schema.merge_snapshot_objects AS objects
        WHERE NOT EXISTS (
          SELECT 1 FROM $schema.merge_outbox_objects AS refs
          WHERE refs.path = objects.path
        );
      ''');
    }
  }

  Future<void> _repairBackupFromPrimary() async {
    if (!await _exists(_databaseFile)) return;
    final temporary = File('${_backupFile.path}.tmp');
    await _databaseFile.copy(temporary.path);
    await temporary.rename(_backupFile.path);
  }

  Future<void> _restorePrimaryFromBackup() async {
    final temporary = File('${_databaseFile.path}.restore.tmp');
    await _backupFile.copy(temporary.path);
    await temporary.rename(_databaseFile.path);
  }

  void _ensureLoaded() {
    if (!_loaded || !_databaseExists) {
      throw StateError('MergeStore database must successfully load before use');
    }
  }


  static Map<String, Object?> _decodeCanonicalObject(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('Expected a JSON record object');
    }
    final result = value.cast<String, Object?>();
    if (canonicalSyncJson(result) != encoded) {
      throw const FormatException('Noncanonical SQLite record row');
    }
    return result;
  }

  static bool _hasLocalEditCandidate(
    Map<String, Object?> documentJson,
    String recordKey,
    String field,
    String id,
  ) {
    final records = (documentJson['records'] as Map).cast<String, Object?>();
    final rawRecord = records[recordKey];
    if (rawRecord is! Map) return false;
    final record = rawRecord.cast<String, Object?>();
    if (field == 'presence') {
      return _cellHasDot(record['presence'], id);
    }
    if (field == 'readDurationMs') {
      return _cellHasDot(record['bases'], id) ||
          _cellHasDot(record['contributions'], id);
    }
    final fields = (record['fields'] as Map).cast<String, Object?>();
    return _cellHasDot(fields[field], id);
  }

  static bool _cellHasDot(Object? rawCell, String id) {
    if (rawCell is! Map) return false;
    final seen = rawCell['seen'];
    return seen is Map && seen.containsKey(id);
  }

  static Set<String> _decodeDomains(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! List) throw const FormatException('Invalid pending domains');
    final domains = <String>{};
    for (final domain in value) {
      if (domain is! String ||
          !{'source', 'sourceSession'}.contains(domain) ||
          !domains.add(domain)) {
        throw const FormatException('Invalid pending domains');
      }
    }
    if (canonicalSyncJson(value) != encoded) {
      throw const FormatException('Noncanonical pending domains');
    }
    return domains;
  }

  static void _validateRecordKey(String key) {
    final identity = decodeSyncRecordKey(key);
    if (identity.isEmpty ||
        identity.first is! String ||
        (identity.first as String).isEmpty) {
      throw const FormatException('Invalid business record identity');
    }
    _validateJson(identity);
  }

  static void _validateJson(Object? value) {
    if (value == null || value is bool || value is String) return;
    if (value is num && value.isFinite) return;
    if (value is List) {
      for (final item in value) {
        _validateJson(item);
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const FormatException('JSON map key is not a string');
        }
        _validateJson(entry.value);
      }
      return;
    }
    throw const FormatException('Invalid JSON business field');
  }

  static Uint8List _asBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    throw const FormatException('Invalid SQLite snapshot bytes');
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameCriticalState(
    MergeStoreDatabaseState left,
    MergeStoreDatabaseState right,
  ) =>
      _sameMap(left.persistedRows, right.persistedRows) &&
      _sameMap(left.persistedMeta, right.persistedMeta) &&
      _sameSet(left.received, right.received) &&
      _sameSet(left.outboxIds.toSet(), right.outboxIds.toSet()) &&
      _sameMap(left.outboxIdentities, right.outboxIdentities) &&
      _sameMap(left.outboxFingerprints, right.outboxFingerprints) &&
      _sameSetMap(left.outboxChangedRecords, right.outboxChangedRecords);
  static bool _hasValidStoredFingerprint(MergeStoreDatabaseState state) =>
      !state.hasCommitFingerprint ||
      state.persistedMeta['commitFingerprint'] == state.commitFingerprint;

  static bool _sameSetMap(
    Map<String, Set<String>> left,
    Map<String, Set<String>> right,
  ) =>
      left.length == right.length &&
      left.entries.every(
        (entry) =>
            right.containsKey(entry.key) &&
            _sameSet(entry.value, right[entry.key]!),
      );

  static String _outboxFingerprint({
    required String id,
    required String batchActor,
    required int counter,
    required String manifestDigest,
    required Map<String, String> objectFingerprints,
  }) {
    final objects = objectFingerprints.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return _rowFingerprint(
      canonicalSyncJson({
        'id': id,
        'actor': batchActor,
        'counter': counter,
        'manifest': manifestDigest,
        'objects': [
          for (final object in objects)
            {'path': object.key, 'digest': object.value},
        ],
      }),
    );
  }

  static String _stateFingerprint({
    required Map<(String, String, String), String> rows,
    required Map<String, String> meta,
    required Set<String> received,
    required Map<String, (String, int)> outboxIdentities,
    required Map<String, String> outboxFingerprints,
    required Map<String, Set<String>> outboxChangedRecords,
  }) {
    final digestSink = _DigestSink();
    final output = sha256.startChunkedConversion(digestSink);
    void addJson(Object? value) {
      output.add(utf8.encode(canonicalSyncJson(value)));
      output.add(utf8.encode('\n'));
    }

    final fingerprintFreeMeta = Map<String, String>.of(meta)
      ..remove('commitFingerprint');
    addJson(['meta', fingerprintFreeMeta]);

    final rowKeys = rows.keys.toList()
      ..sort((left, right) {
        final kind = left.$1.compareTo(right.$1);
        if (kind != 0) return kind;
        final scope = left.$2.compareTo(right.$2);
        return scope != 0 ? scope : left.$3.compareTo(right.$3);
      });
    for (final key in rowKeys) {
      addJson(['row', key.$1, key.$2, key.$3, rows[key]]);
    }

    final receivedNames = received.toList()..sort();
    for (final name in receivedNames) {
      addJson(['received', name]);
    }

    final identities = outboxIdentities.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in identities) {
      addJson(['outboxIdentity', entry.key, entry.value.$1, entry.value.$2]);
    }
    final outboxIds = outboxFingerprints.keys.toList()..sort();
    for (final id in outboxIds) {
      addJson(['outboxContent', id, outboxFingerprints[id]]);
    }

    final changedBatches = outboxChangedRecords.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in changedBatches) {
      final recordKeys = entry.value.toList()..sort();
      addJson(['changedRecords', entry.key, recordKeys]);
    }

    output.close();
    return digestSink.value!.toString();
  }

  static bool _sameRowValues(
    Map<(String, String, String), String> persisted,
    Map<(String, String, String), String> next,
  ) =>
      persisted.length == next.length &&
      next.entries.every(
        (entry) => persisted[entry.key] == _rowFingerprint(entry.value),
      );

  static String _rowFingerprint(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static bool _sameMap<K, V>(Map<K, V> left, Map<K, V> right) =>
      left.length == right.length &&
      left.entries.every((entry) => right[entry.key] == entry.value);

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);

  static Future<bool> _exists(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound;
}

class MergeStoreDatabaseState {
  final MergeDocument document;
  final MergeDocument localObservation;
  final SyncRecords observed;
  final Set<String> received;
  final List<String> outboxIds;
  final Map<String, (String, int)> outboxIdentities;
  final Map<String, String> outboxFingerprints;
  final SyncRecords? pendingApply;
  final Set<String> pendingUnavailableDomains;
  final Map<String, Set<String>> outboxChangedRecords;
  final bool initialized;
  final bool hasCompletedSync;
  final Map<String, Map<String, String>> localEdits;
  final bool recoveredFromBackup;
  final Map<(String, String, String), String> persistedRows;
  final Map<String, String> persistedMeta;
  final int commitRevision;
  final String commitFingerprint;
  final bool hasCommitFingerprint;

  const MergeStoreDatabaseState({
    required this.document,
    required this.localObservation,
    required this.observed,
    required this.received,
    required this.outboxIds,
    required this.pendingApply,
    required this.outboxIdentities,
    required this.outboxFingerprints,
    required this.outboxChangedRecords,
    required this.pendingUnavailableDomains,
    required this.initialized,
    this.hasCompletedSync = false,
    this.localEdits = const {},
    required this.recoveredFromBackup,
    required this.persistedRows,
    required this.persistedMeta,
    required this.commitRevision,
    required this.commitFingerprint,
    required this.hasCommitFingerprint,
  });
  MergeStoreDatabaseState withRecovery(bool value) => MergeStoreDatabaseState(
    document: document,
    localObservation: localObservation,
    observed: observed,
    received: received,
    outboxIds: outboxIds,
    outboxIdentities: outboxIdentities,
    outboxFingerprints: outboxFingerprints,
    pendingApply: pendingApply,
    outboxChangedRecords: outboxChangedRecords,
    pendingUnavailableDomains: pendingUnavailableDomains,
    initialized: initialized,
    hasCompletedSync: hasCompletedSync,
    localEdits: localEdits,
    recoveredFromBackup: value,
    persistedRows: persistedRows,
    persistedMeta: persistedMeta,
    commitRevision: commitRevision,
    commitFingerprint: commitFingerprint,
    hasCommitFingerprint: hasCommitFingerprint,
  );
}

class _DatabaseCommitView {
  final int? revision;
  final int ownCounter;
  final Map<String, String> meta;
  final Map<String, (String, int)> outboxIdentities;
  final bool hasDurableData;

  const _DatabaseCommitView({
    required this.revision,
    required this.ownCounter,
    required this.meta,
    required this.outboxIdentities,
    required this.hasDurableData,
  });
}

class _DatabaseActorMismatch extends StateError {
  _DatabaseActorMismatch(
    String expected,
    String actual, {
    Map<String, Object?> metadata = const {},
  }) : super(
         MergeStoreIntegrityException(
           metadata: {
             'phase': 'load',
             'reason': 'actor_mismatch',
             'actor': expected,
             'storedActor': actual,
             ...metadata,
           },
         ).toString(),
       );

  @override
  String toString() => message;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest digest) {
    value = digest;
  }

  @override
  void close() {}
}
