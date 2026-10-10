import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../../foundation/sync_records.dart';
import 'merge_engine.dart';
import 'merge_snapshot.dart';
import 'merge_store_database.dart';
import 'merge_store_error.dart';
import 'sync_initialization_diagnostics.dart';
export '../../foundation/sync_records.dart';
export 'merge_engine.dart';

/// Endpoint-bound, pure Dart persistence for merge checkpoints and business apply.
///
/// A single state commit contains the document, outbox, observed business baseline,
/// per-field local edit candidates, sync-completion marker and pending apply.
/// Stage/resolve commits precede business writes; only completeApply advances the
/// baseline and retires the pending apply. There is no separately deleted journal
/// that can replay a completed operation.
class MergeStore {
  final Directory directory;
  final String instanceId = SyncInitializationDiagnostics.nextInstanceId(
    'store',
  );
  final String actor;
  MergeDocument _document = MergeDocument();
  MergeDocument _localObservation = MergeDocument();
  final Map<String, Map<String, String>> _localEdits = {};
  bool _hasCompletedSync = false;
  bool _completionMarkerPersisted = false;
  SyncRecords _observed = {};
  final Set<String> _received = {};
  final List<String> _outboxIds = [];
  final Map<String, MergeBatch> _outboxCache = {};
  final Map<String, Set<String>> _outboxChangedRecords = {};
  final Map<String, MergeSnapshot> _outboxSnapshotCache = {};
  final Map<String, int> _pendingRecordKeyCounts = {};
  late final MergeStoreDatabase _database;
  SyncRecords? _pendingApply;
  Set<String> _pendingUnavailableDomains = const {};
  bool _initialized = false;
  bool _loaded = false;
  bool _saving = false;
  bool _recoveredFromBackup = false;
  bool _needsCounterReconciliation = false;
  bool _counterReconciliationVerified = false;
  bool _counterFloorDirty = false;

  MergeStore(this.directory, this.actor) {
    if (actor.isEmpty) {
      throw ArgumentError.value(actor, 'actor', 'Must not be empty');
    }
    _database = MergeStoreDatabase(directory, actor);
  }

  MergeDocument get document => _document;
  bool get hasCompletedSync => _hasCompletedSync;
  String? manualCandidateId(String recordKey, String field) =>
      _localEdits[recordKey]?[field];
  bool get needsRecovery => !_loaded;

  /// A business backup changes the physical baseline outside merge application.
  /// Keep durable intent intact and require a fresh validated view before capture.
  void invalidateForBusinessRestore() {
    _loaded = false;
  }

  /// Causality of the last actually observed business state, not merely received
  /// or published checkpoints. Callers retain this branch across transfer retries.
  MergeDocument get localObservation => _localObservation.clone();
  SyncRecords get observed => cloneSyncRecords(_observed);
  Set<String> get received => Set.unmodifiable(_received);
  SyncRecords? get pendingApply =>
      _pendingApply == null ? null : cloneSyncRecords(_pendingApply!);
  List<MergeBatch> get outbox => UnmodifiableListView(_OutboxView(this));
  int get pendingRecordCount => _pendingRecordKeyCounts.length;
  List<String> get pendingBatchIds => List.unmodifiable(_outboxIds);
  MergeBatch pendingBatch(String id) {
    _ensureLoaded();
    if (!_outboxIds.contains(id)) {
      throw StateError('No pending merge batch with id "$id"');
    }
    return _outboxCache[id] ??
        _database.pendingBatch(id, currentDocument: _document);
  }

  MergeSnapshot pendingSnapshot(String id) {
    _ensureLoaded();
    if (!_outboxIds.contains(id)) {
      throw StateError('No pending merge batch with id "$id"');
    }
    return _outboxSnapshotCache[id] ??= _database.pendingSnapshot(id);
  }

  Set<String> get pendingUnavailableDomains =>
      Set.unmodifiable(_pendingUnavailableDomains);
  Set<String> get pendingScope => pendingUnavailableDomains;

  /// Recovery may have lost publication counters. The controller must reconcile
  /// OWN-actor remote checkpoints before replay/capture, even for an empty cloud.
  bool get recoveredFromBackup => _recoveredFromBackup;

  File get _stateFile => File('${directory.path}/state.json');
  File get _backupFile => File('${_stateFile.path}.bak');
  File get _temporaryFile => File('${_stateFile.path}.tmp');

