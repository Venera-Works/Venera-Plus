import 'package:flutter_test/flutter_test.dart';

import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/features/sync/merge_engine.dart';
import 'package:venera_plus/features/sync/sync_conflict_policy.dart';
import 'package:venera_plus/features/history/reading_progress.dart';

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
      'reading progress ignores local proof and cloud time while settings resolve',
      () {
        final historyKey = syncRecordKey('history', ['progress-policy', 7]);
        final settingKey = syncRecordKey('setting', ['readerMode']);
        final catalogA = ReadingCatalog([
          const ReadingChapter(id: 'chapter-a', ep: 1),
          const ReadingChapter(id: 'chapter-b', ep: 1),
        ]);
        final catalogB = ReadingCatalog([
          const ReadingChapter(id: 'chapter-b', ep: 1),
          const ReadingChapter(id: 'chapter-a', ep: 1),
        ]);
        final baseline = <String, Map<String, Object?>>{
          historyKey: {'readDurationMs': 0},
          settingKey: {'value': 'gallery'},
        };
        final seed = MergeDocument()..captureLocal('seed', {}, baseline);
        final localRecords = cloneSyncRecords(baseline);
        localRecords[historyKey]!['readingProgress'] = ReadingProgress.seed(
          const ReadingPosition(ep: 1, page: 12, chapterId: 'chapter-a'),
          catalog: catalogA,
        ).toJson();
        localRecords[settingKey]!['value'] = 'local-mode';
        final local = seed.clone();
        final localDot =
            'device:${local.captureLocal('device', baseline, localRecords)}';
        final cloudRecords = cloneSyncRecords(baseline);
        cloudRecords[historyKey]!['readingProgress'] = ReadingProgress.seed(
          const ReadingPosition(ep: 1, page: 4, chapterId: 'chapter-b'),
          catalog: catalogB,
        ).toJson();
        cloudRecords[settingKey]!['value'] = 'cloud-mode';
        final cloud = seed.clone()
          ..captureLocal('cloud', baseline, cloudRecords);
        final document = local.clone()..merge(cloud);
        String? localProof(String key, String field) =>
            key == historyKey && field == 'readingProgress' ? localDot : null;
        final choices = automaticConflictResolutions(
          document: document,
          localActor: 'device',
          localRecords: localRecords,
          firstSync: false,
          manualCandidateId: localProof,
          unverifiedManualCandidateId: localProof,
          cloudActorModifiedAt: {'cloud': DateTime.utc(2026, 10, 10)},
        );
        expect(choices.map((choice) => choice.field), ['value']);
        document.resolve(
          'device',
          choices.single.recordKey,
          choices.single.field,
          choices.single.candidateId,
        );

        final merged = document.materialize(preferred: localRecords);
        final progress = ReadingProgress.fromJson(
          merged[historyKey]!['readingProgress'],
        );
        expect(progress.hasOrderConflict, isTrue);
        expect(merged[historyKey]!.containsKey('progress'), isFalse);
        expect(merged[settingKey]!['value'], 'cloud-mode');
        expect(document.conflicts.single.recordKey, historyKey);
        expect(document.conflicts.single.field, 'readingProgress');
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
    test(
      'history delete-and-continue leaves presence manual while resolving ordinary fields',
      () {
        final deletedKey = syncRecordKey('history', ['delete-read', 0]);
        final ordinaryKey = syncRecordKey('history', ['ordinary-edit', 0]);
        final progress = ReadingProgress.seed(
          const ReadingPosition(ep: 1, page: 1),
        );
        final baseRecords = <String, Map<String, Object?>>{
          deletedKey: {
            'title': 'Original',
            'readingProgress': progress.toJson(),
          },
          ordinaryKey: {'title': 'Original'},
        };
        final base = MergeDocument()..captureLocal('seed', {}, baseRecords);
        final previous = base.materialize();

        final local = base.clone();
        final localRecords = cloneSyncRecords(previous)
          ..[deletedKey]!['title'] = 'Local edit'
          ..[deletedKey]!['readingProgress'] = progress
              .record(
                const ReadingPosition(ep: 1, page: 2),
                source: ReadingNavigationSource.userForward,
              )
              .toJson()
          ..[ordinaryKey]!['title'] = 'Local edit';
        local.captureLocal('device', previous, localRecords);
        final localDot = MergeDot('device', local.counterFor('device')).toKey();

        final deletion = base.clone();
        deletion.captureLocal('delete-device', previous, {
          ordinaryKey: previous[ordinaryKey]!,
        });
        final cloud = base.clone();
        final cloudRecords = cloneSyncRecords(previous)
          ..[deletedKey]!['title'] = 'Cloud edit'
          ..[ordinaryKey]!['title'] = 'Cloud edit';
        cloud.captureLocal('cloud-device', previous, cloudRecords);
        final document = local.clone()
          ..merge(deletion)
          ..merge(cloud);

        final deletedFields = document.conflicts
            .where((conflict) => conflict.recordKey == deletedKey)
            .map((conflict) => conflict.field)
            .toSet();
        expect(deletedFields, containsAll({'presence', 'title'}));

        final choices = automaticConflictResolutions(
          document: document,
          localActor: 'device',
          localRecords: localRecords,
          firstSync: false,
          manualCandidateId: (_, _) => localDot,
          cloudActorModifiedAt: {'cloud-device': DateTime.utc(2030)},
        );
        final deletedChoices = choices
            .where((choice) => choice.recordKey == deletedKey)
            .toList();
        expect(deletedChoices.map((choice) => choice.field), ['title']);
        expect(
          choices.any(
            (choice) =>
                choice.recordKey == ordinaryKey && choice.field == 'title',
          ),
          isTrue,
        );
        for (final choice in choices) {
          document.resolve(
            'device',
            choice.recordKey,
            choice.field,
            choice.candidateId,
          );
        }
        final remainingFields = document.conflicts
            .where((conflict) => conflict.recordKey == deletedKey)
            .map((conflict) => conflict.field)
            .toSet();
        expect(remainingFields, {'presence'});
        expect(document.materialize()[deletedKey]!['title'], isNot('Original'));
        final filtered = document.filterRecords(
          (recordKey) => recordKey == deletedKey,
        );
        final reopened = MergeDocument.fromJson(
          Map<String, Object?>.from(filtered.toJson()),
        );
        expect(
          reopened.conflicts.any(
            (conflict) =>
                conflict.recordKey == deletedKey &&
                conflict.field == 'presence',
          ),
          isTrue,
        );
      },
    );

    test(
      'ordinary resolutions cannot revive a causally deleted history record',
      () {
        final key = syncRecordKey('history', ['causal-delete-title']);
        final base = MergeDocument()
          ..captureLocal('seed', {}, {
            key: {'title': 'Original'},
          });
        final previous = base.materialize();
        final left = base.clone();
        final leftRecords = cloneSyncRecords(previous)
          ..[key]!['title'] = 'Left';
        left.captureLocal('left-device', previous, leftRecords);
        final right = base.clone();
        final rightRecords = cloneSyncRecords(previous)
          ..[key]!['title'] = 'Right';
        right.captureLocal('right-device', previous, rightRecords);
        left.merge(right);
        final beforeDelete = left.materialize();
        left.captureLocal('delete-device', beforeDelete, {});
        expect(left.materialize(), isEmpty);

        expect(
          automaticConflictResolutions(
            document: left,
            localActor: 'delete-device',
            localRecords: beforeDelete,
            firstSync: false,
            manualCandidateId: (_, _) => null,
            cloudActorModifiedAt: const {},
          ),
          isEmpty,
        );
        expect(left.materialize(), isEmpty);
        final reopened = MergeDocument.fromJson(
          Map<String, Object?>.from(left.toJson()),
        );
        expect(reopened.materialize(), isEmpty);
      },
    );

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
