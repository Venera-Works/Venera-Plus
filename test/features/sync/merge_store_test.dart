import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/features/sync/merge_store.dart';

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

        // Re-capture identical state causes no new batch
        await store.capture(initialRecords);
        expect(store.outbox.length, 1);

        // Re-load store from directory
        final storeReloaded = MergeStore(tempDir, 'device-alpha');
        await storeReloaded.load();

        expect(storeReloaded.outbox.length, 1);
        expect(storeReloaded.outbox.first.id, batch.id);
        expect(storeReloaded.observed[recordKey]?['name'], 'Favorites');
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
        expect(store.outbox.length, 2);

        expect(batch2.dominates(batch1), isTrue);
        expect(batch2.coversActor('device-alpha', 1), isTrue);
      },
    );

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
      'recovers from state.json.bak if primary state.json is corrupted',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Important Data'},
        });

        // State is saved with backup. Let's corrupt state.json with truncated garbage
        final stateFile = File('${tempDir.path}/state.json');
        await stateFile.writeAsString(
          '{"actor": "device-alpha", "document": {BROKEN_JSON',
        );

        // Reload store: must recover from state.json.bak!
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

    test(
      'fails loudly and never silently resets to empty if state and backup are corrupt',
      () async {
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();

        final key = syncRecordKey('folder', ['f1']);
        await store.capture({
          key: {'name': 'Critical Data'},
        });

        // Corrupt both primary and backup
        final stateFile = File('${tempDir.path}/state.json');
        final bakFile = File('${tempDir.path}/state.json.bak');
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

        await store.resolve(key, 'name', candRemote.id);

        expect(store.document.conflicts, isEmpty);
        expect(store.observed[key]?['name'], 'Local');
        expect(store.pendingApply![key]?['name'], 'Remote');
        expect(
          store.outbox.length,
          2,
        ); // 1 from initial capture + 1 from resolve

        final storeReloaded = MergeStore(tempDir, 'device-alpha');
        await storeReloaded.load();
        expect(storeReloaded.document.conflicts, isEmpty);
        expect(storeReloaded.observed[key]?['name'], 'Local');
        expect(storeReloaded.outbox.length, 2);
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
        await File('${tempDir.path}/state.json').writeAsString('{}');
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
        await File('${tempDir.path}/state.json').delete();
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
        await File('${tempDir.path}/state.json').delete();
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
        final blocker = Directory('${tempDir.path}/state.json.tmp');
        await blocker.create();
        await expectLater(
          store.stageApply({
            key: {'name': 'Not committed'},
          }),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(store.capture({}), throwsStateError);
        await blocker.delete();
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
        final state = File('${tempDir.path}/state.json');
        await state.copy('${state.path}.tmp');
        await state.rename('${state.path}.bak');
        final recovered = MergeStore(tempDir, 'device-alpha');
        await recovered.load();
        expect(recovered.recoveredFromBackup, isTrue);
        expect(recovered.pendingApply![key]?['name'], 'Target');
        expect(recovered.observed[key]?['name'], 'Original');
      },
    );

    for (final invalid in ['{}', '[]', '{\"actor\":\"device-alpha\"}']) {
      test(
        'legal but invalid primary $invalid recovers only a valid backup',
        () async {
          final store = MergeStore(tempDir, 'device-alpha');
          await store.load();
          await File('${tempDir.path}/state.json').writeAsString(invalid);
          final recovered = MergeStore(tempDir, 'device-alpha');
          await recovered.load();
          expect(recovered.recoveredFromBackup, isTrue);
          await File('${tempDir.path}/state.json.bak').writeAsString('[]');
          await expectLater(
            MergeStore(tempDir, 'device-alpha').load(),
            throwsFormatException,
          );
        },
      );
    }

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
        await Directory('${tempDir.path}/apply_journal.json').create();
        await expectLater(
          MergeStore(tempDir, 'device-alpha').load(),
          throwsFormatException,
        );
        final persisted =
            jsonDecode(await File('${tempDir.path}/state.json').readAsString())
                as Map<String, dynamic>;
        expect(persisted['pendingApply'], isNull);
        expect(persisted['observed'][key]['name'], 'Latest');
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
        await store.resolve(sourceKey, 'script', candidateA.id);
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
        final store = MergeStore(tempDir, 'device-alpha');
        await store.load();
        await store.capture({
          syncRecordKey('folder', ['f1']): {'name': 'Critical'},
        });
        final primary = File('${tempDir.path}/state.json');
        final state =
            jsonDecode(await primary.readAsString()) as Map<String, dynamic>;
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
        expect(store.outbox.length, 1);

        // Subsequent save migrates cleanly to schemaVersion 2
        await store.save();
        final migrated =
            jsonDecode(await File('${tempDir.path}/state.json').readAsString())
                as Map<String, dynamic>;
        expect(migrated['schemaVersion'], 2);
        expect(migrated['pendingUnavailableDomains'], isEmpty);
      },
    );

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

    test('resolve rejects conflicts in unavailable domain', () async {
      final store = MergeStore(tempDir, 'device-alpha');
      await store.load();

      final sourceKey = syncRecordKey('source', ['plugin']);
      await expectLater(
        () => store.resolve(
          sourceKey,
          'script',
          'candidate_1',
          unavailableDomains: {'source'},
        ),
        throwsStateError,
      );
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
        await store.resolve(
          folderKey,
          'name',
          candId,
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