  Future<void> load({SyncInitializationDiagnostics? diagnostics}) async {
    if (_saving) throw StateError('A state commit is in progress');
    final context =
        diagnostics ??
        SyncInitializationDiagnostics(
          trigger: 'merge_store.load',
          actor: actor,
          stateDirectory: directory.path,
        );
    if (context.logger != null) {
      context.record(
        'load.begin',
        values: {
          'storeInstanceId': instanceId,
          'databaseInstanceId': _database.instanceId,
        },
      );
    }
    _loaded = false;
    await directory.create(recursive: true);

    // The unpublished split-journal protocol is deliberately not migrated.
    // Any journal evidence must stop startup, never silently skip partial apply.
    for (final suffix in ['', '.tmp', '.bak']) {
      final journal = File('${directory.path}/apply_journal.json$suffix');
      if (await _exists(journal)) {
        throw MergeStoreIntegrityException(
          metadata: {
            'phase': 'load',
            'reason': 'unsupported_separate_apply_journal',
            'actor': actor,
          },
        );
      }
    }

    final databaseState = await _database.load(diagnostics: context);
    _StoreState? legacyState;
    var recovered = databaseState?.recoveredFromBackup ?? false;
    if (databaseState == null) {
      Object? primaryError;
      if (await _exists(_stateFile)) {
        try {
          legacyState = await _readState(_stateFile);
        } on _StoreActorMismatch {
          rethrow; // A valid state belonging to another actor is not corruption.
        } catch (error) {
          primaryError = error;
        }
      }
      if (legacyState == null && await _exists(_backupFile)) {
        try {
          legacyState = await _readState(_backupFile);
          recovered = true;
        } on _StoreActorMismatch {
          rethrow;
        } catch (error) {
          throw MergeStoreIntegrityException(
            metadata: {
              'phase': 'load',
              'reason': 'no_valid_legacy_state',
              'actor': actor,
              'primaryErrorType': primaryError?.runtimeType.toString(),
              'backupErrorType': error.runtimeType.toString(),
            },
          );
        }
      }
      if (legacyState == null) {
        final hasPrimary = await _exists(_stateFile);
        final hasTemporary = await _exists(_temporaryFile);
        final hasBackupTemporary = await _exists(
          File('${_backupFile.path}.tmp'),
        );
        if (hasPrimary || hasTemporary || hasBackupTemporary) {
          // A temp file alone is an interrupted first commit, not a fresh endpoint.
          // Recover its fully validated state, but force counter reconciliation.
          if (!hasPrimary && hasTemporary && !hasBackupTemporary) {
            try {
              legacyState = await _readState(_temporaryFile);
              recovered = true;
            } on _StoreActorMismatch {
              rethrow;
            } catch (error) {
              throw MergeStoreIntegrityException(
                metadata: {
                  'phase': 'load',
                  'reason': 'invalid_temporary_legacy_state',
                  'actor': actor,
                  'errorType': error.runtimeType.toString(),
                },
              );
            }
          } else {
            throw MergeStoreIntegrityException(
              metadata: {
                'phase': 'load',
                'reason': 'no_valid_legacy_state',
                'actor': actor,
                'primaryErrorType': primaryError?.runtimeType.toString(),
              },
            );
          }
        }
      }
    }

    _document =
        databaseState?.document ?? legacyState?.document ?? MergeDocument();
    _localObservation =
        databaseState?.localObservation ??
        legacyState?.localObservation ??
        MergeDocument();
    _observed = cloneSyncRecords(
      databaseState?.observed ?? legacyState?.observed ?? {},
    );
    _received
      ..clear()
      ..addAll(databaseState?.received ?? legacyState?.received ?? {});
    _outboxIds
      ..clear()
      ..addAll(
        databaseState?.outboxIds ??
            legacyState?.outbox.map((batch) => batch.id) ??
            const <String>[],
      );
    _outboxCache
      ..clear()
      ..addEntries(
        (legacyState?.outbox ?? const <MergeBatch>[]).map(
          (batch) => MapEntry(batch.id, batch),
        ),
      );
    _outboxSnapshotCache.clear();
    _outboxChangedRecords.clear();
    _pendingRecordKeyCounts.clear();
    final legacyChangedRecords = <String, Set<String>>{
      for (final batch in legacyState?.outbox ?? const <MergeBatch>[])
        batch.id: batch.document.recordKeys.toSet(),
    };
    final changedRecords =
        databaseState?.outboxChangedRecords ?? legacyChangedRecords;
    for (final entry in changedRecords.entries) {
      _setOutboxChangedRecords(entry.key, entry.value);
    }
    _pendingApply = databaseState?.pendingApply == null
        ? (legacyState?.pendingApply == null
              ? null
              : cloneSyncRecords(legacyState!.pendingApply!))
        : cloneSyncRecords(databaseState!.pendingApply!);
    _pendingUnavailableDomains = Set.unmodifiable(
      databaseState?.pendingUnavailableDomains ??
          legacyState?.pendingUnavailableDomains ??
          const <String>{},
    );
    _localEdits
      ..clear()
      ..addAll({
        for (final entry
            in databaseState?.localEdits.entries ??
                const <MapEntry<String, Map<String, String>>>[])
          entry.key: Map<String, String>.of(entry.value),
      });
    _hasCompletedSync = databaseState?.hasCompletedSync ?? _received.isNotEmpty;
    _completionMarkerPersisted =
        databaseState?.persistedMeta.containsKey('hasCompletedSync') ?? false;
    _initialized =
        databaseState?.initialized ?? legacyState?.initialized ?? false;
    _recoveredFromBackup = recovered;
    _needsCounterReconciliation = recovered;
    _counterReconciliationVerified = false;
    _counterFloorDirty = false;
    _loaded = true;
    if (databaseState == null && legacyState != null) await save();
    if (context.logger != null) {
      final phase = databaseState != null
          ? 'load.existing'
          : legacyState != null
          ? 'load.legacy'
          : 'load.empty';
      context.record(
        phase,
        values: {
          'storeInstanceId': instanceId,
          'databaseInstanceId': _database.instanceId,
          'ownCounter': _document.counterFor(actor),
          'outboxCount': _outboxIds.length,
        },
      );
    }
  }

