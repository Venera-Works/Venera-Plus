import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../foundation/app.dart';
import '../../foundation/appdata.dart';
import '../../foundation/log.dart';
import '../../foundation/res.dart';
import '../../foundation/sync_records.dart';
import '../../network/webdav.dart';
import '../favorites/favorites.dart';
import '../history/history.dart';
import 'data_sync.dart';
import 'legacy_sync_reader.dart';
import 'merge_remote.dart';
import 'merge_store.dart';
import 'sync_preferences_adapter.dart';

/// Exception thrown when local data changes during the apply commit stage.
class ConcurrentEditException implements Exception {
  final String message;
  ConcurrentEditException([
    this.message = 'Concurrent local edit during sync apply',
  ]);

  @override
  String toString() => 'ConcurrentEditException: $message';
}

/// Coordinates multi-device merge synchronization across business domains.
///
/// Responsibilities:
/// - Endpoint-bound state store persistence.
/// - Startup pending-apply replay before local capture.
/// - Local record capture with change generation protection.
/// - Short synchronous commit region across Favorites, History, and Preferences.
/// - One-time legacy `.venera` snapshot migration via [LegacySyncReader].
/// - Outbox checkpoint publishing, acknowledgement, and remote compaction.
class MergeSyncCoordinator {
  MergeSyncCoordinator({
    required this.endpointHash,
    required this.stateDirectory,
    required this.actor,
    required this.store,
    required this.remote,
    SyncPreferencesAdapter? preferencesAdapter,
    this.exportFavoritesOverride,
    this.applyFavoritesOverride,
    this.exportHistoryOverride,
    this.applyHistoryOverride,
    this.exportPreferencesOverride,
    this.applyPreferencesOverride,
    this.getGenerationOverride,
  }) : preferencesAdapter =
           preferencesAdapter ?? SyncPreferencesAdapter(dataPath: App.dataPath);

  final String endpointHash;
  final Directory stateDirectory;
  final String actor;
  final MergeStore store;
  final MergeRemote remote;
  final SyncPreferencesAdapter preferencesAdapter;

  SyncRecords Function()? exportFavoritesOverride;
  void Function(SyncRecords)? applyFavoritesOverride;
  Future<SyncRecords> Function()? exportHistoryOverride;
  void Function(SyncRecords)? applyHistoryOverride;
  Future<SyncRecords> Function()? exportPreferencesOverride;
  Future<void> Function(SyncRecords, {void Function()? beforeCommit})?
  applyPreferencesOverride;
  int Function()? getGenerationOverride;

  int _getGeneration() => getGenerationOverride?.call() ?? 0;

  List<MergeConflict> get conflicts => store.document.conflicts;
  int get conflictCount => conflicts.length;
  bool get hasConflict => conflicts.isNotEmpty;

  static String computeEndpointHash(String url, String username) {
    final normalized = '${normalizeWebDavEndpointUrl(url)}#$username';
    return sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
  }

  static Future<String> getOrCreateActorId() async {
    var id = appdata.implicitData['syncDeviceId'] as String?;
    if (id == null || id.isEmpty) {
      id = 'device_${const Uuid().v4()}';
      appdata.implicitData['syncDeviceId'] = id;
    }
    // Also flush a previously assigned in-memory ID after a failed write.
    await appdata.writeImplicitData();
    return id;
  }

  /// Exports current local snapshot across all business domains.
  /// Throws immediately if any domain export fails, preventing partial DTOs and accidental tombstones.
  Future<SyncLocalSnapshot> exportAllSnapshot() async {
    final records = <String, Map<String, Object?>>{};

    // 1. Favorites
    final favRecords = exportFavoritesOverride != null
        ? exportFavoritesOverride!()
        : LocalFavoritesManager().exportSyncRecords();
    records.addAll(favRecords);

    // 2. History & Image Favorites
    final histRecords = exportHistoryOverride != null
        ? await exportHistoryOverride!()
        : await HistoryManager().exportSyncRecords();
    records.addAll(histRecords);

    // 3. Preferences, cookies, sources
    final SyncLocalSnapshot prefSnapshot;
    if (exportPreferencesOverride != null) {
      final prefRecords = await exportPreferencesOverride!();
      prefSnapshot = SyncLocalSnapshot(records: prefRecords);
    } else {
      prefSnapshot = await preferencesAdapter.exportSyncSnapshot();
    }
    records.addAll(prefSnapshot.records);

    return SyncLocalSnapshot(
      records: records,
      sourceVariants: prefSnapshot.sourceVariants,
      needsSourceNormalization: prefSnapshot.needsSourceNormalization,
    );
  }

