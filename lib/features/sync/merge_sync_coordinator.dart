import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../foundation/app.dart';
import '../../foundation/appdata.dart';
import '../../foundation/appdata_sync_policy.dart';
import '../../foundation/log.dart';
import '../../foundation/res.dart';
import '../../network/webdav.dart';
import '../favorites/favorites.dart';
import '../history/history.dart';
import 'data_sync.dart';
import 'legacy_sync_reader.dart';
import 'merge_remote.dart';
import 'merge_snapshot.dart';
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

  static const _favoriteDomains = {'folder', 'favorite', 'favoriteRole'};
  static const _historyDomains = {'history', 'historyChapter', 'imageFavorite'};
  static const _preferenceDomains = {
    'setting',
    'search',
    'cookies',
    'source',
    'sourceSession',
  };
  final Set<String> _dirtyDomains = {...appdataSyncDomains};
  final Set<String> _changedRecordKeys = {};
  SyncLocalSnapshot? _cachedSnapshot;
  int? _capturedGeneration;
  bool _legacyChangesDetected = false;
  bool get legacyChangesDetected => _legacyChangesDetected;
  int get pendingChangeCount => store.pendingRecordCount;
  bool _counterReconciliationComplete = false;

  /// Hints only narrow reads; startup, explicit checks and failed guards still
  /// reconcile the entire profile so external file edits cannot be missed.
  void markDirty([Set<String>? domains]) {
    _dirtyDomains.addAll(domains ?? appdataSyncDomains);
    if (_dirtyDomains.any(_favoriteDomains.contains)) {
      _dirtyDomains.addAll(_favoriteDomains);
    }
    if (_dirtyDomains.any(_historyDomains.contains)) {
      _dirtyDomains.addAll(_historyDomains);
    }
    if (_dirtyDomains.contains('source') ||
        _dirtyDomains.contains('sourceSession')) {
      _dirtyDomains.addAll({'source', 'sourceSession'});
    }
  }

  Map<String, int> get changedRecordCounts {
    final result = <String, int>{};
    for (final key in _changedRecordKeys) {
      result.update(
        syncRecordDomain(key),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return Map.unmodifiable(result);
  }

  Set<String> _recordChanges(SyncRecords before, SyncRecords after) {
    final domains = <String>{};
    for (final key in {...before.keys, ...after.keys}) {
      if (!preferencesAdapter.shouldObserveRecord(key) ||
          unavailableDomains.contains(syncRecordDomain(key))) {
        continue;
      }
      if (!syncValuesEqual(before[key], after[key])) {
        _changedRecordKeys.add(key);
        domains.add(syncRecordDomain(key));
      }
    }
    return domains;
  }

  /// Durable local preflight. A redundant UI notification never requires a
  /// directory listing or data upload merely to discover that nothing changed.
  Future<bool> captureLocalChanges() async {
    _changedRecordKeys.clear();
    if (store.needsRecovery || store.pendingApply != null) {
      await startupRecovery();
    }
    final captured = await _captureStable();
    if (captured.snapshot.needsSourceNormalization) {
      await _normalizeSourcesLocally(captured);
    }
    return store.pendingBatchIds.isNotEmpty;
  }

  List<SyncSourceIssue> _localSourceIssues = const [];
  Set<String> _localUnavailableDomains = const {};
  List<SyncSourceIssue> _legacySourceIssues = const [];
  Set<String> _legacyUnavailableDomains = const {};
  bool _legacyIssuesLoaded = false;

  File get _legacyIssuesFile =>
      File('${stateDirectory.path}/legacy_issues.json');

  Future<void> _loadLegacyIssuesIfNeeded() async {
    if (_legacyIssuesLoaded) return;
    if (await _legacyIssuesFile.exists()) {
      final decoded = jsonDecode(await _legacyIssuesFile.readAsString());
      if (decoded is! Map ||
          decoded['issues'] is! List ||
          decoded['unavailableDomains'] is! List) {
        throw FormatException(
          'Invalid legacy issues metadata schema: ${_legacyIssuesFile.path}',
        );
      }
      final issues = <SyncSourceIssue>[];
      for (final item in decoded['issues'] as List) {
        if (item is! Map) {
          throw FormatException(
            'Invalid legacy issue item in ${_legacyIssuesFile.path}',
          );
        }
        issues.add(SyncSourceIssue.fromJson(item.cast<String, Object?>()));
      }
      final domains = <String>{};
      for (final item in decoded['unavailableDomains'] as List) {
        if (item is! String ||
            !const {'source', 'sourceSession'}.contains(item) ||
            !domains.add(item)) {
          throw FormatException(
            'Invalid legacy unavailable domain in ${_legacyIssuesFile.path}',
          );
        }
      }
      _legacySourceIssues = issues;
      _legacyUnavailableDomains = domains;
    }
    _legacyIssuesLoaded = true;
  }

  Future<void> _saveLegacyIssues() async {
    if (_legacySourceIssues.isEmpty && _legacyUnavailableDomains.isEmpty) {
      if (await _legacyIssuesFile.exists()) {
        await _legacyIssuesFile.delete();
      }
      return;
    }
    final tmpFile = File('${_legacyIssuesFile.path}.tmp');
    final data = canonicalSyncJson({
      'issues': _legacySourceIssues.map((i) => i.toJson()).toList(),
      'unavailableDomains': _legacyUnavailableDomains.toList()..sort(),
    });
    await tmpFile.writeAsString(data, flush: true);
    await tmpFile.rename(_legacyIssuesFile.path);
  }

  List<SyncSourceIssue> get sourceIssues {
    final issues = List<SyncSourceIssue>.of(_localSourceIssues);
    for (final issue in _legacySourceIssues) {
      if (!issues.contains(issue)) issues.add(issue);
    }
    return List.unmodifiable(issues);
  }

  Set<String> get unavailableDomains => {
    ..._localUnavailableDomains,
    ..._legacyUnavailableDomains,
  };

  SyncRecords _approvedRecoveryRecords() {
    final pending = store.pendingApply;
    if (pending == null) return store.observed;
    final blocked = store.pendingUnavailableDomains;
    if (blocked.isEmpty) return pending;
    final approved = <String, Map<String, Object?>>{};
    for (final entry in store.observed.entries) {
      if (blocked.contains(syncRecordDomain(entry.key))) {
        approved[entry.key] = entry.value;
      }
    }
    for (final entry in pending.entries) {
      if (!blocked.contains(syncRecordDomain(entry.key))) {
        approved[entry.key] = entry.value;
      }
    }
    return approved;
  }

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

  /// Exports a complete snapshot, reusing domains not invalidated by a business
  /// change. Public callers get a fresh reconciliation unless explicitly cached.
  Future<SyncLocalSnapshot> exportAllSnapshot({bool force = true}) async {
    if (force || _cachedSnapshot == null) markDirty();
    if (_dirtyDomains.isEmpty) return _cachedSnapshot!;
    final requested = Set<String>.of(_dirtyDomains);
    final previous = _cachedSnapshot;
    final records = <String, Map<String, Object?>>{
      if (previous != null) ...previous.records,
    }..removeWhere((key, _) => requested.contains(syncRecordDomain(key)));

    if (requested.any(_favoriteDomains.contains) &&
        preferencesAdapter.isDomainEnabled('folder')) {
      records.addAll(
        exportFavoritesOverride != null
            ? exportFavoritesOverride!()
            : LocalFavoritesManager().exportSyncRecords(),
      );
    }
    if (requested.any(_historyDomains.contains) &&
        (preferencesAdapter.isDomainEnabled('history') ||
            preferencesAdapter.isDomainEnabled('imageFavorite'))) {
      records.addAll(
        exportHistoryOverride != null
            ? await exportHistoryOverride!()
            : await HistoryManager().exportSyncRecords(),
      );
    }

    var sourceVariants =
        previous?.sourceVariants ??
        const <String, List<Map<String, Object?>>>{};
    var needsNormalization = previous?.needsSourceNormalization ?? false;
    var issues = previous?.sourceIssues ?? const <SyncSourceIssue>[];
    var unavailable = previous?.unavailableDomains ?? const <String>{};
    final preferenceDomains = requested.intersection(_preferenceDomains);
    if (preferenceDomains.isNotEmpty) {
      final snapshot = exportPreferencesOverride != null
          ? SyncLocalSnapshot(records: await exportPreferencesOverride!())
          : await preferencesAdapter.exportSyncSnapshot(
              recoveryRecords: _approvedRecoveryRecords(),
              domains: preferenceDomains,
            );
      records.addAll(snapshot.records);
      if (preferenceDomains.contains('source') ||
          preferenceDomains.contains('sourceSession')) {
        sourceVariants = snapshot.sourceVariants;
        needsNormalization = snapshot.needsSourceNormalization;
        issues = snapshot.sourceIssues;
        unavailable = snapshot.unavailableDomains;
      }
    }
    final snapshot = SyncLocalSnapshot(
      records: records,
      sourceVariants: sourceVariants,
      needsSourceNormalization: needsNormalization,
      sourceIssues: issues,
      unavailableDomains: unavailable,
    );
    _cachedSnapshot = snapshot;
    _dirtyDomains.removeAll(requested);
    return snapshot;
  }

  /// Applies incoming records atomically across all domains.
  ///
  /// Uses [SyncPreferencesAdapter.applySyncRecords] staging, and executes
  /// favorites and history updates synchronously inside [beforeCommit]
  /// to create a short commit region with zero awaits between domain writes.
  Future<void> applyAllRecords(
    SyncRecords records, {
    void Function()? beforeCommit,
    Set<String> unavailableDomains = const {},
  }) async {
    void runSynchronousCommits() {
      beforeCommit?.call();
      if (preferencesAdapter.isDomainEnabled('folder')) {
        if (applyFavoritesOverride != null) {
          applyFavoritesOverride!(records);
        } else {
          LocalFavoritesManager().applySyncRecords(records);
        }
      }
      final applyHistory = preferencesAdapter.isDomainEnabled('history');
      final applyImages = preferencesAdapter.isDomainEnabled('imageFavorite');
      if (applyHistory || applyImages) {
        if (applyHistoryOverride != null) {
          applyHistoryOverride!({
            for (final entry in records.entries)
              if (preferencesAdapter.shouldObserveRecord(entry.key))
                entry.key: entry.value,
          });
        } else {
          HistoryManager().applySyncRecords(
            records,
            applyHistory: applyHistory,
            applyImageFavorites: applyImages,
          );
        }
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
        unavailableDomains: unavailableDomains,
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
      if (_capturedGeneration != null &&
          _capturedGeneration != _getGeneration() &&
          _dirtyDomains.isEmpty) {
        markDirty();
      }
      final generation = _getGeneration();
      final raw = await exportAllSnapshot(force: false);
      if (_getGeneration() == generation) {
        final projected = SyncLocalSnapshot(
          records: _project(raw.records),
          sourceVariants: raw.sourceVariants,
          needsSourceNormalization: raw.needsSourceNormalization,
          sourceIssues: raw.sourceIssues,
          unavailableDomains: raw.unavailableDomains,
        );
        _capturedGeneration = generation;
        return (snapshot: projected, generation: generation);
      }
      markDirty();
    }
    throw ConcurrentEditException('Local data did not stabilize for export');
  }

  Future<({SyncLocalSnapshot snapshot, int generation})> _captureStable({
    MergeDocument? observation,
  }) async {
    if (exportPreferencesOverride == null &&
        (preferencesAdapter.isDomainEnabled('source') ||
            preferencesAdapter.isDomainEnabled('sourceSession')) &&
        (_cachedSnapshot == null ||
            _dirtyDomains.contains('source') ||
            _dirtyDomains.contains('sourceSession'))) {
      for (var attempt = 0; attempt < 16; attempt++) {
        final gen = _getGeneration();
        try {
          await preferencesAdapter.recoverLocalSources(
            recoveryRecords: _approvedRecoveryRecords(),
            beforeCommit: () {
              if (_getGeneration() != gen) throw ConcurrentEditException();
            },
          );
          break;
        } on ConcurrentEditException {
          continue;
        }
      }
    }
    final stable = await _stableExport();
    _localSourceIssues = List<SyncSourceIssue>.from(
      stable.snapshot.sourceIssues,
    );
    _localUnavailableDomains = Set<String>.from(
      stable.snapshot.unavailableDomains,
    );
    final previous = _project(store.observed);
    _recordChanges(previous, stable.snapshot.records);
    await store.capture(
      stable.snapshot.records,
      previous: previous,
      observation: observation,
      sourceVariants: stable.snapshot.sourceVariants,
      unavailableDomains: unavailableDomains,
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
      final captured = alreadyStaged
          ? null
          : await _captureStable(observation: observation);
      final generation = alreadyStaged
          ? stagedGeneration
          : captured!.generation;
      final unavailable = alreadyStaged
          ? store.pendingUnavailableDomains
          : unavailableDomains;
      final desired = alreadyStaged
          ? store.pendingApply!
          : store.document.materialize(preferred: store.observed);
      final desiredRecords = _project(desired);
      final appliedDomains = _recordChanges(
        _project(store.observed),
        desiredRecords,
      );
      final needsBusinessApply = appliedDomains.isNotEmpty;
      if (!alreadyStaged &&
          !needsBusinessApply &&
          unavailable.isEmpty &&
          syncValuesEqual(
            store.localObservation.toJson(),
            store.document
                .filterRecords(preferencesAdapter.shouldObserveRecord)
                .toJson(),
          )) {
        if (_getGeneration() != generation) {
          markDirty();
          continue;
        }
        return;
      }
      if (!alreadyStaged) {
        await store.stageApply(desired, unavailableDomains: unavailable);
      }
      void guard() {
        if (_getGeneration() != generation) throw ConcurrentEditException();
      }

      try {
        if (needsBusinessApply) {
          await applyAllRecords(
            desired,
            beforeCommit: guard,
            unavailableDomains: unavailable,
          );
          await _finishApply();
          markDirty(appliedDomains);
        } else {
          guard();
        }
      } on ConcurrentEditException {
        await store.cancelApply();
        markDirty();
        continue;
      }
      await store.completeApply(
        _project(desired),
        observation: store.document.filterRecords(
          preferencesAdapter.shouldObserveRecord,
        ),
        unavailableDomains: unavailable,
      );
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
      if (!current.snapshot.needsSourceNormalization ||
          current.snapshot.unavailableDomains.contains('source')) {
        return;
      }
      final generation = current.generation;
      final desired = current.snapshot.records;
      await store.stageApply(
        desired,
        unavailableDomains: current.snapshot.unavailableDomains,
      );
      void guard() {
        if (_getGeneration() != generation) throw ConcurrentEditException();
      }

      try {
        await applyAllRecords(
          desired,
          beforeCommit: guard,
          unavailableDomains: current.snapshot.unavailableDomains,
        );
        await _finishApply();
        markDirty({'source', 'sourceSession'});
      } on ConcurrentEditException {
        await store.cancelApply();
        continue;
      }
      await store.completeApply(
        _project(desired),
        observation: store.localObservation,
        unavailableDomains: current.snapshot.unavailableDomains,
      );
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
    markDirty();
    await _loadLegacyIssuesIfNeeded();
    _counterReconciliationComplete = false;
    await store.load();
    await reconcileBackupRecoveryIfNeeded();
    if (store.pendingApply != null) {
      final stable = await _stableExport();
      final pending = store.pendingApply!;
      _localSourceIssues = List<SyncSourceIssue>.from(
        stable.snapshot.sourceIssues,
      );
      _localUnavailableDomains = Set<String>.from(
        stable.snapshot.unavailableDomains,
      );
      final effectiveUnavailable = {
        ...store.pendingUnavailableDomains,
        ...stable.snapshot.unavailableDomains,
      };
      final desired = await store.recoverPendingApply(
        stable.snapshot.records,
        previous: _project(pending),
        sourceVariants: stable.snapshot.sourceVariants,
        unavailableDomains: effectiveUnavailable,
      );
      try {
        await applyAllRecords(
          desired,
          beforeCommit: () {
            if (_getGeneration() != stable.generation) {
              throw ConcurrentEditException();
            }
          },
          unavailableDomains: effectiveUnavailable,
        );
        await _finishApply();
        markDirty();
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
        unavailableDomains: effectiveUnavailable,
      );
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

    await _loadLegacyIssuesIfNeeded();

    // A newly published checkpoint cannot substitute for reading legacy roots
    // during this endpoint's first archive cutover.
    final remoteDocs = <MergeDocument>[];
    for (final entry in await remote.list(latestOnly: false)) {
      try {
        final batch = await remote.download(entry);
        remoteDocs.add(batch.document);
        if (!applyToLocal) {
          for (final v in batch.document.vclock.entries) {
            store.document.setCounterFloor(v.key, v.value);
          }
        }
      } on MergeRemoteCorruptException catch (error) {
        Log.error(
          'MergeSyncCoordinator',
          'Uncommitted snapshot artifact: $error',
        );
      }
    }

    final scratch =
        customScratchDir ??
        Directory(
          '${stateDirectory.path}_legacy_scratch_${DateTime.now().millisecondsSinceEpoch}',
        );
    final backupDir = Directory('${stateDirectory.path}/legacy_source_backups');
    var hasUnhandledSourceIssues =
        _legacySourceIssues.isNotEmpty || _legacyUnavailableDomains.isNotEmpty;
    final accumulatedLegacyIssues = List<SyncSourceIssue>.of(
      _legacySourceIssues,
    );
    final accumulatedLegacyDomains = Set<String>.of(_legacyUnavailableDomains);
    try {
      final overrideDir = Directory('${stateDirectory.path}/legacy_overrides');
      final reader = LegacySyncReader(
        remote.client,
        scratch,
        preferences: preferencesAdapter,
        verifiedSourceBackupDirectory: backupDir,
        legacyOverrideDirectory: overrideDir,
      );
      final seeds = await reader.readSeeds();
      if (seeds.isNotEmpty) {
        // A fresh set of verified archives is authoritative for old legacy
        // health; a resolved override removes its exact prior issue here.
        hasUnhandledSourceIssues = false;
        accumulatedLegacyIssues.clear();
        accumulatedLegacyDomains.clear();
      }
      if (seeds.isNotEmpty) {
        final observation = store.localObservation;
        await _captureStable(observation: observation);
        for (final seed in seeds) {
          accumulatedLegacyDomains.addAll(seed.unavailableDomains);
          if (seed.sourceIssues.isNotEmpty ||
              seed.unavailableDomains.isNotEmpty) {
            hasUnhandledSourceIssues = true;
            for (final issue in seed.sourceIssues) {
              if (!accumulatedLegacyIssues.contains(issue)) {
                accumulatedLegacyIssues.add(issue);
              }
            }
          }
          bool isActorCovered(String actor) {
            if (store.document.counterFor(actor) > 0) return true;
            for (final doc in remoteDocs) {
              if (doc.counterFor(actor) > 0) return true;
            }
            return false;
          }

          final baseActor = 'legacy_seed_${seed.id}';
          final hasBaseCoverage = isActorCovered(baseActor);
          if (hasBaseCoverage) {
            // Full archive was previously seeded under baseActor; do NOT allocate new domain seeds
            // as old reader never allowed partial migration and re-seeding would resurrect retired fields!
            continue;
          }

          // Check per-domain coverage across validated local/remote docs
          final domainsInSeed = seed.records.keys.map(syncRecordDomain).toSet();
          if (seed.sourceVariants.isNotEmpty) {
            domainsInSeed.add('source');
          }

          for (final domain in domainsInSeed) {
            final domainActor = 'legacy_seed_${seed.id}_$domain';
            if (isActorCovered(domainActor) ||
                seed.unavailableDomains.contains(domain)) {
              continue;
            }

            final domainRecords = Map<String, Map<String, Object?>>.fromEntries(
              seed.records.entries.where(
                (e) => syncRecordDomain(e.key) == domain,
              ),
            );
            if (domainRecords.isNotEmpty) {
              final domainDoc = MergeDocument();
              domainDoc.captureLocal(
                domainActor,
                {},
                domainRecords,
                bootstrap: true,
              );
              store.document.merge(domainDoc);
            }
            if (domain == 'source' && seed.sourceVariants.isNotEmpty) {
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

    if (hasUnhandledSourceIssues) {
      _legacySourceIssues = accumulatedLegacyIssues;
      _legacyUnavailableDomains = accumulatedLegacyDomains;
      await _saveLegacyIssues();
    } else {
      _legacySourceIssues = const [];
      _legacyUnavailableDomains = const {};
      await _saveLegacyIssues();
      appdata.implicitData[markerKey] = true;
      _cleanOldBaselineKeys();
      await appdata.writeImplicitData();
    }
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
    if (!store.recoveredFromBackup || _counterReconciliationComplete) return;

    try {
      final entries = await remote.list(latestOnly: false);
      final legacyEntries = await remote.listLegacyCheckpoints();
      var highest = 0;
      // Reserve even an uncommitted OWN filename's allocation conservatively.
      // Only verified contents may enter causal observation or business state.
      for (final (entry, legacy) in [
        for (final item in entries) (item, false),
        for (final item in legacyEntries) (item, true),
      ].where((item) => item.$1.actor == actor)) {
        if (entry.counter > highest) highest = entry.counter;
        try {
          final batch = legacy
              ? await remote.downloadLegacyCheckpoint(entry)
              : await remote.download(entry);
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
      _counterReconciliationComplete = true;
    } catch (e) {
      throw StateError(
        'Cannot verify remote state after restoring from local backup: $e. '
        'Reconciliation is required to prevent counter regression.',
      );
    }
  }

  /// Reads the highest complete checkpoint for each actor, retaining same-counter
  /// collisions and falling back past incomplete uploads without swallowing I/O.
  Future<bool> _mergeRemoteEntries(
    List<MergeRemoteEntry> entries, {
    bool legacy = false,
    bool requireCompleteHeads = false,
  }) async {
    final byActor = <String, List<MergeRemoteEntry>>{};
    for (final entry in entries) {
      byActor.putIfAbsent(entry.actor, () => []).add(entry);
    }
    final received = store.received;
    var changed = false;
    for (final candidates in byActor.values) {
      candidates.sort((a, b) => b.counter.compareTo(a.counter));
      int? highestSucceeded;
      int? highestIncomplete;
      for (final entry in candidates) {
        if (highestSucceeded != null && entry.counter < highestSucceeded) {
          continue;
        }
        if (received.contains(entry.filename)) {
          highestSucceeded = entry.counter;
          continue;
        }
        try {
          final batch = legacy
              ? await remote.downloadLegacyCheckpoint(entry)
              : await remote.download(entry);
          store.document.merge(batch.document);
          await store.markReceived(entry.filename);
          highestSucceeded = entry.counter;
          changed = true;
        } on MergeRemoteCorruptException catch (error) {
          highestIncomplete ??= entry.counter;
          Log.error(
            'MergeSyncCoordinator',
            'Incomplete checkpoint ${entry.filename}: $error',
          );
        }
      }
      if (requireCompleteHeads &&
          highestIncomplete != null &&
          (highestSucceeded == null || highestIncomplete >= highestSucceeded)) {
        throw StateError(
          'The latest legacy checkpoint is incomplete. Finish or recover the '
          'older device synchronization before migrating; legacy files have '
          'not been deleted or marked as migrated.',
        );
      }
    }
    return changed;
  }

  /// The old namespace is a migration source, not a second ongoing authority.
  /// Explicit consent is required to import writes made by a non-upgraded peer.
  Future<bool> _migrateCheckpointLayout({bool acceptChanges = false}) async {
    final entries = await remote.listLegacyCheckpoints();
    final inventory = {
      for (final entry in entries) entry.filename: entry.digest,
    };
    final previous = store.legacyCheckpointInventory;
    final unexpected =
        previous != null &&
        inventory.entries.any((entry) => previous[entry.key] != entry.value);
    _legacyChangesDetected = unexpected;
    if (unexpected && !acceptChanges) {
      throw StateError(
        'An older device has written to the previous sync format. Upgrade or '
        'stop all older devices, then explicitly import legacy sync changes '
        'from synchronization settings. No legacy data has been deleted.',
      );
    }
    if (previous != null && !acceptChanges) return false;
    await _mergeRemoteEntries(
      entries,
      legacy: true,
      requireCompleteHeads: true,
    );
    final imported = entries.isNotEmpty && (previous == null || unexpected);
    if (imported) {
      // Preserve the bridge as a publication, including in download-only mode
      // where it must remain pending until the user permits uploads.
      // Even a retry whose files were already received must stage this bridge:
      // an earlier interruption may have happened before enqueue or completion.
      await store.enqueueCheckpoint();
    }
    await store.completeCheckpointMigration({
      if (previous != null) ...previous,
      ...inventory,
    }, acceptChanges: acceptChanges);
    _legacyChangesDetected = false;
    return imported;
  }

  /// Executes synchronization according to direction and independent pull timing.
  Future<Res<bool>> performSync({
    required SyncDirection direction,
    bool checkRemote = true,
    bool forceCapture = true,
    bool acceptLegacyChanges = false,
  }) async {
    remote.resetTransferStats();
    if (forceCapture) {
      _changedRecordKeys.clear();
      markDirty();
    }
    try {
      if (store.needsRecovery || store.pendingApply != null) {
        await startupRecovery();
      } else {
        await reconcileBackupRecoveryIfNeeded();
      }
      final captured = await _captureStable();
      if (captured.snapshot.needsSourceNormalization) {
        await _normalizeSourcesLocally(captured);
      }
      final observation = store.localObservation;
      final needsRemoteCheck =
          checkRemote ||
          acceptLegacyChanges ||
          store.legacyCheckpointInventory == null;
      var importedLegacy = false;
      if (needsRemoteCheck) {
        importedLegacy = await _migrateCheckpointLayout(
          acceptChanges: acceptLegacyChanges,
        );
        await migrateLegacyIfNeeded(
          applyToLocal: direction != SyncDirection.uploadOnly,
        );
      }

      List<MergeRemoteEntry>? discovered;
      if (direction != SyncDirection.uploadOnly && needsRemoteCheck) {
        discovered = await remote.list(latestOnly: false);
        await _mergeRemoteEntries(discovered);
        // Rules are opt-in and limited to non-secret ordinary setting values.
        // Capture edits that arrived while waiting for the remote before making
        // any durable selection; the normal apply guard remains authoritative.
        final stable = await _captureStable(observation: observation);
        final preference = appdata.implicitData['syncPreferredSettingActor'];
        final resolutions = store.document
            .preferredSettingResolutions(
              preference is String ? preference : null,
            )
            .where(
              (choice) =>
                  preferencesAdapter.shouldObserveRecord(choice.recordKey),
            )
            .toList();
        if (resolutions.isNotEmpty) {
          await store.resolveAll(
            resolutions,
            unavailableDomains: unavailableDomains,
          );
          await _applyMerged(observation, stagedGeneration: stable.generation);
        } else {
          await _applyMerged(observation);
        }
      }

      if (direction != SyncDirection.downloadOnly) {
        await _uploadOutboxWithRecovery(
          discovered: discovered,
          ensurePublished: needsRemoteCheck,
        );
      }
      return Res(!acceptLegacyChanges || importedLegacy);
    } catch (e, s) {
      Log.error('MergeSyncCoordinator', 'performSync error: $e\n$s');
      return Res.error(e.toString());
    }
  }

  /// Resolves an active conflict batch, applies it, then publishes the durable
  /// checkpoint if allowed by [direction].
  Future<Res<bool>> resolveConflicts(
    List<MergeConflictResolution> resolutions, {
    required SyncDirection direction,
  }) async {
    final immutableResolutions = List<MergeConflictResolution>.unmodifiable([
      for (final resolution in resolutions)
        MergeConflictResolution(
          recordKey: resolution.recordKey,
          field: resolution.field,
          candidateId: resolution.candidateId,
          expectedCandidateIds: resolution.expectedCandidateIds == null
              ? null
              : Set.unmodifiable(resolution.expectedCandidateIds!),
          expectedCandidateFingerprint: resolution.expectedCandidateFingerprint,
        ),
    ]);
    remote.resetTransferStats();
    var batchCommitted = false;
    var applyCompleted = false;
    try {
      if (store.needsRecovery || store.pendingApply != null) {
        await startupRecovery();
      }
      await _migrateCheckpointLayout();
      final captured = await _captureStable();
      final observation = store.localObservation;
      await store.resolveAll(
        immutableResolutions,
        unavailableDomains: unavailableDomains,
      );
      batchCommitted = true;
      await _applyMerged(observation, stagedGeneration: captured.generation);
      applyCompleted = true;

      if (direction != SyncDirection.downloadOnly) {
        await _uploadOutboxWithRecovery();
      }

      return const Res(true);
    } on MergeStorePersistenceException catch (e, s) {
      Log.error('MergeSyncCoordinator', 'resolveConflicts error: $e\n$s');
      return Res.error(
        'Batch persistence status is uncertain; reopen sync or restart to '
        'recover before retrying. The save operation failed before its '
        'commit could be confirmed.',
      );
    } catch (e, s) {
      Log.error('MergeSyncCoordinator', 'resolveConflicts error: $e\n$s');
      if (!batchCommitted) return Res.error(e.toString());
      if (applyCompleted) {
        return Res.error(
          'Resolution batch was durably saved and applied locally, but '
          'publishing may be incomplete. Retry sync to publish it.',
        );
      }
      return Res.error(
        'Resolution batch was durably saved, but local application or '
        'publishing may be incomplete. Restart or retry sync to recover it.',
      );
    }
  }

  /// Publishes outbox checkpoints, recovers from upload conflicts by reserving
  /// a dominating replacement checkpoint, acknowledges batches, and compacts.
  Future<void> _uploadOutboxWithRecovery({
    List<MergeRemoteEntry>? discovered,
    bool ensurePublished = true,
  }) async {
    if (!ensurePublished && store.pendingBatchIds.isEmpty) return;
    final priorEntries =
        discovered ??
        (ensurePublished
            ? await remote.list(latestOnly: false)
            : const <MergeRemoteEntry>[]);
    // An already-acknowledged local store may have no outbox in the new remote
    // namespace. Seed it once unless this actor already has a published checkpoint.
    if (store.pendingBatchIds.isEmpty &&
        !priorEntries.any((entry) => entry.actor == actor)) {
      await store.enqueueCheckpoint();
    }
    MergeSnapshot? lastUploaded;

    final pendingIds = store.pendingBatchIds;
    for (final id in pendingIds) {
      // A replacement publication may subsume older queued references.
      if (!store.pendingBatchIds.contains(id)) continue;
      final snapshot = store.pendingSnapshot(id);
      try {
        final uploadedPath = await remote.uploadSnapshot(snapshot);
        await store.acknowledge(id);
        await store.markReceived(uploadedPath);
        lastUploaded = snapshot;
      } on MergeRemoteConflictException catch (e) {
        Log.error(
          'MergeSyncCoordinator',
          'Upload conflict on $id: $e. Reserving replacement checkpoint dominating intended batch.',
        );
        final replacement = await store.enqueueCheckpoint();
        final replacementSnapshot = store.pendingSnapshot(replacement.id);
        final uploadedPath = await remote.uploadSnapshot(replacementSnapshot);
        await store.acknowledge(id);
        await store.acknowledge(replacement.id);
        await store.markReceived(uploadedPath);
        lastUploaded = replacementSnapshot;
      }
    }

    if (lastUploaded != null && ensurePublished) {
      await remote.compact(
        MergeSnapshot.decode(
          lastUploaded.serializeManifest(),
          lastUploaded.objects,
        ),
        priorEntries,
      );
    }
  }
}
