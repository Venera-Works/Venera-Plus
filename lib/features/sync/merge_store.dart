import 'dart:convert';
import 'dart:io';

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
  }) async {
    _ensureCanAllocate();
    if (_pendingApply != null) {
      throw StateError(
        'Complete or cancel pending business apply before capture',
      );
    }
    final current = _parseSyncRecords(records);
    final baseline = previous == null ? _observed : _parseSyncRecords(previous);
    final branch = observation?.clone() ?? _localObservation.clone();
    // Allocation and own cumulative prefixes are not remote causal observation.
    branch.setCounterFloor(actor, _document.counterFor(actor));
    final counter = branch.captureLocal(
      actor,
      baseline,
      current,
      bootstrap: !_initialized,
      contributionFloor: _document,
    );

    var newVariantsAdded = false;
    if (sourceVariants != null && sourceVariants.isNotEmpty) {
      for (final entry in sourceVariants.entries) {
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
      _localObservation = branch.clone();
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

    final shouldSave =
        counter > 0 ||
        newVariantsAdded ||
        !_initialized ||
        _counterFloorDirty ||
        !syncValuesEqual(_observed, current);
    _initialized = true;
    _observed = current;
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
  Future<void> stageApply(SyncRecords records) async {
    _ensureLoaded();
    _pendingApply = _parseSyncRecords(records);
    await save();
  }

  /// The caller reports the business state actually committed. Passing the old
  /// observed state also cancels an apply aborted by the beforeCommit guard.
  /// [observation] is the applied policy-visible causal view. Keep contexts for
  /// allowed tombstones; filter forbidden records, not materialized record keys.
  Future<void> completeApply(
    SyncRecords records, {
    MergeDocument? observation,
  }) async {
    _ensureLoaded();
    if (_pendingApply == null) throw StateError('No business apply is staged');
    final actual = _parseSyncRecords(records);
    if (observation != null || syncValuesEqual(actual, _pendingApply)) {
      final appliedObservation = observation ?? _document;
      if (!_document.dominates(appliedObservation)) {
        throw ArgumentError(
          'Applied observation is not covered by the document',
        );
      }
      _localObservation = appliedObservation.clone();
    }
    _observed = actual;
    _pendingApply = null;
    _initialized = true;
    await save();
  }

  /// Cancels an apply that was aborted before any business commit. The caller
  /// must not use cancellation to skip recovery of partially written databases.
  Future<void> cancelApply() async {
    _ensureLoaded();
    _pendingApply = null;
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
  }) async {
    _ensureCanAllocate();
    if (_pendingApply == null) throw StateError('No business apply is staged');
    final actual = _parseSyncRecords(records);
    final target = _parseSyncRecords(previous ?? _pendingApply!);
    final branch = MergeDocument();
    branch.setCounterFloor(actor, _document.counterFor(actor));
    final counter = branch.captureLocal(
      actor,
      target,
      actual,
      bootstrap: false,
      contributionFloor: _document,
    );

    var newVariantsAdded = false;
    if (sourceVariants != null && sourceVariants.isNotEmpty) {
      for (final entry in sourceVariants.entries) {
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
      _localObservation.merge(branch);
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
    _observed =
        actual; // These records really are present in the business stores.
    _initialized = true;
    _pendingApply = _document.materialize(preferred: actual);
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

  /// Resolves, publishes and journals the target in the SAME durable commit.
  /// The observed baseline remains the old business state until completeApply.
  Future<void> resolve(
    String recordKey,
    String field,
    String candidateId,
  ) async {
    _ensureCanAllocate();
    if (_pendingApply != null) {
      throw StateError(
        'Complete or cancel pending business apply before resolve',
      );
    }
    _document.resolve(actor, recordKey, field, candidateId);
    _outbox.add(
      MergeBatch.create(
        actor: actor,
        counter: _document.counterFor(actor),
        document: _document.clone(),
      ),
    );
    _pendingApply = _document.materialize(preferred: _observed);
    await save();
  }

  /// Successful return means both primary and backup contain this complete
  /// commit. During replacement a flushed prior backup always remains available.
  /// IO failures are never hidden; this instance is fail-closed until reload.
  Future<void> save() async {
    _ensureLoaded();
    _saving = true;
    try {
      final content = canonicalSyncJson({
        'schemaVersion': 1,
        'actor': actor,
        'document': _document.toJson(),
        'localObservation': _localObservation.toJson(),
        'observed': _observed,
        'received': _received.toList()..sort(),
        'outbox': _outbox.map((batch) => batch.toJson()).toList(),
        'pendingApply': _pendingApply,
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
    if (decoded is! Map ||
        !_hasExactKeys(decoded, const {
          'schemaVersion',
          'actor',
          'document',
          'observed',
          'received',
          'outbox',
          'pendingApply',
          'initialized',
          'localObservation',
        }) ||
        decoded['schemaVersion'] is! int ||
        decoded['schemaVersion'] != 1 ||
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
    return _StoreState(
      document,
      localObservation,
      observed,
      received,
      outbox,
      pending,
      decoded['initialized'] as bool,
    );
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
}

class _StoreState {
  final MergeDocument document;
  final MergeDocument localObservation;
  final SyncRecords observed;
  final Set<String> received;
  final List<MergeBatch> outbox;
  final SyncRecords? pendingApply;
  final bool initialized;

  _StoreState(
    this.document,
    this.localObservation,
    this.observed,
    this.received,
    this.outbox,
    this.pendingApply,
    this.initialized,
  );
}

class _StoreActorMismatch extends StateError {
  _StoreActorMismatch(String expected, String actual)
    : super('Store actor mismatch: expected "$expected", found "$actual"');
}