  /// Applies incoming records atomically across all domains.
  ///
  /// Uses [SyncPreferencesAdapter.applySyncRecords] staging, and executes
  /// favorites and history updates synchronously inside [beforeCommit]
  /// to create a short commit region with zero awaits between domain writes.
  Future<void> applyAllRecords(
    SyncRecords records, {
    void Function()? beforeCommit,
  }) async {
    void runSynchronousCommits() {
      beforeCommit?.call();
      if (applyFavoritesOverride != null) {
        applyFavoritesOverride!(records);
      } else {
        LocalFavoritesManager().applySyncRecords(records);
      }
      if (applyHistoryOverride != null) {
        applyHistoryOverride!(records);
      } else {
        HistoryManager().applySyncRecords(records);
      }
    }

    if (applyPreferencesOverride != null) {
      await applyPreferencesOverride!(
        records,
        beforeCommit: runSynchronousCommits,
      );
    } else {
      await preferencesAdapter.applySyncRecords(
        records,
        beforeCommit: runSynchronousCommits,
        hasPreservedSourceVariant: (recordKey, script) =>
            store.document.hasObservedFieldValue(recordKey, 'script', script),
      );
    }
  }

  SyncRecords _project(SyncRecords records) =>
      preferencesAdapter.projectRecordsForLocalPolicy(records);

  /// An export may await several independent stores. Only use a snapshot whose
  /// generation stayed unchanged throughout, never adopt the ending generation.
  Future<({SyncLocalSnapshot snapshot, int generation})> _stableExport() async {
    for (var attempt = 0; attempt < 16; attempt++) {
      final generation = _getGeneration();
      final raw = await exportAllSnapshot();
      if (_getGeneration() == generation) {
        final projected = SyncLocalSnapshot(
          records: _project(raw.records),
          sourceVariants: raw.sourceVariants,
          needsSourceNormalization: raw.needsSourceNormalization,
        );
        return (snapshot: projected, generation: generation);
      }
    }
    throw ConcurrentEditException('Local data did not stabilize for export');
  }

  Future<({SyncLocalSnapshot snapshot, int generation})> _captureStable({
    MergeDocument? observation,
  }) async {
    final stable = await _stableExport();
    await store.capture(
      stable.snapshot.records,
      previous: _project(store.observed),
      observation: observation,
      sourceVariants: stable.snapshot.sourceVariants,
    );
    return stable;
  }

  Future<void> _finishApply() async {
    if (applyPreferencesOverride == null) {
      await preferencesAdapter.finishApply();
    }
  }

  /// Every guard failure cancels its durable target before another export.
  /// Partial business-write failures deliberately retain their recovery target.
  Future<void> _applyMerged(
    MergeDocument observation, {
    int? stagedGeneration,
  }) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      final alreadyStaged = attempt == 0 && stagedGeneration != null;
      final generation = alreadyStaged
          ? stagedGeneration
          : (await _captureStable(observation: observation)).generation;
      final desired = alreadyStaged
          ? store.pendingApply!
          : store.document.materialize(preferred: store.observed);
      final needsBusinessApply = !syncValuesEqual(
        _project(desired),
        _project(store.observed),
      );
      if (!alreadyStaged) await store.stageApply(desired);
      void guard() {
        if (_getGeneration() != generation) throw ConcurrentEditException();
      }

