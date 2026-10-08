import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../../foundation/sync_records.dart';
import 'merge_engine.dart';

export '../../foundation/sync_records.dart';
export 'merge_engine.dart';

/// Endpoint-bound, pure Dart persistence for merge checkpoints and business apply.
///
/// A single state commit contains the document, outbox, observed business baseline,
/// initialization marker and pending apply. Stage/resolve commits precede business
/// writes; only completeApply advances the baseline and retires the pending apply.
/// There is no separately deleted journal that can replay a completed operation.
class MergeStore {
  final Directory directory;
  final String actor;

  MergeDocument _document = MergeDocument();
  MergeDocument _localObservation = MergeDocument();
  SyncRecords _observed = {};
  final Set<String> _received = {};
  final List<MergeBatch> _outbox = [];
  SyncRecords? _pendingApply;
  Set<String> _pendingUnavailableDomains = const {};
  bool _initialized = false;
  bool _loaded = false;
  bool _saving = false;
  bool _recoveredFromBackup = false;
  bool _needsCounterReconciliation = false;
  bool _counterFloorDirty = false;

  MergeStore(this.directory, this.actor) {
    if (actor.isEmpty) {
      throw ArgumentError.value(actor, 'actor', 'Must not be empty');
    }
  }

  MergeDocument get document => _document;

  /// Causality of the last actually observed business state, not merely received
  /// or published checkpoints. Callers retain this branch across transfer retries.
  MergeDocument get localObservation => _localObservation.clone();
  SyncRecords get observed => cloneSyncRecords(_observed);
  Set<String> get received => Set.unmodifiable(_received);
  SyncRecords? get pendingApply =>
      _pendingApply == null ? null : cloneSyncRecords(_pendingApply!);
  List<MergeBatch> get outbox => List.unmodifiable(_outbox);
  Set<String> get pendingUnavailableDomains =>
      Set.unmodifiable(_pendingUnavailableDomains);
  Set<String> get pendingScope => pendingUnavailableDomains;

  /// Recovery may have lost publication counters. The controller must reconcile
  /// OWN-actor remote checkpoints before replay/capture, even for an empty cloud.
  bool get recoveredFromBackup => _recoveredFromBackup;

  File get _stateFile => File('${directory.path}/state.json');
  File get _backupFile => File('${_stateFile.path}.bak');
  File get _temporaryFile => File('${_stateFile.path}.tmp');