  /// Captures local business differences. The first capture, including an empty
  /// one, durably establishes the original-profile baseline. Later new readings
  /// are contributions, not shared legacy baselines.
  Future<void> capture(
    SyncRecords records, {
    MergeDocument? observation,
    SyncRecords? previous,
    Map<String, List<Map<String, Object?>>>? sourceVariants,
    Set<String> unavailableDomains = const {},
  }) async {
    _ensureCanAllocate();
    _validateUnavailableDomains(unavailableDomains);
    if (_pendingApply != null) {
      throw StateError(
        'Complete or cancel pending business apply before capture',
      );
    }
    final current = _parseSyncRecords(records);
    final baseline = previous == null ? _observed : _parseSyncRecords(previous);

    final filteredBaseline = unavailableDomains.isEmpty
        ? baseline
        : Map<String, Map<String, Object?>>.fromEntries(
            baseline.entries.where(
              (e) => !unavailableDomains.contains(syncRecordDomain(e.key)),
            ),
          );
    final filteredCurrent = unavailableDomains.isEmpty
        ? current
        : Map<String, Map<String, Object?>>.fromEntries(
            current.entries.where(
              (e) => !unavailableDomains.contains(syncRecordDomain(e.key)),
            ),
          );
    final changedRecordKeys = _changedRecordKeys(
      filteredBaseline,
      filteredCurrent,
    );
    if (!_initialized) changedRecordKeys.addAll(filteredCurrent.keys);

    final branch = observation?.clone() ?? _localObservation.clone();
    // Allocation and own cumulative prefixes are not remote causal observation.
    branch.setCounterFloor(actor, _document.counterFor(actor));
    final counter = branch.captureLocal(
      actor,
      filteredBaseline,
      filteredCurrent,
      bootstrap: !_initialized,
      contributionFloor: _document,
    );

    var newVariantsAdded = false;
    final sourceVariantRecordKeys = <String>{};
    final effectiveVariants =
        (sourceVariants == null || unavailableDomains.isEmpty)
        ? sourceVariants
        : Map<String, List<Map<String, Object?>>>.fromEntries(
            sourceVariants.entries.where(
              (e) => !unavailableDomains.contains(syncRecordDomain(e.key)),
            ),
          );
    if (effectiveVariants != null && effectiveVariants.isNotEmpty) {
      for (final entry in effectiveVariants.entries) {
        final recordKey = entry.key;
        for (final script in entry.value) {
          final seedDoc = MergeDocument.createSourceVariantSeed(
            recordKey,
            script,
          );
          if (!_document.dominates(seedDoc)) {
            _document.merge(seedDoc);
            _localObservation.merge(seedDoc);
            branch.merge(seedDoc);
            if (observation != null) {
              observation.merge(seedDoc);
            }
            newVariantsAdded = true;
            sourceVariantRecordKeys.add(recordKey);
          }
        }
      }
    }

    if (counter > 0) {
      _document.merge(branch);
      _addOutbox(
        MergeBatch.create(actor: actor, counter: counter, document: _document),
        changedRecordKeys: {...changedRecordKeys, ...sourceVariantRecordKeys},
      );
      if (_initialized) {
        _recordCaptureManualChanges(
          filteredBaseline,
          filteredCurrent,
          MergeDot(actor, counter).toKey(),
        );
      }
      if (unavailableDomains.isEmpty) {
        _localObservation = branch.clone();
      } else {
        _localObservation = _mergeLocalObservations(
          oldLocal: _localObservation,
          appliedObservation: branch,
          unavailableDomains: unavailableDomains,
        );
      }
    } else if (newVariantsAdded) {
      final checkpointCounter = _document.reserveCounter(actor);
      _addOutbox(
        MergeBatch.create(
          actor: actor,
          counter: checkpointCounter,
          document: _document,
        ),
        changedRecordKeys: sourceVariantRecordKeys,
      );
    }

    final SyncRecords nextObserved;
    if (unavailableDomains.isEmpty) {
      nextObserved = current;
    } else {
      nextObserved = <String, Map<String, Object?>>{};
      for (final entry in _observed.entries) {
        if (unavailableDomains.contains(syncRecordDomain(entry.key))) {
          nextObserved[entry.key] = entry.value;
        }
      }
      for (final entry in filteredCurrent.entries) {
        nextObserved[entry.key] = entry.value;
      }
    }

    var localObservationChanged = false;
    if (counter == 0 && observation != null) {
      final completeObservation = _localObservation.clone()..merge(branch);
      final nextLocalObservation = _mergeLocalObservations(
        oldLocal: _localObservation,
        appliedObservation: completeObservation,
        unavailableDomains: unavailableDomains,
      );
      if (!_document.dominates(nextLocalObservation)) {
        throw ArgumentError('Local observation is not covered by the document');
      }
      if (!syncValuesEqual(
        _localObservation.toJson(),
        nextLocalObservation.toJson(),
      )) {
        _localObservation = nextLocalObservation;
        localObservationChanged = true;
      }
    }

    final shouldSave =
        counter > 0 ||
        newVariantsAdded ||
        localObservationChanged ||
        !_initialized ||
        _counterFloorDirty ||
        !syncValuesEqual(_observed, nextObserved);
    _initialized = true;
    _observed = nextObserved;
    if (shouldSave) await save();
    // Retain only local branch causality for subsequent generation-guard retries.
    // Never merge the incoming main document into the caller's observation.
    if (counter > 0 && observation != null) observation.merge(branch);
  }

  Future<MergeBatch> enqueueCheckpoint() async {
    _ensureCanAllocate();
    final counter = _document.reserveCounter(actor);
    final batch = MergeBatch.create(
      actor: actor,
      counter: counter,
      document: _document,
    );
    _addOutbox(batch);
    await save();
    return batch;
  }

  /// Called only after successful remote reconciliation, including an empty
  /// listing. Floors own allocation without manufacturing observed causality.
  void reconcileActorCounter(
    String targetActor,
    int highestKnownCounter, {
    Iterable<String> verifiedFilenames = const [],
  }) {
    _ensureLoaded();
    if (targetActor != actor || highestKnownCounter < 0) {
      throw ArgumentError(
        'Only a nonnegative OWN-actor counter may be reconciled',
      );
    }
    if (_needsCounterReconciliation ||
        highestKnownCounter > _document.counterFor(actor)) {
      _counterFloorDirty = true;
    }
    for (final filename in verifiedFilenames) {
      if (_received.add(filename)) _counterFloorDirty = true;
    }
    _document.setCounterFloor(actor, highestKnownCounter);
    _needsCounterReconciliation = false;
    _counterReconciliationVerified = true;
  }

  /// Commits the apply target together with the document/outbox before DB writes.
  Future<void> stageApply(
    SyncRecords records, {
    Set<String> unavailableDomains = const {},
  }) async {
    _ensureLoaded();
    _validateUnavailableDomains(unavailableDomains);
    _pendingApply = _parseSyncRecords(records);
    _pendingUnavailableDomains = Set<String>.unmodifiable({
      ..._pendingUnavailableDomains,
      ...unavailableDomains,
    });
    _validateUnavailableDomains(_pendingUnavailableDomains);
    await save();
  }