      try {
        if (needsBusinessApply) {
          await applyAllRecords(desired, beforeCommit: guard);
        } else {
          guard();
        }
      } on ConcurrentEditException {
        await store.cancelApply();
        continue;
      }
      await store.completeApply(
        _project(desired),
        observation: store.document.filterRecords(
          preferencesAdapter.shouldObserveRecord,
        ),
      );
      if (needsBusinessApply) await _finishApply();
      await _captureStable();
      return;
    }
    throw ConcurrentEditException('Local data did not stabilize for apply');
  }

  /// Journaled normalization of local physical source duplicates without importing
  /// foreign/unapplied remote business records from [store.document].
  Future<void> _normalizeSourcesLocally(
    ({SyncLocalSnapshot snapshot, int generation}) staged,
  ) async {
    for (var attempt = 0; attempt < 16; attempt++) {
      final current = attempt == 0 ? staged : await _captureStable();
      if (!current.snapshot.needsSourceNormalization) {
        return;
      }
      final generation = current.generation;
      final desired = current.snapshot.records;
      await store.stageApply(desired);
      void guard() {
        if (_getGeneration() != generation) throw ConcurrentEditException();
      }

      try {
        await applyAllRecords(desired, beforeCommit: guard);
      } on ConcurrentEditException {
        await store.cancelApply();
        continue;
      }
      await store.completeApply(
        _project(desired),
        observation: store.localObservation,
      );
      await _finishApply();
      await _captureStable();
      return;
    }
    throw ConcurrentEditException(
      'Local data did not stabilize for source normalization',
    );
  }

  /// A pending target may have been partly applied before a crash. Preserve the
  /// real profile as a concurrent branch before choosing any replacement target.
  Future<void> startupRecovery() async {
    await store.load();
    await reconcileBackupRecoveryIfNeeded();
    if (store.pendingApply != null) {
      final stable = await _stableExport();
      final pending = store.pendingApply!;
      final desired = await store.recoverPendingApply(
        stable.snapshot.records,
        previous: _project(pending),
        sourceVariants: stable.snapshot.sourceVariants,
      );
      try {
        await applyAllRecords(
          desired,
          beforeCommit: () {
            if (_getGeneration() != stable.generation) {
              throw ConcurrentEditException();
            }
          },
        );
      } on ConcurrentEditException {
        await store.cancelApply();
        await _applyMerged(store.localObservation);
        return;
      }
      await store.completeApply(
        _project(desired),
        observation: store.document.filterRecords(
          preferencesAdapter.shouldObserveRecord,
        ),
      );
      await _finishApply();
    }
    final captured = await _captureStable();
    if (captured.snapshot.needsSourceNormalization) {
      await _normalizeSourcesLocally(captured);
    }
  }

  /// Performs one-time legacy `.venera` snapshot migration if needed.
  Future<void> migrateLegacyIfNeeded({
    Directory? customScratchDir,
    bool applyToLocal = true,
  }) async {
    final markerKey = 'legacyMigrationDone_$endpointHash';
    if (appdata.implicitData[markerKey] == true) {
      return;
    }

    // Validate namespace evidence, but never let a newly published local v2 file
    // substitute for reading legacy roots during this endpoint's first cutover.
    for (final entry in await remote.list(latestOnly: false)) {
      try {
        await remote.download(entry);
      } on MergeRemoteCorruptException catch (error) {
        Log.error('MergeSyncCoordinator', 'Uncommitted v2 artifact: $error');
      }
    }

    final scratch =
        customScratchDir ??
        Directory(
          '${stateDirectory.path}_legacy_scratch_${DateTime.now().millisecondsSinceEpoch}',
        );
    try {
      final reader = LegacySyncReader(
        remote.client,
        scratch,
        preferences: preferencesAdapter,
      );
      final seeds = await reader.readSeeds();
      if (seeds.isNotEmpty) {
        final observation = store.localObservation;
        await _captureStable(observation: observation);
        for (final seed in seeds) {
          final seedActor = 'legacy_seed_${seed.id}';
          final seedDoc = MergeDocument();
          seedDoc.captureLocal(seedActor, {}, seed.records, bootstrap: true);
          store.document.merge(seedDoc);
          if (seed.sourceVariants.isNotEmpty) {
            for (final entry in seed.sourceVariants.entries) {
              final recordKey = entry.key;
              for (final script in entry.value) {
                final variantDoc = MergeDocument.createSourceVariantSeed(
                  recordKey,
                  script,
                );
                if (!store.document.dominates(variantDoc)) {
                  store.document.merge(variantDoc);
                }
              }
            }
          }
        }
        await store.enqueueCheckpoint();
        if (applyToLocal) await _applyMerged(observation);
      }
    } catch (e, s) {
      Log.error('MergeSyncCoordinator', 'Legacy migration error: $e\n$s');
      rethrow;
    } finally {
      if (await scratch.exists()) {
        try {
          await scratch.delete(recursive: true);
        } catch (_) {}
      }
    }

    appdata.implicitData[markerKey] = true;
    _cleanOldBaselineKeys();
    await appdata.writeImplicitData();
  }

  void _cleanOldBaselineKeys() {
    appdata.implicitData.remove('webdavSyncBaseline');
    appdata.implicitData.remove('webdavSyncBaselineEtag');
    appdata.implicitData.remove('webdavSyncBaselineTime');
    appdata.implicitData.remove('webdavSyncLastRemoteFile');
    appdata.implicitData.remove('webdavSyncLastRemoteVersion');
  }

  /// If state was restored from backup, reconciles highest known actor counter from
  /// remote checkpoints before capturing new local edits.
  Future<void> reconcileBackupRecoveryIfNeeded() async {
    if (!store.recoveredFromBackup) return;

    try {
      final entries = await remote.list(latestOnly: false);
      var highest = 0;
      // Reserve even an uncommitted OWN filename's allocation conservatively.
      // Only verified contents may enter causal observation or business state.
      for (final entry in entries.where((entry) => entry.actor == actor)) {
        if (entry.counter > highest) highest = entry.counter;
        try {
          final batch = await remote.download(entry);
          store.document.merge(batch.document);
          await store.markReceived(entry.filename);
        } on MergeRemoteCorruptException catch (error) {
          Log.error(
            'MergeSyncCoordinator',
            'Uncommitted recovery artifact: $error',
          );
        }
      }
      store.reconcileActorCounter(actor, highest);
      await store.save();
    } catch (e) {
      throw StateError(
        'Cannot verify remote state after restoring from local backup: $e. '
        'Reconciliation is required to prevent counter regression.',
      );
    }
  }

  /// Executes synchronization according to [direction].
  Future<Res<bool>> performSync({required SyncDirection direction}) async {
    try {
      await reconcileBackupRecoveryIfNeeded();
      if (store.pendingApply != null) {
        throw StateError('Startup recovery is required before synchronization');
      }
      final captured = await _captureStable();
      if (captured.snapshot.needsSourceNormalization) {
        await _normalizeSourcesLocally(captured);
      }
      await migrateLegacyIfNeeded(
        applyToLocal: direction != SyncDirection.uploadOnly,
      );

      if (direction != SyncDirection.uploadOnly) {
        final preMergeObservation = store.localObservation;
        // List all candidates to avoid a newer bad/partial file masking valid older checkpoints
        final remoteEntries = await remote.list(latestOnly: false);
        final byActor = <String, List<MergeRemoteEntry>>{};
        for (final entry in remoteEntries) {
          byActor.putIfAbsent(entry.actor, () => []).add(entry);
        }

        for (final entryList in byActor.values) {
          entryList.sort((a, b) => b.counter.compareTo(a.counter));
          int? highestSucceededCounter;

          for (final entry in entryList) {
            if (highestSucceededCounter != null &&
                entry.counter < highestSucceededCounter) {
              // Older than an already-processed valid checkpoint for this actor
              continue;
            }

            if (store.received.contains(entry.filename)) {
              highestSucceededCounter = entry.counter;
              continue;
            }

            try {
              final batch = await remote.download(entry);
              store.document.merge(batch.document);
              await store.markReceived(entry.filename);
              highestSucceededCounter = entry.counter;
            } on MergeRemoteCorruptException catch (e) {
              Log.error(
                'MergeSyncCoordinator',
                'Candidate ${entry.filename} is corrupt/partial: $e. '
                    'Skipping uncommitted bad artifact to continue reading valid checkpoints.',
              );
              // Do not mark received; continue to next candidate to find valid older ones
              // Only corrupt artifacts with bad SHA or truncated body are skipped.
            }
          }
        }

        // Apply also after a previous transfer failed: downloaded checkpoints
        // may already be durable/received but not yet in the business stores.
        await _applyMerged(preMergeObservation);
      }

      // Step 3: Publish outbox checkpoints (bidirectional or uploadOnly)
      if (direction != SyncDirection.downloadOnly) {
        await _uploadOutboxWithRecovery();
      }

      return const Res(true);
    } catch (e, s) {
      Log.error('MergeSyncCoordinator', 'performSync error: $e\n$s');
      return Res.error(e.toString());
    }
  }

  /// Resolves an active conflict, establishes a new causal dot, materializes, applies,
  /// and publishes the resolution checkpoint if allowed by [direction].
  Future<Res<bool>> resolveConflict({
    required String recordKey,
    required String field,
    required String candidateId,
    required SyncDirection direction,
  }) async {
    try {
      final captured = await _captureStable();
      final observation = store.localObservation;
      await store.resolve(recordKey, field, candidateId);
      await _applyMerged(observation, stagedGeneration: captured.generation);

      if (direction != SyncDirection.downloadOnly) {
        await _uploadOutboxWithRecovery();
      }

      return const Res(true);
    } catch (e, s) {
      Log.error('MergeSyncCoordinator', 'resolveConflict error: $e\n$s');
      return Res.error(e.toString());
    }
  }

  /// Publishes outbox checkpoints, recovers from upload conflicts by reserving
  /// a dominating replacement checkpoint, acknowledges batches, and compacts.
  Future<void> _uploadOutboxWithRecovery() async {
    final priorEntries = await remote.list(latestOnly: false);
    MergeBatch? lastUploaded;

    final outboxBatches = List<MergeBatch>.from(store.outbox);
    for (final batch in outboxBatches) {
      try {
        final uploadedPath = await remote.upload(batch);
        await store.acknowledge(batch.id);
        await store.markReceived(uploadedPath);
        lastUploaded = batch;
      } on MergeRemoteConflictException catch (e) {
        Log.error(
          'MergeSyncCoordinator',
          'Upload conflict on ${batch.id}: $e. Reserving replacement checkpoint dominating intended batch.',
        );
        final replacement = await store.enqueueCheckpoint();
        final uploadedPath = await remote.upload(replacement);
        await store.acknowledge(batch.id);
        await store.acknowledge(replacement.id);
        await store.markReceived(uploadedPath);
        lastUploaded = replacement;
      }
    }

    if (lastUploaded != null) {
      await remote.compact(lastUploaded, priorEntries);
    }
  }
}
