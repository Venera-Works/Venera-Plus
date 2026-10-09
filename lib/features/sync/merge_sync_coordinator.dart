import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../foundation/app.dart';
import '../../foundation/appdata.dart';
import '../../foundation/appdata_sync_policy.dart';
import '../../foundation/log.dart';
import '../../foundation/res.dart';
import '../../network/webdav.dart';
import '../comic_source/comic_source.dart';
import '../favorites/favorites.dart';
import '../history/history.dart';
import 'data_sync.dart';
import 'legacy_sync_reader.dart';
import 'merge_remote.dart';
import 'merge_snapshot.dart';
import 'merge_store.dart';
import 'merge_store_error.dart';
import 'sync_preferences_adapter.dart';

const bool _syncDiagnosticsEnabled =
    kDebugMode || bool.fromEnvironment('VENERA_SYNC_DIAGNOSTICS');

/// Exception thrown when local data changes during the apply commit stage.
class ConcurrentEditException implements Exception {
  final String message;
  ConcurrentEditException([
    this.message = 'Concurrent local edit during sync apply',
  ]);

  @override
  String toString() => 'ConcurrentEditException: $message';
}

class _SyncDiagnostics {
  final Map<String, int> phaseDurationsMs = {};

  void add(String phase, int milliseconds) {
    phaseDurationsMs.update(
      phase,
      (current) => current + milliseconds,
      ifAbsent: () => milliseconds,
    );
  }
}

Future<T> _measureSyncPhase<T>(
  _SyncDiagnostics diagnostics,
  String phase,
  Future<T> Function() action,
) async {
  final stopwatch = Stopwatch()..start();
  try {
    return await action();
  } finally {
    diagnostics.add(phase, stopwatch.elapsedMilliseconds);
  }
}