  /// The caller reports the business state actually committed. Passing the old
  /// observed state also cancels an apply aborted by the beforeCommit guard.
  /// [observation] is the applied policy-visible causal view. Keep contexts for
  /// allowed tombstones; filter forbidden records, not materialized record keys.
  Future<void> completeApply(
    SyncRecords records, {
    MergeDocument? observation,
    Set<String> unavailableDomains = const {},
  }) async {
    _ensureLoaded();
    _validateUnavailableDomains(unavailableDomains);
    if (_pendingApply == null) throw StateError('No business apply is staged');
    final effectiveUnavailable = {
      ..._pendingUnavailableDomains,
      ...unavailableDomains,
    };
    _validateUnavailableDomains(effectiveUnavailable);
    final actual = _parseSyncRecords(records);
    if (observation != null || syncValuesEqual(actual, _pendingApply)) {
      final appliedObservation = observation ?? _document;
      if (!_document.dominates(appliedObservation)) {
        throw ArgumentError(
          'Applied observation is not covered by the document',
        );
      }
      if (effectiveUnavailable.isEmpty) {
        _localObservation = appliedObservation.clone();
      } else {
        _localObservation = _mergeLocalObservations(
          oldLocal: _localObservation,
          appliedObservation: appliedObservation,
          unavailableDomains: effectiveUnavailable,
        );
      }
    }
    if (effectiveUnavailable.isEmpty) {
      _observed = actual;
    } else {
      final updatedObserved = <String, Map<String, Object?>>{};
      for (final entry in _observed.entries) {
        if (effectiveUnavailable.contains(syncRecordDomain(entry.key))) {
          updatedObserved[entry.key] = entry.value;
        }
      }
      for (final entry in actual.entries) {
        if (!effectiveUnavailable.contains(syncRecordDomain(entry.key))) {
          updatedObserved[entry.key] = entry.value;
        }
      }
      _observed = updatedObserved;
    }
    _pendingApply = null;
    _pendingUnavailableDomains = const {};
    _initialized = true;
    await save();
  }

  /// Cancels an apply that was aborted before any business commit. The caller
  /// must not use cancellation to skip recovery of partially written databases.
  Future<void> cancelApply() async {
    _ensureLoaded();
    _pendingApply = null;
    _pendingUnavailableDomains = const {};
    await save();
  }

  /// Preserves physical edits made during an interrupted multi-database apply.
  /// A physical value may equal the old observed value even though the pending
  /// target differs, so comparison must be against that TARGET, not observed.
  /// The empty-seen branch keeps these differences concurrent with the target:
  /// partial writes and user edits cannot reliably be distinguished after crash.
  /// [previous] lets the controller project the pending target to the same local
  /// opt-in policy as [records], without manufacturing forbidden-key deletions.
  Future<SyncRecords> recoverPendingApply(
    SyncRecords records, {
    SyncRecords? previous,
    Map<String, List<Map<String, Object?>>>? sourceVariants,
    Set<String> unavailableDomains = const {},
  }) async {
    _ensureCanAllocate();
    _validateUnavailableDomains(unavailableDomains);
    if (_pendingApply == null) throw StateError('No business apply is staged');
    final effectiveUnavailable = {
      ..._pendingUnavailableDomains,
      ...unavailableDomains,
    };
    _validateUnavailableDomains(effectiveUnavailable);
    final actual = _parseSyncRecords(records);
    final target = _parseSyncRecords(previous ?? _pendingApply!);

    final filteredTarget = effectiveUnavailable.isEmpty
        ? target
        : Map<String, Map<String, Object?>>.fromEntries(
            target.entries.where(
              (e) => !effectiveUnavailable.contains(syncRecordDomain(e.key)),
            ),
          );
    final filteredActual = effectiveUnavailable.isEmpty
        ? actual
        : Map<String, Map<String, Object?>>.fromEntries(
            actual.entries.where(
              (e) => !effectiveUnavailable.contains(syncRecordDomain(e.key)),
            ),
          );
    final changedRecordKeys = _changedRecordKeys(
      filteredTarget,
      filteredActual,
    );
    final confirmedManualChanges = _confirmedRecoveryManualChanges(
      target: filteredTarget,
      actual: filteredActual,
      previous: _observed,
    );

    final branch = MergeDocument();
    branch.setCounterFloor(actor, _document.counterFor(actor));
    final counter = branch.captureLocal(
      actor,
      filteredTarget,
      filteredActual,
      bootstrap: false,
      contributionFloor: _document,
    );

    var newVariantsAdded = false;
    final sourceVariantRecordKeys = <String>{};
    final effectiveVariants =
        (sourceVariants == null || effectiveUnavailable.isEmpty)
        ? sourceVariants
        : Map<String, List<Map<String, Object?>>>.fromEntries(
            sourceVariants.entries.where(
              (e) => !effectiveUnavailable.contains(syncRecordDomain(e.key)),
            ),
          );
    if (effectiveVariants != null && effectiveVariants.isNotEmpty) {
      for (final entry in effectiveVariants.entries) {
        final recordKey = entry.key;
        for (final script in entry.value) {
          final seedDoc = MergeDocument.createSourceVariantSeed(
            recordKey,
            script,
          );
          if (!_document.dominates(seedDoc)) {
            _document.merge(seedDoc);
            _localObservation.merge(seedDoc);
            branch.merge(seedDoc);
            newVariantsAdded = true;
            sourceVariantRecordKeys.add(recordKey);
          }
        }
      }
    }

    if (counter > 0) {
      _document.merge(branch);
      if (effectiveUnavailable.isEmpty) {
        _localObservation.merge(branch);
      } else {
        _localObservation = _mergeLocalObservations(
          oldLocal: _localObservation,
          appliedObservation: branch,
          unavailableDomains: effectiveUnavailable,
        );
      }
      _addOutbox(
        MergeBatch.create(actor: actor, counter: counter, document: _document),
        changedRecordKeys: {...changedRecordKeys, ...sourceVariantRecordKeys},
      );
      if (confirmedManualChanges.isNotEmpty) {
        _recordManualChanges(
          confirmedManualChanges,
          MergeDot(actor, counter).toKey(),
        );
      }
    } else if (newVariantsAdded) {
      final checkpointCounter = _document.reserveCounter(actor);
      _addOutbox(
        MergeBatch.create(
          actor: actor,
          counter: checkpointCounter,
          document: _document,
        ),
        changedRecordKeys: sourceVariantRecordKeys,
      );
    }

    if (effectiveUnavailable.isEmpty) {
      _observed = actual;
    } else {
      final updatedObserved = <String, Map<String, Object?>>{};
      for (final entry in _observed.entries) {
        if (effectiveUnavailable.contains(syncRecordDomain(entry.key))) {
          updatedObserved[entry.key] = entry.value;
        }
      }
      for (final entry in filteredActual.entries) {
        updatedObserved[entry.key] = entry.value;
      }
      _observed = updatedObserved;
    }
    _initialized = true;
    _pendingApply = _document.materialize(preferred: actual);
    _pendingUnavailableDomains = Set<String>.unmodifiable(effectiveUnavailable);
    await save();
    return cloneSyncRecords(_pendingApply!);
  }

