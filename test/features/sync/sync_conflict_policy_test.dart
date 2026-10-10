import 'package:flutter_test/flutter_test.dart';

import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/features/sync/merge_engine.dart';
import 'package:venera_plus/features/sync/sync_conflict_policy.dart';

void main() {
  group('automaticConflictResolutions', () {
    test(
      'first sync uses cloud server time instead of cross-actor counters',
      () {
        final key = syncRecordKey('setting', ['themeMode']);
        final local = MergeDocument()
          ..captureLocal('device', {}, {
            key: {'value': 'bootstrap'},
          }, bootstrap: true);
        final oldCloud = MergeDocument()
          ..setCounterFloor('cloud-old', 800)
          ..captureLocal('cloud-old', {}, {
            key: {'value': 'old cloud'},
          });
        final recentCloud = MergeDocument()
          ..captureLocal('cloud-recent', {}, {
            key: {'value': 'recent cloud'},
          });
        final document = local.clone()
          ..merge(oldCloud)
          ..merge(recentCloud);
        final conflict = document.conflicts.singleWhere(
          (item) => item.recordKey == key && item.field == 'value',
        );
        final recentId = conflict.candidates
            .singleWhere((candidate) => candidate.actor == 'cloud-recent')
            .id;

        final choices = automaticConflictResolutions(
          document: document,
          localActor: 'device',
          localRecords: local.materialize(),
          firstSync: true,
          initialSyncCounter: local.counterFor('device'),
          manualCandidateId: (_, _) => null,
          cloudActorModifiedAt: {
            'cloud-old': DateTime.utc(2026, 1, 1),
            'cloud-recent': DateTime.utc(2026, 2, 1),
          },
        );

        expect(choices, hasLength(1));
        expect(choices.single.candidateId, recentId);
        expect(choices.single.expectedCandidateIds, {
          for (final candidate in conflict.candidates) candidate.id,
        });
        expect(
          choices.single.expectedCandidateFingerprint,
          conflict.candidateFingerprint,
        );
      },
    );

    test(
      'unverified legacy progress remains pending while unrelated settings merge',
      () {
        final historyKey = syncRecordKey('history', ['legacy-progress', 7]);
        final settingKey = syncRecordKey('setting', ['readerMode']);
        final baseline = <String, Map<String, Object?>>{
          historyKey: {
            'progress': {'ep': 1, 'page': 1, 'group': null, 'time': 1000},
            'readDurationMs': 0,
          },
          settingKey: {'value': 'gallery'},
        };
        final seed = MergeDocument()..captureLocal('seed', {}, baseline);
        final localRecords = cloneSyncRecords(baseline);
        localRecords[historyKey]!['progress'] = {
          'ep': 1,
          'page': 1,
          'group': null,
          'time': 2000,
        };
        localRecords[settingKey]!['value'] = 'local-mode';
        final local = seed.clone();
        final localDot =
            'device:${local.captureLocal('device', baseline, localRecords)}';
        final cloudRecords = cloneSyncRecords(baseline);
        cloudRecords[historyKey]!['progress'] = {
          'ep': 3,
          'page': 20,
          'group': null,
          'time': 3000,
        };
        cloudRecords[settingKey]!['value'] = 'cloud-mode';
        final cloud = seed.clone()
          ..captureLocal('cloud', baseline, cloudRecords);
        final document = local.clone()..merge(cloud);
        String? legacyMarker(String key, String field) =>
            key == historyKey && field == 'progress' ? localDot : null;
        final choices = automaticConflictResolutions(
          document: document,
          localActor: 'device',
          localRecords: localRecords,
          firstSync: false,
          manualCandidateId: legacyMarker,
          unverifiedManualCandidateId: legacyMarker,
          cloudActorModifiedAt: {'cloud': DateTime.utc(2026, 10, 10)},
        );
        for (final choice in choices) {
          document.resolve(
            'device',
            choice.recordKey,
            choice.field,
            choice.candidateId,
          );
        }
        final merged = document.materialize(preferred: localRecords);
        expect(merged[settingKey]!['value'], 'cloud-mode');
        expect(
          merged[historyKey]!['progress'],
          localRecords[historyKey]!['progress'],
        );
        expect(document.conflicts.single.recordKey, historyKey);
        expect(document.conflicts.single.field, 'progress');
      },
    );

    test('manual edits win for protected settings, sessions, and deletion', () {
      final secretKey = syncRecordKey('setting', ['account', 'token']);
      final sessionKey = syncRecordKey('cookies', ['example.test']);
      final deletedKey = syncRecordKey('favorite', ['folder', 'comic', 0]);
      final initial = <String, Map<String, Object?>>{
        secretKey: {'value': 'initial-secret'},
        sessionKey: {
          'cookies': [
            {'name': 'session', 'value': 'initial-session'},
          ],
        },
        deletedKey: {'title': 'initial'},
      };
      final common = MergeDocument()..captureLocal('seed', {}, initial);
      final local = common.clone();
      final cloud = common.clone();
      final localBefore = local.materialize();
      final localAfter = cloneSyncRecords(localBefore)
        ..[secretKey]!['value'] = 'local-secret'
        ..[sessionKey]!['cookies'] = [
          {'name': 'session', 'value': 'local-session'},
        ]
        ..remove(deletedKey);
      local.captureLocal('device', localBefore, localAfter);
      final localDot = MergeDot('device', local.counterFor('device')).toKey();

      final cloudBefore = cloud.materialize();
      final cloudAfter = cloneSyncRecords(cloudBefore)
        ..[secretKey]!['value'] = 'cloud-secret'
        ..[sessionKey]!['cookies'] = [
          {'name': 'session', 'value': 'cloud-session'},
        ]
        ..[deletedKey]!['title'] = 'cloud edit';
      cloud.captureLocal('cloud', cloudBefore, cloudAfter);
      final document = local.clone()..merge(cloud);
      final manualIds = {
        '$secretKey\u0000value': localDot,
        '$sessionKey\u0000cookies': localDot,
        '$deletedKey\u0000presence': localDot,
      };

      final choices = automaticConflictResolutions(
        document: document,
        localActor: 'device',
        localRecords: localAfter,
        firstSync: false,
        manualCandidateId: (key, field) => manualIds['$key\u0000$field'],
        cloudActorModifiedAt: {'cloud': DateTime.utc(2026, 5, 1)},
      );

      expect(choices, hasLength(3));
      expect(
        choices
            .map((choice) => '${choice.recordKey}\u0000${choice.field}')
            .toSet(),
        {
          '$secretKey\u0000value',
          '$sessionKey\u0000cookies',
          '$deletedKey\u0000presence',
        },
      );
      expect(choices.every((choice) => choice.candidateId == localDot), isTrue);
      expect(document.activeCandidateIds, contains(localDot));
      for (final choice in choices) {
        final resolved = document.clone()
          ..resolve(
            'resolver',
            choice.recordKey,
            choice.field,
            choice.candidateId,
          );
        if (choice.recordKey == deletedKey) {
          expect(resolved.materialize().containsKey(deletedKey), isFalse);
        } else {
          expect(
            resolved.materialize()[choice.recordKey],
            localAfter[choice.recordKey],
          );
        }
      }
      final staleRecords = cloneSyncRecords(localAfter)
        ..[secretKey]!['value'] = 'stale local value';
      final staleChoices = automaticConflictResolutions(
        document: document,
        localActor: 'device',
        localRecords: staleRecords,
        firstSync: false,
        manualCandidateId: (key, field) =>
            key == secretKey && field == 'value' ? localDot : null,
        cloudActorModifiedAt: {'cloud': DateTime.utc(2026, 5, 1)},
      );
      final cloudSecretId = document.conflicts
          .singleWhere(
            (conflict) =>
                conflict.recordKey == secretKey && conflict.field == 'value',
          )
          .candidates
          .singleWhere((candidate) => candidate.actor == 'cloud')
          .id;
      expect(
        staleChoices
            .singleWhere((choice) => choice.recordKey == secretKey)
            .candidateId,
        cloudSecretId,
      );
    });

    test('cleared manual local values adopt the cloud candidate', () {
      final key = syncRecordKey('setting', ['homepage']);
      for (final emptyValue in [
        null,
        '',
        '   ',
        <Object?>[],
        <String, Object?>{},
      ]) {
        final localRecords = {
          key: <String, Object?>{'value': emptyValue},
        };
        final document = MergeDocument()
          ..captureLocal('device', {}, localRecords);
        document.merge(
          MergeDocument()..captureLocal('cloud', {}, {
            key: {'value': 'cloud candidate'},
          }),
        );
        final choices = automaticConflictResolutions(
          document: document,
          localActor: 'device',
          localRecords: localRecords,
          firstSync: false,
          manualCandidateId: (_, _) => 'device:1',
          cloudActorModifiedAt: {'cloud': DateTime.utc(2026, 3, 1)},
        );
        for (final choice in choices) {
          document.resolve(
            'device',
            choice.recordKey,
            choice.field,
            choice.candidateId,
          );
        }
        expect(document.materialize()[key], {'value': 'cloud candidate'});
        expect(document.conflicts, isEmpty);
      }
    });

    test('a new edit during first-sync waiting beats cloud candidates', () {
      final key = syncRecordKey('favorite', ['folder', 'comic', 0]);
      final local = MergeDocument()
        ..captureLocal('device', {}, {
          key: {'title': 'before sync'},
        }, bootstrap: true);
      final initialSyncCounter = local.counterFor('device');
      final beforeEdit = local.materialize();
      final afterEdit = cloneSyncRecords(beforeEdit)
        ..[key]!['title'] = 'edited while waiting';
      local.captureLocal('device', beforeEdit, afterEdit);
      final localDot = MergeDot('device', local.counterFor('device')).toKey();
      final cloud = MergeDocument()
        ..captureLocal('cloud', {}, {
          key: {'title': 'cloud title'},
        });
      final document = local.clone()..merge(cloud);

      final choices = automaticConflictResolutions(
        document: document,
        localActor: 'device',
        localRecords: afterEdit,
        firstSync: true,
        initialSyncCounter: initialSyncCounter,
        manualCandidateId: (recordKey, field) =>
            recordKey == key && field == 'title' ? localDot : null,
        cloudActorModifiedAt: {'cloud': DateTime.utc(2030, 1, 1)},
      );

      expect(choices, hasLength(1));
      expect(choices.single.candidateId, localDot);

      final cloudId = document.conflicts
          .singleWhere((conflict) => conflict.recordKey == key)
          .candidates
          .singleWhere((candidate) => candidate.actor == 'cloud')
          .id;
      final beforeNetworkChoices = automaticConflictResolutions(
        document: document,
        localActor: 'device',
        localRecords: afterEdit,
        firstSync: true,
        initialSyncCounter: local.counterFor('device'),
        manualCandidateId: (recordKey, field) =>
            recordKey == key && field == 'title' ? localDot : null,
        cloudActorModifiedAt: {'cloud': DateTime.utc(2030, 1, 1)},
      );
      expect(beforeNetworkChoices.single.candidateId, cloudId);
    });

    test('blocked domains and unobserved records are left unresolved', () {
      final key = syncRecordKey('sourceSession', ['source']);
      final local = MergeDocument()
        ..captureLocal('device', {}, {
          key: {'session': 'local'},
        });
      final cloud = MergeDocument()
        ..captureLocal('cloud', {}, {
          key: {'session': 'cloud'},
        });
      final document = local.clone()..merge(cloud);

      List<MergeConflictResolution> choose({
        Set<String> unavailableDomains = const {},
        bool Function(String)? shouldObserveRecord,
      }) => automaticConflictResolutions(
        document: document,
        localActor: 'device',
        localRecords: local.materialize(),
        firstSync: false,
        manualCandidateId: (_, _) => null,
        cloudActorModifiedAt: {'cloud': DateTime.utc(2026, 1, 1)},
        unavailableDomains: unavailableDomains,
        shouldObserveRecord: shouldObserveRecord,
      );

      expect(choose(unavailableDomains: {'sourceSession'}), isEmpty);
      expect(choose(shouldObserveRecord: (_) => false), isEmpty);
      expect(
        choose(shouldObserveRecord: (recordKey) => recordKey == key),
        hasLength(1),
      );
    });

    test('stable actor/id fallback ignores cross-actor counters', () {
      final key = syncRecordKey('setting', ['locale']);
      final highCounter = MergeDocument()
        ..setCounterFloor('cloud-a', 700)
        ..captureLocal('cloud-a', {}, {
          key: {'value': 'counter winner'},
        });
      final stableWinner = MergeDocument()
        ..captureLocal('cloud-z', {}, {
          key: {'value': 'stable winner'},
        });
      final document = highCounter.clone()..merge(stableWinner);

      final choices = automaticConflictResolutions(
        document: document,
        localActor: 'device',
        localRecords: {
          key: {'value': 'local'},
        },
        firstSync: true,
        manualCandidateId: (_, _) => null,
        cloudActorModifiedAt: const {},
      );

      expect(choices, hasLength(1));
      expect(
        document.conflicts.single.candidates
            .singleWhere((candidate) => candidate.actor == 'cloud-z')
            .id,
        choices.single.candidateId,
      );
    });

    test('keeps conflicts with no cloud or matching manual candidate', () {
      final key = syncRecordKey('history', ['comic', 0]);
      final document = MergeDocument()
        ..captureLocal('device', {}, {
          key: {'readDurationMs': 1000},
        }, bootstrap: true);
      final beforeReset = document.materialize();
      final afterReset = <String, Map<String, Object?>>{
        key: {'readDurationMs': 0},
      };
      document.captureLocal('device', beforeReset, afterReset);
      expect(
        document.conflicts.any(
          (conflict) => conflict.field == 'readDurationMs',
        ),
        isTrue,
      );

      final choices = automaticConflictResolutions(
        document: document,
        localActor: 'device',
        localRecords: afterReset,
        firstSync: false,
        manualCandidateId: (_, _) => null,
        cloudActorModifiedAt: const {},
      );

      expect(choices, isEmpty);
    });

    test(
      'duration contribution manual edit selects aggregate, not engine as cloud',
      () {
        final key = syncRecordKey('history', ['comic', 0]);
        final baseA = MergeDocument()
          ..captureLocal('seed-a', {}, {
            key: {'readDurationMs': 10000},
          }, bootstrap: true);
        final baseB = MergeDocument()
          ..captureLocal('seed-b', {}, {
            key: {'readDurationMs': 10000},
          }, bootstrap: true);
        final common = baseA.clone()..merge(baseB);
        final local = common.clone();
        final cloud = common.clone();
        local.captureLocal('device', local.materialize(), {
          key: {'readDurationMs': 0},
        });
        cloud.captureLocal('cloud', cloud.materialize(), {
          key: {'readDurationMs': 11000},
        });
        final document = local.clone()..merge(cloud);
        final actualBeforeIncrement = <String, Map<String, Object?>>{
          key: {'readDurationMs': 11000},
        };
        final actualAfterIncrement = <String, Map<String, Object?>>{
          key: {'readDurationMs': 12000},
        };
        document.captureLocal(
          'device',
          actualBeforeIncrement,
          actualAfterIncrement,
        );
        final contributionDot = MergeDot(
          'device',
          document.counterFor('device'),
        ).toKey();
        final durationConflict = document.conflicts.singleWhere(
          (item) => item.recordKey == key && item.field == 'readDurationMs',
        );
        expect(
          durationConflict.candidates.any(
            (candidate) => candidate.id == 'accumulated_total',
          ),
          isTrue,
        );

        final manualChoices = automaticConflictResolutions(
          document: document,
          localActor: 'device',
          localRecords: actualAfterIncrement,
          firstSync: false,
          manualCandidateId: (_, _) => contributionDot,
          cloudActorModifiedAt: {
            'seed-a': DateTime.utc(2026, 1, 1),
            'seed-b': DateTime.utc(2026, 2, 1),
            'engine': DateTime.utc(2099, 1, 1),
          },
        );
        expect(manualChoices, hasLength(1));
        expect(manualChoices.single.candidateId, 'accumulated_total');
        expect(document.activeCandidateIds, contains(contributionDot));

        final resolved = document.clone()
          ..resolve(
            'resolver',
            key,
            'readDurationMs',
            manualChoices.single.candidateId,
          );
        expect(resolved.conflicts, isEmpty);
        expect(resolved.materialize()[key]?['readDurationMs'], 12000);

        final cloudChoices = automaticConflictResolutions(
          document: document,
          localActor: 'device',
          localRecords: actualAfterIncrement,
          firstSync: true,
          initialSyncCounter: document.counterFor('device'),
          manualCandidateId: (_, _) => null,
          cloudActorModifiedAt: {
            'seed-a': DateTime.utc(2026, 1, 1),
            'seed-b': DateTime.utc(2026, 2, 1),
            'engine': DateTime.utc(2099, 1, 1),
          },
        );
        expect(cloudChoices, hasLength(1));
        expect(cloudChoices.single.candidateId, isNot('accumulated_total'));
      },
    );
  });
}