Future<T> _measureCoordinatorPhase<T>(
  _SyncDiagnostics? diagnostics,
  String phase,
  Future<T> Function() action,
) async {
  if (diagnostics == null) return action();
  return _measureSyncPhase(diagnostics, phase, action);
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
  _SyncDiagnostics? _activeDiagnostics;
  bool _counterReconciliationComplete = false;
  Future<void>? _startupRecoveryFuture;

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
  int _lastSyncDurationMs = 0;
  int get lastSyncDurationMs => _lastSyncDurationMs;

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

  int get pendingChangeCount => store.pendingRecordCount;

  Future<T> _measure<T>(String phase, Future<T> Function() action) =>
      _measureCoordinatorPhase(_activeDiagnostics, phase, action);

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

  String? _legacyIssueDomain(SyncSourceIssue issue) {
    final filename = issue.filename.toLowerCase();
    if (filename.endsWith('.js') ||
        filename == SourceFileMetadata.sidecarFileName.toLowerCase()) {
      return 'source';
    }
    if (filename.endsWith('.data')) return 'sourceSession';
    return null;
  }

  Future<void> _reconcileExplicitLegacySourceHealth({
    required String backupName,
    required LegacyMergeSeed seed,
    required List<SyncSourceIssue> previousIssues,
    required Set<String> previousUnavailableDomains,
    required List<SyncSourceIssue> issues,
    required Set<String> unavailableDomains,
  }) async {
    final currentIssueFilenames = seed.sourceIssues
        .map((issue) => issue.filename)
        .toSet();
    final updatedIssues = <SyncSourceIssue>[];
    final repairedDomains = <String>{};
    for (final issue in previousIssues) {
      if (issue.archiveName != backupName ||
          !seed.appliedOverrideFilenames.contains(issue.filename) ||
          issue.backupPath == null) {
        updatedIssues.add(issue);
        continue;
      }

      var archiveMatches = false;
      try {
        final backup = File(issue.backupPath!);
        if (await backup.exists()) {
          archiveMatches =
              (await sha256.bind(backup.openRead()).first)
                  .toString()
                  .toLowerCase() ==
              seed.id;
        }
      } catch (_) {}
      if (!archiveMatches) {
        updatedIssues.add(issue);
        continue;
      }

      if (currentIssueFilenames.contains(issue.filename)) continue;
      final domain = _legacyIssueDomain(issue);
      if (domain != null) repairedDomains.add(domain);
    }
    for (final issue in seed.sourceIssues) {
      if (!updatedIssues.contains(issue)) updatedIssues.add(issue);
    }

    final updatedDomains = Set<String>.of(previousUnavailableDomains)
      ..addAll(seed.unavailableDomains);
    for (final domain in repairedDomains) {
      if (seed.unavailableDomains.contains(domain)) continue;
      final blockedByIssue = updatedIssues.any((issue) {
        final issueDomain = _legacyIssueDomain(issue);
        return issueDomain == null || issueDomain == domain;
      });
      if (!blockedByIssue) updatedDomains.remove(domain);
    }

    issues
      ..clear()
      ..addAll(updatedIssues);
    unavailableDomains
      ..clear()
      ..addAll(updatedDomains);
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
  Future<void> startupRecovery() =>
      _startupRecoveryFuture ??= _startupRecoveryWithReload().whenComplete(() {
        _startupRecoveryFuture = null;
      });

  Future<void> _startupRecoveryWithReload() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _startupRecoveryOnce();
        return;
      } on MergeStoreStaleStateException {
        if (attempt == 1) rethrow;
        // Discard the failed runtime attempt, load the committed state, and
        // recapture actual business data with its validated allocation floor.
      }
    }
  }

  Future<void> _startupRecoveryOnce() async {
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

  /// Seeds causal state from the WebDAV root's original `.venera` backups.
  ///
  /// Supplying [backupName] bypasses the automatic migration marker and reads
  /// only that validated root file. Explicit imports never alter the automatic
  /// migration marker. They clear an old source issue only when a verified
  /// override for the same archive hash has actually repaired that entry.
  Future<bool> migrateLegacyIfNeeded({
    Directory? customScratchDir,
    bool applyToLocal = true,
    String? backupName,
  }) async {
    final markerKey = 'legacyMigrationDone_$endpointHash';
    if (backupName == null && appdata.implicitData[markerKey] == true) {
      return false;
    }

    await _loadLegacyIssuesIfNeeded();

    // Discover only the current Pack layout to avoid re-seeding a backup whose
    // stable seed actor is already present locally or remotely.
    final remoteEntries = await _measure(
      'discover',
      () => remote.list(latestOnly: false),
    );
    final remoteDocs = <MergeDocument>[];
    for (final entry in remoteEntries) {
      try {
        final batch = await _measure('download', () => remote.download(entry));
        remoteDocs.add(batch.document);
        if (!applyToLocal) {
          for (final value in batch.document.vclock.entries) {
            store.document.setCounterFloor(value.key, value.value);
          }
        }
      } on MergeRemoteCorruptException {
        Log.warning(
          'MergeSyncCoordinator',
          'An uncommitted snapshot candidate was skipped.',
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
    final previousLegacyIssues = List<SyncSourceIssue>.of(_legacySourceIssues);
    final previousLegacyDomains = Set<String>.of(_legacyUnavailableDomains);
    final accumulatedLegacyIssues = List<SyncSourceIssue>.of(
      _legacySourceIssues,
    );
    final accumulatedLegacyDomains = Set<String>.of(_legacyUnavailableDomains);
    var imported = false;
    try {
      final reader = LegacySyncReader(
        remote.client,
        scratch,
        preferences: preferencesAdapter,
        verifiedSourceBackupDirectory: backupDir,
        legacyOverrideDirectory: Directory(
          '${stateDirectory.path}/legacy_overrides',
        ),
      );
      final seeds = await _measure(
        'download',
        () => reader.readSeeds(backupName: backupName),
      );
      if (backupName == null && seeds.isNotEmpty) {
        hasUnhandledSourceIssues = false;
        accumulatedLegacyIssues.clear();
        accumulatedLegacyDomains.clear();
      }

      if (seeds.isNotEmpty) {
        final observation = store.localObservation;
        await _captureStable(observation: observation);
        var changed = false;
        for (final seed in seeds) {
          if (backupName == null) {
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
          }
          bool isActorCovered(String actor) {
            if (store.document.counterFor(actor) > 0) return true;
            for (final doc in remoteDocs) {
              if (doc.counterFor(actor) > 0) return true;
            }
            return false;
          }

          final baseActor = 'legacy_seed_${seed.id}';
          if (isActorCovered(baseActor)) continue;

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
                (entry) => syncRecordDomain(entry.key) == domain,
              ),
            );
            if (domainRecords.isNotEmpty) {
              final domainDoc = MergeDocument()
                ..captureLocal(domainActor, {}, domainRecords, bootstrap: true);
              store.document.merge(domainDoc);
              changed = true;
            }
            if (domain == 'source' && seed.sourceVariants.isNotEmpty) {
              for (final entry in seed.sourceVariants.entries) {
                for (final script in entry.value) {
                  final variantDoc = MergeDocument.createSourceVariantSeed(
                    entry.key,
                    script,
                  );
                  if (!store.document.dominates(variantDoc)) {
                    store.document.merge(variantDoc);
                    changed = true;
                  }
                }
              }
            }
          }
        }
        if (changed) {
          imported = true;
          await store.enqueueCheckpoint();
          if (applyToLocal) await _applyMerged(store.localObservation);
        }
        if (backupName != null && seeds.isNotEmpty) {
          await _reconcileExplicitLegacySourceHealth(
            backupName: backupName,
            seed: seeds.single,
            previousIssues: previousLegacyIssues,
            previousUnavailableDomains: previousLegacyDomains,
            issues: accumulatedLegacyIssues,
            unavailableDomains: accumulatedLegacyDomains,
          );
          hasUnhandledSourceIssues =
              accumulatedLegacyIssues.isNotEmpty ||
              accumulatedLegacyDomains.isNotEmpty;
        }
      }
    } catch (_) {
      Log.error('MergeSyncCoordinator', 'Legacy migration failed.');
      rethrow;
    } finally {
      if (await scratch.exists()) {
        try {
          await scratch.delete(recursive: true);
        } catch (_) {}
      }
    }

    if (backupName != null) {
      _legacySourceIssues = accumulatedLegacyIssues;
      _legacyUnavailableDomains = accumulatedLegacyDomains;
      await _saveLegacyIssues();
    } else if (hasUnhandledSourceIssues) {
      _legacySourceIssues = accumulatedLegacyIssues;
      _legacyUnavailableDomains = accumulatedLegacyDomains;
      await _saveLegacyIssues();
    } else {
      _legacySourceIssues = const [];
      _legacyUnavailableDomains = const {};
      await _saveLegacyIssues();
      appdata.implicitData[markerKey] = true;
      await appdata.writeImplicitData();
    }
    return imported;
  }

  /// Restored local backups may have rolled back actor counters. Reconcile only
  /// against this device's commits in the current Pack namespace.
  Future<void> reconcileBackupRecoveryIfNeeded() async {
    if (!store.recoveredFromBackup || _counterReconciliationComplete) return;

    try {
      final entries = await _measure(
        'discover',
        () => remote.list(latestOnly: false),
      );
      MergeDocument? verifiedDocument;
      final verifiedFilenames = <String>[];
      final publications = <int, String>{};
      var highest = 0;
      for (final entry in entries.where((entry) => entry.actor == actor)) {
        final batch = await _measure('download', () => remote.download(entry));
        final priorId = publications[batch.counter];
        if (priorId != null && priorId != batch.id) {
          throw MergeOutboxCounterConflictException(
            actor: actor,
            counter: batch.counter,
            existingBatchId: priorId,
            incomingBatchId: batch.id,
            metadata: {'phase': 'remote_recovery'},
          );
        }
        publications[batch.counter] = batch.id;
        try {
          final staged = verifiedDocument ?? store.document;
          if (staged.dominates(batch.document)) {
            staged.validateEventIdentities(batch.document);
          } else {
            verifiedDocument ??= store.document.clone();
            verifiedDocument.merge(batch.document);
          }
        } on FormatException {
          throw MergeStoreIntegrityException(
            metadata: {
              'phase': 'remote_recovery',
              'reason': 'causal_identity_conflict',
              'actor': actor,
              'counter': batch.counter,
              'batchId': batch.id,
            },
          );
        }
        if (batch.counter > highest) highest = batch.counter;
        verifiedFilenames.add(entry.filename);
      }
      // No durable writes, acknowledgements, or allocation-floor changes until
      // every required own publication and its referenced Packs were verified.
      if (verifiedDocument != null) {
        try {
          store.document.merge(verifiedDocument);
        } on FormatException {
          throw MergeStoreIntegrityException(
            metadata: {
              'phase': 'remote_recovery',
              'reason': 'causal_identity_conflict',
              'actor': actor,
            },
          );
        }
      }
      store.reconcileActorCounter(
        actor,
        highest,
        verifiedFilenames: verifiedFilenames,
      );
      await store.save();
      _counterReconciliationComplete = true;
    } on MergeStoreStateException {
      rethrow;
    } catch (error) {
      throw MergeStoreRemoteRecoveryException(
        metadata: {
          'phase': 'remote_recovery',
          'actor': actor,
          'errorType': error.runtimeType.toString(),
          if (error is MergeRemoteException) 'httpStatus': error.statusCode,
        },
      );
    }
  }

  /// Lists only valid original backups stored at the WebDAV root.
  Future<List<LegacyRemoteBackup>> listLegacyBackups() {
    final scratch = Directory('${stateDirectory.path}_legacy_list');
    return _measure(
      'discover',
      () => LegacySyncReader(
        remote.client,
        scratch,
        preferences: preferencesAdapter,
      ).listBackups(),
    );
  }

  /// Imports a selected root backup through the same causal seed path as the
  /// automatic migration, while honoring local apply and publish direction.
  Future<Res<bool>> importLegacyBackup(
    String backupName, {
    required SyncDirection direction,
  }) => performSync(
    direction: direction,
    checkRemote: true,
    forceCapture: true,
    legacyBackupName: backupName,
  );

  Future<bool> _mergeRemoteEntries(List<MergeRemoteEntry> entries) async {
    final byActor = <String, List<MergeRemoteEntry>>{};
    for (final entry in entries) {
      byActor.putIfAbsent(entry.actor, () => []).add(entry);
    }
    final received = store.received;
    var changed = false;
    for (final candidates in byActor.values) {
      candidates.sort((a, b) => b.counter.compareTo(a.counter));
      int? highestSucceeded;
      for (final entry in candidates) {
        if (highestSucceeded != null && entry.counter < highestSucceeded) {
          continue;
        }
        if (received.contains(entry.filename)) {
          highestSucceeded = entry.counter;
          continue;
        }
        try {
          final batch = await _measure(
            'download',
            () => remote.download(entry),
          );
          await _measure('merge', () async {
            store.document.merge(batch.document);
            await store.markReceived(entry.filename);
          });
          highestSucceeded = entry.counter;
          changed = true;
        } on MergeRemoteCorruptException {
          Log.warning(
            'MergeSyncCoordinator',
            'An incomplete checkpoint candidate was skipped.',
          );
        }
      }
    }
    return changed;
  }

  /// Executes synchronization according to direction and independent pull timing.
  Future<Res<bool>> performSync({
    required SyncDirection direction,
    bool checkRemote = true,
    bool forceCapture = true,
    String? legacyBackupName,
  }) async {
    remote.resetTransferStats();
    final diagnostics = _SyncDiagnostics();
    final total = Stopwatch()..start();
    _activeDiagnostics = diagnostics;
    if (forceCapture) {
      _changedRecordKeys.clear();
      markDirty();
    }
    try {
      await _measure('capture', () async {
        if (store.needsRecovery || store.pendingApply != null) {
          await startupRecovery();
        } else {
          await reconcileBackupRecoveryIfNeeded();
        }
        final captured = await _captureStable();
        if (captured.snapshot.needsSourceNormalization) {
          await _normalizeSourcesLocally(captured);
        }
      });
      final observation = store.localObservation;
      final markerKey = 'legacyMigrationDone_$endpointHash';
      final shouldMigrateLegacy =
          legacyBackupName != null || appdata.implicitData[markerKey] != true;
      var importedLegacy = false;
      if (shouldMigrateLegacy) {
        importedLegacy = await _measure(
          'legacyMigration',
          () => migrateLegacyIfNeeded(
            applyToLocal: direction != SyncDirection.uploadOnly,
            backupName: legacyBackupName,
          ),
        );
      }
      final needsRemoteCheck = checkRemote;

      List<MergeRemoteEntry>? discovered;
      if (direction != SyncDirection.uploadOnly && needsRemoteCheck) {
        discovered = await _measure<List<MergeRemoteEntry>>(
          'discover',
          () => remote.list(latestOnly: false),
        );
        await _mergeRemoteEntries(discovered);
      }
      if (direction != SyncDirection.uploadOnly &&
          (needsRemoteCheck || importedLegacy)) {
        // Capture edits that arrived while waiting for remote data before
        // making a durable selection; the apply guard remains authoritative.
        final stable = await _measure(
          'capture',
          () => _captureStable(observation: observation),
        );
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
          await _measure(
            'apply',
            () =>
                _applyMerged(observation, stagedGeneration: stable.generation),
          );
        } else {
          await _measure('apply', () => _applyMerged(observation));
        }
      }

      if (direction != SyncDirection.downloadOnly) {
        await _uploadOutboxWithRecovery(
          discovered: discovered,
          ensurePublished: needsRemoteCheck || forceCapture,
        );
      }
      return legacyBackupName == null ? const Res(true) : Res(importedLegacy);
    } catch (error) {
      Log.error(
        'MergeSyncCoordinator',
        error is MergeStoreStateException
            ? 'performSync failed: $error'
            : 'performSync failed (${error.runtimeType})',
      );
      return Res.error(mergeStoreErrorMessage(error));
    } finally {
      total.stop();
      diagnostics.add('totalDurationMs', total.elapsedMilliseconds);
      _lastSyncDurationMs = total.elapsedMilliseconds;
      if (_syncDiagnosticsEnabled) {
        final phases = diagnostics.phaseDurationsMs.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        Log.info(
          'MergeSyncCoordinator',
          'Sync timing ms: ${phases.map((entry) => '${entry.key}=${entry.value}').join(' ')}',
        );
        Log.info(
          'MergeSyncCoordinator',
          'Sync transfer stats: ${canonicalSyncJson(remote.transferStats)}',
        );
      }
      _activeDiagnostics = null;
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
    final diagnostics = _SyncDiagnostics();
    final total = Stopwatch()..start();
    _activeDiagnostics = diagnostics;
    var batchCommitted = false;
    var applyCompleted = false;
    try {
      await _measure('capture', () async {
        if (store.needsRecovery || store.pendingApply != null) {
          await startupRecovery();
        } else {
          await reconcileBackupRecoveryIfNeeded();
        }
      });
      final captured = await _measure('capture', _captureStable);
      final observation = store.localObservation;
      await store.resolveAll(
        immutableResolutions,
        unavailableDomains: unavailableDomains,
      );
      batchCommitted = true;
      await _measure(
        'apply',
        () => _applyMerged(observation, stagedGeneration: captured.generation),
      );
      applyCompleted = true;

      if (direction != SyncDirection.downloadOnly) {
        await _uploadOutboxWithRecovery(ensurePublished: true);
      }
      return const Res(true);
    } on MergeStorePersistenceException catch (error) {
      if (error.cause is MergeStoreStateException) {
        Log.error('MergeSyncCoordinator', mergeStoreErrorMessage(error.cause));
        return Res.error(mergeStoreErrorMessage(error.cause));
      }
      Log.error(
        'MergeSyncCoordinator',
        'Conflict resolution persistence failed.',
      );
      return Res.error(
        'Batch persistence status is uncertain; reopen sync or restart to '
        'recover before retrying. The save operation failed before its '
        'commit could be confirmed.',
      );
    } catch (error) {
      Log.error(
        'MergeSyncCoordinator',
        error is MergeStoreStateException
            ? 'Conflict resolution failed: $error'
            : 'Conflict resolution failed (${error.runtimeType})',
      );
      if (error is MergeStoreStateException || !batchCommitted) {
        return Res.error(mergeStoreErrorMessage(error));
      }
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
    } finally {
      total.stop();
      diagnostics.add('totalDurationMs', total.elapsedMilliseconds);
      _lastSyncDurationMs = total.elapsedMilliseconds;
      if (_syncDiagnosticsEnabled) {
        final phases = diagnostics.phaseDurationsMs.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        Log.info(
          'MergeSyncCoordinator',
          'Sync timing ms: ${phases.map((entry) => '${entry.key}=${entry.value}').join(' ')}',
        );
        Log.info(
          'MergeSyncCoordinator',
          'Sync transfer stats: ${canonicalSyncJson(remote.transferStats)}',
        );
      }
      _activeDiagnostics = null;
    }
  }

  static const _compactMinimumOwnCommits = 3;
  static const _compactBatchThreshold = 32;
  static const _compactMinimumInterval = Duration(days: 7);
  static const _compactCountThrottle = Duration(hours: 24);

  Future<void> _compactIfDue(
    MergeSnapshot snapshot,
    List<MergeRemoteEntry>? priorEntries, {
    required int newlyUploadedCommitCount,
  }) async {
    final ownCommitCount =
        (priorEntries ?? const <MergeRemoteEntry>[])
            .where((entry) => entry.actor == actor)
            .length +
        newlyUploadedCommitCount;
    if (ownCommitCount < _compactMinimumOwnCommits) return;

    final key = 'syncV5LastCompactionAttempt_$endpointHash';
    final previousValue = appdata.implicitData[key];
    final previousTime = previousValue is int
        ? DateTime.fromMillisecondsSinceEpoch(previousValue)
        : null;
    final now = DateTime.now();
    final elapsed = previousTime == null ? null : now.difference(previousTime);
    final countDue =
        ownCommitCount >= _compactBatchThreshold &&
        (elapsed == null || elapsed >= _compactCountThrottle);
    final timeDue = elapsed != null && elapsed >= _compactMinimumInterval;
    if (!countDue && !timeDue) return;

    try {
      final candidates =
          priorEntries ??
          await _measure<List<MergeRemoteEntry>>(
            'discover',
            () => remote.list(latestOnly: false),
          );
      await _measure(
        'compact',
        () => remote.compact(
          MergeSnapshot.decode(snapshot.serializeManifest(), snapshot.objects),
          candidates,
        ),
      );
    } catch (_) {
      // Compaction only removes obsolete own commit records. It is cleanup,
      // never a prerequisite for the already verified publication.
      Log.warning('MergeSyncCoordinator', 'Remote compaction was skipped.');
    } finally {
      appdata.implicitData[key] = now.millisecondsSinceEpoch;
      try {
        await appdata.writeImplicitData();
      } catch (_) {
        Log.warning(
          'MergeSyncCoordinator',
          'The remote compaction throttle could not be persisted.',
        );
      }
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
            ? await _measure('discover', () => remote.list(latestOnly: false))
            : null);
    // A durable local state may have no outbox in the new namespace. Publish
    // its full causal document once unless this actor already has a commit.
    if (priorEntries != null &&
        store.pendingBatchIds.isEmpty &&
        !priorEntries.any((entry) => entry.actor == actor)) {
      await store.enqueueCheckpoint();
    }
    MergeSnapshot? lastUploaded;
    var newlyUploadedCommitCount = 0;

    final pendingIds = store.pendingBatchIds;
    for (final id in pendingIds) {
      // A replacement publication may subsume older queued references.
      if (!store.pendingBatchIds.contains(id)) continue;
      final snapshot = store.pendingSnapshot(id);
      final expectedBatch = store.pendingBatch(id);
      String uploadedPath;
      try {
        uploadedPath = await _measure(
          'upload',
          () => remote.uploadSnapshot(snapshot),
        );
      } on MergeRemoteConflictException {
        Log.warning(
          'MergeSyncCoordinator',
          'A Pack publication conflict requires a dominating replacement.',
        );
        final replacement = await store.enqueueCheckpoint();
        final replacementSnapshot = store.pendingSnapshot(replacement.id);
        final replacementBatch = store.pendingBatch(replacement.id);
        if (!replacementBatch.document.dominates(expectedBatch.document)) {
          throw StateError(
            'The replacement checkpoint does not cover the pending intent.',
          );
        }
        final replacementPath = await _measure(
          'upload',
          () => remote.uploadSnapshot(replacementSnapshot),
        );
        final publishedEntry = MergeRemoteEntry.tryParsePackCommit(
          replacementPath,
          actor: actor,
        );
        if (publishedEntry == null ||
            publishedEntry.counter != replacementBatch.counter) {
          throw const FormatException(
            'The replacement Pack commit path does not match its checkpoint.',
          );
        }
        // uploadSnapshot returns only after exact manifest and Pack read-back
        // verification, so acknowledgement follows the durable publication.
        await store.acknowledge(id);
        await store.acknowledge(replacement.id);
        await store.markReceived(replacementPath);
        lastUploaded = replacementSnapshot;
        newlyUploadedCommitCount++;
        continue;
      }

      final publishedEntry = MergeRemoteEntry.tryParsePackCommit(
        uploadedPath,
        actor: actor,
      );
      if (publishedEntry == null ||
          publishedEntry.counter != expectedBatch.counter) {
        throw const FormatException(
          'The Pack commit path does not match its checkpoint.',
        );
      }
      await store.acknowledge(id);
      await store.markReceived(uploadedPath);
      lastUploaded = snapshot;
      newlyUploadedCommitCount++;
    }

    if (lastUploaded != null) {
      await _compactIfDue(
        lastUploaded,
        priorEntries,
        newlyUploadedCommitCount: newlyUploadedCommitCount,
      );
    }
  }
}
