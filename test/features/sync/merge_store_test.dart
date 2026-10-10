import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/file_interaction.dart' show overrideIO;

import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/features/sync/merge_store.dart';
import 'package:venera_plus/features/sync/merge_store_database.dart';
import 'package:venera_plus/features/sync/merge_store_error.dart';

import 'package:venera_plus/features/sync/sync_conflict_policy.dart';

SyncRecords _historySnapshot(
  String key,
  int page,
  int time, {
  int duration = 100,
}) => {
  key: {
    'readDurationMs': duration,
    'progress': {'ep': 1, 'page': page, 'group': null, 'time': time},
  },
};

Future<void> _applyCloudHistoryBaseline(
  MergeStore store,
  SyncRecords baseline,
) async {
  final cloud = MergeDocument()
    ..captureLocal('history-cloud-seed', {}, baseline, bootstrap: true);
  store.document.merge(cloud);
  await store.stageApply(baseline);
  await store.completeApply(baseline);
}

List<MergeConflictResolution> _automaticChoices(
  MergeStore store, {
  required String cloudActor,
}) => automaticConflictResolutions(
  document: store.document,
  localActor: store.actor,
  localRecords: store.observed,
  firstSync: false,
  manualCandidateId: store.manualCandidateId,
  unverifiedManualCandidateId: store.unverifiedHistoryCandidateId,
  cloudActorModifiedAt: {cloudActor: DateTime.utc(2026)},
);

Future<void> _writeLegacyUnverifiedHistoryMarker(Directory directory) async {
  const actor = 'device-alpha';
  final database = MergeStoreDatabase(directory, actor);
  final state = (await database.load())!;
  await database.commit(
    document: state.document,
    localObservation: state.localObservation,
    observed: state.observed,
    received: state.received,
    outboxIds: state.outboxIds,
    newOutboxBatches: const {},
    outboxChangedRecords: state.outboxChangedRecords,
    pendingApply: state.pendingApply,
    pendingUnavailableDomains: state.pendingUnavailableDomains,
    initialized: state.initialized,
    localEdits: state.localEdits,
    verifiedHistoryEdits: const {},
    hasCompletedSync: state.hasCompletedSync,
  );
}

({
  int revision,
  bool initialized,
  int ownCounter,
  int outboxCount,
  int observedCount,
})
_databaseSummary(File file, String actor) {
  final database = sqlite3.open(file.path);
  try {
    final metadata = <String, String>{
      for (final row in database.select('''
        SELECT key, value FROM merge_store_meta
        WHERE key IN ('commitRevision', 'initialized');
        '''))
        row['key'] as String: row['value'] as String,
    };
    final counters = database.select(
      '''
      SELECT counter FROM merge_document_vclock
      WHERE scope = 'document' AND actor = ?;
      ''',
      [actor],
    );
    final outboxRows = database.select(
      'SELECT COUNT(*) AS count FROM merge_outbox;',
    );
    final observedRows = database.select('''
      SELECT COUNT(*) AS count FROM merge_business_records
      WHERE kind = 'observed';
      ''');
    final outboxCount = outboxRows.single['count'] as int;
    final observedCount = observedRows.single['count'] as int;
    return (
      revision: int.parse(metadata['commitRevision']!),
      initialized: metadata['initialized'] == '1',
      ownCounter: counters.isEmpty ? 0 : counters.single['counter'] as int,
      outboxCount: outboxCount,
      observedCount: observedCount,
    );
  } finally {
    database.close();
  }
}

Map<String, Object?> _legacySchema2State() {
  const actor = 'device-alpha';
  final key = syncRecordKey('folder', ['fixture']);
  final records = <String, Map<String, Object?>>{
    key: {'name': 'Critical'},
  };
  final document = MergeDocument()..captureLocal(actor, {}, records);
  final batch = MergeBatch.create(
    actor: actor,
    counter: document.counterFor(actor),
    document: document,
  );
  return {
    'schemaVersion': 2,
    'actor': actor,
    'document': document.toJson(),
    'localObservation': document.toJson(),
    'observed': records,
    'received': <String>[],
    'outbox': [batch.toJson()],
    'pendingApply': null,
    'pendingUnavailableDomains': <String>[],
    'initialized': true,
  };
}

Map<String, Object?> _legacyStateWithIncomparableOutbox() {
  final state = _legacySchema2State();
  final document = MergeDocument()..setCounterFloor('device-alpha', 2);
  state['document'] = document.toJson();
  state['localObservation'] = MergeDocument().toJson();
  state['observed'] = <String, Object?>{};
  state['initialized'] = false;
  return state;
}

