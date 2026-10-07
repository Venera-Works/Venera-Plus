import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:venera_plus/foundation/sync_records.dart';
import 'package:venera_plus/features/sync/merge_engine.dart';

void main() {
  group('MergeDocument & MergeEngine', () {
    test('three-device independent creations converge in any merge order', () {
      final docA = MergeDocument();
      final docB = MergeDocument();
      final docC = MergeDocument();

      final folderAKey = syncRecordKey('folder', ['folder-a']);
      final folderBKey = syncRecordKey('folder', ['folder-b']);
      final folderCKey = syncRecordKey('folder', ['folder-c']);

      docA.captureLocal('devA', {}, {
        folderAKey: {'name': 'Manga A', 'order': 1},
      });

      docB.captureLocal('devB', {}, {
        folderBKey: {'name': 'Manga B', 'order': 2},
      });

      docC.captureLocal('devC', {}, {
        folderCKey: {'name': 'Manga C', 'order': 3},
      });

      // Merge (A + B) + C
      final merged1 = docA.clone();
      merged1.merge(docB.clone());
      merged1.merge(docC.clone());

      // Merge C + (A + B)
      final merged2 = docC.clone();
      final tempAB = docA.clone()..merge(docB.clone());
      merged2.merge(tempAB);

      // Merge (B + C) + A
      final merged3 = docB.clone();
      merged3.merge(docC.clone());
      merged3.merge(docA.clone());

      final mat1 = merged1.materialize();
      final mat2 = merged2.materialize();
      final mat3 = merged3.materialize();

      expect(mat1.length, 3);
      expect(mat1.containsKey(folderAKey), isTrue);
      expect(mat1.containsKey(folderBKey), isTrue);
      expect(mat1.containsKey(folderCKey), isTrue);

      expect(syncValuesEqual(mat1, mat2), isTrue);
      expect(syncValuesEqual(mat1, mat3), isTrue);
      expect(merged1.conflicts, isEmpty);
    });

    test('field-level causal merge and semantic coalescing', () {
      final key = syncRecordKey('favorite', ['folder-1', 'comic-100', 0]);

      // Step 1: Initial creation on Device A
      final docA = MergeDocument();
      docA.captureLocal('devA', {}, {
        key: {'title': 'Hero', 'author': 'Author One', 'hasNewUpdate': false},
      });

      // Step 2: Device B syncs from A
      final docB = docA.clone();

      // Step 3: Concurrent edits on distinct fields
      docA.captureLocal('devA', docA.materialize(), {
        key: {'title': 'Hero', 'author': 'Author Two', 'hasNewUpdate': false},
      });

      docB.captureLocal('devB', docB.materialize(), {
        key: {'title': 'Hero', 'author': 'Author One', 'hasNewUpdate': true},
      });

      // Step 4: Merge A and B
      docA.merge(docB);
      final mat = docA.materialize();

      expect(mat[key]?['title'], 'Hero');
      expect(mat[key]?['author'], 'Author Two');
      expect(mat[key]?['hasNewUpdate'], true);
      expect(
        docA.conflicts,
        isEmpty,
      ); // No conflict: distinct fields and identical 'title'
    });

    test(
      'concurrent equal values coalesce semantically without false conflict',
      () {
        final key = syncRecordKey('setting', ['themeMode']);
        final docA = MergeDocument();
        final docB = MergeDocument();

        docA.captureLocal('devA', {}, {
          key: {'value': 'dark'},
        });
        docB.captureLocal('devB', {}, {
          key: {'value': 'dark'},
        });

        docA.merge(docB);

        expect(docA.conflicts, isEmpty);
        final mat = docA.materialize();
        expect(mat[key]?['value'], 'dark');
      },
    );

    test(
      'concurrent conflicting field edits report conflict and resolution establishes new version',
      () {
        final key = syncRecordKey('favorite', ['folder-1', 'comic-200', 0]);
        final docA = MergeDocument();
        docA.captureLocal('devA', {}, {
          key: {'title': 'Original'},
        });

        final docB = docA.clone();

        // Concurrent differing edits to 'title'
        docA.captureLocal('devA', docA.materialize(), {
          key: {'title': 'Title By A'},
        });

        docB.captureLocal('devB', docB.materialize(), {
          key: {'title': 'Title By B'},
        });

        docA.merge(docB);

        expect(docA.conflicts.length, 1);
        final conflict = docA.conflicts.first;
        expect(conflict.recordKey, key);
        expect(conflict.field, 'title');
        expect(conflict.candidates.length, 2);

        // Choose candidate from A
        final candA = conflict.candidates.firstWhere((c) => c.actor == 'devA');
        docA.resolve('devA', key, 'title', candA.id);

        expect(docA.conflicts, isEmpty);
        expect(docA.materialize()[key]?['title'], 'Title By A');

        // Now sync to B: B accepts the resolved version
        docB.merge(docA);
        expect(docB.conflicts, isEmpty);
        expect(docB.materialize()[key]?['title'], 'Title By A');
      },
    );

    test(
      'edit wins over concurrent delete: preserves metadata, reports presence conflict, and supports resolution',
      () {
        final key = syncRecordKey('favorite', ['folder-1', 'comic-123', 0]);
        final docA = MergeDocument();
        docA.captureLocal('devA', {}, {
          key: {
            'title': 'Original',
            'author': 'OriginalAuthor',
            'cover': 'cover.jpg',
          },
        });

        final docB = docA.clone();

        // Device A deletes the favorite
        docA.captureLocal('devA', docA.materialize(), {});

        // Device B concurrently edits only title
        final obsB = docB.materialize();
        docB.captureLocal('devB', obsB, {
          key: {...obsB[key]!, 'title': 'Concurrent edit'},
        });

        // Merge
        docA.merge(docB);

        // 1. Materialized view contains the favorite
        final mat = docA.materialize();
        expect(mat.containsKey(key), isTrue);
        expect(mat[key]?['title'], 'Concurrent edit');
        // 2. Untouched metadata is completely preserved (not wiped out by delete)!
        expect(mat[key]?['author'], 'OriginalAuthor');
        expect(mat[key]?['cover'], 'cover.jpg');

        // 3. Single presence conflict is exposed
        expect(docA.conflicts.isNotEmpty, isTrue);
        final presenceConflict = docA.conflicts.firstWhere(
          (c) => c.field == 'presence',
        );
        expect(presenceConflict.candidates.any((c) => c.isDeleted), isTrue);
        expect(presenceConflict.candidates.any((c) => !c.isDeleted), isTrue);

        // 4. Resolving presence conflict to deleted cleanly tombstones the record
        final docResolvedDelete = docA.clone();
        final delCand = presenceConflict.candidates.firstWhere(
          (c) => c.isDeleted,
        );
        docResolvedDelete.resolve('devA', key, 'presence', delCand.id);
        expect(docResolvedDelete.materialize().containsKey(key), isFalse);
        expect(docResolvedDelete.conflicts, isEmpty);
      },
    );

    test('child records survive parent deletion', () {
      final parentKey = syncRecordKey('history', ['comic-999', 0]);
      final ch1Key = syncRecordKey('historyChapter', [
        'comic-999',
        0,
        'chapter-1',
      ]);
      final ch2Key = syncRecordKey('historyChapter', [
        'comic-999',
        0,
        'chapter-2',
      ]);
      final imgKey = syncRecordKey('imageFavorite', [
        'comic-999',
        'sourceA',
        'ep1',
        5,
      ]);

      final docA = MergeDocument();
      docA.captureLocal('devA', {}, {
        parentKey: {'readDurationMs': 1000},
        ch1Key: {'title': 'Chapter 1'},
      });

      final docB = docA.clone();

      // Device A deletes the parent history record
      final observedA = docA.materialize();
      final currentA = cloneSyncRecords(observedA)..remove(parentKey);
      docA.captureLocal('devA', observedA, currentA);

      // Device B concurrently reads chapter 2 and stars an image
      final observedB = docB.materialize();
      final currentB = cloneSyncRecords(observedB)
        ..[ch2Key] = {'title': 'Chapter 2'}
        ..[imgKey] = {'imageKey': 'img-5'};
      docB.captureLocal('devB', observedB, currentB);

      // Merge
      docA.merge(docB);
      final mat = docA.materialize();

      // Parent is tombstoned, but child chapter and image records MUST survive!
      expect(mat.containsKey(parentKey), isFalse);
      expect(mat.containsKey(ch1Key), isTrue);
      expect(mat.containsKey(ch2Key), isTrue);
      expect(mat.containsKey(imgKey), isTrue);
      expect(mat[ch2Key]?['title'], 'Chapter 2');
    });

    test(
      'reading duration: legacy base deduplication and multi-device positive increments',
      () {
        final key = syncRecordKey('history', ['comic-555', 0]);

        // Both devices import same migrated legacy snapshot with duration 10000 ms
        final docA = MergeDocument();
        docA.captureLocal('devA', {}, {
          key: {'readDurationMs': 10000},
        }, bootstrap: true);

        final docB = MergeDocument();
        docB.captureLocal('devB', {}, {
          key: {'readDurationMs': 10000},
        }, bootstrap: true);

        // Merge A and B: base is 10000, NOT double-counted to 20000!
        docA.merge(docB);
        expect(docA.materialize()[key]?['readDurationMs'], 10000);

        // Device A reads for +5000 ms (total 15000)
        final obsA = docA.materialize();
        docA.captureLocal('devA', obsA, {
          key: {'readDurationMs': 15000},
        });

        // Device B concurrently reads for +8000 ms (total 18000)
        final obsB = docB.materialize();
        docB.captureLocal('devB', obsB, {
          key: {'readDurationMs': 18000},
        });

        // Merge: total must be 10000 + 5000 + 8000 = 23000 ms!
        docA.merge(docB);
        expect(docA.materialize()[key]?['readDurationMs'], 23000);

        // Device A observes 23000 and reads +2000 ms more (total 25000)
        final obsA2 = docA.materialize();
        docA.captureLocal('devA', obsA2, {
          key: {'readDurationMs': 25000},
        });

        expect(docA.materialize()[key]?['readDurationMs'], 25000);
      },
    );

    test(
      'reading duration: negative rewind/reset triggers explicit conflict',
      () {
        final key = syncRecordKey('history', ['comic-777', 0]);
        final doc = MergeDocument();
        doc.captureLocal('devA', {}, {
          key: {'readDurationMs': 20000},
        });

        // User resets reading duration to 0 ms
        final obs = doc.materialize();
        doc.captureLocal('devA', obs, {
          key: {'readDurationMs': 0},
        });

        expect(doc.conflicts.any((c) => c.field == 'readDurationMs'), isTrue);

        // Resolve reset conflict
        final conflict = doc.conflicts.firstWhere(
          (c) => c.field == 'readDurationMs',
        );
        final resetCandidate = conflict.candidates.firstWhere(
          (c) => c.value == 0,
        );
        doc.resolve('devA', key, 'readDurationMs', resetCandidate.id);

        expect(doc.conflicts, isEmpty);
        expect(doc.materialize()[key]?['readDurationMs'], 0);
      },
    );

    test(
      'preferred active session/script preserved in materialize without phantom edits',
      () {
        final key = syncRecordKey('cookies', ['example.com']);
        final docA = MergeDocument();
        final docB = MergeDocument();

        final sessionA = [
          {'name': 'session_token', 'value': 'token_dev_a'},
        ];
        final sessionB = [
          {'name': 'session_token', 'value': 'token_dev_b'},
        ];

        docA.captureLocal('devA', {}, {
          key: {'cookies': sessionA},
        });
        docB.captureLocal('devB', {}, {
          key: {'cookies': sessionB},
        });

        docA.merge(docB);

        // Conflict exists
        expect(docA.conflicts.length, 1);
        final cand = docA.conflicts.first.candidates.first;
        // Safe label must mask token
        expect(cand.safeLabel.contains('token_dev'), isFalse);

        // Materializing with preferred active session keeps local session
        final preferred = {
          key: {'cookies': sessionA},
        };
        final matPreferred = docA.materialize(preferred: preferred);
        expect(matPreferred[key]?['cookies'], sessionA);

        // Preferred selection MUST NOT clear or modify the conflict
        expect(docA.conflicts.length, 1);
      },
    );

    test('detects Byzantine conflicting payload for identical dot', () {
      final docA = MergeDocument();
      final docB = MergeDocument();

      final key = syncRecordKey('setting', ['test']);
      docA.captureLocal('devA', {}, {
        key: {'value': 'alpha'},
      });

      // The same allocation identity must never carry a second business payload.
      docB.captureLocal('devA', {}, {
        key: {'value': 'tampered'},
      });

      expect(() => docA.merge(docB), throwsFormatException);
    });

    test('causal checkpoint dominates, covers, and coversActor', () {
      final docA = MergeDocument();
      docA.captureLocal('devA', {}, {
        'k1': {'v': 1},
      });
      docA.captureLocal('devA', docA.materialize(), {
        'k1': {'v': 2},
      });

      final docB = MergeDocument();
      docB.captureLocal('devB', {}, {
        'k2': {'v': 1},
      });

      expect(docA.dominates(docB), isFalse);
      expect(docA.coversActor('devA', 2), isTrue);
      expect(docA.coversActor('devA', 3), isFalse);
      expect(docA.coversActor('devB', 1), isFalse);

      // Merge B into A
      docA.merge(docB);
      expect(docA.dominates(docB), isTrue);
      expect(docA.covers(docB), isTrue);
      expect(docA.coversActor('devB', 1), isTrue);

      // MergeBatch
      final batch = MergeBatch.create(
        actor: 'devA',
        counter: 2,
        document: docA,
      );
      expect(batch.id, isNotEmpty);
      expect(batch.computeDigest(), batch.id);
      expect(
        batch.dominates(
          MergeBatch.create(actor: 'devB', counter: 1, document: docB),
        ),
        isTrue,
      );
      expect(batch.coversActor('devB', 1), isTrue);

      final bytes = batch.serializeBytes();
      expect(sha256.convert(bytes).toString(), batch.computeDigest());
      final decodedJson =
          jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      expect(decodedJson.containsKey('id'), isFalse);
      // The authenticated remote filename supplies the wire payload's digest.
      final reloadedBatch = MergeBatch.fromJson({
        ...decodedJson,
        'id': batch.id,
      });
      expect(reloadedBatch.id, batch.id);
      final persistedBatch = MergeBatch.fromJson(batch.toJson());
      expect(persistedBatch.id, batch.id);
    });

    test(
      'reading duration reset resolution propagates and supersedes prior increments',
      () {
        final key = syncRecordKey('history', ['comic-888', 0]);
        final docA = MergeDocument();
        final docB = MergeDocument();

        // Initial shared base of 10000 ms
        docA.captureLocal('devA', {}, {
          key: {'readDurationMs': 10000},
        }, bootstrap: true);
        docB.captureLocal('devB', {}, {
          key: {'readDurationMs': 10000},
        }, bootstrap: true);
        docA.merge(docB);
        docB.merge(docA);

        // devA reads +2000 (total 12000)
        docA.captureLocal('devA', docA.materialize(), {
          key: {'readDurationMs': 12000},
        });

        // devB reads +3000 (total 13000)
        docB.captureLocal('devB', docB.materialize(), {
          key: {'readDurationMs': 13000},
        });

        // Merge: total is 10000 + 2000 + 3000 = 15000
        docA.merge(docB);
        expect(docA.materialize()[key]?['readDurationMs'], 15000);

        // devA resets to 0 and resolves conflict
        docA.captureLocal('devA', docA.materialize(), {
          key: {'readDurationMs': 0},
        });
        final conflict = docA.conflicts.firstWhere(
          (c) => c.field == 'readDurationMs',
        );
        final resetCand = conflict.candidates.firstWhere((c) => c.value == 0);
        docA.resolve('devA', key, 'readDurationMs', resetCand.id);
        expect(docA.materialize()[key]?['readDurationMs'], 0);

        // Sync to devB: devB must accept the reset (old devB increments superseded)
        docB.merge(docA);
        expect(docB.materialize()[key]?['readDurationMs'], 0);
        expect(docB.conflicts, isEmpty);
      },
    );

    test(
      'runtime new comic read independently on initialized A and B merges sum (100 + 200 = 300ms)',
      () {
        // Both devices already initialized on protocol
        final docA = MergeDocument();
        final docB = MergeDocument();

        final initKey = syncRecordKey('folder', ['f1']);
        docA.captureLocal('devA', {}, {
          initKey: {'name': 'F1'},
        });
        docB.captureLocal('devB', {}, {
          initKey: {'name': 'F1'},
        });
        docA.merge(docB);
        docB.merge(docA);

        final comicKey = syncRecordKey('history', ['comic-new', 0]);

        // Runtime reading: A reads 100ms
        final obsA = docA.materialize();
        docA.captureLocal('devA', obsA, {
          ...obsA,
          comicKey: {'readDurationMs': 100},
        });

        // Runtime reading: B reads 200ms
        final obsB = docB.materialize();
        docB.captureLocal('devB', obsB, {
          ...obsB,
          comicKey: {'readDurationMs': 200},
        });

        // Merged must be 100 + 200 = 300ms, NOT max(100, 200) = 200!
        docA.merge(docB);
        expect(docA.materialize()[comicKey]?['readDurationMs'], 300);
      },
    );

    test(
      'identical old snapshot 100 on 3 devices merges to 100, common base 100 + offline increments 100/60 merges to 260',
      () {
        final key = syncRecordKey('history', ['comic-migrated', 0]);

        // Explicit legacy actors seed a shared migrated baseline.
        final docA = MergeDocument();
        final docB = MergeDocument();
        final docC = MergeDocument();

        docA.captureLocal('legacy_A', {}, {
          key: {'readDurationMs': 100},
        });
        docB.captureLocal('legacy_B', {}, {
          key: {'readDurationMs': 100},
        });
        docC.captureLocal('legacy_C', {}, {
          key: {'readDurationMs': 100},
        });

        // Merge all 3: base is 100, NOT 300
        docA.merge(docB);
        docA.merge(docC);
        expect(docA.materialize()[key]?['readDurationMs'], 100);

        // Now devices A and B start with common base 100
        final docA2 = docA.clone();
        final docB2 = docA.clone();

        // A offline reads +100 (total 200)
        final obsA = docA2.materialize();
        docA2.captureLocal('devA', obsA, {
          key: {'readDurationMs': 200},
        });

        // B offline reads +60 (total 160)
        final obsB = docB2.materialize();
        docB2.captureLocal('devB', obsB, {
          key: {'readDurationMs': 160},
        });

        // Merge: common base 100 + 100 + 60 = 260!
        docA2.merge(docB2);
        expect(docA2.materialize()[key]?['readDurationMs'], 260);
      },
    );

    test(
      'causally deleted history re-read starts fresh incarnation without accumulating deleted counter, while concurrent read survives',
      () {
        final key = syncRecordKey('history', ['comic-incarnation', 0]);
        final docA = MergeDocument();
        final docB = MergeDocument();

        // Initial read: 1000ms
        docA.captureLocal('devA', {}, {
          key: {'readDurationMs': 1000},
        });
        docB.merge(docA);

        // Scenario 1: A deletes history
        final obsA = docA.materialize();
        docA.captureLocal('devA', obsA, {}); // A deletes

        // B has not seen delete, concurrently reads for 500ms more (total 1500ms)
        final obsB = docB.materialize();
        docB.captureLocal('devB', obsB, {
          key: {'readDurationMs': 1500},
        });

        // Merge: concurrent read on B SURVIVES delete
        final mergedConcurrent = docA.clone()..merge(docB);
        expect(mergedConcurrent.materialize().containsKey(key), isTrue);
        expect(mergedConcurrent.materialize()[key]?['readDurationMs'], 1500);

        // Scenario 2: A deleted history, and subsequently re-reads the comic starting a fresh incarnation (50ms)
        final obsAAfterDelete = docA.materialize(); // empty
        docA.captureLocal('devA', obsAAfterDelete, {
          key: {'readDurationMs': 50},
        });

        // A's duration in new incarnation is exactly 50ms, does not accumulate deleted 1000ms
        expect(docA.materialize()[key]?['readDurationMs'], 50);
      },
    );

    test(
      'dominates verifies actual all cells and duration counters rather than root floor alone',
      () {
        final docA = MergeDocument();
        final docB = MergeDocument();

        final key = syncRecordKey('history', ['comic-dom', 0]);
        docB.captureLocal('devB', {}, {
          key: {'readDurationMs': 100},
        });
        docB.captureLocal('devB', docB.materialize(), {
          key: {'readDurationMs': 200},
        });

        // docA artificially has root counter floor set to 5 for devB, but has NOT merged docB's cells
        docA.setCounterFloor('devB', 5);
        // Root counter floor for devB is 5 >= 2, but docA does NOT dominate docB because it lacks docB's cells
        expect(docA.dominates(docB), isFalse);

        // Once docB is actually merged, docA dominates docB
        docA.merge(docB);
        expect(docA.dominates(docB), isTrue);
      },
    );
    test(
      'allocation gaps never retire unseen records or fields or prove coverage',
      () {
        final seed = MergeDocument()..captureLocal('A', {}, {'R': {}});
        final publication = seed.clone();
        publication.captureLocal('A', publication.materialize(), {
          'R': {'x': 1},
        });
        final restored = seed.clone()..setCounterFloor('A', 2);
        restored.captureLocal('A', restored.materialize(), {
          'R': {'y': 2},
        });
        expect(restored.dominates(publication), isFalse);
        final batch = MergeBatch.create(
          actor: 'A',
          counter: 3,
          document: restored,
        );
        final predecessor = MergeBatch.create(
          actor: 'A',
          counter: 2,
          document: publication,
        );
        expect(batch.covers(predecessor), isFalse);
        restored.merge(publication);
        expect(restored.materialize()['R'], {'x': 1, 'y': 2});
        expect(restored.dominates(publication), isTrue);

        final empty = MergeDocument()..setCounterFloor('A', 50);
        empty.merge(seed);
        expect(empty.materialize(), seed.materialize());
      },
    );

    test(
      'unrelated edits do not resolve deletion and null membership is a diff',
      () {
        final seed = MergeDocument()
          ..captureLocal('A', {}, {
            'R': {'value': 1},
            'S': {},
          });
        final deleted = seed.clone();
        deleted.captureLocal('A', deleted.materialize(), {'S': {}});
        final edited = seed.clone();
        edited.captureLocal('B', edited.materialize(), {
          'R': {'value': 2},
          'S': {},
        });
        deleted.merge(edited);
        final before = deleted.materialize();
        deleted.captureLocal('C', before, {
          ...before,
          'S': {'value': null},
        });
        expect(
          deleted.conflicts.any((item) => item.field == 'presence'),
          isTrue,
        );
        final nullAdded = deleted.clone();
        final current = deleted.materialize();
        expect(
          deleted.captureLocal('C', current, {...current, 'S': {}}),
          greaterThan(0),
        );
        expect(deleted.materialize()['S']!.containsKey('value'), isFalse);
        nullAdded.merge(deleted);
        expect(nullAdded.materialize()['S']!.containsKey('value'), isFalse);
        final without = deleted.materialize();
        expect(
          deleted.captureLocal('C', without, {
            ...without,
            'S': {'value': null},
          }),
          greaterThan(0),
        );
        expect(deleted.materialize()['S']!.containsKey('value'), isTrue);
      },
    );

    test(
      'preferred null is a real candidate and field deletion membership is preferred',
      () {
        final key = syncRecordKey('setting', ['nullable']);
        final a = MergeDocument()
          ..captureLocal('A', {}, {
            key: {'value': null},
          });
        final b = MergeDocument()
          ..captureLocal('B', {}, {
            key: {'value': 'enabled'},
          });
        a.merge(b);
        expect(
          a.materialize(
            preferred: {
              key: {'value': null},
            },
          )[key]!['value'],
          isNull,
        );
        final branch = a.clone();
        branch.captureLocal('C', branch.materialize(), {key: {}});
        final concurrent = a.clone();
        concurrent.captureLocal('D', concurrent.materialize(), {
          key: {'value': 'new'},
        });
        branch.merge(concurrent);
        expect(
          branch.materialize(preferred: {key: {}})[key]!.containsKey('value'),
          isFalse,
        );
      },
    );

    test(
      'field and duration resolution are presence edits concurrent with deletion',
      () {
        for (final duration in [false, true]) {
          final key = duration ? syncRecordKey('history', ['resolve', 0]) : 'R';
          final field = duration ? 'readDurationMs' : 'value';
          final seed = MergeDocument()
            ..captureLocal('A', {}, {
              key: {field: 100},
            });
          final left = seed.clone();
          final right = seed.clone();
          left.captureLocal('A', left.materialize(), {
            key: {field: duration ? 0 : 1},
          });
          right.captureLocal('B', right.materialize(), {
            key: {field: duration ? 50 : 2},
          });
          left.merge(right);
          final deleting = left.clone();
          deleting.captureLocal('D', deleting.materialize(), {});
          final conflict = left.conflicts.firstWhere(
            (item) => item.field == field,
          );
          left.resolve('C', key, field, conflict.candidates.last.id);
          left.merge(deleting);
          expect(left.materialize().containsKey(key), isTrue);
          expect(
            left.conflicts.any((item) => item.field == 'presence'),
            isTrue,
          );
        }
      },
    );

    test(
      'first runtime contributions and reincarnation are idempotent in every order',
      () {
        final key = syncRecordKey('history', ['first', 0]);
        final a = MergeDocument();
        final b = MergeDocument();
        expect(a.captureLocal('A', {}, {}), 0);
        expect(b.captureLocal('B', {}, {}), 0);
        a.captureLocal('A', {}, {
          key: {'readDurationMs': 10},
        });
        b.captureLocal('B', {}, {
          key: {'readDurationMs': 20},
        });
        for (final order in [
          [a, b],
          [b, a],
          [a, a, b, b],
        ]) {
          final merged = MergeDocument();
          for (final checkpoint in order) merged.merge(checkpoint);
          merged.merge(merged.clone());
          expect(merged.materialize()[key]!['readDurationMs'], 30);
          expect(merged.conflicts, isEmpty);
        }
        final old = a.clone();
        final concurrent = a.clone();
        concurrent.captureLocal('B', concurrent.materialize(), {
          key: {'readDurationMs': 15},
        });
        a.captureLocal('A', a.materialize(), {});
        a.captureLocal('A', {}, {
          key: {'readDurationMs': 2},
        });
        a.merge(a.clone());
        expect(a.materialize()[key]!['readDurationMs'], 2);
        for (final order in [
          [a, old, concurrent],
          [concurrent, old, a],
        ]) {
          final merged = MergeDocument();
          for (final checkpoint in order) merged.merge(checkpoint);
          expect(merged.materialize()[key]!['readDurationMs'], 7);
        }
      },
    );

    test(
      'reset absorbs cumulative prefixes and retired proposals never resurrect',
      () {
        final key = syncRecordKey('history', ['prefix', 0]);
        final a = MergeDocument()
          ..captureLocal('legacy_seed', {}, {
            key: {'readDurationMs': 100},
          });
        a.captureLocal('A', a.materialize(), {
          key: {'readDurationMs': 110},
        });
        final b = a.clone();
        b.captureLocal('B', b.materialize(), {
          key: {'readDurationMs': 0},
        });
        final oldReset = b.clone();
        final reset = b.conflicts
            .firstWhere((item) => item.field == 'readDurationMs')
            .candidates
            .firstWhere((item) => item.value == 0);
        b.resolve('B', key, 'readDurationMs', reset.id);
        a.captureLocal('A', a.materialize(), {
          key: {'readDurationMs': 115},
        });
        final latest = a.clone();
        for (final order in [
          [b, latest, oldReset],
          [oldReset, latest, b],
          [latest, b, oldReset, b, latest],
        ]) {
          final merged = MergeDocument();
          for (final checkpoint in order) merged.merge(checkpoint);
          merged.merge(merged.clone());
          expect(merged.materialize()[key]!['readDurationMs'], 5);
          expect(merged.conflicts, isEmpty);
        }
        final keep = oldReset.clone();
        keep.resolve('C', key, 'readDurationMs', 'accumulated_total');
        keep.merge(oldReset);
        expect(keep.materialize()[key]!['readDurationMs'], 110);
        expect(keep.conflicts, isEmpty);
      },
    );

    test(
      'different legacy bases remain candidates but explicit resolution retires provenance',
      () {
        final key = syncRecordKey('history', ['legacy-values', 0]);
        final a = MergeDocument()
          ..captureLocal('legacy_A', {}, {
            key: {'readDurationMs': 100},
          });
        final b = MergeDocument()
          ..captureLocal('legacy_B', {}, {
            key: {'readDurationMs': 200},
          });
        a.merge(b);
        final old = a.clone();
        final conflict = a.conflicts.firstWhere(
          (item) => item.field == 'readDurationMs',
        );
        expect(
          conflict.candidates.map((item) => item.value),
          containsAll([100, 200]),
        );
        final chosen = conflict.candidates.firstWhere(
          (item) => item.value == 100,
        );
        a.resolve('C', key, 'readDurationMs', chosen.id);
        a.merge(old);
        expect(a.materialize()[key]!['readDurationMs'], 100);
        expect(a.conflicts, isEmpty);
      },
    );

    test(
      'same-dot forks reject baseline, cumulative, reset, resolution and retired values',
      () {
        final key = syncRecordKey('history', ['fork', 0]);
        for (final bootstrap in [false, true]) {
          final a = MergeDocument()
            ..captureLocal('A', {}, {
              key: {'readDurationMs': 100},
            }, bootstrap: bootstrap);
          final b = MergeDocument()
            ..captureLocal('A', {}, {
              key: {'readDurationMs': 200},
            }, bootstrap: bootstrap);
          expect(() => a.merge(b), throwsFormatException);
          expect(() => b.merge(a), throwsFormatException);
        }
        final seed = MergeDocument()
          ..captureLocal('A', {}, {
            key: {'readDurationMs': 100},
          });
        for (final values in [
          [110, 120],
          [0, 20],
        ]) {
          final a = seed.clone();
          final b = seed.clone();
          a.captureLocal('A', a.materialize(), {
            key: {'readDurationMs': values.first},
          });
          b.captureLocal('A', b.materialize(), {
            key: {'readDurationMs': values.last},
          });
          expect(() => a.merge(b), throwsFormatException);
        }
        final a = seed.clone();
        a.captureLocal('B', a.materialize(), {
          key: {'readDurationMs': 0},
        });
        final b = a.clone();
        final resetId = a.conflicts.first.candidates
            .firstWhere((item) => item.value == 0)
            .id;
        a.resolve('C', key, 'readDurationMs', resetId);
        b.resolve('C', key, 'readDurationMs', 'accumulated_total');
        expect(() => a.merge(b), throwsFormatException);

        final secret = MergeDocument()
          ..captureLocal('A', {}, {
            'R': {'value': 'old-secret'},
          });
        final old = secret.clone();
        secret.captureLocal('A', secret.materialize(), {
          'R': {'value': 'new'},
        });
        expect(
          canonicalSyncJson(secret.toJson()),
          isNot(contains('old-secret')),
        );
        final forged = MergeDocument()
          ..captureLocal('A', {}, {
            'R': {'value': 'forged'},
          });
        expect(() => secret.merge(forged), throwsFormatException);
        secret.merge(old);
        expect(secret.materialize()['R']!['value'], 'new');
      },
    );

    test(
      'observation branches use own contribution floor without importing field causality',
      () {
        final key = syncRecordKey('history', ['branch', 0]);
        final current = MergeDocument()
          ..captureLocal('A', {}, {
            key: {'readDurationMs': 10},
          });
        final observation = current.clone();
        current.captureLocal('A', current.materialize(), {
          key: {'readDurationMs': 20, 'x': 1},
        });
        observation.setCounterFloor('A', current.counterFor('A'));
        observation.captureLocal('A', observation.materialize(), {
          key: {'readDurationMs': 15, 'y': 2},
        }, contributionFloor: current);
        expect(observation.dominates(current), isFalse);
        current.merge(observation);
        expect(current.materialize()[key], {
          'readDurationMs': 25,
          'x': 1,
          'y': 2,
        });

        final recovery = MergeDocument()
          ..setCounterFloor('A', current.counterFor('A'));
        recovery.captureLocal(
          'A',
          {
            key: {'readDurationMs': 25},
          },
          {
            key: {'readDurationMs': 7},
          },
          contributionFloor: current,
        );
        current.merge(recovery);
        expect(
          current.materialize(
            preferred: {
              key: {'readDurationMs': 7},
            },
          )[key]!['readDurationMs'],
          7,
        );
        expect(
          current.conflicts.any((item) => item.field == 'readDurationMs'),
          isTrue,
        );
      },
    );

    test('safe labels hide WebDAV credentials and compound settings', () {
      for (final key in ['backupWebdav', 'webdavComicLibrary', 'ordinary']) {
        for (final value in [
          ['https://example.invalid', 'user', 'password-secret'],
          {'password': 'password-secret', 'token': 'token-secret'},
        ]) {
          final candidate = MergeCandidate(
            id: 'A:1',
            value: value,
            actor: 'A',
            counter: 1,
            isDeleted: false,
            recordKey: syncRecordKey('setting', [key]),
            field: 'value',
          );
          expect(candidate.safeLabel, isNot(contains('password-secret')));
          expect(candidate.safeLabel, isNot(contains('token-secret')));
        }
      }
    });

    test(
      'strict checkpoint schema rejects missing metadata and malformed candidates',
      () {
        expect(() => MergeDocument.fromJson({}), throwsFormatException);
        final doc = MergeDocument()
          ..captureLocal('A', {}, {
            'R': {'value': 1},
          });
        final json = doc.toJson();
        final records = json['records'] as Map;
        final field = ((records['R'] as Map)['fields'] as Map)['value'] as Map;
        (field['values'] as Map)['A:1'] = {'value': 2, 'deleted': false};
        expect(() => MergeDocument.fromJson(json), throwsFormatException);
        final batch = MergeBatch.create(actor: 'A', counter: 1, document: doc);
        final missingId = batch.toJson()..remove('id');
        expect(() => MergeBatch.fromJson(missingId), throwsFormatException);
      },
    );

    test(
      'observation policy projection retains tombstones but excludes unaccepted causality',
      () {
        final visible = syncRecordKey('setting', ['visible']);
        final private = syncRecordKey('setting', ['backupWebdav']);
        final full = MergeDocument()
          ..captureLocal('A', {}, {
            visible: {'value': 'old'},
            private: {
              'value': ['endpoint', 'password-secret'],
            },
          });
        final old = full.clone();
        full.captureLocal('A', full.materialize(), {
          private: {
            'value': ['endpoint', 'password-secret'],
          },
        });
        final observation = full.filterRecords((key) => key == visible);
        expect(observation.materialize(), isEmpty);
        expect(observation.dominates(full), isFalse);
        expect(
          canonicalSyncJson(observation.toJson()),
          isNot(contains('password-secret')),
        );
        final decoded = MergeDocument.fromJson(observation.toJson());
        expect(decoded.toJson(), observation.toJson());
        decoded.merge(old.filterRecords((key) => key == visible));
        expect(decoded.materialize(), isEmpty);

        final empty = full.filterRecords((_) => false);
        expect(MergeDocument.fromJson(empty.toJson()).materialize(), isEmpty);
        empty.merge(old);
        expect(empty.materialize()[visible]!['value'], 'old');
        expect(empty.materialize().containsKey(private), isTrue);

        // A received-but-unapplied record was excluded even when it used an actor
        // counter already present in the allocation floor.
        final incoming = old.clone();
        final branch = full.filterRecords((key) => key == visible);
        branch.captureLocal('A', branch.materialize(), {
          private: {'value': 'local'},
        });
        branch.merge(incoming);
        expect(
          branch.conflicts.any((item) => item.recordKey == private),
          isTrue,
        );
      },
    );
  });
}