  Future<void> markReceived(String filename) async {
    _ensureLoaded();
    if (filename.isEmpty) throw ArgumentError.value(filename, 'filename');
    _received.add(filename);
    await save();
  }

  Future<void> completeSync() async {
    _ensureLoaded();
    if (_hasCompletedSync && _completionMarkerPersisted) return;
    _hasCompletedSync = true;
    await save();
  }

  /// Acknowledging an old immutable checkpoint never clears newer publications.
  Future<void> acknowledge(String id) async {
    _ensureLoaded();
    _removeOutbox(id);
    await save();
  }

  /// Resolves a batch atomically in one durable state commit. The observed
  /// baseline remains the old business state until completeApply.
  Future<void> resolveAll(
    List<MergeConflictResolution> resolutions, {
    Set<String> unavailableDomains = const {},
    bool manual = true,
  }) async {
    _ensureCanAllocate();
    _validateUnavailableDomains(unavailableDomains);
    if (_pendingApply != null) {
      throw StateError(
        'Complete or cancel pending business apply before resolve',
      );
    }
    if (resolutions.isEmpty) {
      throw ArgumentError.value(
        resolutions,
        'resolutions',
        'Must not be empty',
      );
    }

    final stagedDocument = _document.clone();
    final activeConflicts = {
      for (final conflict in stagedDocument.conflicts)
        (conflict.recordKey, conflict.field): conflict,
    };
    final selectedConflicts = <(String, String)>{};
    for (final resolution in resolutions) {
      if (resolution.recordKey.isEmpty ||
          resolution.field.isEmpty ||
          resolution.candidateId.isEmpty) {
        throw ArgumentError.value(resolution, 'resolutions');
      }
      final key = (resolution.recordKey, resolution.field);
      if (!selectedConflicts.add(key)) {
        throw StateError('Duplicate conflict resolution request');
      }
      final conflict = activeConflicts[key];
      if (conflict == null ||
          !conflict.candidates.any(
            (candidate) => candidate.id == resolution.candidateId,
          )) {
        throw StateError('Conflict candidate is invalid or stale');
      }
      final expectedCandidateIds = resolution.expectedCandidateIds;
      if (expectedCandidateIds != null &&
          (expectedCandidateIds.length != conflict.candidates.length ||
              !conflict.candidates.every(
                (candidate) => expectedCandidateIds.contains(candidate.id),
              ))) {
        throw StateError('Conflict candidate is invalid or stale');
      }
      if (resolution.expectedCandidateFingerprint != null &&
          conflict.candidateFingerprint !=
              resolution.expectedCandidateFingerprint) {
        throw StateError('Conflict candidate is invalid or stale');
      }
      final domain = syncRecordDomain(resolution.recordKey);
      if (unavailableDomains.contains(domain)) {
        throw StateError(
          'Cannot resolve conflict for unavailable domain "$domain"',
        );
      }
    }
    final stagedManualCandidates = {
      for (final entry in _localEdits.entries)
        entry.key: Map<String, String>.of(entry.value),
    };
    void resolveAndTrack(MergeConflictResolution resolution) {
      final previousManualId =
          stagedManualCandidates[resolution.recordKey]?[resolution.field];
      final preservesManualCandidate =
          resolution.candidateId == previousManualId ||
          (resolution.field == 'readDurationMs' &&
              resolution.candidateId == 'accumulated_total' &&
              previousManualId != null &&
              stagedDocument.hasActiveDurationContribution(
                resolution.recordKey,
                previousManualId,
              ));
      stagedDocument.resolve(
        actor,
        resolution.recordKey,
        resolution.field,
        resolution.candidateId,
      );
      final fields = stagedManualCandidates.putIfAbsent(
        resolution.recordKey,
        () => <String, String>{},
      );
      if (manual || preservesManualCandidate) {
        fields[resolution.field] = MergeDot(
          actor,
          stagedDocument.counterFor(actor),
        ).toKey();
      } else {
        fields.remove(resolution.field);
        if (fields.isEmpty) stagedManualCandidates.remove(resolution.recordKey);
      }
    }

    // Resolve ordinary cells before presence: a chosen deletion can make the
    // record inactive, but must not invalidate another selection from this batch.
    for (final resolution in resolutions) {
      if (resolution.field == 'presence') continue;
      resolveAndTrack(resolution);
    }
    for (final resolution in resolutions) {
      if (resolution.field != 'presence') continue;
      resolveAndTrack(resolution);
    }

    final checkpoint = MergeBatch.create(
      actor: actor,
      counter: stagedDocument.counterFor(actor),
      document: stagedDocument,
    );
    final pendingApply = stagedDocument.materialize(preferred: _observed);
    final pendingUnavailableDomains = Set<String>.unmodifiable(
      unavailableDomains,
    );
    _document = stagedDocument;
    _addOutbox(
      checkpoint,
      changedRecordKeys: {
        for (final resolution in resolutions) resolution.recordKey,
      },
    );
    _localEdits
      ..clear()
      ..addAll(stagedManualCandidates);
    _pendingApply = pendingApply;
    _pendingUnavailableDomains = pendingUnavailableDomains;
    try {
      await save();
    } catch (error) {
      throw MergeStorePersistenceException(error);
    }
  }

