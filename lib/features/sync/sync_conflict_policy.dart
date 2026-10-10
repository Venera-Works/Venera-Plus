import '../../foundation/sync_records.dart';
import 'merge_engine.dart';

/// Selects safe, field-level resolutions for conflicts that can be decided
/// without a user prompt.
///
/// Local manual edits win only when their recorded dot still identifies the
/// current local value. Otherwise, the latest eligible cloud candidate is
/// selected; unverified legacy manual choices remain unresolved.
List<MergeConflictResolution> automaticConflictResolutions({
  required MergeDocument document,
  required String localActor,
  required SyncRecords localRecords,
  required bool firstSync,
  required String? Function(String recordKey, String field) manualCandidateId,
  required Map<String, DateTime> cloudActorModifiedAt,
  int? initialSyncCounter,
  String? Function(String recordKey, String field)? unverifiedManualCandidateId,
  Set<String> unavailableDomains = const {},
  bool Function(String recordKey)? shouldObserveRecord,
}) {
  final resolutions = <MergeConflictResolution>[];
  for (final conflict in document.conflicts) {
    final domain = _recordDomain(conflict.recordKey);
    if (unavailableDomains.contains(domain) ||
        (shouldObserveRecord != null &&
            !shouldObserveRecord(conflict.recordKey))) {
      continue;
    }

    final manual = _matchingManualCandidate(
      conflict: conflict,
      document: document,
      localActor: localActor,
      localRecords: localRecords,
      firstSync: firstSync,
      initialSyncCounter: initialSyncCounter,
      manualCandidateId: manualCandidateId,
    );
    if (manual != null &&
        unverifiedManualCandidateId?.call(conflict.recordKey, conflict.field) ==
            manual.id) {
      continue;
    }
    final chosen =
        manual ??
        _latestCloudCandidate(
          conflict.candidates,
          localActor: localActor,
          cloudActorModifiedAt: cloudActorModifiedAt,
        );
    if (chosen == null) continue;

    resolutions.add(
      MergeConflictResolution(
        recordKey: conflict.recordKey,
        field: conflict.field,
        candidateId: chosen.id,
        expectedCandidateIds: Set.unmodifiable(
          conflict.candidates.map((candidate) => candidate.id),
        ),
        expectedCandidateFingerprint: conflict.candidateFingerprint,
      ),
    );
  }
  return List.unmodifiable(resolutions);
}

String _recordDomain(String recordKey) {
  try {
    return syncRecordDomain(recordKey);
  } catch (_) {
    return '';
  }
}

MergeCandidate? _matchingManualCandidate({
  required MergeConflict conflict,
  required MergeDocument document,
  required String localActor,
  required SyncRecords localRecords,
  required bool firstSync,
  required int? initialSyncCounter,
  required String? Function(String recordKey, String field) manualCandidateId,
}) {
  final id = manualCandidateId(conflict.recordKey, conflict.field);
  if (id == null || id.isEmpty) return null;

  final dot = _tryParseDot(id);
  if (dot == null || dot.actor != localActor) return null;
  if (firstSync &&
      (initialSyncCounter == null || dot.counter <= initialSyncCounter)) {
    return null;
  }

  for (final candidate in conflict.candidates) {
    if (candidate.id == id &&
        document.hasActiveCandidate(conflict.recordKey, conflict.field, id) &&
        _candidateMatchesLocal(candidate, localRecords)) {
      if (!candidate.isDeleted &&
          candidate.field != 'presence' &&
          _isEmptyValue(candidate.value)) {
        return null;
      }
      return candidate;
    }
  }

  // A duration increment is stored as a contribution dot, while its resolvable
  // local choice is the engine's accumulated total. Require both the active
  // contribution and an exact match with the current local total.
  if (conflict.field == 'readDurationMs' &&
      document.hasActiveDurationContribution(conflict.recordKey, id)) {
    final localRecord = localRecords[conflict.recordKey];
    if (localRecord == null || !localRecord.containsKey(conflict.field)) {
      return null;
    }
    for (final candidate in conflict.candidates) {
      if (candidate.id == 'accumulated_total' &&
          syncValuesEqual(localRecord[conflict.field], candidate.value)) {
        return candidate;
      }
    }
  }
  return null;
}

MergeDot? _tryParseDot(String id) {
  try {
    return MergeDot.parse(id);
  } on FormatException {
    return null;
  }
}

bool _candidateMatchesLocal(
  MergeCandidate candidate,
  SyncRecords localRecords,
) {
  final record = localRecords[candidate.recordKey];
  if (candidate.field == 'presence') {
    return candidate.isDeleted ==
        !localRecords.containsKey(candidate.recordKey);
  }
  if (record == null) return false;
  if (candidate.field == 'readDurationMs') {
    return record.containsKey(candidate.field) &&
        syncValuesEqual(record[candidate.field], candidate.value);
  }
  final hasField = record.containsKey(candidate.field);
  if (candidate.isDeleted) return !hasField;
  return hasField && syncValuesEqual(record[candidate.field], candidate.value);
}

bool _isEmptyValue(Object? value) =>
    value == null ||
    (value is String && value.trim().isEmpty) ||
    (value is List && value.isEmpty) ||
    (value is Map && value.isEmpty);

MergeCandidate? _latestCloudCandidate(
  List<MergeCandidate> candidates, {
  required String localActor,
  required Map<String, DateTime> cloudActorModifiedAt,
}) {
  // Duration totals are synthetic. Only an explicitly tracked local
  // contribution can select that total; cloud choices require a real actor.
  MergeCandidate? winner;
  for (final candidate in candidates) {
    if (candidate.actor == localActor || candidate.id == 'accumulated_total') {
      continue;
    }
    if (winner == null) {
      winner = candidate;
      continue;
    }
    if (candidate.actor == winner.actor) {
      if (candidate.counter > winner.counter ||
          (candidate.counter == winner.counter &&
              candidate.id.compareTo(winner.id) > 0)) {
        winner = candidate;
      }
      continue;
    }
    final candidateTime = cloudActorModifiedAt[candidate.actor];
    final winnerTime = cloudActorModifiedAt[winner.actor];
    final timeOrder = candidateTime == null
        ? (winnerTime == null ? 0 : -1)
        : (winnerTime == null ? 1 : candidateTime.compareTo(winnerTime));
    if (timeOrder > 0 ||
        (timeOrder == 0 && _stableCandidateCompare(candidate, winner) > 0)) {
      winner = candidate;
    }
  }
  return winner;
}

int _stableCandidateCompare(MergeCandidate left, MergeCandidate right) {
  final actor = left.actor.compareTo(right.actor);
  return actor != 0 ? actor : left.id.compareTo(right.id);
}
