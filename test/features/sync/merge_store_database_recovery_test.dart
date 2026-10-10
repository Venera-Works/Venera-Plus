import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:venera_plus/features/sync/merge_engine.dart';
import 'package:venera_plus/features/sync/merge_snapshot.dart';
import 'package:venera_plus/features/sync/merge_store_database.dart';
import 'package:venera_plus/features/sync/merge_store_error.dart';
import 'package:venera_plus/foundation/sync_records.dart';

const _actor = 'device_alpha';
final _recordKey = syncRecordKey('folder', ['critical']);

class _Fixture {
  final MergeDocument document;
  final MergeDocument localObservation;
  final SyncRecords observed;
  final MergeBatch batch;

  const _Fixture({
    required this.document,
    required this.localObservation,
    required this.observed,
    required this.batch,
  });

  factory _Fixture.named(String name) {
    final records = <String, Map<String, Object?>>{
      _recordKey: {'name': name},
    };
    final document = MergeDocument()..captureLocal(_actor, const {}, records);
    return _Fixture(
      document: document,
      localObservation: document.clone(),
      observed: records,
      batch: MergeBatch.create(
        actor: _actor,
        counter: document.counterFor(_actor),
        document: document,
      ),
    );
  }

  _Fixture next(String name) {
    final nextDocument = document.clone();
    final before = document.materialize();
    final after = <String, Map<String, Object?>>{
      for (final entry in before.entries)
        entry.key: Map<String, Object?>.of(entry.value),
    }..[_recordKey] = {'name': name};
    nextDocument.captureLocal(_actor, before, after);
    return _Fixture(
      document: nextDocument,
      localObservation: nextDocument.clone(),
      observed: after,
      batch: MergeBatch.create(
        actor: _actor,
        counter: nextDocument.counterFor(_actor),
        document: nextDocument,
      ),
    );
  }
}

Future<void> _commitFixture(
  MergeStoreDatabase database,
  _Fixture fixture, {
  Set<String> received = const {'known/commit.json'},
  Map<String, MergeBatch>? batches,
  Map<String, Map<String, String>> localEdits = const {},
  bool? counterReconciliationRequired,
}) async {
  await database.commit(
    document: fixture.document,
    localObservation: fixture.localObservation,
    observed: fixture.observed,
    received: received,
    outboxIds: [fixture.batch.id],
    newOutboxBatches: batches ?? {fixture.batch.id: fixture.batch},
    outboxChangedRecords: {
      fixture.batch.id: {_recordKey},
    },
    pendingApply: null,
    pendingUnavailableDomains: const {},
    initialized: true,
    localEdits: localEdits,
    counterReconciliationRequired: counterReconciliationRequired,
  );
}

Future<MergeStoreDatabaseState> _readState(Directory directory) async {
  final database = MergeStoreDatabase(directory, _actor);
  return (await database.load())!;
}

void _stripOutboxAndFingerprint(Directory directory) {
  for (final file in [_primary(directory), _replica(directory)]) {
    final database = sqlite3.open(file.path);
    try {
      database.execute('PRAGMA foreign_keys = ON;');
      database.execute('BEGIN IMMEDIATE;');
      database.execute('DELETE FROM merge_outbox_changed_records;');
      database.execute('DELETE FROM merge_outbox_objects;');
      database.execute('DELETE FROM merge_outbox;');
      database.execute('DELETE FROM merge_snapshot_objects;');
      database.execute(
        "DELETE FROM merge_store_meta WHERE key = 'commitFingerprint';",
      );
      database.execute(
        "DELETE FROM merge_store_meta WHERE key = 'hasCompletedSync';",
      );
      database.execute('COMMIT;');
    } finally {
      database.close();
    }
  }
}

File _primary(Directory directory) =>
    File('${directory.path}/merge_store.sqlite3');
File _replica(Directory directory) =>
    File('${directory.path}/merge_store.sqlite3.bak');
File _recoveryMarker(Directory directory) =>
    File('${directory.path}/merge_store.sqlite3.reconcile');