  /// Successful return means primary and backup received the same incremental
  /// commit through one SQLite attached-database transaction.
  /// IO failures are never hidden; this instance is fail-closed until reload.
  Future<void> save() async {
    _ensureLoaded();
    _saving = true;
    try {
      final newSnapshots = await _database.commit(
        document: _document,
        localObservation: _localObservation,
        observed: _observed,
        received: _received,
        outboxIds: _outboxIds,
        newOutboxBatches: _outboxCache,
        outboxChangedRecords: _outboxChangedRecords,
        pendingApply: _pendingApply,
        pendingUnavailableDomains: _pendingUnavailableDomains,
        initialized: _initialized,
        localEdits: _localEdits,
        hasCompletedSync: _hasCompletedSync,
        counterReconciliationRequired: _needsCounterReconciliation
            ? true
            : _counterReconciliationVerified
            ? false
            : null,
      );
      _outboxSnapshotCache.addAll(newSnapshots);
      _outboxCache.clear();
      _completionMarkerPersisted = true;

      _counterFloorDirty = false;
      _counterReconciliationVerified = false;
    } catch (_) {
      _loaded = false;
      rethrow;
    } finally {
      _saving = false;
    }
  }

  void _addOutbox(
    MergeBatch batch, {
    Set<String> changedRecordKeys = const {},
  }) {
    try {
      if (batch.actor != actor ||
          batch.counter <= 0 ||
          batch.document.counterFor(actor) != batch.counter) {
        throw MergeStoreIntegrityException(
          metadata: {'phase': 'queue', 'actor': actor, 'batchId': batch.id},
        );
      }
      final mergedChangedKeys = Set<String>.of(changedRecordKeys);
      final dominatedIds = <String>[];
      var alreadyQueued = false;
      // Inspect the complete queue before changing it. Coverage cannot authorize
      // giving a different publication the same allocation identity.
      for (final priorId in _outboxIds) {
        final prior = pendingBatch(priorId);
        if (priorId == batch.id) {
          if (prior.actor != batch.actor ||
              prior.counter != batch.counter ||
              !syncValuesEqual(
                prior.document.toJson(),
                batch.document.toJson(),
              )) {
            throw MergeStoreIntegrityException(
              metadata: {
                'phase': 'queue',
                'reason': 'batch_identity_changed',
                'actor': actor,
                'batchId': batch.id,
                'counter': batch.counter,
              },
            );
          }
          alreadyQueued = true;
          mergedChangedKeys.addAll(_outboxChangedRecords[priorId] ?? const {});
          continue;
        }
        if (prior.actor == batch.actor && prior.counter == batch.counter) {
          throw MergeOutboxCounterConflictException(
            actor: batch.actor,
            counter: batch.counter,
            existingBatchId: prior.id,
            incomingBatchId: batch.id,
            metadata: {
              'phase': 'queue',
              'ownCounter': _document.counterFor(actor),
            },
          );
        }
        if (batch.document.dominates(prior.document)) {
          mergedChangedKeys.addAll(_outboxChangedRecords[priorId] ?? const {});
          dominatedIds.add(priorId);
        }
      }
      for (final id in dominatedIds) {
        _removeOutbox(id);
      }
      if (!alreadyQueued) _outboxIds.add(batch.id);
      _outboxCache[batch.id] = batch;
      _setOutboxChangedRecords(batch.id, mergedChangedKeys);
    } catch (_) {
      // The enclosing capture may already have changed its in-memory document.
      // Never allocate again from that failed attempt; durable load is required.
      _loaded = false;
      rethrow;
    }
  }