void main() {
  group('MergeStore', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('merge-store-test-');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test(
      'fresh store initializes clean state and persists on capture',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final databaseFile = File('${tempDir.path}/merge_store.sqlite3');
        final replicaFile = File('${databaseFile.path}.bak');
        expect(await databaseFile.exists(), isFalse);
        expect(await replicaFile.exists(), isFalse);
        expect(store.document.counterFor('device-alpha'), 0);
        expect(store.observed, isEmpty);
        expect(store.outbox, isEmpty);
        expect(store.received, isEmpty);
        expect(store.pendingApply, isNull);

        final recordKey = syncRecordKey('folder', ['folder-1']);
        final initialRecords = {
          recordKey: {'name': 'Favorites', 'order': 1},
        };

        await store.capture(initialRecords);

        expect(store.outbox.length, 1);
        final batch = store.outbox.first;
        expect(batch.actor, 'device-alpha');
        expect(batch.counter, 1);
        expect(store.observed.containsKey(recordKey), isTrue);

        final firstMain = _databaseSummary(databaseFile, 'device-alpha');
        final firstReplica = _databaseSummary(replicaFile, 'device-alpha');
        expect(firstMain, firstReplica);
        expect(firstMain.revision, 1);
        expect(firstMain.initialized, isTrue);
        expect(firstMain.ownCounter, 1);
        expect(firstMain.outboxCount, 1);
        expect(firstMain.observedCount, 1);

        // Re-capture identical state causes no new batch or durable revision.
        await store.capture(initialRecords);
        expect(store.outbox.length, 1);
        expect(
          _databaseSummary(databaseFile, 'device-alpha').revision,
          firstMain.revision,
        );
        expect(
          _databaseSummary(replicaFile, 'device-alpha'),
          _databaseSummary(databaseFile, 'device-alpha'),
        );

        // Re-load store from directory
        final storeReloaded = MergeStore(tempDir, 'device-alpha');
        await storeReloaded.load();
        expect(storeReloaded.localObservation.counterFor('device-alpha'), 1);

        expect(storeReloaded.outbox.length, 1);
        expect(storeReloaded.outbox.first.id, batch.id);
        expect(storeReloaded.observed[recordKey]?['name'], 'Favorites');
      },
    );

    test(
      'first empty capture persists initialization without revision churn',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final primary = File('${tempDir.path}/merge_store.sqlite3');
        final replica = File('${primary.path}.bak');
        expect(await primary.exists(), isFalse);
        expect(await replica.exists(), isFalse);

        await store.capture({});
        final first = _databaseSummary(primary, 'device-alpha');
        expect(first, _databaseSummary(replica, 'device-alpha'));
        expect(first.revision, 1);
        expect(first.initialized, isTrue);
        expect(first.ownCounter, 0);
        expect(first.outboxCount, 0);
        expect(first.observedCount, 0);

        await store.capture({});
        expect(
          _databaseSummary(primary, 'device-alpha').revision,
          first.revision,
        );
        expect(_databaseSummary(primary, 'device-alpha'), first);
        expect(_databaseSummary(replica, 'device-alpha'), first);

        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        await reopened.capture({});
        expect(_databaseSummary(primary, 'device-alpha'), first);
        expect(_databaseSummary(replica, 'device-alpha'), first);
      },
    );
    test('tracks bootstrap, local fields, and sync completion durably', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      await store.capture({});
      expect(store.hasCompletedSync, isFalse);

      final key = syncRecordKey('folder', ['manual-field']);
      await store.capture({
        key: {'name': 'Local'},
      });
      final manualId = store.manualCandidateId(key, 'name');
      expect(manualId, 'device-alpha:1');
      expect(store.manualCandidateId(key, 'presence'), 'device-alpha:1');

      await store.completeSync();
      final reopened = MergeStore(tempDir, 'device-alpha');
      await reopened.load();
      expect(reopened.hasCompletedSync, isTrue);
      expect(reopened.manualCandidateId(key, 'name'), manualId);

      String localEditsJson(File file) {
        final database = sqlite3.open(file.path);
        try {
          return database
                  .select(
                    '''
                SELECT value_json FROM merge_business_records
                WHERE kind = 'localEdits' AND record_key = ?;
                ''',
                    [key],
                  )
                  .single['value_json']
              as String;
        } finally {
          database.close();
        }
      }

      String completedMarker(File file) {
        final database = sqlite3.open(file.path);
        try {
          return database
                  .select(
                    "SELECT value FROM merge_store_meta WHERE key = 'hasCompletedSync';",
                  )
                  .single['value']
              as String;
        } finally {
          database.close();
        }
      }

      final primary = File('${tempDir.path}/merge_store.sqlite3');
      final replica = File('${primary.path}.bak');
      expect(localEditsJson(primary), localEditsJson(replica));
      expect(completedMarker(primary), '1');
      expect(completedMarker(replica), '1');
    });

    test(
      'cloud apply is not manual and capture tracks record deletion',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final cloudKey = syncRecordKey('folder', ['cloud-import']);
        final cloudRecords = {
          cloudKey: {'name': 'Cloud'},
        };
        await store.stageApply(cloudRecords);
        await store.completeApply(cloudRecords);
        expect(store.manualCandidateId(cloudKey, 'name'), isNull);
        expect(store.hasCompletedSync, isFalse);

        final localKey = syncRecordKey('folder', ['deleted-locally']);
        await store.capture({
          ...cloudRecords,
          localKey: {'name': 'Local'},
        });
        expect(store.manualCandidateId(localKey, 'name'), 'device-alpha:1');
        await store.capture(cloudRecords);
        expect(store.manualCandidateId(localKey, 'presence'), 'device-alpha:2');
        expect(store.manualCandidateId(localKey, 'name'), isNull);
        expect(store.manualCandidateId(cloudKey, 'name'), isNull);
      },
    );

    test('manual record edits survive a concurrent cloud deletion', () async {
      final key = syncRecordKey('favorite', ['folder', 'comic', 0]);
      final base = {
        key: <String, Object?>{'title': 'Original', 'order': 0},
      };
      var store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      await store.capture(base);
      final cloud = store.document.clone()..captureLocal('cloud', base, {});
      await store.capture({
        key: {'title': 'Manual title', 'order': 0},
      });
      final titleId = store.manualCandidateId(key, 'title');
      await store.capture({
        key: {'title': 'Manual title', 'order': 1},
      });
      store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      store.document.merge(cloud);
      final conflict = store.document.conflicts.singleWhere(
        (item) => item.field == 'presence',
      );
      await store.resolveAll([
        MergeConflictResolution(
          recordKey: key,
          field: 'presence',
          candidateId: store.manualCandidateId(key, 'presence')!,
          expectedCandidateIds: conflict.candidates
              .map((item) => item.id)
              .toSet(),
        ),
      ], manual: false);
      expect(store.pendingApply![key], {'title': 'Manual title', 'order': 1});
      expect(store.manualCandidateId(key, 'title'), titleId);
      expect(store.document.conflicts, isEmpty);
    });

    test(
      'automatic resolution inherits or clears a local manual field',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['automatic-manual-choice']);
        final base = {
          key: {'name': 'Base'},
        };
        await store.capture(base);
        await store.capture({
          key: {'name': 'Local'},
        });
        final firstManualId = store.manualCandidateId(key, 'name')!;

        final remoteA = MergeDocument()
          ..captureLocal('remote-a', {}, base)
          ..captureLocal('remote-a', base, {
            key: {'name': 'Cloud A'},
          });
        store.document.merge(remoteA);
        final firstConflict = store.document.conflicts.singleWhere(
          (conflict) => conflict.field == 'name',
        );
        expect(
          firstConflict.candidates.map((candidate) => candidate.id),
          contains(firstManualId),
        );
        await store.resolveAll([
          MergeConflictResolution(
            recordKey: key,
            field: 'name',
            candidateId: firstManualId,
          ),
        ], manual: false);
        final inheritedManualId = store.manualCandidateId(key, 'name');
        expect(inheritedManualId, isNotNull);
        expect(inheritedManualId, isNot(firstManualId));
        await store.completeApply(store.pendingApply!);

        await store.capture({
          key: {'name': 'Local again'},
        });
        final secondManualId = store.manualCandidateId(key, 'name')!;
        final remoteB = MergeDocument()
          ..captureLocal('remote-b', {}, base)
          ..captureLocal('remote-b', base, {
            key: {'name': 'Cloud B'},
          });
        store.document.merge(remoteB);
        final secondConflict = store.document.conflicts.singleWhere(
          (conflict) => conflict.recordKey == key && conflict.field == 'name',
        );
        final cloudCandidate = secondConflict.candidates.singleWhere(
          (candidate) =>
              candidate.actor == 'remote-b' && candidate.value == 'Cloud B',
        );
        expect(
          secondConflict.candidates.map((candidate) => candidate.id),
          contains(secondManualId),
        );
        await store.resolveAll([
          MergeConflictResolution(
            recordKey: key,
            field: 'name',
            candidateId: cloudCandidate.id,
          ),
        ], manual: false);
        expect(store.manualCandidateId(key, 'name'), isNull);
      },
    );

    test(
      'automatic duration total inherits a local contribution marker',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['manual-duration']);
        final base = {
          key: {'readDurationMs': 100},
        };
        await store.capture(base);
        await store.capture({
          key: {'readDurationMs': 120},
        });
        final manualId = store.manualCandidateId(key, 'readDurationMs')!;

        final remote = MergeDocument()
          ..captureLocal('remote-duration', {}, base, bootstrap: true)
          ..captureLocal('remote-duration', base, {
            key: {'readDurationMs': 50},
          });
        store.document.merge(remote);
        final conflict = store.document.conflicts.singleWhere(
          (candidate) => candidate.field == 'readDurationMs',
        );
        final accumulatedTotal = conflict.candidates.singleWhere(
          (candidate) => candidate.id == 'accumulated_total',
        );
        expect(accumulatedTotal.value, 120);

        await store.resolveAll([
          MergeConflictResolution(
            recordKey: key,
            field: 'readDurationMs',
            candidateId: accumulatedTotal.id,
          ),
        ], manual: false);
        expect(
          store.manualCandidateId(key, 'readDurationMs'),
          'device-alpha:3',
        );
        expect(store.manualCandidateId(key, 'readDurationMs'), isNot(manualId));
      },
    );
    test('pending recovery only marks proven edits as manual', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      final key = syncRecordKey('folder', ['recovered-local-edit']);
      await store.capture({
        key: {'name': 'Original', 'order': 1},
      });

      final firstTarget = {
        key: {'name': 'Cloud', 'order': 2},
      };
      await store.stageApply(firstTarget);
      await store.recoverPendingApply({
        key: {'name': 'Cloud', 'order': 1},
      }, previous: firstTarget);
      expect(store.manualCandidateId(key, 'order'), isNull);
      await store.completeApply(store.pendingApply!);

      final nextTarget = {
        key: {'name': 'Next cloud', 'order': 3},
      };
      await store.stageApply(nextTarget);
      await store.recoverPendingApply({
        key: {'name': 'Next cloud', 'order': 4},
      }, previous: nextTarget);
      expect(store.manualCandidateId(key, 'order'), 'device-alpha:3');
    });
    test(
      'history time refresh does not steal a cloud position choice',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['time-only']);
        final baseline = _historySnapshot(key, 1, 100);
        await _applyCloudHistoryBaseline(store, baseline);

        await store.capture(_historySnapshot(key, 1, 200));
        expect(store.manualCandidateId(key, 'progress'), isNull);
        expect(store.manualCandidateId(key, 'presence'), isNull);

        const cloudActor = 'history-cloud-time-only';
        store.document.merge(
          MergeDocument()
            ..captureLocal(cloudActor, baseline, _historySnapshot(key, 2, 300)),
        );
        final choices = _automaticChoices(store, cloudActor: cloudActor);
        final progressChoice = choices.singleWhere(
          (choice) => choice.recordKey == key && choice.field == 'progress',
        );
        final progressConflict = store.document.conflicts.singleWhere(
          (conflict) =>
              conflict.recordKey == key && conflict.field == 'progress',
        );
        expect(
          progressChoice.candidateId,
          progressConflict.candidates
              .singleWhere((candidate) => candidate.actor == cloudActor)
              .id,
        );

        await store.resolveAll(choices, manual: false);
        expect(
          store.pendingApply![key]!['progress'],
          _historySnapshot(key, 2, 300)[key]!['progress'],
        );
        await store.completeApply(store.pendingApply!);
        expect(store.observed[key]!['progress'], {
          'ep': 1,
          'page': 2,
          'group': null,
          'time': 300,
        });
      },
    );

    test(
      'time refresh with duration change does not prefer progress',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['time-and-duration']);
        final baseline = _historySnapshot(key, 1, 100);
        await _applyCloudHistoryBaseline(store, baseline);
        await store.capture(_historySnapshot(key, 1, 200, duration: 130));

        expect(store.manualCandidateId(key, 'progress'), isNull);
        expect(store.manualCandidateId(key, 'readDurationMs'), isNotNull);
        expect(store.manualCandidateId(key, 'presence'), isNotNull);
        expect(store.unverifiedHistoryCandidateId(key, 'presence'), isNull);

        const cloudActor = 'history-cloud-time-and-duration';
        store.document.merge(
          MergeDocument()..captureLocal(
            cloudActor,
            baseline,
            _historySnapshot(key, 2, 300, duration: 130),
          ),
        );
        final choices = _automaticChoices(store, cloudActor: cloudActor);
        final progressChoice = choices.singleWhere(
          (choice) => choice.recordKey == key && choice.field == 'progress',
        );
        final progressConflict = store.document.conflicts.singleWhere(
          (conflict) =>
              conflict.recordKey == key && conflict.field == 'progress',
        );
        expect(
          progressChoice.candidateId,
          progressConflict.candidates
              .singleWhere((candidate) => candidate.actor == cloudActor)
              .id,
        );
        await store.resolveAll(choices, manual: false);
        await store.completeApply(store.pendingApply!);
        expect(
          store.observed[key]!['progress'],
          _historySnapshot(key, 2, 300, duration: 130)[key]!['progress'],
        );
      },
    );

    test('verified reread survives a later time refresh and restart', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      final key = syncRecordKey('history', ['verified-reread']);
      final baseline = _historySnapshot(key, 1, 100);
      await _applyCloudHistoryBaseline(store, baseline);

      await store.capture(_historySnapshot(key, 2, 200, duration: 140));
      await store.capture(_historySnapshot(key, 2, 300, duration: 140));
      expect(store.unverifiedHistoryCandidateId(key, 'progress'), isNull);
      expect(store.unverifiedHistoryCandidateId(key, 'presence'), isNull);

      final reopened = MergeStore(tempDir, 'device-alpha');
      await reopened.load();
      expect(reopened.unverifiedHistoryCandidateId(key, 'progress'), isNull);
      expect(reopened.unverifiedHistoryCandidateId(key, 'presence'), isNull);

      const cloudActor = 'history-cloud-after-reread';
      reopened.document.merge(
        MergeDocument()..captureLocal(
          cloudActor,
          baseline,
          _historySnapshot(key, 3, 400, duration: 140),
        ),
      );
      final choices = _automaticChoices(reopened, cloudActor: cloudActor);
      final choice = choices.singleWhere(
        (resolution) =>
            resolution.recordKey == key && resolution.field == 'progress',
      );
      expect(choice.candidateId, reopened.manualCandidateId(key, 'progress'));

      await reopened.resolveAll(choices, manual: false);
      expect(reopened.pendingApply![key]!['progress'], {
        'ep': 1,
        'page': 2,
        'group': null,
        'time': 300,
      });
      await reopened.completeApply(reopened.pendingApply!);
      expect(reopened.observed[key]!['progress'], {
        'ep': 1,
        'page': 2,
        'group': null,
        'time': 300,
      });
    });

    test(
      'unverified legacy history marker waits for explicit confirmation',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['legacy-marker']);
        final baseline = _historySnapshot(key, 1, 100);
        await _applyCloudHistoryBaseline(store, baseline);
        await store.capture(_historySnapshot(key, 2, 200));
        final oldManualId = store.manualCandidateId(key, 'progress')!;

        await _writeLegacyUnverifiedHistoryMarker(tempDir);
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        await reopened.capture(_historySnapshot(key, 2, 250, duration: 130));
        final inheritedManualId = reopened.manualCandidateId(key, 'progress')!;
        expect(inheritedManualId, isNot(oldManualId));
        expect(
          reopened.unverifiedHistoryCandidateId(key, 'progress'),
          inheritedManualId,
        );
        final inheritedPresenceId = reopened.manualCandidateId(
          key,
          'presence',
        )!;
        expect(
          reopened.unverifiedHistoryCandidateId(key, 'presence'),
          inheritedPresenceId,
        );
        final afterRefresh = MergeStore(tempDir, 'device-alpha');
        await afterRefresh.load();
        expect(
          afterRefresh.manualCandidateId(key, 'progress'),
          inheritedManualId,
        );
        expect(
          afterRefresh.unverifiedHistoryCandidateId(key, 'progress'),
          inheritedManualId,
        );
        expect(
          afterRefresh.unverifiedHistoryCandidateId(key, 'presence'),
          inheritedPresenceId,
        );
        const cloudActor = 'history-cloud-legacy-marker';
        afterRefresh.document.merge(
          MergeDocument()
            ..captureLocal(cloudActor, baseline, _historySnapshot(key, 3, 300)),
        );
        expect(
          _automaticChoices(afterRefresh, cloudActor: cloudActor),
          isEmpty,
        );
        expect(
          afterRefresh.document.conflicts.any(
            (conflict) =>
                conflict.recordKey == key && conflict.field == 'progress',
          ),
          isTrue,
        );

        final progressConflict = afterRefresh.document.conflicts.singleWhere(
          (conflict) =>
              conflict.recordKey == key && conflict.field == 'progress',
        );
        final cloudCandidate = progressConflict.candidates.singleWhere(
          (candidate) => candidate.actor == cloudActor,
        );
        await afterRefresh.resolveAll([
          MergeConflictResolution(
            recordKey: key,
            field: 'progress',
            candidateId: cloudCandidate.id,
          ),
        ]);
        expect(afterRefresh.pendingApply![key]!['progress'], {
          'ep': 1,
          'page': 3,
          'group': null,
          'time': 300,
        });

        final afterChoice = MergeStore(tempDir, 'device-alpha');
        await afterChoice.load();
        expect(afterChoice.document.conflicts, isEmpty);
        expect(afterChoice.pendingApply![key]!['progress'], {
          'ep': 1,
          'page': 3,
          'group': null,
          'time': 300,
        });
        expect(
          afterChoice.unverifiedHistoryCandidateId(key, 'progress'),
          isNull,
        );
        await afterChoice.completeApply(afterChoice.pendingApply!);
        final afterApply = MergeStore(tempDir, 'device-alpha');
        await afterApply.load();
        expect(afterApply.observed[key]!['progress'], {
          'ep': 1,
          'page': 3,
          'group': null,
          'time': 300,
        });
      },
    );

    test(
      'pending recovery ignores old-position timestamp during cloud apply',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['recovery-old-position-time']);
        final baseline = _historySnapshot(key, 1, 100);
        await _applyCloudHistoryBaseline(store, baseline);
        const cloudActor = 'history-cloud-recovery-old-position';
        store.document.merge(
          MergeDocument()..captureLocal(
            cloudActor,
            baseline,
            _historySnapshot(key, 2, 200, duration: 110),
          ),
        );
        final choices = _automaticChoices(store, cloudActor: cloudActor);
        await store.resolveAll(choices, manual: false);
        final target = store.pendingApply!;
        expect(target[key]!['progress'], {
          'ep': 1,
          'page': 2,
          'group': null,
          'time': 200,
        });

        await store.recoverPendingApply(
          _historySnapshot(key, 1, 101),
          previous: target,
        );
        expect(store.manualCandidateId(key, 'progress'), isNull);
        expect(store.manualCandidateId(key, 'presence'), isNull);

        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.manualCandidateId(key, 'progress'), isNull);
        expect(reopened.manualCandidateId(key, 'presence'), isNull);
        await reopened.completeApply(reopened.pendingApply!);
        const nextCloudActor = 'history-cloud-after-interrupted-apply';
        reopened.document.merge(
          MergeDocument()..captureLocal(
            nextCloudActor,
            baseline,
            _historySnapshot(key, 3, 300, duration: 110),
          ),
        );
        await reopened.resolveAll(
          _automaticChoices(reopened, cloudActor: nextCloudActor),
          manual: false,
        );
        await reopened.completeApply(reopened.pendingApply!);
        expect(
          reopened.observed[key]!['progress'],
          _historySnapshot(key, 3, 300)[key]!['progress'],
        );
      },
    );

    test('recovery does not upgrade an unknown history source', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      final key = syncRecordKey('history', ['recovery-unknown-source']);
      final baseline = _historySnapshot(key, 1, 100);
      await _applyCloudHistoryBaseline(store, baseline);
      await store.capture(_historySnapshot(key, 2, 200));
      final oldManualId = store.manualCandidateId(key, 'progress')!;
      await _writeLegacyUnverifiedHistoryMarker(tempDir);

      final reopened = MergeStore(tempDir, 'device-alpha');
      await reopened.load();
      const cloudActor = 'history-cloud-recovery-unknown';
      final remote = MergeDocument()
        ..captureLocal(cloudActor, baseline, _historySnapshot(key, 3, 300));
      reopened.document.merge(remote);
      final target = remote.materialize();
      await reopened.stageApply(target);
      await reopened.recoverPendingApply(
        _historySnapshot(key, 2, 250),
        previous: target,
      );
      final inheritedManualId = reopened.manualCandidateId(key, 'progress')!;
      expect(inheritedManualId, isNot(oldManualId));
      expect(
        reopened.unverifiedHistoryCandidateId(key, 'progress'),
        inheritedManualId,
      );

      final afterRecovery = MergeStore(tempDir, 'device-alpha');
      await afterRecovery.load();
      expect(
        afterRecovery.manualCandidateId(key, 'progress'),
        inheritedManualId,
      );
      expect(
        afterRecovery.unverifiedHistoryCandidateId(key, 'progress'),
        inheritedManualId,
      );
      expect(
        _automaticChoices(afterRecovery, cloudActor: cloudActor).where(
          (choice) => choice.recordKey == key && choice.field == 'progress',
        ),
        isEmpty,
      );
      expect(
        afterRecovery.document.conflicts.any(
          (conflict) =>
              conflict.recordKey == key && conflict.field == 'progress',
        ),
        isTrue,
      );
      expect(
        afterRecovery.pendingApply![key]!['progress'],
        _historySnapshot(key, 2, 250)[key]!['progress'],
      );
    });

    test(
      'verified reread source survives interrupted recovery time refresh',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['recovery-verified-source']);
        final baseline = _historySnapshot(key, 1, 100);
        await _applyCloudHistoryBaseline(store, baseline);
        await store.capture(_historySnapshot(key, 2, 200, duration: 140));

        const cloudActor = 'history-cloud-recovery-verified';
        store.document.merge(
          MergeDocument()..captureLocal(
            cloudActor,
            baseline,
            _historySnapshot(key, 3, 300, duration: 140),
          ),
        );
        final choices = _automaticChoices(store, cloudActor: cloudActor);
        final progressChoice = choices.singleWhere(
          (choice) => choice.recordKey == key && choice.field == 'progress',
        );
        expect(
          progressChoice.candidateId,
          store.manualCandidateId(key, 'progress'),
        );
        await store.resolveAll(choices, manual: false);
        final target = store.pendingApply!;
        final resolvedId = store.manualCandidateId(key, 'progress')!;
        expect(store.unverifiedHistoryCandidateId(key, 'progress'), isNull);

        await store.recoverPendingApply(
          _historySnapshot(key, 2, 250, duration: 140),
          previous: target,
        );
        final recoveredId = store.manualCandidateId(key, 'progress')!;
        expect(recoveredId, isNot(resolvedId));
        expect(store.unverifiedHistoryCandidateId(key, 'progress'), isNull);

        final afterRecovery = MergeStore(tempDir, 'device-alpha');
        await afterRecovery.load();
        expect(afterRecovery.manualCandidateId(key, 'progress'), recoveredId);
        expect(
          afterRecovery.unverifiedHistoryCandidateId(key, 'progress'),
          isNull,
        );
        await afterRecovery.completeApply(afterRecovery.pendingApply!);

        final afterApply = MergeStore(tempDir, 'device-alpha');
        await afterApply.load();
        const nextCloudActor = 'history-cloud-after-recovery-refresh';
        afterApply.document.merge(
          MergeDocument()..captureLocal(
            nextCloudActor,
            baseline,
            _historySnapshot(key, 4, 400, duration: 140),
          ),
        );
        final nextChoices = _automaticChoices(
          afterApply,
          cloudActor: nextCloudActor,
        );
        final nextChoice = nextChoices.singleWhere(
          (choice) => choice.recordKey == key && choice.field == 'progress',
        );
        expect(nextChoice.candidateId, recoveredId);
        await afterApply.resolveAll(nextChoices, manual: false);
        await afterApply.completeApply(afterApply.pendingApply!);
        expect(
          afterApply.observed[key]!['progress'],
          _historySnapshot(key, 2, 250)[key]!['progress'],
        );
      },
    );

    test('verified history edit tampering fails closed', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      final key = syncRecordKey('history', ['tampered-source']);
      await _applyCloudHistoryBaseline(store, _historySnapshot(key, 1, 100));
      await store.capture(_historySnapshot(key, 2, 200));

      for (final file in [
        File('${tempDir.path}/merge_store.sqlite3'),
        File('${tempDir.path}/merge_store.sqlite3.bak'),
      ]) {
        final database = sqlite3.open(file.path);
        try {
          final current =
              jsonDecode(
                    database
                            .select(
                              '''
                  SELECT value_json FROM merge_business_records
                  WHERE kind = 'verifiedHistoryEdits' AND record_key = ?;
                  ''',
                              [key],
                            )
                            .single['value_json']
                        as String,
                  )
                  as Map<String, Object?>;
          current['progress'] = 'device-alpha:999';
          database.execute(
            '''
            UPDATE merge_business_records SET value_json = ?
            WHERE kind = 'verifiedHistoryEdits' AND record_key = ?;
            ''',
            [canonicalSyncJson(current), key],
          );
        } finally {
          database.close();
        }
      }
      await expectLater(
        MergeStore(tempDir, 'device-alpha').load(),
        throwsA(isA<MergeStoreIntegrityException>()),
      );
    });
    test('committed empty store captures inside overrideIO', () async {
      const actor = 'device-alpha';
      final primary = File('${tempDir.path}/merge_store.sqlite3');
      final replica = File('${primary.path}.bak');
      final emptyStore = MergeStore(tempDir, actor);
      await emptyStore.load();
      await emptyStore.save();

      final committedEmpty = _databaseSummary(primary, actor);
      expect(committedEmpty, _databaseSummary(replica, actor));
      expect(committedEmpty.revision, 1);
      expect(committedEmpty.initialized, isFalse);
      expect(committedEmpty.ownCounter, 0);
      expect(committedEmpty.outboxCount, 0);

      final recordKey = syncRecordKey('folder', ['first-profile']);
      final profile = {
        recordKey: {'name': 'First profile'},
      };
      await overrideIO(() async {
        final reopened = MergeStore(tempDir, actor);
        await reopened.load();
        expect(reopened.document.counterFor(actor), 0);
        expect(reopened.observed, isEmpty);
        expect(reopened.outbox, isEmpty);

        await reopened.capture(profile);
        expect(reopened.document.counterFor(actor), 1);
        expect(reopened.observed, profile);
        expect(reopened.outbox, hasLength(1));
        expect(reopened.outbox.single.counter, 1);
        final batchId = reopened.outbox.single.id;

        final committed = _databaseSummary(primary, actor);
        expect(committed, _databaseSummary(replica, actor));
        expect(committed.revision, 2);
        expect(committed.initialized, isTrue);
        expect(committed.ownCounter, 1);
        expect(committed.outboxCount, 1);
        expect(committed.observedCount, 1);

        final recovered = MergeStore(tempDir, actor);
        await recovered.load();
        expect(recovered.document.counterFor(actor), 1);
        expect(recovered.localObservation.counterFor(actor), 1);
        expect(recovered.observed, profile);
        expect(recovered.pendingBatchIds, [batchId]);
        expect(recovered.outbox.single.counter, 1);
        expect(_databaseSummary(primary, actor), committed);
      });
    });

    test('existing profile preserves causal state inside overrideIO', () async {
      const actor = 'device-alpha';
      final primary = File('${tempDir.path}/merge_store.sqlite3');
      final replica = File('${primary.path}.bak');
      final recordKey = syncRecordKey('folder', ['profile']);
      final store = MergeStore(tempDir, actor);
      await store.load();

      for (var version = 1; version <= 4; version++) {
        await store.capture({
          recordKey: {'name': 'Profile $version'},
        });
      }
      expect(store.document.counterFor(actor), 4);
      final lastBatchId = store.outbox.last.id;
      await store.acknowledge(lastBatchId);
      expect(store.outbox, isEmpty);

      final receivedFiles = <String>{
        'remote-checkpoint-1.json',
        'remote-checkpoint-2.json',
        'remote-checkpoint-3.json',
        'remote-checkpoint-4.json',
        'remote-checkpoint-5.json',
        'remote-checkpoint-6.json',
      };
      for (final filename in receivedFiles) {
        await store.markReceived(filename);
      }

      final profile = {
        recordKey: {'name': 'Profile 4'},
      };
      final revisionEleven = _databaseSummary(primary, actor);
      expect(revisionEleven, _databaseSummary(replica, actor));
      expect(revisionEleven.revision, 11);
      expect(revisionEleven.ownCounter, 4);
      expect(revisionEleven.outboxCount, 0);
      expect(revisionEleven.observedCount, 1);

      await overrideIO(() async {
        final reopened = MergeStore(tempDir, actor);
        await reopened.load();
        expect(reopened.observed, profile);
        expect(reopened.document.counterFor(actor), 4);
        expect(reopened.localObservation.counterFor(actor), 4);
        expect(reopened.received, receivedFiles);
        expect(reopened.outbox, isEmpty);
        expect(_databaseSummary(primary, actor), revisionEleven);

        final nextProfile = {
          recordKey: {'name': 'Profile 5'},
        };
        await reopened.capture(nextProfile);
        expect(reopened.observed, nextProfile);
        expect(reopened.document.counterFor(actor), 5);
        expect(reopened.outbox, hasLength(1));
        final pendingBatch = reopened.outbox.single;
        expect(pendingBatch.counter, 5);
        expect(pendingBatch.document.materialize(), nextProfile);

        final revisionTwelve = _databaseSummary(primary, actor);
        expect(revisionTwelve, _databaseSummary(replica, actor));
        expect(revisionTwelve.revision, 12);
        expect(revisionTwelve.ownCounter, 5);
        expect(revisionTwelve.outboxCount, 1);
        expect(revisionTwelve.observedCount, 1);

        final recovered = MergeStore(tempDir, actor);
        await recovered.load();
        expect(recovered.observed, nextProfile);
        expect(recovered.document.counterFor(actor), 5);
        expect(recovered.localObservation.counterFor(actor), 5);
        expect(recovered.received, receivedFiles);
        expect(recovered.pendingBatchIds, [pendingBatch.id]);
        expect(
          recovered.pendingBatch(pendingBatch.id).toJson(),
          pendingBatch.toJson(),
        );
        expect(recovered.outbox.single.document.materialize(), nextProfile);
        expect(_databaseSummary(primary, actor), revisionTwelve);
      });
    });

    test(
      'stale empty writer cannot be overwritten and reload enables capture',
      () async {
        final stale = MergeStore(tempDir, 'device-alpha');
        await stale.load();

        final competing = MergeStoreDatabase(tempDir, 'device-alpha');
        expect(await competing.load(), isNull);
        await competing.commit(
          document: MergeDocument(),
          localObservation: MergeDocument(),
          observed: {},
          received: {},
          outboxIds: [],
          newOutboxBatches: {},
          outboxChangedRecords: {},
          pendingApply: null,
          pendingUnavailableDomains: {},
          initialized: false,
        );
        final primary = File('${tempDir.path}/merge_store.sqlite3');
        final replica = File('${primary.path}.bak');
        final emptyStore = _databaseSummary(primary, 'device-alpha');
        expect(emptyStore, _databaseSummary(replica, 'device-alpha'));
        expect(emptyStore.revision, 1);
        expect(emptyStore.initialized, isFalse);
        expect(emptyStore.ownCounter, 0);
        expect(emptyStore.outboxCount, 0);
        final primaryBefore = await primary.readAsBytes();
        final replicaBefore = await replica.readAsBytes();

        final key = syncRecordKey('folder', ['after-empty-writer']);
        final records = {
          key: {'name': 'Durable capture'},
        };
        await expectLater(
          stale.capture(records),
          throwsA(
            isA<MergeStoreStaleStateException>().having(
              (error) => error.code,
              'code',
              'SYNC_STATE_CHANGED',
            ),
          ),
        );
        expect(await primary.readAsBytes(), orderedEquals(primaryBefore));
        expect(await replica.readAsBytes(), orderedEquals(replicaBefore));

        final reloaded = MergeStore(tempDir, 'device-alpha');
        await reloaded.load();
        expect(reloaded.observed, isEmpty);
        await reloaded.capture(records);

        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.observed[key], {'name': 'Durable capture'});
        expect(reopened.outbox, hasLength(1));
        expect(reopened.outbox.single.counter, 1);
        final committed = _databaseSummary(primary, 'device-alpha');
        expect(committed, _databaseSummary(replica, 'device-alpha'));
        expect(committed.revision, 2);
        expect(committed.initialized, isTrue);
        expect(committed.ownCounter, 1);
        expect(committed.outboxCount, 1);
        expect(committed.observedCount, 1);
      },
    );

    test(
      'enqueueCheckpoint forces new publication batch without diff',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final batch1 = await store.enqueueCheckpoint();
        expect(batch1.counter, 1);
        expect(store.outbox.length, 1);

        final batch2 = await store.enqueueCheckpoint();
        expect(batch2.counter, 2);
        expect(store.outbox.length, 1);

        expect(batch2.dominates(batch1), isTrue);
        expect(batch2.coversActor('device-alpha', 1), isTrue);
      },
    );
    test('retains a queued snapshot unless the new one dominates it', () async {
      final legacyState = jsonEncode(_legacyStateWithIncomparableOutbox());
      await File('${tempDir.path}/state.json').writeAsString(legacyState);
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      final oldId = store.pendingBatchIds.single;

      final checkpoint = await store.enqueueCheckpoint();
      expect(checkpoint.counter, 3);
      expect(store.pendingBatchIds, [oldId, checkpoint.id]);

      final reopened = MergeStore(tempDir, 'device-alpha');
      await reopened.load();
      expect(reopened.pendingBatchIds, [oldId, checkpoint.id]);
      expect(reopened.pendingBatch(oldId).counter, 1);
      expect(reopened.pendingBatch(checkpoint.id).counter, 3);
    });

    test(
      'acknowledge removes published batches from outbox and persists',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        await store.capture({
          syncRecordKey('folder', ['f1']): {'name': 'F1'},
        });

        expect(store.outbox.length, 1);
        final batchId = store.outbox.first.id;

        await store.acknowledge(batchId);
        expect(store.outbox, isEmpty);

        // Verify persisted state
        final storeReloaded = MergeStore(tempDir, 'device-alpha');
        await storeReloaded.load();
        expect(storeReloaded.outbox, isEmpty);
      },
    );

    test(
      'stageApply writes durable journal and recovers pendingApply after crash',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final stagedRecords = {
          syncRecordKey('folder', ['remote-folder']): {'name': 'Remote Folder'},
        };

        // Stage apply in journal
        await store.stageApply(stagedRecords);
        expect(store.pendingApply, isNotNull);

        // Simulate crash: new store instance opens directory without completeApply having run
        final storeCrashed = MergeStore(tempDir, 'device-alpha');
        await storeCrashed.load();

        // Pending apply MUST be recovered from journal
        expect(storeCrashed.pendingApply, isNotNull);
        expect(
          storeCrashed.pendingApply![syncRecordKey('folder', [
            'remote-folder',
          ])]?['name'],
          'Remote Folder',
        );

        // Now complete apply
        await storeCrashed.completeApply(stagedRecords);
        expect(storeCrashed.pendingApply, isNull);
        expect(
          storeCrashed.observed.containsKey(
            syncRecordKey('folder', ['remote-folder']),
          ),
          isTrue,
        );

        // Verify journal file was deleted
        final journalFile = File('${tempDir.path}/apply_journal.json');
        expect(await journalFile.exists(), isFalse);
      },
    );

    test(
      'recovers from SQLite backup if primary database is corrupted',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Important Data'},
        });

        // A committed SQLite backup remains available if the primary is damaged.
        final stateFile = File('${tempDir.path}/merge_store.sqlite3');
        await stateFile.writeAsString('BROKEN_SQLITE_PRIMARY');

        // Reload store: must recover from the committed SQLite backup.
        final storeReloaded = MergeStore(tempDir, 'device-alpha');
        await storeReloaded.load();

        expect(storeReloaded.observed.containsKey(key), isTrue);
        expect(storeReloaded.observed[key]?['name'], 'Important Data');
        expect(storeReloaded.recoveredFromBackup, isTrue);

        // Reconcile counter floor to prevent counter regression
        storeReloaded.reconcileActorCounter('device-alpha', 10);
        expect(storeReloaded.document.counterFor('device-alpha'), 10);
        await storeReloaded.capture({
          key: {'name': 'New Data'},
        });
        expect(storeReloaded.document.counterFor('device-alpha'), 11);
      },
    );
    test('repairs a stale mirror by commit revision before recovery', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      final key = syncRecordKey('folder', ['replica-revision']);
      await store.capture({
        key: {'name': 'First'},
      });
      final stateFile = File('${tempDir.path}/merge_store.sqlite3');
      final backupFile = File('${stateFile.path}.bak');
      final staleBackup = File('${tempDir.path}/stale-merge-store.bak');
      await backupFile.copy(staleBackup.path);

      await store.capture({
        key: {'name': 'Latest'},
      });
      await backupFile.delete();
      await staleBackup.copy(backupFile.path);

      final synchronized = MergeStore(tempDir, 'device-alpha');
      await synchronized.load();
      expect(synchronized.recoveredFromBackup, isFalse);
      expect(synchronized.observed[key]?['name'], 'Latest');

      await stateFile.delete();
      await staleBackup.copy(stateFile.path);
      final recovered = MergeStore(tempDir, 'device-alpha');
      await recovered.load();
      expect(recovered.recoveredFromBackup, isTrue);
      expect(recovered.observed[key]?['name'], 'Latest');
    });

    test(
      'fails loudly and never silently resets to empty if state and backup are corrupt',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Critical Data'},
        });

        // Corrupt both primary and backup.
        final stateFile = File('${tempDir.path}/merge_store.sqlite3');
        final bakFile = File('${tempDir.path}/merge_store.sqlite3.bak');
        await stateFile.writeAsString('GARBAGE_PRIMARY');
        await bakFile.writeAsString('GARBAGE_BACKUP');

        final storeReloaded = MergeStore(tempDir, 'device-alpha');
        expect(() => storeReloaded.load(), throwsFormatException);
      },
    );

    test('tracks received filenames across reloads', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();

      await store.markReceived('devB_1_abc123.json');
      await store.markReceived('devC_1_def456.json');

      expect(store.received.contains('devB_1_abc123.json'), isTrue);
      expect(store.received.contains('devC_1_def456.json'), isTrue);

      final storeReloaded = MergeStore(tempDir, 'device-alpha');
      await storeReloaded.load();

      expect(storeReloaded.received.contains('devB_1_abc123.json'), isTrue);
      expect(storeReloaded.received.contains('devC_1_def456.json'), isTrue);
    });

    test('prevents opening endpoint directory with mismatched actor', () async {
      final store1 = MergeStore(tempDir, 'device-alpha');
      await store1.load();
      await store1.capture({
        syncRecordKey('folder', ['f1']): {'name': 'F1'},
      });

      final store2 = MergeStore(tempDir, 'device-beta');
      expect(() => store2.load(), throwsStateError);
    });

    test(
      'resolve journals the choice without claiming unapplied business state',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Local'},
        });

        // Simulate receiving conflicting remote document
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('device-beta', {}, {
          key: {'name': 'Remote'},
        });
        store.document.merge(remoteDoc);

        expect(store.document.conflicts.length, 1);
        final conflict = store.document.conflicts.first;
        final candRemote = conflict.candidates.firstWhere(
          (c) => c.actor == 'device-beta',
        );

        await store.resolveAll([
          MergeConflictResolution(
            recordKey: key,
            field: 'name',
            candidateId: candRemote.id,
          ),
        ]);
        final manualResolutionId = store.manualCandidateId(key, 'name');
        expect(manualResolutionId, 'device-alpha:2');

        expect(store.document.conflicts, isEmpty);
        expect(store.observed[key]?['name'], 'Local');
        expect(store.pendingApply![key]?['name'], 'Remote');
        expect(store.outbox.length, 1);
        expect(store.pendingRecordCount, 1);

        final storeReloaded = MergeStore(tempDir, 'device-alpha');
        await storeReloaded.load();
        expect(storeReloaded.document.conflicts, isEmpty);
        expect(storeReloaded.observed[key]?['name'], 'Local');
        expect(
          storeReloaded.manualCandidateId(key, 'name'),
          manualResolutionId,
        );
        expect(storeReloaded.outbox.length, 1);
        expect(storeReloaded.pendingApply![key]?['name'], 'Remote');
        expect(
          () => storeReloaded.capture({
            key: {'name': 'Local'},
          }),
          throwsStateError,
        );
        await storeReloaded.completeApply(storeReloaded.pendingApply!);
        expect(storeReloaded.observed[key]?['name'], 'Remote');
        final completed = MergeStore(tempDir, 'device-alpha');
        await completed.load();
        expect(completed.pendingApply, isNull);
        expect(completed.observed[key]?['name'], 'Remote');
      },
    );

    test(
      'resolves independent conflicts in one recoverable durable batch',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['mixed-choice']);
        await store.capture({
          key: {'name': 'Local', 'order': 1},
        });
        final remote = MergeDocument()
          ..captureLocal('device-beta', {}, {
            key: {'name': 'Remote', 'order': 2},
          });
        store.document.merge(remote);
        await store.markReceived('device-beta_1.json');

        final conflicts = {
          for (final conflict in store.document.conflicts)
            conflict.field: conflict,
        };
        expect(conflicts.keys, containsAll(['name', 'order']));
        final nameConflict = conflicts['name']!;
        final orderConflict = conflicts['order']!;
        final localName = nameConflict.candidates.firstWhere(
          (candidate) => candidate.actor == 'device-alpha',
        );
        final remoteOrder = orderConflict.candidates.firstWhere(
          (candidate) => candidate.actor == 'device-beta',
        );

        MergeConflictResolution select(
          MergeConflict conflict,
          MergeCandidate candidate,
        ) => MergeConflictResolution(
          recordKey: conflict.recordKey,
          field: conflict.field,
          candidateId: candidate.id,
          expectedCandidateIds: Set.unmodifiable(
            conflict.candidates.map((item) => item.id),
          ),
          expectedCandidateFingerprint: conflict.candidateFingerprint,
        );

        await store.resolveAll([
          select(nameConflict, localName),
          select(orderConflict, remoteOrder),
        ]);

        expect(store.document.conflicts, isEmpty);
        expect(store.pendingApply![key], {'name': 'Local', 'order': 2});
        expect(store.outbox, hasLength(1));
        expect(
          store.outbox.last.counter,
          store.document.counterFor('device-alpha'),
        );

        final recovered = MergeStore(tempDir, 'device-alpha');
        await recovered.load();
        expect(recovered.document.conflicts, isEmpty);
        expect(recovered.outbox.map((batch) => batch.id), [
          for (final batch in store.outbox) batch.id,
        ]);
        expect(recovered.pendingApply![key], {'name': 'Local', 'order': 2});
      },
    );

    test(
      'rejects a stale later selection without persisting earlier resolutions',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['stale-choice']);
        await store.capture({
          key: {'name': 'Local', 'order': 1},
        });
        final remote = MergeDocument()
          ..captureLocal('device-beta', {}, {
            key: {'name': 'Remote', 'order': 2},
          });
        store.document.merge(remote);
        final displayed = {
          for (final conflict in store.document.conflicts)
            conflict.field: conflict,
        };
        final nameConflict = displayed['name']!;
        final orderConflict = displayed['order']!;
        final firstChoice = nameConflict.candidates.firstWhere(
          (candidate) => candidate.actor == 'device-beta',
        );
        final staleChoice = orderConflict.candidates.firstWhere(
          (candidate) => candidate.actor == 'device-beta',
        );

        final laterRemote = MergeDocument()
          ..captureLocal('device-gamma', {}, {
            key: {'order': 3},
          });
        store.document.merge(laterRemote);
        await store.markReceived('device-gamma_1.json');
        final currentOrder = store.document.conflicts.singleWhere(
          (conflict) => conflict.field == 'order',
        );
        expect(
          currentOrder.candidates.map((candidate) => candidate.id),
          contains(staleChoice.id),
        );
        expect(currentOrder.candidates, hasLength(3));
        final before = canonicalSyncJson(store.document.toJson());
        final outboxIds = store.outbox.map((batch) => batch.id).toList();

        await expectLater(
          () => store.resolveAll([
            MergeConflictResolution(
              recordKey: nameConflict.recordKey,
              field: nameConflict.field,
              candidateId: firstChoice.id,
              expectedCandidateIds: {
                for (final candidate in nameConflict.candidates) candidate.id,
              },
            ),
            MergeConflictResolution(
              recordKey: orderConflict.recordKey,
              field: orderConflict.field,
              candidateId: staleChoice.id,
              expectedCandidateIds: {
                for (final candidate in orderConflict.candidates) candidate.id,
              },
            ),
          ]),
          throwsStateError,
        );

        expect(canonicalSyncJson(store.document.toJson()), before);
        expect(store.outbox.map((batch) => batch.id), outboxIds);
        expect(store.pendingApply, isNull);
        final recovered = MergeStore(tempDir, 'device-alpha');
        await recovered.load();
        expect(recovered.document.conflicts, hasLength(2));
        expect(recovered.pendingApply, isNull);
        expect(recovered.outbox.map((batch) => batch.id), outboxIds);
      },
    );

    test(
      'rejects a changed accumulated duration even when candidate IDs survive',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['duration-choice', 0]);
        await store.capture({
          key: {'readDurationMs': 20000},
        });
        final initial = store.document.materialize();
        final remote = store.document.clone();
        await store.capture({
          key: {'readDurationMs': 0},
        });
        final displayed = store.document.conflicts.singleWhere(
          (conflict) => conflict.field == 'readDurationMs',
        );
        final selected = displayed.candidates.singleWhere(
          (candidate) => candidate.id == 'accumulated_total',
        );
        final fingerprint = displayed.candidateFingerprint;
        final candidateIds = displayed.candidates
            .map((item) => item.id)
            .toSet();

        remote.captureLocal('device-beta', initial, {
          key: {'readDurationMs': 25000},
        });
        store.document.merge(remote);
        await store.save();
        final current = store.document.conflicts.singleWhere(
          (conflict) => conflict.field == 'readDurationMs',
        );
        expect(current.candidates.map((item) => item.id).toSet(), candidateIds);
        expect(
          current.candidates
              .singleWhere((item) => item.id == selected.id)
              .value,
          25000,
        );
        final before = canonicalSyncJson(store.document.toJson());
        await expectLater(
          store.resolveAll([
            MergeConflictResolution(
              recordKey: key,
              field: displayed.field,
              candidateId: selected.id,
              expectedCandidateIds: candidateIds,
              expectedCandidateFingerprint: fingerprint,
            ),
          ]),
          throwsStateError,
        );
        expect(canonicalSyncJson(store.document.toJson()), before);
        expect(store.pendingApply, isNull);

        await store.resolveAll([
          MergeConflictResolution(
            recordKey: key,
            field: current.field,
            candidateId: selected.id,
            expectedCandidateIds: candidateIds,
            expectedCandidateFingerprint: current.candidateFingerprint,
          ),
        ]);
        expect(store.pendingApply![key]?['readDurationMs'], 25000);
      },
    );

    test(
      'capture with observation branch prevents accidental deletion of unapplied remote records',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final key1 = syncRecordKey('folder', ['f1']);
        await store.capture({
          key1: {'name': 'Folder 1'},
        });

        // Keep observation clone before remote merge
        final preMergeObservation = store.document.clone();

        // Remote doc arrives with new folder f2
        final key2 = syncRecordKey('folder', ['f2']);
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('device-beta', {}, {
          key2: {'name': 'Folder 2 Remote'},
        });
        store.document.merge(remoteDoc);

        // Local DB has not applied f2 yet, so local DB edits f1 only
        final updatedLocalRecords = {
          key1: {'name': 'Folder 1 Edited'},
        };

        // User capture with preMergeObservation branch
        await store.capture(
          updatedLocalRecords,
          observation: preMergeObservation,
        );

        // store.document must contain BOTH the edited f1 AND the remote f2 (f2 is NOT deleted!)
        final mat = store.document.materialize();
        expect(mat[key1]?['name'], 'Folder 1 Edited');
        expect(mat[key2]?['name'], 'Folder 2 Remote');
        expect(store.observed[key1]?['name'], 'Folder 1 Edited');
      },
    );

    test(
      'acknowledging an older batch retains newer durable publications',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'First'},
        });
        final oldId = store.outbox.single.id;
        await store.capture({
          key: {'name': 'Second'},
        });
        final newestId = store.outbox.last.id;
        await store.acknowledge(oldId);
        await store.acknowledge(oldId);
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.outbox.single.id, newestId);
        expect(reopened.observed[key]?['name'], 'Second');
      },
    );
    test(
      'pending record count persists and follows folded snapshots',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final firstKey = syncRecordKey('folder', ['count-first']);
        final secondKey = syncRecordKey('folder', ['count-second']);
        await store.capture({
          firstKey: {'name': 'First'},
        });
        expect(store.pendingRecordCount, 1);
        final firstId = store.pendingBatchIds.single;

        await store.capture({
          firstKey: {'name': 'Updated'},
          secondKey: {'name': 'Second'},
        });
        expect(store.pendingRecordCount, 2);
        final currentId = store.pendingBatchIds.single;

        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.pendingRecordCount, 2);
        await reopened.acknowledge(firstId);
        expect(reopened.pendingRecordCount, 2);
        await reopened.acknowledge(currentId);
        expect(reopened.pendingRecordCount, 0);
      },
    );

    test(
      'acknowledging an old snapshot retains a later same-record change',
      () async {
        await File(
          '${tempDir.path}/state.json',
        ).writeAsString(jsonEncode(_legacyStateWithIncomparableOutbox()));
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['fixture']);
        expect(store.pendingRecordCount, 1);
        final oldId = store.pendingBatchIds.single;

        await store.capture({
          key: {'name': 'Updated after import'},
        });
        expect(store.pendingBatchIds, hasLength(2));
        expect(store.pendingRecordCount, 1);
        final laterId = store.pendingBatchIds.last;
        await store.acknowledge(oldId);
        expect(store.pendingRecordCount, 1);

        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.pendingRecordCount, 1);
        await reopened.acknowledge(laterId);
        expect(reopened.pendingRecordCount, 0);
      },
    );

    test(
      'completed apply cannot replay after later edits or backup recovery',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Old'},
        });
        final target = {
          key: {'name': 'Applied'},
        };
        await store.stageApply(target);
        expect(store.observed[key]?['name'], 'Old');
        await store.completeApply(target);
        await store.capture({
          key: {'name': 'Later user edit'},
        });
        await File('${tempDir.path}/merge_store.sqlite3').writeAsString('{}');
        final recovered = MergeStore(tempDir, 'device-alpha');
        await recovered.load();
        expect(recovered.recoveredFromBackup, isTrue);
        expect(recovered.pendingApply, isNull);
        expect(recovered.observed[key]?['name'], 'Later user edit');
      },
    );

    test(
      'guard-aborted apply durably cancels without changing business baseline',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Local'},
        });
        await store.stageApply({
          key: {'name': 'Remote'},
        });
        await store.completeApply(store.observed);
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.pendingApply, isNull);
        expect(reopened.observed[key]?['name'], 'Local');
      },
    );

    test(
      'restored counters require reconciliation and stay floored on no-op capture',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        final records = {
          key: {'name': 'Same'},
        };
        await store.capture(records);
        await File('${tempDir.path}/merge_store.sqlite3').delete();
        final recovered = MergeStore(tempDir, 'device-alpha');
        await recovered.load();
        await expectLater(recovered.capture(records), throwsStateError);
        await expectLater(recovered.enqueueCheckpoint(), throwsStateError);
        recovered.reconcileActorCounter('device-alpha', 12);
        recovered.reconcileActorCounter('device-alpha', 2);
        await recovered.capture(records);
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.document.counterFor('device-alpha'), 12);
        await reopened.capture({
          key: {'name': 'New'},
        });
        expect(reopened.outbox.last.counter, 13);
      },
    );

    test(
      'empty cloud reconciliation is explicit and cannot floor another actor',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        await store.capture({});
        await File('${tempDir.path}/merge_store.sqlite3').delete();
        final recovered = MergeStore(tempDir, 'device-alpha');
        await recovered.load();
        expect(
          () => recovered.reconcileActorCounter('device-beta', 4),
          throwsArgumentError,
        );
        recovered.reconcileActorCounter('device-alpha', 0);
        await recovered.capture({});
        expect(recovered.observed, isEmpty);
      },
    );

    test(
      'first empty capture survives restart so new readings add independently',
      () async {
        final secondDir = await Directory.systemTemp.createTemp(
          'merge-store-peer-',
        );
        try {
          final first = MergeStore(tempDir, 'device-alpha');
          final second = MergeStore(secondDir, 'device-beta');
          await first.load();
          await second.load();
          await first.capture({});
          await second.capture({});
          final reopened = MergeStore(tempDir, 'device-alpha');
          await reopened.load();
          final key = syncRecordKey('history', ['comic', 1]);
          await reopened.capture({
            key: {'readDurationMs': 10},
          });
          await second.capture({
            key: {'readDurationMs': 20},
          });
          reopened.document.merge(second.document);
          expect(reopened.document.materialize()[key]?['readDurationMs'], 30);
        } finally {
          await secondDir.delete(recursive: true);
        }
      },
    );

    test(
      'original profiles seed the same baseline instead of double counting',
      () async {
        final secondDir = await Directory.systemTemp.createTemp(
          'merge-store-peer-',
        );
        try {
          final first = MergeStore(tempDir, 'device-alpha');
          final second = MergeStore(secondDir, 'device-beta');
          await first.load();
          await second.load();
          final key = syncRecordKey('history', ['comic', 1]);
          final original = {
            key: {'readDurationMs': 100},
          };
          await first.capture(original);
          await second.capture(original);
          first.document.merge(second.document);
          expect(first.document.materialize()[key]?['readDurationMs'], 100);
        } finally {
          await secondDir.delete(recursive: true);
        }
      },
    );

    test(
      'observation floor does not retire an unseen same-actor field',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Original'},
        });
        final observation = store.document.clone();
        final newer = observation.clone();
        newer.captureLocal('device-alpha', store.observed, {
          key: {'name': 'Original', 'remoteField': 1},
        });
        store.document.merge(newer);
        await store.capture({
          key: {'name': 'Original', 'localField': 2},
        }, observation: observation);
        expect(store.document.materialize()[key], {
          'name': 'Original',
          'remoteField': 1,
          'localField': 2,
        });
        expect(observation.counterFor('device-alpha'), 3);
        expect(
          observation.materialize()[key]?.containsKey('remoteField'),
          isFalse,
        );
        expect(store.outbox.last.counter, 3);
        await store.capture({
          key: {'name': 'Original', 'localField': 3},
        }, observation: observation);
        expect(store.document.materialize()[key]?['remoteField'], 1);
        expect(store.document.materialize()[key]?['localField'], 3);
        expect(store.document.conflicts, isEmpty);
      },
    );

    test(
      'failed staging commit fails closed and cannot report durable apply',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Original'},
        });
        final blocker = sqlite3.open('${tempDir.path}/merge_store.sqlite3');
        blocker.execute('BEGIN EXCLUSIVE;');
        try {
          await expectLater(
            store.stageApply({
              key: {'name': 'Not committed'},
            }),
            throwsA(isA<Exception>()),
          );
          await expectLater(store.capture({}), throwsStateError);
        } finally {
          blocker.execute('ROLLBACK;');
          blocker.close();
        }
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.pendingApply, isNull);
        expect(reopened.observed[key]?['name'], 'Original');
      },
    );

    test(
      'rotation crash recovers backup with pending apply and unchanged observed',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Original'},
        });
        await store.stageApply({
          key: {'name': 'Target'},
        });
        final state = File('${tempDir.path}/merge_store.sqlite3');
        await state.copy('${state.path}.bak.tmp');
        await File('${state.path}.bak').delete();
        await File('${state.path}.bak.tmp').rename('${state.path}.bak');
        await state.writeAsString('INTERRUPTED_PRIMARY');
        final recovered = MergeStore(tempDir, 'device-alpha');
        await recovered.load();
        expect(recovered.recoveredFromBackup, isTrue);
        expect(recovered.pendingApply![key]?['name'], 'Target');
        expect(recovered.observed[key]?['name'], 'Original');
      },
    );

    test(
      'branch capture keeps newer own duration prefixes without observing fields',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['comic', 1]);
        await store.capture({
          key: {'readDurationMs': 100},
        });
        final observation = store.document.clone();
        final newer = observation.clone();
        newer.captureLocal('device-alpha', store.observed, {
          key: {'readDurationMs': 110, 'unseenField': 'Remote'},
        });
        store.document.merge(newer);
        await store.capture({
          key: {'readDurationMs': 120},
        }, observation: observation);
        final result = store.document.materialize();
        expect(result[key]?['readDurationMs'], 130);
        expect(result[key]?['unseenField'], 'Remote');
      },
    );

    for (final artifact in [
      'state.json',
      'state.json.bak',
      'state.json.bak.tmp',
    ]) {
      test(
        'invalid isolated $artifact evidence never fresh-initializes',
        () async {
          await File('${tempDir.path}/$artifact').writeAsString('[]');
          await expectLater(
            MergeStore(tempDir, 'device-alpha').load(),
            throwsFormatException,
          );
          expect(await File('${tempDir.path}/$artifact').readAsString(), '[]');
        },
      );
    }

    test(
      'a journal path that cannot be deleted stops startup rather than replaying',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'First'},
        });
        await store.stageApply({
          key: {'name': 'Applied'},
        });
        await store.completeApply(store.pendingApply!);
        await store.capture({
          key: {'name': 'Latest'},
        });
        final persisted = MergeStore(tempDir, 'device-alpha');
        await persisted.load();
        expect(persisted.pendingApply, isNull);
        expect(persisted.observed[key]?['name'], 'Latest');
        await Directory('${tempDir.path}/apply_journal.json').create();
        await expectLater(
          MergeStore(tempDir, 'device-alpha').load(),
          throwsFormatException,
        );
      },
    );

    for (final physicalName in ['Original', 'New user edit']) {
      test(
        'pending recovery preserves $physicalName as concurrent physical state',
        () async {
          final store = MergeStore(tempDir, 'device-alpha');
          await store.load();
          final key = syncRecordKey('folder', ['f1']);
          await store.capture({
            key: {'name': 'Original'},
          });
          final incoming = store.document.clone();
          incoming.captureLocal('device-beta', store.observed, {
            key: {'name': 'Remote target'},
          });
          store.document.merge(incoming);
          await store.stageApply({
            key: {'name': 'Remote target'},
          });
          final reopened = MergeStore(tempDir, 'device-alpha');
          await reopened.load();
          final target = await reopened.recoverPendingApply({
            key: {'name': physicalName},
          });
          expect(target[key]?['name'], physicalName);
          expect(reopened.observed[key]?['name'], physicalName);
          final values = reopened.document.conflicts
              .firstWhere((conflict) => conflict.field == 'name')
              .candidates
              .map((candidate) => candidate.value)
              .toSet();
          expect(values, {physicalName, 'Remote target'});
          final interruptedAgain = MergeStore(tempDir, 'device-alpha');
          await interruptedAgain.load();
          expect(interruptedAgain.pendingApply![key]?['name'], physicalName);
          expect(interruptedAgain.outbox.last.id, reopened.outbox.last.id);
          await interruptedAgain.completeApply(target);
        },
      );
    }

    test(
      'pending duration recovery preserves a lower actual total without readding prefixes',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('history', ['comic', 1]);
        await store.capture({
          key: {'readDurationMs': 100},
        });
        await store.capture({
          key: {'readDurationMs': 110},
        });
        final incoming = store.document.clone();
        incoming.captureLocal('device-beta', store.observed, {
          key: {'readDurationMs': 120},
        });
        store.document.merge(incoming);
        await store.stageApply({
          key: {'readDurationMs': 120},
        });
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        final target = await reopened.recoverPendingApply({
          key: {'readDurationMs': 115},
        });
        expect(target[key]?['readDurationMs'], 115);
        expect(
          reopened.document.conflicts.any(
            (conflict) => conflict.field == 'readDurationMs',
          ),
          isTrue,
        );
      },
    );

    test(
      'policy-projected capture persists baseline without deleting retained records',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('setting', ['optionalSetting']);
        await store.capture({
          key: {'value': 'Retained'},
        });
        final counter = store.document.counterFor('device-alpha');
        await store.capture({}, previous: {});
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.observed, isEmpty);
        expect(reopened.document.materialize()[key]?['value'], 'Retained');
        expect(reopened.document.counterFor('device-alpha'), counter);
      },
    );

    test(
      'policy-projected interrupted recovery does not create forbidden tombstones',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('setting', ['optionalSetting']);
        await store.capture({
          key: {'value': 'Retained'},
        });
        await store.stageApply({
          key: {'value': 'Retained'},
        });
        final counter = store.document.counterFor('device-alpha');
        await store.recoverPendingApply({}, previous: {});
        expect(store.document.counterFor('device-alpha'), counter);
        expect(store.document.materialize()[key]?['value'], 'Retained');
        expect(store.document.conflicts, isEmpty);
        await store.stageApply({});
        await store.completeApply({});
      },
    );

    test(
      'explicit cancellation persists without advancing observed baseline',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Actual'},
        });
        await store.stageApply({
          key: {'name': 'Not applied'},
        });
        await store.cancelApply();
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.pendingApply, isNull);
        expect(reopened.observed[key]?['name'], 'Actual');
      },
    );

    test(
      'restart capture cannot retire received but unapplied field metadata',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Original'},
        });
        final incoming = store.document.clone();
        incoming.captureLocal('device-beta', store.observed, {
          key: {'name': 'Unapplied remote'},
        });
        store.document.merge(incoming);
        await store.markReceived('remote-metadata-before-business-apply.json');
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(
          reopened.localObservation.materialize()[key]?['name'],
          'Original',
        );
        await reopened.capture({
          key: {'name': 'New local edit'},
        });
        final values = reopened.document.conflicts
            .firstWhere((conflict) => conflict.field == 'name')
            .candidates
            .map((candidate) => candidate.value)
            .toSet();
        expect(values, {'New local edit', 'Unapplied remote'});
        final reloadedAgain = MergeStore(tempDir, 'device-alpha');
        await reloadedAgain.load();
        expect(
          reloadedAgain.localObservation.materialize()[key]?['name'],
          'New local edit',
        );
      },
    );

    test(
      'successful apply advances local observation and later edits retire seen values',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Original'},
        });
        final incoming = store.document.clone();
        incoming.captureLocal('device-beta', store.observed, {
          key: {'name': 'Applied remote'},
        });
        store.document.merge(incoming);
        final target = {
          key: {'name': 'Applied remote'},
        };
        await store.stageApply(target);
        await store.completeApply(target, observation: store.document);
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        await reopened.capture({
          key: {'name': 'Later edit'},
        });
        expect(reopened.document.conflicts, isEmpty);
        expect(reopened.document.materialize()[key]?['name'], 'Later edit');
      },
    );

    test(
      'policy-visible observation retains allowed tombstones and excludes unapplied records',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final folder = syncRecordKey('folder', ['f1']);
        final forbidden = syncRecordKey('setting', ['optionalSetting']);
        await store.capture({
          folder: {'name': 'Original'},
        });
        final incoming = store.document.clone();
        incoming.captureLocal('device-beta', store.observed, {
          forbidden: {'value': 'Not applied'},
        });
        store.document.merge(incoming);
        final allowedObservation = store.document.filterRecords(
          (key) => key != forbidden,
        );
        await store.stageApply(store.document.materialize());
        await store.completeApply({}, observation: allowedObservation);
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.localObservation.toJson(), allowedObservation.toJson());
        expect(reopened.localObservation.materialize(), isEmpty);
        expect(reopened.localObservation.dominates(store.document), isFalse);
        await reopened.capture({
          forbidden: {'value': 'New local opt-in value'},
        });
        final values = reopened.document.conflicts
            .firstWhere((conflict) => conflict.recordKey == forbidden)
            .candidates
            .map((candidate) => candidate.value)
            .toSet();
        expect(values, {'Not applied', 'New local opt-in value'});
        expect(reopened.document.materialize().containsKey(folder), isFalse);
      },
    );

    test(
      'cancelled apply does not advance durable local observation to unseen values',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Original'},
        });
        final incoming = store.document.clone();
        incoming.captureLocal('device-beta', store.observed, {
          key: {'name': 'Never applied'},
        });
        store.document.merge(incoming);
        await store.stageApply({
          key: {'name': 'Never applied'},
        });
        await store.cancelApply();
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(
          reopened.localObservation.materialize()[key]?['name'],
          'Original',
        );
        await reopened.capture({
          key: {'name': 'Local change'},
        });
        expect(
          reopened.document.conflicts.any(
            (conflict) => conflict.field == 'name',
          ),
          isTrue,
        );
      },
    );

    test(
      'variant capture is idempotent and preserves all variants across re-open',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final sourceKey = syncRecordKey('source', ['jm']);
        final variantA = {'filename': 'jm.js', 'content': 'script A content'};
        final variantB = {
          'filename': 'sync_123.js',
          'content': 'script B content',
        };

        final records = {
          sourceKey: {'script': variantA},
        };
        final sourceVariants = {
          sourceKey: [variantA, variantB],
        };

        await store.capture(records, sourceVariants: sourceVariants);

        // Both variants observed in cell fingerprints
        expect(
          store.document.hasObservedFieldValue(sourceKey, 'script', variantA),
          isTrue,
        );
        expect(
          store.document.hasObservedFieldValue(sourceKey, 'script', variantB),
          isTrue,
        );
        expect(
          store.document.conflicts.any((c) => c.field == 'script'),
          isTrue,
        );

        final outboxCount = store.outbox.length;
        final outboxBatchId = store.outbox.first.id;

        // Re-capture identical state is strictly idempotent
        await store.capture(records, sourceVariants: sourceVariants);
        expect(store.outbox.length, outboxCount);
        expect(store.pendingRecordCount, 1);
        expect(store.outbox.first.id, outboxBatchId);

        // Re-open store from disk and verify durability
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();

        expect(
          reopened.document.hasObservedFieldValue(
            sourceKey,
            'script',
            variantA,
          ),
          isTrue,
        );
        expect(
          reopened.document.hasObservedFieldValue(
            sourceKey,
            'script',
            variantB,
          ),
          isTrue,
        );
        expect(
          reopened.document.conflicts.any((c) => c.field == 'script'),
          isTrue,
        );
      },
    );

    test(
      'explicit resolution persists and replay does not resurrect resolved seed',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final sourceKey = syncRecordKey('source', ['jm']);
        final variantA = {'filename': 'jm.js', 'content': 'script A content'};
        final variantB = {
          'filename': 'sync_123.js',
          'content': 'script B content',
        };

        // Capture local variantA normally without any sourceVariants seed
        await store.capture({
          sourceKey: {'script': variantA},
        });

        // Merge foreign remote peer variantB normally without any sourceVariants seed
        final peerDoc = MergeDocument();
        peerDoc.captureLocal('device-beta', {}, {
          sourceKey: {'script': variantB},
        });
        store.document.merge(peerDoc);

        final conflict = store.document.conflicts.firstWhere(
          (c) => c.field == 'script',
        );
        final candidateA = conflict.candidates.firstWhere(
          (c) => (c.value as Map)['content'] == 'script A content',
        );

        // Resolve in favor of variantA
        await store.resolveAll([
          MergeConflictResolution(
            recordKey: sourceKey,
            field: 'script',
            candidateId: candidateA.id,
          ),
        ]);
        expect(store.pendingApply, isNotNull);
        await store.completeApply(store.pendingApply!);

        // Conflict is resolved
        expect(
          store.document.conflicts.any((c) => c.field == 'script'),
          isFalse,
        );

        // Re-open store
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(
          reopened.document.conflicts.any((c) => c.field == 'script'),
          isFalse,
        );

        // Replaying the old variant seeds on re-opened store does NOT resurrect seed B
        await reopened.capture(
          {
            sourceKey: {'script': variantA},
          },
          sourceVariants: {
            sourceKey: [variantA, variantB],
          },
        );
        expect(
          reopened.document.conflicts.any((c) => c.field == 'script'),
          isFalse,
        );

        // Both values remain permanently observed in cell fingerprints (active and retired)
        expect(
          reopened.document.hasObservedFieldValue(
            sourceKey,
            'script',
            variantA,
          ),
          isTrue,
        );
        expect(
          reopened.document.hasObservedFieldValue(
            sourceKey,
            'script',
            variantB,
          ),
          isTrue,
        );
      },
    );

    test(
      'unchanged primary records create outbox checkpoint when new variants are discovered',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final sourceKey = syncRecordKey('source', ['jm']);
        final variantA = {'filename': 'jm.js', 'content': 'script A content'};
        final variantB = {
          'filename': 'sync_123.js',
          'content': 'script B content',
        };

        // Initial capture establishes baseline with variantA only
        await store.capture({
          sourceKey: {'script': variantA},
        });

        expect(store.outbox.length, 1);
        final initialBatch = store.outbox.first;
        expect(
          store.document.hasObservedFieldValue(sourceKey, 'script', variantB),
          isFalse,
        );

        // Acknowledge initial batch to clear outbox
        await store.acknowledge(initialBatch.id);
        expect(store.outbox, isEmpty);

        // Capture with identical primary records (records equal observed), but new variantB in sourceVariants
        await store.capture(
          {
            sourceKey: {'script': variantA},
          },
          sourceVariants: {
            sourceKey: [variantA, variantB],
          },
        );

        // Outbox checkpoint must be created covering the new variant even though flat records did not change
        expect(store.outbox.length, 1);
        final variantBatch = store.outbox.first;
        expect(variantBatch.counter, greaterThan(initialBatch.counter));
        expect(
          store.document.hasObservedFieldValue(sourceKey, 'script', variantB),
          isTrue,
        );

        // Re-open verifies the checkpoint and variant are durable on disk
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.outbox.length, 1);
        expect(
          reopened.document.hasObservedFieldValue(
            sourceKey,
            'script',
            variantB,
          ),
          isTrue,
        );
      },
    );

    final invalidStates = <String, void Function(Map<String, dynamic>)>{
      'missing schema': (state) => state.remove('schemaVersion'),
      'invalid schema type': (state) => state['schemaVersion'] = 1.0,
      'unknown state member': (state) => state['unexpected'] = true,
      'missing actor': (state) => state.remove('actor'),
      'empty actor': (state) => state['actor'] = '',
      'invalid actor type': (state) => state['actor'] = 1,
      'missing observed': (state) => state.remove('observed'),
      'invalid observed type': (state) => state['observed'] = [],
      'missing pendingApply': (state) => state.remove('pendingApply'),
      'missing initialized': (state) => state.remove('initialized'),
      'invalid initialized': (state) => state['initialized'] = 1,
      'false initialized with baseline': (state) =>
          state['initialized'] = false,
      'invalid document': (state) => state['document'] = {},
      'missing local observation': (state) => state.remove('localObservation'),
      'invalid local observation': (state) => state['localObservation'] = {},
      'invalid records': (state) => state['observed'] = {
        syncRecordKey('folder', ['f1']): [],
      },
      'invalid identity': (state) => state['observed'] = {'not-a-key': {}},
      'invalid journal target': (state) => state['pendingApply'] = [],
      'invalid received': (state) => state['received'] = [1],
      'duplicate received': (state) => state['received'] = ['same', 'same'],
      'invalid outbox item': (state) => state['outbox'] = [null],
      'missing batch id': (state) =>
          (state['outbox'] as List).first.remove('id'),
      'wrong batch digest': (state) =>
          (state['outbox'] as List).first['id'] = 'bad',
      'wrong batch actor': (state) =>
          (state['outbox'] as List).first['actor'] = 'other',
      'invalid batch counter': (state) =>
          (state['outbox'] as List).first['counter'] = 1.5,
      'invalid batch document': (state) =>
          (state['outbox'] as List).first['document'] = {},
      'missing pendingUnavailableDomains': (state) =>
          state.remove('pendingUnavailableDomains'),
      'invalid pendingUnavailableDomains type': (state) =>
          state['pendingUnavailableDomains'] = {},
      'invalid pendingUnavailableDomains item': (state) =>
          state['pendingUnavailableDomains'] = [123],
      'unsupported pendingUnavailableDomains item': (state) =>
          state['pendingUnavailableDomains'] = ['cookies'],
      'empty pendingUnavailableDomains item': (state) =>
          state['pendingUnavailableDomains'] = [''],
      'duplicate pendingUnavailableDomains item': (state) =>
          state['pendingUnavailableDomains'] = ['source', 'source'],
      'pendingUnavailableDomains with null pendingApply': (state) =>
          state['pendingUnavailableDomains'] = ['source'],
      'unsupported schema version': (state) => state['schemaVersion'] = 99,
    };
    for (final entry in invalidStates.entries) {
      test('rejects ${entry.key} in both persisted replicas', () async {
        final primary = File('${tempDir.path}/state.json');
        final state =
            jsonDecode(jsonEncode(_legacySchema2State()))
                as Map<String, dynamic>;
        entry.value(state);
        final corrupt = jsonEncode(state);
        await primary.writeAsString(corrupt);
        await File('${primary.path}.bak').writeAsString(corrupt);
        await expectLater(
          MergeStore(tempDir, 'device-alpha').load(),
          throwsFormatException,
        );
        expect(await primary.readAsString(), corrupt);
      });
    }

    for (final journal in ['', '[]', '{\"records\":[]}', '{\"timestamp\":1}']) {
      test(
        'never skips unsupported or corrupt separate journal $journal',
        () async {
          final store = MergeStore(tempDir, 'device-alpha');
          await store.load();
          await File(
            '${tempDir.path}/apply_journal.json',
          ).writeAsString(journal);
          await expectLater(
            MergeStore(tempDir, 'device-alpha').load(),
            throwsFormatException,
          );
        },
      );
    }

    test(
      'temporary-only corruption is not mistaken for fresh initialization',
      () async {
        await File('${tempDir.path}/state.json.tmp').writeAsString('{}');
        await expectLater(
          MergeStore(tempDir, 'device-alpha').load(),
          throwsFormatException,
        );
        expect(await File('${tempDir.path}/state.json').exists(), isFalse);
      },
    );

    test(
      'explicit lossless migration from existing schemaVersion1 state file',
      () async {
        final doc = MergeDocument();
        final folderKey = syncRecordKey('folder', ['f1']);
        doc.captureLocal('device-alpha', {}, {
          folderKey: {'name': 'Legacy Folder'},
        });
        final batch = MergeBatch.create(
          actor: 'device-alpha',
          counter: 1,
          document: doc.clone(),
        );
        final schema1State = {
          'schemaVersion': 1,
          'actor': 'device-alpha',
          'document': doc.toJson(),
          'localObservation': doc.toJson(),
          'observed': {
            folderKey: {'name': 'Legacy Folder'},
          },
          'received': <String>[],
          'outbox': [batch.toJson()],
          'pendingApply': null,
          'initialized': true,
        };
        final jsonStr = jsonEncode(schema1State);
        await File('${tempDir.path}/state.json').writeAsString(jsonStr);
        await File('${tempDir.path}/state.json.bak').writeAsString(jsonStr);

        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        expect(store.observed.containsKey(folderKey), isTrue);
        expect(store.pendingUnavailableDomains, isEmpty);
        expect(store.pendingBatchIds, [batch.id]);
        expect(store.pendingBatch(batch.id).id, batch.id);

        // Migration is one-shot: legacy backups remain untouched, and all
        // durable records plus the snapshot reference survive process restart.
        await store.save();
        expect(
          await File('${tempDir.path}/state.json').readAsString(),
          jsonStr,
        );
        expect(
          await File('${tempDir.path}/state.json.bak').readAsString(),
          jsonStr,
        );
        expect(
          await File('${tempDir.path}/merge_store.sqlite3').exists(),
          isTrue,
        );
        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.observed[folderKey]?['name'], 'Legacy Folder');
        expect(reopened.pendingBatchIds, [batch.id]);
        expect(reopened.pendingBatch(batch.id).id, batch.id);
      },
    );
    test(
      'schema 2 migration preserves received and interrupted apply state',
      () async {
        const actor = 'device-alpha';
        final state = _legacySchema2State();
        final key = syncRecordKey('folder', ['fixture']);
        state['pendingApply'] = {
          key: {'name': 'Critical'},
        };
        state['pendingUnavailableDomains'] = ['source'];
        state['received'] = ['legacy-checkpoint.json'];
        final encoded = jsonEncode(state);
        final primary = File('${tempDir.path}/state.json');
        await primary.writeAsString(encoded);
        await File('${primary.path}.bak').writeAsString(encoded);
        final expectedBatch = MergeBatch.fromJson(
          (state['outbox'] as List).single as Map<String, Object?>,
        );

        await overrideIO(() async {
          final store = MergeStore(tempDir, actor);
          await store.load();
          expect(store.document.toJson(), state['document']);
          expect(store.localObservation.toJson(), state['localObservation']);
          expect(store.observed, {
            key: {'name': 'Critical'},
          });
          expect(store.pendingBatchIds, [expectedBatch.id]);
          expect(
            store.pendingBatch(expectedBatch.id).toJson(),
            expectedBatch.toJson(),
          );
          expect(store.pendingApply, {
            key: {'name': 'Critical'},
          });
          expect(store.pendingUnavailableDomains, {'source'});
          expect(store.received, {'legacy-checkpoint.json'});

          final migrated = _databaseSummary(
            File('${tempDir.path}/merge_store.sqlite3'),
            actor,
          );
          expect(
            migrated,
            _databaseSummary(
              File('${tempDir.path}/merge_store.sqlite3.bak'),
              actor,
            ),
          );
          expect(migrated.revision, 1);
          expect(migrated.ownCounter, 1);
          expect(migrated.outboxCount, 1);
          expect(migrated.observedCount, 1);

          final reopened = MergeStore(tempDir, actor);
          await reopened.load();
          expect(reopened.document.toJson(), state['document']);
          expect(reopened.localObservation.toJson(), state['localObservation']);
          expect(reopened.observed, {
            key: {'name': 'Critical'},
          });
          expect(reopened.pendingBatchIds, [expectedBatch.id]);
          expect(
            reopened.pendingBatch(expectedBatch.id).toJson(),
            expectedBatch.toJson(),
          );
          expect(reopened.pendingApply, {
            key: {'name': 'Critical'},
          });
          expect(reopened.pendingUnavailableDomains, {'source'});
          expect(reopened.received, {'legacy-checkpoint.json'});
          expect(
            _databaseSummary(
              File('${tempDir.path}/merge_store.sqlite3'),
              actor,
            ),
            migrated,
          );
        });
      },
    );

    for (final artifact in ['state.json.bak', 'state.json.tmp']) {
      test('migrates pending causal state from $artifact', () async {
        final state = _legacySchema2State();
        final key = syncRecordKey('folder', ['fixture']);
        state['pendingApply'] = {
          key: {'name': 'Critical'},
        };
        state['pendingUnavailableDomains'] = ['source'];
        state['received'] = ['legacy-checkpoint.json'];
        final encoded = jsonEncode(state);
        await File('${tempDir.path}/$artifact').writeAsString(encoded);

        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        expect(store.recoveredFromBackup, isTrue);
        expect(store.document.toJson(), state['document']);
        expect(store.pendingApply, {
          key: {'name': 'Critical'},
        });
        expect(store.pendingUnavailableDomains, {'source'});
        expect(store.received, {'legacy-checkpoint.json'});
        final batchId = store.pendingBatchIds.single;
        expect(store.pendingBatch(batchId).actor, 'device-alpha');

        final reopened = MergeStore(tempDir, 'device-alpha');
        await reopened.load();
        expect(reopened.document.toJson(), state['document']);
        expect(reopened.pendingBatchIds, [batchId]);
        expect(reopened.pendingBatch(batchId).id, batchId);
        expect(reopened.pendingApply, {
          key: {'name': 'Critical'},
        });
        expect(reopened.pendingUnavailableDomains, {'source'});
        expect(reopened.received, {'legacy-checkpoint.json'});
      });
    }

    test('old SQLite metadata preserves causal and pending state', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();
      final retiredKey = syncRecordKey('folder', ['retired']);
      final observedKey = syncRecordKey('folder', ['observed']);
      await store.capture({
        retiredKey: {'name': 'Retained as a tombstone'},
        observedKey: {'name': 'Observed business state'},
      });
      await store.capture({
        observedKey: {'name': 'Observed business state'},
      });
      await store.markReceived('remote-1.json');

      final pendingKey = syncRecordKey('folder', ['pending']);
      final pendingApply = {
        pendingKey: {'name': 'Pending remote apply'},
      };
      await store.stageApply(pendingApply, unavailableDomains: {'source'});
      final batchId = store.pendingBatchIds.single;
      final document = store.document.toJson();
      final localObservation = store.localObservation.toJson();
      final batch = store.pendingBatch(batchId).toJson();

      for (final path in [
        '${tempDir.path}/merge_store.sqlite3',
        '${tempDir.path}/merge_store.sqlite3.bak',
      ]) {
        final database = sqlite3.open(path);
        try {
          // Older databases had this metadata but no state fingerprint.
          database.execute(
            "DELETE FROM merge_store_meta WHERE key = 'commitFingerprint';",
          );
          database.execute('''
            INSERT OR REPLACE INTO merge_store_meta(key, value)
            VALUES ('checkpointMigrationComplete', '1');
          ''');
          database.execute('''
            CREATE TABLE merge_checkpoint_inventory (
              path TEXT PRIMARY KEY NOT NULL,
              digest TEXT NOT NULL
            );
          ''');
          database.execute(
            'INSERT INTO merge_checkpoint_inventory(path, digest) VALUES (?, ?);',
            ['legacy.json', 'obsolete-digest'],
          );
        } finally {
          database.close();
        }
      }

      void expectPreserved(MergeStore value) {
        final documentState = value.document.toJson();
        expect(documentState, document);
        expect(value.localObservation.toJson(), localObservation);
        expect(value.document.counterFor('device-alpha'), 2);
        expect(value.document.materialize().containsKey(retiredKey), isFalse);
        expect(value.observed, {
          observedKey: {'name': 'Observed business state'},
        });
        expect(value.received, {'remote-1.json'});
        expect(value.pendingApply, pendingApply);
        expect(value.pendingUnavailableDomains, {'source'});
        expect(value.pendingBatchIds, [batchId]);
        expect(value.pendingBatch(batchId).toJson(), batch);
      }

      final reopened = MergeStore(tempDir, 'device-alpha');
      await reopened.load();
      expectPreserved(reopened);
      await reopened.save();
      expectPreserved(reopened);

      final reloaded = MergeStore(tempDir, 'device-alpha');
      await reloaded.load();
      expectPreserved(reloaded);
    });

    test(
      'scoped capture with unavailableDomains prevents false tombstones and preserves baseline',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final sourceKey = syncRecordKey('source', ['komiic']);
        final favoriteKey = syncRecordKey('folder', ['fav1']);
        final initialRecords = {
          sourceKey: {
            'script': {'filename': 'komiic.js', 'content': 'console.log(1)'},
          },
          favoriteKey: {'name': 'Favorites'},
        };

        await store.capture(initialRecords);
        expect(store.observed.containsKey(sourceKey), isTrue);
        expect(store.observed.containsKey(favoriteKey), isTrue);

        // Next capture: source file became temporarily unreadable (empty/corrupted),
        // so physical reading only saw favoriteKey with an updated name.
        // We mark 'source' in unavailableDomains.
        final readingWithoutSource = {
          favoriteKey: {'name': 'Updated Favorites'},
        };
        await store.capture(
          readingWithoutSource,
          unavailableDomains: {'source'},
        );

        // Source baseline must be preserved; favorite must be updated
        expect(store.observed.containsKey(sourceKey), isTrue);
        expect(store.observed[favoriteKey]?['name'], 'Updated Favorites');

        // Document must NOT have emitted a tombstone for source
        expect(
          store.document.hasObservedFieldValue(sourceKey, 'script', {
            'filename': 'komiic.js',
            'content': 'console.log(1)',
          }),
          isTrue,
        );
      },
    );

    test(
      'completeApply with unavailableDomains does not adopt unapplied foreign source causality',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final sourceKey = syncRecordKey('source', ['remote_plugin']);
        final histKey = syncRecordKey('history', ['comic_1']);
        final localFav = syncRecordKey('folder', ['local_f']);

        await store.capture({
          localFav: {'name': 'Local'},
        });

        final remoteDoc = MergeDocument();
        // A remote device published a new comic source and history record
        // The blocked source was written at a later actor counter than history.
        // Filtering only the record without its per-domain clock would wrongly
        // acknowledge the source event as locally observed.
        remoteDoc.captureLocal('device-beta', {}, {
          histKey: {'readDurationMs': 1000},
        });
        remoteDoc.captureLocal(
          'device-beta',
          {
            histKey: {'readDurationMs': 1000},
          },
          {
            histKey: {'readDurationMs': 1000},
            sourceKey: {
              'script': {'filename': 'remote.js', 'content': 'valid'},
            },
          },
        );
        store.document.merge(remoteDoc);

        final desired = store.document.materialize(preferred: store.observed);
        await store.stageApply(desired, unavailableDomains: {'source'});

        // Local system could only apply history (sources were unavailable/blocked)
        final appliedSubset = {
          localFav: {'name': 'Local'},
          histKey: {'readDurationMs': 1000},
        };

        await store.completeApply(
          appliedSubset,
          observation: store.document,
          unavailableDomains: {'source'},
        );

        expect(store.localObservation.counterFor('device-beta'), 1);
        expect(store.observed.containsKey(histKey), isTrue);
        expect(store.observed.containsKey(sourceKey), isFalse);

        // Local observation must NOT adopt the foreign causality for source
        // So if local device captures again without sourceKey, it will NOT allocate a tombstone!
        final outboxBefore = store.outbox.length;
        await store.capture({
          localFav: {'name': 'Local'},
          histKey: {'readDurationMs': 1000},
        });
        // No deletion allocated
        expect(store.outbox.length, outboxBefore);
        expect(store.document.counterFor('device-beta'), 2);

        final restarted = MergeStore(tempDir, 'device-alpha');
        await restarted.load();
        expect(restarted.observed.containsKey(sourceKey), isFalse);
        expect(restarted.localObservation.counterFor('device-beta'), 1);
        expect(restarted.document.counterFor('device-beta'), 2);
      },
    );

    test(
      'stageApply unions pending unavailable domains across restaging and persists them',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final staged = {
          syncRecordKey('folder', ['f1']): {'name': 'Staged'},
        };
        await store.stageApply(staged, unavailableDomains: {'source'});
        await store.stageApply(staged, unavailableDomains: {'sourceSession'});
        expect(store.pendingApply, isNotNull);
        expect(store.pendingUnavailableDomains, {'source', 'sourceSession'});

        // Simulate restart
        final restarted = MergeStore(tempDir, 'device-alpha');
        await restarted.load();
        expect(restarted.pendingApply, isNotNull);
        expect(restarted.pendingUnavailableDomains, {
          'source',
          'sourceSession',
        });

        await restarted.cancelApply();
        expect(restarted.pendingApply, isNull);
        expect(restarted.pendingUnavailableDomains, isEmpty);
      },
    );

    test('resolveAll rejects conflicts in unavailable domains', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();

      final sourceKey = syncRecordKey('source', ['plugin']);
      await store.capture({
        sourceKey: {
          'script': {'filename': 'plugin.js', 'content': 'local source'},
        },
      });
      final remoteDoc = MergeDocument()
        ..captureLocal('device-beta', {}, {
          sourceKey: {
            'script': {'filename': 'plugin.js', 'content': 'remote source'},
          },
        });
      store.document.merge(remoteDoc);
      final conflict = store.document.conflicts.single;
      final candidate = conflict.candidates.first;

      await expectLater(
        () => store.resolveAll(
          [
            MergeConflictResolution(
              recordKey: sourceKey,
              field: 'script',
              candidateId: candidate.id,
            ),
          ],
          unavailableDomains: {'source'},
        ),
        throwsStateError,
      );
      expect(store.document.conflicts, hasLength(1));
      expect(store.outbox, hasLength(1));
      expect(store.pendingApply, isNull);
    });

    test(
      'resolve persists passed unavailableDomains so subsequent apply retains source exclusions',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final folderKey = syncRecordKey('folder', ['f1']);
        await store.capture({
          folderKey: {'name': 'Original'},
        });

        // Remote device modifies folder
        final remoteDoc = MergeDocument();
        remoteDoc.captureLocal('device-beta', {}, {
          folderKey: {'name': 'Remote'},
        });
        store.document.merge(remoteDoc);

        final conflict = store.document.conflicts.first;
        final candId = conflict.candidates.first.id;

        // Resolving conflict while 'source' is unavailable
        await store.resolveAll(
          [
            MergeConflictResolution(
              recordKey: folderKey,
              field: 'name',
              candidateId: candId,
            ),
          ],
          unavailableDomains: {'source'},
        );

        expect(store.pendingApply, isNotNull);
        expect(store.pendingUnavailableDomains, {'source'});

        // Verify across reload
        final reloaded = MergeStore(tempDir, 'device-alpha');
        await reloaded.load();
        expect(reloaded.pendingUnavailableDomains, {'source'});
      },
    );

    test(
      'completeApply and recoverPendingApply union caller exclusions with persisted scope',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final folderKey = syncRecordKey('folder', ['f1']);
        final sessionKey = syncRecordKey('sourceSession', ['s1']);
        final sourceKey = syncRecordKey('source', ['src1']);

        await store.capture({
          folderKey: {'name': 'F1'},
          sessionKey: {'cookie': 'c1'},
          sourceKey: {
            'script': {'filename': 'src1.js', 'content': 'valid'},
          },
        });

        // Stage apply with {'source'}
        final staged = {
          folderKey: {'name': 'F1_updated'},
        };
        await store.stageApply(staged, unavailableDomains: {'source'});
        expect(store.pendingUnavailableDomains, {'source'});

        // Replay/complete with caller providing {'sourceSession'}
        // Union ensures BOTH 'source' and 'sourceSession' remain blocked
        await store.completeApply(
          staged,
          unavailableDomains: {'sourceSession'},
        );

        // Both source and session baselines were preserved
        expect(store.observed.containsKey(sourceKey), isTrue);
        expect(store.observed.containsKey(sessionKey), isTrue);
        expect(store.observed[folderKey]?['name'], 'F1_updated');
      },
    );
  });
}