Future<void> _replaceReplicaOutbox(
  Directory directory,
  String oldBatchId,
  MergeBatch replacement,
) async {
  final snapshot = MergeSnapshot.fromBatch(replacement);
  final backup = sqlite3.open(_replica(directory).path);
  try {
    backup.execute('PRAGMA foreign_keys = OFF;');
    backup.execute('BEGIN IMMEDIATE;');
    backup.execute('DELETE FROM merge_outbox_objects WHERE batch_id = ?;', [
      oldBatchId,
    ]);
    backup.execute(
      'DELETE FROM merge_outbox_changed_records WHERE batch_id = ?;',
      [oldBatchId],
    );
    backup.execute('DELETE FROM merge_outbox WHERE batch_id = ?;', [
      oldBatchId,
    ]);
    backup.execute('DELETE FROM merge_snapshot_objects;');
    backup.execute(
      '''
      INSERT INTO merge_outbox(batch_id, actor, counter, manifest)
      VALUES (?, ?, ?, ?);
      ''',
      [
        replacement.id,
        replacement.actor,
        replacement.counter,
        snapshot.serializeManifest(),
      ],
    );
    for (final entry in snapshot.objects.entries) {
      backup.execute(
        'INSERT INTO merge_snapshot_objects(path, content) VALUES (?, ?);',
        [entry.key, entry.value],
      );
      backup.execute(
        'INSERT INTO merge_outbox_objects(batch_id, path) VALUES (?, ?);',
        [replacement.id, entry.key],
      );
    }
    backup.execute(
      '''
      INSERT INTO merge_outbox_changed_records(batch_id, record_key)
      VALUES (?, ?);
      ''',
      [replacement.id, _recordKey],
    );
    backup.execute('COMMIT;');
  } catch (_) {
    try {
      backup.execute('ROLLBACK;');
    } on Object {
      // Preserve the fixture operation's original failure.
    }
    rethrow;
  } finally {
    backup.close();
  }
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'merge-store-database-recovery-',
    );
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('fresh initialization refuses to replace a committed store', () async {
    final staleWriter = MergeStoreDatabase(directory, _actor);
    expect(await staleWriter.load(), isNull);

    final live = MergeStoreDatabase(directory, _actor);
    expect(await live.load(), isNull);
    final original = _Fixture.named('durable intent');
    await _commitFixture(live, original);
    final primaryBefore = await _primary(directory).readAsBytes();
    final replicaBefore = await _replica(directory).readAsBytes();

    final staleIntent = _Fixture.named('stale in-memory intent');
    await expectLater(
      _commitFixture(staleWriter, staleIntent),
      throwsA(
        isA<MergeStoreStaleStateException>().having(
          (error) => error.code,
          'code',
          'SYNC_STATE_CHANGED',
        ),
      ),
    );

    expect(
      await _primary(directory).readAsBytes(),
      orderedEquals(primaryBefore),
    );
    expect(
      await _replica(directory).readAsBytes(),
      orderedEquals(replicaBefore),
    );
    final state = await _readState(directory);
    expect(state.observed[_recordKey], {'name': 'durable intent'});
    expect(state.outboxIds, [original.batch.id]);
    expect(state.document.counterFor(_actor), 1);
  });

  test(
    'empty SQLite files can still receive the first committed state',
    () async {
      _primary(directory).writeAsBytesSync(const []);
      final emptyFile = sqlite3.open(_primary(directory).path);
      emptyFile.close();
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);

      final fixture = _Fixture.named('initialized');
      await _commitFixture(database, fixture);
      final loaded = await _readState(directory);
      expect(loaded.observed[_recordKey], {'name': 'initialized'});
      expect(loaded.outboxIds, [fixture.batch.id]);
    },
  );

  test('empty merge schema is still uninitialized', () async {
    final emptySchema = sqlite3.open(_primary(directory).path);
    emptySchema.execute('''
      CREATE TABLE merge_store_meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
    ''');
    emptySchema.execute('PRAGMA user_version = 1;');
    emptySchema.close();

    final database = MergeStoreDatabase(directory, _actor);
    expect(await database.load(), isNull);
    final fixture = _Fixture.named('initialized from empty schema');
    await _commitFixture(database, fixture);
    final durable = await _readState(directory);
    expect(durable.observed[_recordKey], {
      'name': 'initialized from empty schema',
    });
    expect(durable.outboxIds, [fixture.batch.id]);
  });
  test(
    'legacy completion metadata uses received evidence without resetting counter',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final fixture = _Fixture.named('legacy checkpoint');
      await _commitFixture(database, fixture);
      _stripOutboxAndFingerprint(directory);

      final legacyReader = MergeStoreDatabase(directory, _actor);
      final legacyState = await legacyReader.load();
      expect(legacyState!.hasCompletedSync, isTrue);
      expect(legacyState.document.counterFor(_actor), 1);
      await _commitFixture(legacyReader, fixture.next('after upgrade'));

      final reopened = await _readState(directory);
      expect(reopened.hasCompletedSync, isTrue);
      expect(reopened.document.counterFor(_actor), 2);

      final noEvidenceDirectory = Directory('${directory.path}/no-evidence')
        ..createSync();
      final noEvidenceWriter = MergeStoreDatabase(noEvidenceDirectory, _actor);
      expect(await noEvidenceWriter.load(), isNull);
      await _commitFixture(
        noEvidenceWriter,
        _Fixture.named('without received checkpoint'),
        received: const {},
      );
      _stripOutboxAndFingerprint(noEvidenceDirectory);
      final noEvidence = await MergeStoreDatabase(
        noEvidenceDirectory,
        _actor,
      ).load();
      expect(noEvidence!.hasCompletedSync, isFalse);
    },
  );

  test(
    'legacy loaded cache detects identical same-revision replacement',
    () async {
      final legacyDirectory = Directory('${directory.path}/legacy')
        ..createSync();
      final replacementDirectory = Directory('${directory.path}/replacement')
        ..createSync();
      final oldFixture = _Fixture.named('loaded legacy state');
      final oldWriter = MergeStoreDatabase(legacyDirectory, _actor);
      expect(await oldWriter.load(), isNull);
      await _commitFixture(oldWriter, oldFixture);
      _stripOutboxAndFingerprint(legacyDirectory);

      final loaded = MergeStoreDatabase(legacyDirectory, _actor);
      final loadedState = await loaded.load();
      expect(loadedState!.outboxIds, isEmpty);
      expect(loadedState.commitRevision, 1);

      final replacementFixture = _Fixture.named('replacement legacy state');
      final replacementWriter = MergeStoreDatabase(
        replacementDirectory,
        _actor,
      );
      expect(await replacementWriter.load(), isNull);
      await _commitFixture(replacementWriter, replacementFixture);
      _stripOutboxAndFingerprint(replacementDirectory);

      await _primary(replacementDirectory).copy(_primary(legacyDirectory).path);
      await _replica(replacementDirectory).copy(_replica(legacyDirectory).path);
      final primaryBefore = await _primary(legacyDirectory).readAsBytes();
      final replicaBefore = await _replica(legacyDirectory).readAsBytes();
      await expectLater(
        _commitFixture(loaded, oldFixture),
        throwsA(
          isA<MergeStoreStaleStateException>().having(
            (error) => error.code,
            'code',
            'SYNC_STATE_CHANGED',
          ),
        ),
      );

      expect(
        await _primary(legacyDirectory).readAsBytes(),
        orderedEquals(primaryBefore),
      );
      expect(
        await _replica(legacyDirectory).readAsBytes(),
        orderedEquals(replicaBefore),
      );
      final durable = await _readState(legacyDirectory);
      expect(durable.observed[_recordKey], {
        'name': 'replacement legacy state',
      });
      expect(durable.outboxIds, isEmpty);
      expect(durable.document.counterFor(_actor), 1);
    },
  );

  test(
    'delete-old/add-same-counter fails before changing either database',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final persisted = _Fixture.named('old dot');
      await _commitFixture(database, persisted);
      final primaryBefore = await _primary(directory).readAsBytes();
      final replicaBefore = await _replica(directory).readAsBytes();
      final replacement = _Fixture.named('different dot payload');

      await expectLater(
        _commitFixture(database, replacement),
        throwsA(
          isA<MergeOutboxCounterConflictException>()
              .having((error) => error.actor, 'actor', _actor)
              .having((error) => error.counter, 'counter', 1)
              .having(
                (error) => error.existingBatchId,
                'existing id',
                persisted.batch.id,
              )
              .having(
                (error) => error.incomingBatchId,
                'incoming id',
                replacement.batch.id,
              ),
        ),
      );

      expect(
        await _primary(directory).readAsBytes(),
        orderedEquals(primaryBefore),
      );
      expect(
        await _replica(directory).readAsBytes(),
        orderedEquals(replicaBefore),
      );
      final state = await _readState(directory);
      expect(state.observed[_recordKey], {'name': 'old dot'});
      expect(state.outboxIds, [persisted.batch.id]);
    },
  );

  test(
    'same-id retry is idempotent and a changed identity is rejected',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final persisted = _Fixture.named('same identity');
      await _commitFixture(database, persisted);
      final primaryBefore = await _primary(directory).readAsBytes();
      final replicaBefore = await _replica(directory).readAsBytes();

      await _commitFixture(database, persisted);
      expect(
        await _primary(directory).readAsBytes(),
        orderedEquals(primaryBefore),
      );
      expect(
        await _replica(directory).readAsBytes(),
        orderedEquals(replicaBefore),
      );

      final otherContent = _Fixture.named('changed identity');
      final forged = MergeBatch(
        actor: _actor,
        counter: 1,
        document: otherContent.document,
        id: persisted.batch.id,
      );
      await expectLater(
        _commitFixture(
          database,
          persisted,
          batches: {persisted.batch.id: forged},
        ),
        throwsA(isA<MergeStoreIntegrityException>()),
      );
      expect(
        await _primary(directory).readAsBytes(),
        orderedEquals(primaryBefore),
      );
      expect(
        await _replica(directory).readAsBytes(),
        orderedEquals(replicaBefore),
      );
      final state = await _readState(directory);
      expect(state.outboxIds, [persisted.batch.id]);
      expect(state.observed[_recordKey], {'name': 'same identity'});
    },
  );

  test(
    'a higher counter can replace old pending intent and retain business data',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final first = _Fixture.named('first intent');
      await _commitFixture(database, first);
      final second = first.next('second intent');
      await _commitFixture(database, second);

      final state = await _readState(directory);
      expect(state.document.counterFor(_actor), 2);
      expect(state.observed[_recordKey], {'name': 'second intent'});
      expect(state.outboxIds, [second.batch.id]);
      final reopened = MergeStoreDatabase(directory, _actor);
      await reopened.load();
      expect(
        reopened
            .pendingBatch(second.batch.id, currentDocument: state.document)
            .counter,
        2,
      );
    },
  );
  test('a lower candidate cannot regress the durable own counter', () async {
    final database = MergeStoreDatabase(directory, _actor);
    expect(await database.load(), isNull);
    final first = _Fixture.named('first durable intent');
    await _commitFixture(database, first);
    final second = first.next('second durable intent');
    await _commitFixture(database, second);
    final primaryBefore = await _primary(directory).readAsBytes();
    final replicaBefore = await _replica(directory).readAsBytes();

    await expectLater(
      _commitFixture(database, _Fixture.named('stale lower counter')),
      throwsA(
        isA<MergeStoreStaleStateException>()
            .having((error) => error.metadata['ownCounter'], 'candidate', 1)
            .having(
              (error) => error.metadata['mainOwnCounter'],
              'durable counter',
              2,
            ),
      ),
    );
    expect(
      await _primary(directory).readAsBytes(),
      orderedEquals(primaryBefore),
    );
    expect(
      await _replica(directory).readAsBytes(),
      orderedEquals(replicaBefore),
    );
    final state = await _readState(directory);
    expect(state.document.counterFor(_actor), 2);
    expect(state.observed[_recordKey], {'name': 'second durable intent'});
    expect(state.outboxIds, [second.batch.id]);
  });

  test(
    'same-revision divergent business rows preserve both replicas',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final fixture = _Fixture.named('primary intent');
      final manualEdits = {
        _recordKey: {'name': '$_actor:1'},
      };
      await _commitFixture(database, fixture, localEdits: manualEdits);
      final backup = sqlite3.open(_replica(directory).path);
      try {
        backup.execute(
          '''
        UPDATE merge_business_records SET value_json = ?
        WHERE kind = 'localEdits' AND record_key = ?;
        ''',
          [
            canonicalSyncJson({'name': '$_actor:2'}),
            _recordKey,
          ],
        );
      } finally {
        backup.close();
      }
      final primaryBefore = await _primary(directory).readAsBytes();
      final replicaBefore = await _replica(directory).readAsBytes();
      await expectLater(
        _commitFixture(database, fixture.next('must not overwrite replica')),
        throwsA(isA<MergeStoreReplicaDivergenceException>()),
      );

      await expectLater(
        _readState(directory),
        throwsA(
          isA<MergeStoreReplicaDivergenceException>().having(
            (error) => error.code,
            'code',
            'SYNC_STATE_DIVERGED',
          ),
        ),
      );
      expect(
        await _primary(directory).readAsBytes(),
        orderedEquals(primaryBefore),
      );
      expect(
        await _replica(directory).readAsBytes(),
        orderedEquals(replicaBefore),
      );
    },
  );

  test(
    'same-revision divergent outbox snapshots preserve both replicas',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final fixture = _Fixture.named('primary intent');
      await _commitFixture(database, fixture);

      final alternateDocument = fixture.document.clone();
      final before = alternateDocument.materialize();
      final after = <String, Map<String, Object?>>{
        for (final entry in before.entries)
          entry.key: Map<String, Object?>.of(entry.value),
      }..[syncRecordKey('folder', ['replica-only'])] = {'name': 'extra'};
      alternateDocument.captureLocal('device_beta', before, after);
      final alternateBatch = MergeBatch.create(
        actor: _actor,
        counter: 1,
        document: alternateDocument,
      );
      await _replaceReplicaOutbox(directory, fixture.batch.id, alternateBatch);
      final primaryBefore = await _primary(directory).readAsBytes();
      final replicaBefore = await _replica(directory).readAsBytes();
      await expectLater(
        _commitFixture(database, fixture.next('must not overwrite replica')),
        throwsA(isA<MergeStoreReplicaDivergenceException>()),
      );

      await expectLater(
        _readState(directory),
        throwsA(isA<MergeStoreReplicaDivergenceException>()),
      );
      expect(
        await _primary(directory).readAsBytes(),
        orderedEquals(primaryBefore),
      );
      expect(
        await _replica(directory).readAsBytes(),
        orderedEquals(replicaBefore),
      );
    },
  );

  test(
    'failed recovery commit preserves intent and obligation across restart',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final first = _Fixture.named('first durable intent');
      await _commitFixture(database, first);
      final olderPrimary = await _primary(directory).readAsBytes();
      final second = first.next('second durable intent');
      await _commitFixture(database, second);
      final latestReplica = await _replica(directory).readAsBytes();

      await _primary(directory).writeAsBytes(olderPrimary, flush: true);
      final recovered = MergeStoreDatabase(directory, _actor);
      final recoveredState = (await recovered.load())!;
      expect(recoveredState.recoveredFromBackup, isTrue);
      expect(_recoveryMarker(directory).existsSync(), isTrue);
      expect(
        await _primary(directory).readAsBytes(),
        orderedEquals(latestReplica),
      );

      final restoredPrimary = await _primary(directory).readAsBytes();
      final restoredReplica = await _replica(directory).readAsBytes();
      final conflictingIntent = _Fixture.named(
        'conflicting prior generation',
      ).next('conflicting counter two');
      await expectLater(
        _commitFixture(recovered, conflictingIntent),
        throwsA(isA<MergeOutboxCounterConflictException>()),
      );
      expect(_recoveryMarker(directory).existsSync(), isTrue);
      expect(
        await _primary(directory).readAsBytes(),
        orderedEquals(restoredPrimary),
      );
      expect(
        await _replica(directory).readAsBytes(),
        orderedEquals(restoredReplica),
      );

      final restarted = MergeStoreDatabase(directory, _actor);
      final restartedState = (await restarted.load())!;
      expect(restartedState.recoveredFromBackup, isTrue);
      expect(_recoveryMarker(directory).existsSync(), isTrue);
      expect(restartedState.document.counterFor(_actor), 2);
      expect(restartedState.observed[_recordKey], {
        'name': 'second durable intent',
      });
      expect(restartedState.outboxIds, [second.batch.id]);

      final third = second.next('third durable intent');
      await _commitFixture(
        restarted,
        third,
        counterReconciliationRequired: false,
      );
      expect(_recoveryMarker(directory).existsSync(), isFalse);
      final finalState = await _readState(directory);
      expect(finalState.recoveredFromBackup, isFalse);
      expect(finalState.document.counterFor(_actor), 3);
      expect(finalState.observed[_recordKey], {'name': 'third durable intent'});
      expect(finalState.outboxIds, [third.batch.id]);
    },
  );
  test('a recovery marker without either replica fails closed', () async {
    await _recoveryMarker(
      directory,
    ).writeAsString('counter-reconciliation-required\n', flush: true);
    await expectLater(
      MergeStoreDatabase(directory, _actor).load(),
      throwsA(isA<MergeStoreIntegrityException>()),
    );
    expect(_recoveryMarker(directory).existsSync(), isTrue);
  });
  test('invalid replicas fail with safe typed integrity diagnostics', () async {
    await _primary(
      directory,
    ).writeAsString('BUSINESS-SENSITIVE-PAYLOAD', flush: true);
    await _replica(
      directory,
    ).writeAsString('MANIFEST-SENSITIVE-PAYLOAD', flush: true);

    await expectLater(
      MergeStoreDatabase(directory, _actor).load(),
      throwsA(
        isA<MergeStoreIntegrityException>()
            .having((error) => error.code, 'code', 'SYNC_STATE_INVALID')
            .having(
              (error) => error.metadata['reason'],
              'reason',
              'no_valid_replica',
            )
            .having(
              (error) => error.metadata.toString(),
              'safe metadata',
              isNot(contains('SENSITIVE-PAYLOAD')),
            ),
      ),
    );
    expect(
      await _primary(directory).readAsString(),
      'BUSINESS-SENSITIVE-PAYLOAD',
    );
    expect(
      await _replica(directory).readAsString(),
      'MANIFEST-SENSITIVE-PAYLOAD',
    );
  });

  test(
    'a verified no-op commit clears the recovery marker without a revision bump',
    () async {
      final database = MergeStoreDatabase(directory, _actor);
      expect(await database.load(), isNull);
      final fixture = _Fixture.named('already committed');
      await _commitFixture(
        database,
        fixture,
        counterReconciliationRequired: true,
      );
      final before = await _readState(directory);
      expect(before.recoveredFromBackup, isTrue);
      expect(_recoveryMarker(directory).existsSync(), isTrue);

      await _commitFixture(
        database,
        fixture,
        counterReconciliationRequired: false,
      );
      expect(_recoveryMarker(directory).existsSync(), isFalse);
      final after = await _readState(directory);
      expect(after.recoveredFromBackup, isFalse);
      expect(after.commitRevision, before.commitRevision);
      expect(after.document.counterFor(_actor), 1);
      expect(after.observed[_recordKey], {'name': 'already committed'});
    },
  );
}