  void _setOutboxChangedRecords(String id, Set<String> recordKeys) {
    _removeOutboxChangedRecords(id);
    if (recordKeys.isEmpty) return;
    final copy = Set<String>.of(recordKeys);
    _outboxChangedRecords[id] = copy;
    for (final key in copy) {
      _pendingRecordKeyCounts.update(
        key,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  void _removeOutboxChangedRecords(String id) {
    final recordKeys = _outboxChangedRecords.remove(id);
    if (recordKeys == null) return;
    for (final key in recordKeys) {
      final count = _pendingRecordKeyCounts[key]!;
      if (count == 1) {
        _pendingRecordKeyCounts.remove(key);
      } else {
        _pendingRecordKeyCounts[key] = count - 1;
      }
    }
  }

  void _removeOutbox(String id) {
    _outboxIds.remove(id);
    _outboxCache.remove(id);
    _outboxSnapshotCache.remove(id);
    _removeOutboxChangedRecords(id);
  }

  void _ensureLoaded() {
    if (!_loaded)
      throw StateError('MergeStore must successfully load before use');
    if (_saving) throw StateError('A state commit is in progress');
  }

  void _ensureCanAllocate() {
    _ensureLoaded();
    if (_needsCounterReconciliation) {
      throw StateError(
        'Reconcile restored OWN-actor counters before allocating',
      );
    }
  }

  Future<_StoreState> _readState(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['schemaVersion'] is! int) {
      throw FormatException(
        'Invalid complete merge state schema: ${file.path}',
      );
    }
    final schema = decoded['schemaVersion'] as int;
    if (schema != 1 && schema != 2) {
      throw FormatException(
        'Unsupported merge schema version: $schema in ${file.path}',
      );
    }
    final requiredKeys = schema == 1
        ? const {
            'schemaVersion',
            'actor',
            'document',
            'observed',
            'received',
            'outbox',
            'pendingApply',
            'initialized',
            'localObservation',
          }
        : const {
            'schemaVersion',
            'actor',
            'document',
            'observed',
            'received',
            'outbox',
            'pendingApply',
            'pendingUnavailableDomains',
            'initialized',
            'localObservation',
          };
    if (!_hasExactKeys(decoded, requiredKeys) ||
        decoded['actor'] is! String ||
        (decoded['actor'] as String).isEmpty ||
        decoded['initialized'] is! bool ||
        decoded['document'] is! Map ||
        decoded['localObservation'] is! Map ||
        decoded['received'] is! List ||
        decoded['outbox'] is! List) {
      throw FormatException(
        'Invalid complete merge state schema: ${file.path}',
      );
    }
    final documentJson = (decoded['document'] as Map).cast<String, Object?>();
    final document = MergeDocument.fromJson(documentJson);
    if (!syncValuesEqual(documentJson, document.toJson())) {
      throw FormatException('Noncanonical or incomplete merge document');
    }
    final observationJson = (decoded['localObservation'] as Map)
        .cast<String, Object?>();
    final localObservation = MergeDocument.fromJson(observationJson);
    if (!syncValuesEqual(observationJson, localObservation.toJson()) ||
        !document.dominates(localObservation)) {
      throw FormatException('Invalid local business causal observation');
    }
    final observed = _parseSyncRecords(decoded['observed']);
    final pending = decoded['pendingApply'] == null
        ? null
        : _parseSyncRecords(decoded['pendingApply']);
    if (decoded['initialized'] == false && observed.isNotEmpty) {
      throw FormatException('Uninitialized state has an observed baseline');
    }
    final received = <String>{};
    for (final item in decoded['received'] as List) {
      if (item is! String || item.isEmpty || !received.add(item)) {
        throw FormatException('Invalid or duplicate received filename');
      }
    }
    final outbox = <MergeBatch>[];
    final ids = <String>{};
    final counters = <int>{};
    for (final item in decoded['outbox'] as List) {
      if (item is! Map ||
          !_hasExactKeys(item, const {'actor', 'counter', 'document', 'id'}) ||
          item['actor'] != decoded['actor'] ||
          item['counter'] is! int ||
          (item['counter'] as int) <= 0 ||
          item['document'] is! Map ||
          item['id'] is! String) {
        throw FormatException('Invalid complete outbox batch');
      }
      final batch = MergeBatch.fromJson(item.cast<String, Object?>());
      final expected = MergeBatch.create(
        actor: batch.actor,
        counter: batch.counter,
        document: batch.document,
      );
      if (batch.id != expected.id ||
          !syncValuesEqual(item, batch.toJson()) ||
          batch.document.counterFor(batch.actor) != batch.counter ||
          batch.counter > document.counterFor(batch.actor) ||
          !ids.add(batch.id) ||
          !counters.add(batch.counter)) {
        throw FormatException('Invalid outbox digest, document or counter');
      }
      outbox.add(batch);
    }
    if (decoded['actor'] != actor) {
      throw _StoreActorMismatch(actor, decoded['actor'] as String);
    }
    final pendingUnavailableDomains = <String>{};
    if (schema == 2) {
      final rawDomains = decoded['pendingUnavailableDomains'];
      if (rawDomains is! List) {
        throw FormatException(
          'pendingUnavailableDomains must be a list in ${file.path}',
        );
      }
      for (final item in rawDomains) {
        if (item is! String ||
            !_validateUnavailableDomain(item) ||
            !pendingUnavailableDomains.add(item)) {
          throw FormatException(
            'Invalid or duplicate pendingUnavailableDomains item in ${file.path}',
          );
        }
      }
      if (decoded['pendingApply'] == null &&
          pendingUnavailableDomains.isNotEmpty) {
        throw FormatException(
          'pendingUnavailableDomains must be empty when pendingApply is null',
        );
      }
    }
    return _StoreState(
      document,
      localObservation,
      observed,
      received,
      outbox,
      pending,
      pendingUnavailableDomains,
      decoded['initialized'] as bool,
    );
  }

  static const _unavailableDomains = {'source', 'sourceSession'};

  static bool _validateUnavailableDomain(String domain) =>
      domain.isNotEmpty && _unavailableDomains.contains(domain);

  static void _validateUnavailableDomains(Set<String> domains) {
    if (!domains.every(_validateUnavailableDomain)) {
      throw ArgumentError.value(
        domains,
        'unavailableDomains',
        'Only source and sourceSession may be unavailable',
      );
    }
  }

  static bool _hasExactKeys(Map map, Set<String> keys) =>
      map.length == keys.length && keys.every(map.containsKey);
  static Future<bool> _exists(File file) async =>
      await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound;

  static SyncRecords _parseSyncRecords(Object? value) {
    if (value is! Map) throw FormatException('Business records must be a map');
    final records = <String, Map<String, Object?>>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw FormatException('Invalid business record');
      }
      final key = entry.key as String;
      final identity = decodeSyncRecordKey(key);
      if (identity.isEmpty ||
          identity.first is! String ||
          (identity.first as String).isEmpty) {
        throw FormatException('Invalid business record identity');
      }
      _validateJson(identity);
      final fields = entry.value as Map;
      _validateJson(fields);
      records[key] = Map<String, Object?>.from(fields);
    }
    return cloneSyncRecords(records);
  }

  static Set<String> _changedRecordKeys(
    SyncRecords baseline,
    SyncRecords current,
  ) {
    final changed = <String>{};
    for (final key in <String>{...baseline.keys, ...current.keys}) {
      if (!baseline.containsKey(key) ||
          !current.containsKey(key) ||
          !syncValuesEqual(baseline[key], current[key])) {
        changed.add(key);
      }
    }
    return changed;
  }