  Future<void> load() async {
    if (_saving) throw StateError('A state commit is in progress');
    _loaded = false;
    await directory.create(recursive: true);

    // The unpublished split-journal protocol is deliberately not migrated.
    // Any journal evidence must stop startup, never silently skip partial apply.
    for (final suffix in ['', '.tmp', '.bak']) {
      final journal = File('${directory.path}/apply_journal.json$suffix');
      if (await _exists(journal)) {
        throw FormatException(
          'Unsupported separate apply journal: ${journal.path}',
        );
      }
    }

    _StoreState? state;
    Object? primaryError;
    if (await _exists(_stateFile)) {
      try {
        state = await _readState(_stateFile);
      } on _StoreActorMismatch {
        rethrow; // A valid state belonging to another actor is not corruption.
      } catch (error) {
        primaryError = error;
      }
    }
    var recovered = false;
    if (state == null && await _exists(_backupFile)) {
      try {
        state = await _readState(_backupFile);
        recovered = true;
      } on _StoreActorMismatch {
        rethrow;
      } catch (error) {
        throw FormatException(
          'Invalid merge state and backup: $primaryError; $error',
        );
      }
    }
    if (state == null) {
      final hasPrimary = await _exists(_stateFile);
      final hasTemporary = await _exists(_temporaryFile);
      final hasBackupTemporary = await _exists(File('${_backupFile.path}.tmp'));
      if (hasPrimary || hasTemporary || hasBackupTemporary) {
        // A temp file alone is an interrupted first commit, not a fresh endpoint.
        // Recover its fully validated state, but force counter reconciliation.
        if (!hasPrimary && hasTemporary && !hasBackupTemporary) {
          state = await _readState(_temporaryFile);
          recovered = true;
        } else {
          throw FormatException(
            'No valid committed merge state: $primaryError',
          );
        }
      }
    }

    _document = state?.document ?? MergeDocument();
    _localObservation = state?.localObservation ?? MergeDocument();
    _observed = state?.observed ?? {};
    _received
      ..clear()
      ..addAll(state?.received ?? {});
    _outbox
      ..clear()
      ..addAll(state?.outbox ?? []);
    _pendingApply = state?.pendingApply;
    _pendingUnavailableDomains = state?.pendingUnavailableDomains ?? const {};
    _initialized = state?.initialized ?? false;
    _recoveredFromBackup = recovered;
    _needsCounterReconciliation = recovered;
    _counterFloorDirty = false;
    _loaded = true;
    if (state == null) await save();
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
          }
        }
      }
    }

    if (counter > 0) {
      _document.merge(branch);
      _outbox.add(
        MergeBatch.create(
          actor: actor,
          counter: counter,
          document: _document.clone(),
        ),
      );
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
      _outbox.add(
        MergeBatch.create(
          actor: actor,
          counter: checkpointCounter,
          document: _document.clone(),
        ),
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

    final shouldSave =
        counter > 0 ||
        newVariantsAdded ||
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
      document: _document.clone(),
    );
    _outbox.add(batch);
    await save();
    return batch;
  }

  /// Called only after successful remote reconciliation, including an empty
  /// listing. Floors own allocation without manufacturing observed causality.
  void reconcileActorCounter(String targetActor, int highestKnownCounter) {
    _ensureLoaded();
    if (targetActor != actor || highestKnownCounter < 0) {
      throw ArgumentError(
        'Only a nonnegative OWN-actor counter may be reconciled',
      );
    }
    if (highestKnownCounter > _document.counterFor(actor)) {
      _counterFloorDirty = true;
    }
    _document.setCounterFloor(actor, highestKnownCounter);
    _needsCounterReconciliation = false;
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
      _outbox.add(
        MergeBatch.create(
          actor: actor,
          counter: counter,
          document: _document.clone(),
        ),
      );
    } else if (newVariantsAdded) {
      final checkpointCounter = _document.reserveCounter(actor);
      _outbox.add(
        MergeBatch.create(
          actor: actor,
          counter: checkpointCounter,
          document: _document.clone(),
        ),
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

  /// Acknowledging an old immutable checkpoint never clears newer publications.
  Future<void> acknowledge(String id) async {
    _ensureLoaded();
    _outbox.removeWhere((batch) => batch.id == id);
    await save();
  }

  /// Resolves a batch atomically in one durable state commit. The observed
  /// baseline remains the old business state until completeApply.
  Future<void> resolveAll(
    List<MergeConflictResolution> resolutions, {
    Set<String> unavailableDomains = const {},
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

    // Resolve ordinary cells before presence: a chosen deletion can make the
    // record inactive, but must not invalidate another selection from this batch.
    for (final resolution in resolutions) {
      if (resolution.field == 'presence') continue;
      stagedDocument.resolve(
        actor,
        resolution.recordKey,
        resolution.field,
        resolution.candidateId,
      );
    }
    for (final resolution in resolutions) {
      if (resolution.field != 'presence') continue;
      stagedDocument.resolve(
        actor,
        resolution.recordKey,
        resolution.field,
        resolution.candidateId,
      );
    }

    final checkpoint = MergeBatch.create(
      actor: actor,
      counter: stagedDocument.counterFor(actor),
      document: stagedDocument.clone(),
    );
    final pendingApply = stagedDocument.materialize(preferred: _observed);
    final pendingUnavailableDomains = Set<String>.unmodifiable(
      unavailableDomains,
    );
    _document = stagedDocument;
    _outbox.add(checkpoint);
    _pendingApply = pendingApply;
    _pendingUnavailableDomains = pendingUnavailableDomains;
    try {
      await save();
    } catch (error) {
      throw MergeStorePersistenceException(error);
    }
  }

  /// Successful return means both primary and backup contain this complete
  /// commit. During replacement a flushed prior backup always remains available.
  /// IO failures are never hidden; this instance is fail-closed until reload.
  Future<void> save() async {
    _ensureLoaded();
    _saving = true;
    try {
      final content = canonicalSyncJson({
        'schemaVersion': 2,
        'actor': actor,
        'document': _document.toJson(),
        'localObservation': _localObservation.toJson(),
        'observed': _observed,
        'received': _received.toList()..sort(),
        'outbox': _outbox.map((batch) => batch.toJson()).toList(),
        'pendingApply': _pendingApply,
        'pendingUnavailableDomains': _pendingUnavailableDomains.toList()
          ..sort(),
        'initialized': _initialized,
      });
      await _temporaryFile.writeAsString(content, flush: true);
      // Dart rename replaces a destination file on Windows too. Never replace
      // via copy/delete: a locked target must fail rather than become torn JSON.
      if (await _stateFile.exists() && !_recoveredFromBackup) {
        await _stateFile.rename(_backupFile.path);
      }
      await _temporaryFile.rename(_stateFile.path);
      final backupTemporary = File('${_backupFile.path}.tmp');
      await backupTemporary.writeAsString(content, flush: true);
      await backupTemporary.rename(_backupFile.path);
      _counterFloorDirty = false;
    } catch (_) {
      _loaded = false;
      rethrow;
    } finally {
      _saving = false;
    }
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
    : super('Store actor mismatch: expected "$expected", found "$actual"');
}

/// The durable state replacement failed after the in-memory batch was staged.
/// The on-disk commit may have succeeded, so callers must allow recovery before
/// retrying a choice.
class MergeStorePersistenceException implements Exception {
  final Object cause;

  const MergeStorePersistenceException(this.cause);

  @override
  String toString() => 'MergeStore persistence status is uncertain: $cause';
}