  void _recordCaptureManualChanges(
    SyncRecords previous,
    SyncRecords current,
    String dot,
  ) {
    final changed = <(String, String)>{};
    for (final key in <String>{...previous.keys, ...current.keys}) {
      final before = previous[key];
      final after = current[key];
      if (before == null || after == null) {
        _localEdits.remove(key);
        changed.add((key, 'presence'));
        if (after != null) {
          for (final field in after.keys) {
            changed.add((key, field));
          }
        }
        continue;
      }
      var recordChanged = false;
      for (final field in <String>{...before.keys, ...after.keys}) {
        if (!_sameFieldValue(before, after, field)) {
          changed.add((key, field));
          recordChanged = true;
        }
      }
      if (recordChanged) {
        changed.add((key, 'presence'));
      }
    }
    _recordManualChanges(changed, dot);
  }

  void _recordManualChanges(Set<(String, String)> changes, String dot) {
    for (final (recordKey, field) in changes) {
      _localEdits.putIfAbsent(recordKey, () => <String, String>{})[field] = dot;
    }
  }

  static Set<(String, String)> _confirmedRecoveryManualChanges({
    required SyncRecords target,
    required SyncRecords actual,
    required SyncRecords previous,
  }) {
    final changes = <(String, String)>{};
    for (final key in <String>{...target.keys, ...actual.keys}) {
      final targetRecord = target[key];
      final actualRecord = actual[key];
      final previousRecord = previous[key];
      if ((targetRecord != null) != (actualRecord != null) &&
          (actualRecord != null) != (previousRecord != null)) {
        changes.add((key, 'presence'));
      }
      if (actualRecord == null) continue;
      for (final field in <String>{
        ...?targetRecord?.keys,
        ...actualRecord.keys,
      }) {
        if (!_sameFieldValue(targetRecord, actualRecord, field) &&
            !_sameFieldValue(previousRecord, actualRecord, field)) {
          changes.add((key, field));
        }
      }
    }
    return changes;
  }

  static bool _sameFieldValue(
    Map<String, Object?>? left,
    Map<String, Object?>? right,
    String field,
  ) {
    final leftHas = left?.containsKey(field) ?? false;
    final rightHas = right?.containsKey(field) ?? false;
    return leftHas == rightHas &&
        (!leftHas || syncValuesEqual(left![field], right![field]));
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
        if (entry.key is! String)
          throw FormatException('JSON map key is not a string');
        _validateJson(entry.value);
      }
      return;
    }
    throw FormatException('Invalid JSON business field');
  }

  static MergeDocument _mergeLocalObservations({
    required MergeDocument oldLocal,
    required MergeDocument appliedObservation,
    required Set<String> unavailableDomains,
  }) {
    final oldJson = oldLocal.toJson();
    final appliedJson = appliedObservation.toJson();

    final records = <String, Object?>{};
    final eventDigests = <String, String>{};
    final vclock = <String, int>{};

    final oldRecords = (oldJson['records'] as Map).cast<String, Object?>();
    final appliedRecords = (appliedJson['records'] as Map)
        .cast<String, Object?>();

    for (final entry in oldRecords.entries) {
      if (unavailableDomains.contains(syncRecordDomain(entry.key))) {
        records[entry.key] = entry.value;
      }
    }
    for (final entry in appliedRecords.entries) {
      if (!unavailableDomains.contains(syncRecordDomain(entry.key))) {
        records[entry.key] = entry.value;
      }
    }

    final oldDigests = (oldJson['eventDigests'] as Map).cast<String, String>();
    final appliedDigests = (appliedJson['eventDigests'] as Map)
        .cast<String, String>();

    final presenceEvents = <String>{};
    for (final entry in records.entries) {
      final recordMap = entry.value as Map<String, Object?>;
      final presence = recordMap['presence'] as Map<String, Object?>;
      final seen = (presence['seen'] as Map).keys.cast<String>();
      presenceEvents.addAll(seen);
    }

    for (final id in presenceEvents) {
      final digest = appliedDigests[id] ?? oldDigests[id];
      if (digest != null) {
        eventDigests[id] = digest;
      }
      final dot = MergeDot.parse(id);
      vclock[dot.actor] = max(vclock[dot.actor] ?? 0, dot.counter);
    }

    // A vector clock is global, but this view is only a proof of per-record
    // observation. Rebuild actor floors from retained record events instead
    // of carrying counters whose only evidence belongs to a blocked domain.

    return MergeDocument.fromJson({
      'schema': 3,
      'vclock': vclock,
      'eventDigests': eventDigests,
      'records': records,
    });
  }
}

class _OutboxView extends ListBase<MergeBatch> {
  final MergeStore _store;

  _OutboxView(this._store);

  @override
  int get length => _store._outboxIds.length;

  @override
  set length(int value) => throw UnsupportedError('Outbox view is immutable');

  @override
  MergeBatch operator [](int index) =>
      _store.pendingBatch(_store._outboxIds[index]);

  @override
  void operator []=(int index, MergeBatch value) {
    throw UnsupportedError('Outbox view is immutable');
  }
}

class _StoreState {
  final MergeDocument document;
  final MergeDocument localObservation;
  final SyncRecords observed;
  final Set<String> received;
  final List<MergeBatch> outbox;
  final SyncRecords? pendingApply;
  final Set<String> pendingUnavailableDomains;
  final bool initialized;

  _StoreState(
    this.document,
    this.localObservation,
    this.observed,
    this.received,
    this.outbox,
    this.pendingApply,
    this.pendingUnavailableDomains,
    this.initialized,
  );
}

class _StoreActorMismatch extends StateError {
  _StoreActorMismatch(String expected, String actual)
    : super(
        MergeStoreIntegrityException(
          metadata: {
            'phase': 'load',
            'reason': 'actor_mismatch',
            'actor': expected,
            'storedActor': actual,
          },
        ).toString(),
      );

  @override
  String toString() => message;
}

/// The durable state replacement failed after the in-memory batch was staged.
/// The on-disk commit may have succeeded, so callers must allow recovery before
/// retrying a choice.
class MergeStorePersistenceException implements Exception {
  final Object cause;

  const MergeStorePersistenceException(this.cause);

  @override
  String toString() =>
      'MergeStore persistence status is uncertain: ${mergeStoreErrorMessage(cause)}';
}
