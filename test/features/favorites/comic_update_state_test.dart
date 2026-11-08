import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/models.dart';
import 'package:venera_plus/features/favorites/comic_update_state.dart';

ComicDetails _details({
  String? updateTime,
  Map<String, List<String>> tags = const {},
}) {
  return ComicDetails.fromJson({
    'title': 'Test Comic',
    'cover': 'cover.jpg',
    'sourceKey': 'test-source',
    'comicId': 'test-comic',
    'tags': tags,
    'updateTime': updateTime,
  });
}

void main() {
  group('ComicDetails.findUpdateTime', () {
    test('returns canonical date only for date-only inputs', () {
      final details1 = _details(updateTime: '2026-07-01');
      expect(details1.findUpdateTime(), '2026-07-01');

      final details2 = _details(updateTime: '2026-08-15');
      expect(details2.findUpdateTime(), '2026-08-15');

      for (final input in ['2026-7-1', '2026-07-1', '2026-7-01']) {
        expect(_details(updateTime: input).findUpdateTime(), '2026-07-01');
      }
      expect(_details(updateTime: '2026-11-4').findUpdateTime(), '2026-11-04');
      expect(
        _details(
          tags: {
            '更新': ['2026-9-16'],
          },
        ).findUpdateTime(),
        '2026-09-16',
      );
    });

    test(
      'returns normalized UTC ISO timestamp preserving fractional precision for datetime inputs',
      () {
        final details1 = _details(updateTime: '2026-07-01T08:00:00.123456Z');
        expect(details1.findUpdateTime(), '2026-07-01T08:00:00.123456Z');

        // Aware datetime with non-UTC offset normalizes to UTC ISO
        final details2 = _details(updateTime: '2026-07-01T10:00:00+02:00');
        expect(details2.findUpdateTime(), '2026-07-01T08:00:00.000Z');
      },
    );

    test(
      'returns normalized UTC ISO timestamp for epoch seconds and milliseconds',
      () {
        // 1782806400 corresponds to UTC 2026-06-30 08:00:00
        final expectedUtc = DateTime.fromMillisecondsSinceEpoch(
          1782806400 * 1000,
          isUtc: true,
        ).toIso8601String();
        expect(expectedUtc, '2026-06-30T08:00:00.000Z');

        final detailsSec = _details(updateTime: '1782806400');
        expect(detailsSec.findUpdateTime(), '2026-06-30T08:00:00.000Z');

        final detailsMs = _details(updateTime: '1782806400500');
        expect(detailsMs.findUpdateTime(), '2026-06-30T08:00:00.500Z');
      },
    );

    test(
      'tries all accepted update tag candidates if explicit field invalid',
      () {
        final details = _details(
          updateTime: 'not-a-valid-date',
          tags: {
            'author': ['Someone'],
            'update': ['also-invalid', '2026-07-05'],
          },
        );
        expect(details.findUpdateTime(), '2026-07-05');
      },
    );

    test('accepts all standard update tag namespace variants', () {
      for (final ns in ['更新', '最後更新', '最后更新', 'Update', 'LAST UPDATE ']) {
        final details = _details(
          updateTime: null,
          tags: {
            ns: ['2026-08-10'],
          },
        );
        expect(details.findUpdateTime(), '2026-08-10');
      }
    });

    test(
      'rejects dates outside year 2000-3000 for both date-only and datetime',
      () {
        final detailsOldDate = _details(updateTime: '1999-12-31');
        expect(detailsOldDate.findUpdateTime(), isNull);

        final detailsFarDate = _details(updateTime: '3001-01-01');
        expect(detailsFarDate.findUpdateTime(), isNull);

        final detailsOldTime = _details(updateTime: '1999-12-31T23:59:59Z');
        expect(detailsOldTime.findUpdateTime(), isNull);

        final detailsFarTime = _details(updateTime: '3001-01-01T00:00:00Z');
        expect(detailsFarTime.findUpdateTime(), isNull);
      },
    );
  });

  group('ComicUpdateSnapshot', () {
    test('null or empty catalog is not reliable data', () {
      final nullSnap = ComicUpdateSnapshot.fromChapters(null);
      expect(nullSnap.hasReliableChapters, isFalse);
      expect(nullSnap.chapterKeys, isEmpty);
      expect(nullSnap.chapterKeyFor('c1'), isNull);

      final emptySnap = ComicUpdateSnapshot.fromChapters(const {});
      expect(emptySnap.hasReliableChapters, isFalse);
      expect(emptySnap.chapterKeys, isEmpty);
      expect(emptySnap.chapterKeyFor('c1'), isNull);
    });

    test('unique chapter IDs ignore group names and encode unambiguously', () {
      final snap = ComicUpdateSnapshot.fromChapters({
        'c1': 'Chapter 1',
        'c2': 'Chapter 2',
      });
      expect(snap.hasReliableChapters, isTrue);
      expect(snap.chapterKeyFor('c1'), jsonEncode(['u', 'c1']));
      expect(
        snap.chapterKeyFor('c1', groupId: 'any_group'),
        jsonEncode(['u', 'c1']),
      );
      expect(snap.chapterKeys, contains(jsonEncode(['u', 'c1'])));
    });

    test('unique IDs containing slashes do not collide with grouped IDs', () {
      final snapUniqueSlash = ComicUpdateSnapshot.fromChapters({
        'vol/1': 'Chapter 1',
      });
      final keyUnique = snapUniqueSlash.chapterKeyFor('vol/1');
      expect(keyUnique, jsonEncode(['u', 'vol/1']));

      final snapGrouped = ComicUpdateSnapshot.fromChapters({
        'vol': {'1': 'Ch 1'},
        'extra': {'1': 'Ch 1 Extra'},
      });
      final keyGrouped = snapGrouped.chapterKeyFor('1', groupId: 'vol');
      expect(keyGrouped, jsonEncode(['g', 'vol', '1']));

      expect(keyUnique, isNot(equals(keyGrouped)));
    });

    test(
      'duplicate chapter IDs disambiguate using group ID and record lookup',
      () {
        final snap = ComicUpdateSnapshot.fromChapters({
          'Vol 1': {'1': 'Ch 1', '2': 'Ch 2'},
          'Vol 2': {'1': 'Extra 1', '3': 'Ch 3'},
        });
        final expectedKeys = {
          jsonEncode(['g', 'Vol 1', '1']),
          jsonEncode(['u', '2']),
          jsonEncode(['g', 'Vol 2', '1']),
          jsonEncode(['u', '3']),
        };
        expect(snap.chapterKeys, equals(expectedKeys));

        // Unique IDs ignore group names
        expect(snap.chapterKeyFor('2'), jsonEncode(['u', '2']));
        expect(snap.chapterKeyFor('3'), jsonEncode(['u', '3']));

        // Duplicate IDs require group ID
        expect(snap.chapterKeyFor('1'), isNull);
        expect(
          snap.chapterKeyFor('1', groupId: 'Vol 1'),
          jsonEncode(['g', 'Vol 1', '1']),
        );
        expect(
          snap.chapterKeyFor('1', groupId: 'Vol 2'),
          jsonEncode(['g', 'Vol 2', '1']),
        );
        expect(snap.chapterKeyFor('1', groupId: 'Vol 3'), isNull);
      },
    );

    test(
      'does not infer maxPage from max of chapterPageCounts and ignores nonpositive',
      () {
        final snap = ComicUpdateSnapshot.fromChapters(
          {'c1': '1', 'c2': '2'},
          maxPage: null,
          chapterPageCounts: {'c1': 15, 'c2': 25, 'c3': 0, 'c4': -1},
        );
        expect(snap.maxPage, isNull);
        expect(snap.chapterPageCounts[snap.chapterKeyFor('c1')], 15);
        expect(snap.chapterPageCounts[snap.chapterKeyFor('c2')], 25);
        expect(snap.chapterPageCounts.containsKey('c3'), isFalse);
        expect(snap.chapterPageCounts.containsKey('c4'), isFalse);
      },
    );

    test('collections in snapshot are unmodifiable', () {
      final snap = ComicUpdateSnapshot.fromChapters(
        {'c1': '1'},
        chapterPageCounts: {'c1': 10},
      );
      expect(() => snap.chapterKeys.add('other'), throwsUnsupportedError);
      expect(() => snap.chapterPageCounts['c1'] = 20, throwsUnsupportedError);
    });
  });

  group('ComicUpdateState observations and transitions', () {
    test('no signals results in unknown status and leaves state unchanged', () {
      const state = ComicUpdateState.empty();
      final snap = ComicUpdateSnapshot.fromChapters(null);
      final obs = state.observe(snap);

      expect(obs.status, ComicUpdateCheckStatus.unknown);
      expect(obs.newChapterCount, 0);
      expect(obs.state, equals(state));
    });

    test(
      'first reliable basis establishes baseline without marking updates',
      () {
        const state = ComicUpdateState.empty();
        final snap = ComicUpdateSnapshot.fromChapters(
          {'c1': '1', 'c2': '2'},
          updateTime: '2026-07-01',
          maxPage: 30,
        );
        final obs = state.observe(snap);

        expect(obs.status, ComicUpdateCheckStatus.baseline);
        expect(obs.newChapterCount, 0);
        expect(obs.state.hasNewUpdate, isFalse);
        expect(obs.state.hasBaseline, isTrue);
        expect(obs.state.updateTime, '2026-07-01');
        expect(obs.state.maxPage, 30);
      },
    );

    test(
      'first reliable dimension introduced after time-only baseline yields baseline status',
      () {
        final legacy = ComicUpdateState.fromLegacy(
          updateTime: '2026-07-01',
          unread: false,
        );
        expect(legacy.hasBaseline, isTrue);
        expect(legacy.knownChapterKeys, isEmpty);

        final snap = ComicUpdateSnapshot.fromChapters({
          'c1': '1',
          'c2': '2',
        }, updateTime: '2026-07-01');
        final obs = legacy.observe(snap);

        expect(obs.status, ComicUpdateCheckStatus.baseline);
        expect(obs.newChapterCount, 0);
        expect(obs.state.hasNewUpdate, isFalse);
        expect(obs.state.knownChapterKeys.length, 2);

        final obsNext = obs.state.observe(snap);
        expect(obsNext.status, ComicUpdateCheckStatus.unchanged);
        expect(obsNext.newChapterCount, 0);
      },
    );

    test('baseline A:1 then A:1, B:1 reports 1 addition', () {
      final snap1 = ComicUpdateSnapshot.fromChapters({
        'A': {'1': 'a'},
      });
      final baseline = const ComicUpdateState.empty().observe(snap1).state;

      final snap2 = ComicUpdateSnapshot.fromChapters({
        'A': {'1': 'a'},
        'B': {'1': 'b'},
      });
      final obs = baseline.observe(snap2);

      expect(obs.status, ComicUpdateCheckStatus.updated);
      expect(obs.newChapterCount, 1);
      expect(obs.state.hasNewUpdate, isTrue);
    });

    test('full duplicate A:1, B:1 to partial A:1 reports 0 additions', () {
      final snapFull = ComicUpdateSnapshot.fromChapters({
        'A': {'1': 'a'},
        'B': {'1': 'b'},
      });
      final baseline = const ComicUpdateState.empty().observe(snapFull).state;

      final snapPartial = ComicUpdateSnapshot.fromChapters({
        'A': {'1': 'a'},
      });
      final obs = baseline.observe(snapPartial);

      expect(obs.status, ComicUpdateCheckStatus.unchanged);
      expect(obs.newChapterCount, 0);
      expect(obs.state.hasNewUpdate, isFalse);
    });

    test('unique ID group rename does not trigger update', () {
      final snap1 = ComicUpdateSnapshot.fromChapters({
        'Group A': {'c1': '1'},
      });
      final baseline = const ComicUpdateState.empty().observe(snap1).state;

      final snapRenamed = ComicUpdateSnapshot.fromChapters({
        'Group B': {'c1': '1'},
      });
      final obs = baseline.observe(snapRenamed);

      expect(obs.status, ComicUpdateCheckStatus.unchanged);
      expect(obs.newChapterCount, 0);
      expect(obs.state.hasNewUpdate, isFalse);
    });

    test('forward source timestamp and same-second fractional growth', () {
      final snap1 = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
      }, updateTime: '2026-07-01T08:00:00.100Z');
      final baseline = const ComicUpdateState.empty().observe(snap1).state;

      // Equivalent offset representation is not forward
      final snapEquivalent = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
      }, updateTime: '2026-07-01T10:00:00.100+02:00');
      final obsEq = baseline.observe(snapEquivalent);
      expect(obsEq.status, ComicUpdateCheckStatus.unchanged);
      expect(obsEq.state.hasNewUpdate, isFalse);

      // Same-second fractional growth is detected as forward
      final snapFrac = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
      }, updateTime: '2026-07-01T08:00:00.500Z');
      final obsFrac = baseline.observe(snapFrac);
      expect(obsFrac.status, ComicUpdateCheckStatus.updated);
      expect(obsFrac.state.hasNewUpdate, isTrue);
      expect(obsFrac.state.updateTime, '2026-07-01T08:00:00.500Z');
    });

    test(
      'same-day precision upgrade is not forward independent of local process TZ',
      () {
        final baseline = ComicUpdateState.fromLegacy(
          updateTime: '2026-07-01',
          unread: false,
        );

        final snap = ComicUpdateSnapshot.fromChapters({
          'c1': '1',
        }, updateTime: '2026-07-01T08:00:00.000Z');
        final obs = baseline.observe(snap);

        expect(obs.status, ComicUpdateCheckStatus.baseline);
        expect(obs.newChapterCount, 0);
        expect(obs.state.hasNewUpdate, isFalse);
        expect(obs.state.updateTime, '2026-07-01T08:00:00.000Z');
      },
    );

    test('compares unpadded legacy dates in calendar order', () {
      final baseline = ComicUpdateState.fromLegacy(updateTime: '2026-9-16');
      for (final time in ['2026-8-20', '2026-09-16']) {
        final observation = baseline.observe(
          ComicUpdateSnapshot.fromChapters(null, updateTime: time),
        );
        expect(observation.status, ComicUpdateCheckStatus.unchanged);
        expect(observation.state.hasNewUpdate, isFalse);
      }
      final observation = baseline.observe(
        ComicUpdateSnapshot.fromChapters(null, updateTime: '2026-11-4'),
      );
      expect(observation.status, ComicUpdateCheckStatus.updated);
      expect(observation.state.updateTime, '2026-11-4');
      expect(observation.state.hasNewUpdate, isTrue);
    });

    test('invalid legacy timestamp does not dominate future valid data', () {
      final legacy = ComicUpdateState.fromLegacy(
        updateTime: 'corrupt-date-string',
        unread: false,
      );

      final snap = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
      }, updateTime: '2026-07-01');
      final obs = legacy.observe(snap);

      expect(obs.state.updateTime, '2026-07-01');
    });

    test(
      'per-chapter page growth is detected and retained as pending even if overall max is unchanged',
      () {
        final snap1 = ComicUpdateSnapshot.fromChapters(
          {'c1': '1', 'c2': '2'},
          maxPage: 100,
          chapterPageCounts: {'c1': 10, 'c2': 100},
        );
        final baseline = const ComicUpdateState.empty().observe(snap1).state;

        // c1 grows from 10 to 11 pages, but c2:100 and overall maxPage:100 stay unchanged
        final snap2 = ComicUpdateSnapshot.fromChapters(
          {'c1': '1', 'c2': '2'},
          maxPage: 100,
          chapterPageCounts: {'c1': 11, 'c2': 100},
        );
        final obs = baseline.observe(snap2);

        expect(obs.status, ComicUpdateCheckStatus.updated);
        expect(obs.state.hasNewUpdate, isTrue);

        final ackC1 = obs.state.acknowledgeSnapshot(
          snap2,
          chapterId: 'c1',
          isLastChapter: false,
        );
        expect(ackC1.hasNewUpdate, isFalse);

        final snap3 = ComicUpdateSnapshot.fromChapters(
          {'c1': '1', 'c2': '2'},
          maxPage: 100,
          chapterPageCounts: {'c1': 12, 'c2': 100},
        );
        final obs3 = ackC1.observe(snap3);
        expect(obs3.status, ComicUpdateCheckStatus.updated);
        expect(obs3.state.hasNewUpdate, isTrue);
      },
    );
  });

  group('Acknowledgments', () {
    test(
      'acknowledgeSnapshot does not fall back to persisted updateTime or maxPage when reader lacks them',
      () {
        final snap1 = ComicUpdateSnapshot.fromChapters(
          {'c1': '1'},
          updateTime: '2026-07-01T08:00:00Z',
          maxPage: 50,
        );
        final baseline = const ComicUpdateState.empty().observe(snap1).state;

        // Update arrives with newer timestamp and higher maxPage
        final snap2 = ComicUpdateSnapshot.fromChapters(
          {'c1': '1'},
          updateTime: '2026-07-02T08:00:00Z',
          maxPage: 60,
        );
        final updated = baseline.observe(snap2).state;
        expect(updated.hasNewUpdate, isTrue);

        // Reader snapshot has NO updateTime and NO maxPage
        final readerSnap = ComicUpdateSnapshot.fromChapters(
          {'c1': '1'},
          updateTime: null,
          maxPage: null,
        );
        final acked = updated.acknowledgeSnapshot(
          readerSnap,
          chapterId: 'c1',
          isLastChapter: true,
        );

        // Must not fall back to state.updateTime / state.maxPage as completion evidence
        expect(acked.acknowledgedUpdateTime, isNull);
        expect(acked.acknowledgedMaxPage, isNull);
        // Because 2026-07-02 update was not seen/acknowledged in readerSnap, update remains pending!
        expect(acked.hasNewUpdate, isTrue);
      },
    );

    test(
      'completing B from a partial single-group snapshot does not acknowledge A',
      () {
        final snapSeed = ComicUpdateSnapshot.fromChapters({
          'old': {'old': 'Old'},
        });
        final baseline = const ComicUpdateState.empty().observe(snapSeed).state;

        // Add A:1 and B:1 so both are truly pending chapter updates
        final snapUpdate = ComicUpdateSnapshot.fromChapters({
          'old': {'old': 'Old'},
          'A': {'1': 'a'},
          'B': {'1': 'b'},
        });
        final updated = baseline.observe(snapUpdate).state;
        expect(updated.hasNewUpdate, isTrue);

        // User reads only group B in a partial snapshot
        final snapB = ComicUpdateSnapshot.fromChapters({
          'B': {'1': 'b'},
        });
        final ackB = updated.acknowledgeSnapshot(
          snapB,
          chapterId: '1',
          groupId: 'B',
          isLastChapter: false,
        );

        // Group A must remain unacknowledged
        expect(ackB.hasNewUpdate, isTrue);
      },
    );

    test(
      'completing A and B from full catalog clears pending updates without orphaning unique identities',
      () {
        final snapSeed = ComicUpdateSnapshot.fromChapters({
          'old': {'old': 'Old'},
        });
        final baseline = const ComicUpdateState.empty().observe(snapSeed).state;

        // First observe single-group A:1 (appears unique in this snapshot)
        final snapSingle = ComicUpdateSnapshot.fromChapters({
          'old': {'old': 'Old'},
          'A': {'1': 'a'},
        });
        final stateSingle = baseline.observe(snapSingle).state;
        expect(stateSingle.hasNewUpdate, isTrue);

        // Next observe full duplicate A:1, B:1
        final snapFull = ComicUpdateSnapshot.fromChapters({
          'old': {'old': 'Old'},
          'A': {'1': 'a'},
          'B': {'1': 'b'},
        });
        final stateFull = stateSingle.observe(snapFull).state;
        expect(stateFull.hasNewUpdate, isTrue);

        // Completing A from full catalog
        final ackA = stateFull.acknowledgeSnapshot(
          snapFull,
          chapterId: '1',
          groupId: 'A',
          isLastChapter: false,
        );
        expect(ackA.hasNewUpdate, isTrue);

        // Completing B from full catalog
        final ackAll = ackA.acknowledgeSnapshot(
          snapFull,
          chapterId: '1',
          groupId: 'B',
          isLastChapter: true,
        );
        expect(ackAll.hasNewUpdate, isFalse);
      },
    );

    test(
      'acknowledgeSnapshot on final chapter only acknowledges completed chapter identity',
      () {
        final snap1 = ComicUpdateSnapshot.fromChapters({'c1': '1'});
        final baseline = const ComicUpdateState.empty().observe(snap1).state;

        final snap2 = ComicUpdateSnapshot.fromChapters({
          'c1': '1',
          'c2': '2',
          'c3': '3',
        }, updateTime: '2026-07-02');
        final updated = baseline.observe(snap2).state;
        expect(updated.hasNewUpdate, isTrue);

        // User jumps to and only finishes final chapter c3!
        final ackC3Only = updated.acknowledgeSnapshot(
          snap2,
          chapterId: 'c3',
          isLastChapter: true,
        );

        // c2 is STILL unacknowledged! hasNewUpdate MUST remain true!
        expect(ackC3Only.hasNewUpdate, isTrue);

        // Now user reads c2
        final ackAll = ackC3Only.acknowledgeSnapshot(
          snap2,
          chapterId: 'c2',
          isLastChapter: false,
        );
        expect(ackAll.hasNewUpdate, isFalse);
      },
    );

    test('acknowledgeAll confirms currently known items, not future items', () {
      final snap1 = ComicUpdateSnapshot.fromChapters({'c1': '1'});
      final baseline = const ComicUpdateState.empty().observe(snap1).state;

      final snap2 = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
        'c2': '2',
      }, updateTime: '2026-07-02');
      final updated = baseline.observe(snap2).state;
      expect(updated.hasNewUpdate, isTrue);

      final acked = updated.acknowledgeAll();
      expect(acked.hasNewUpdate, isFalse);

      final snap3 = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
        'c2': '2',
        'c3': '3',
      }, updateTime: '2026-07-03');
      final obs3 = acked.observe(snap3);
      expect(obs3.status, ComicUpdateCheckStatus.updated);
      expect(obs3.newChapterCount, 1);
      expect(obs3.state.hasNewUpdate, isTrue);
    });
  });

  group('CRDT Merge and exact neutral element', () {
    test(
      'exact neutral element preserves pre-baseline completion evidence',
      () {
        final snapReader = ComicUpdateSnapshot.fromChapters({'c1': '1'});
        final devAPreBaseline = const ComicUpdateState.empty()
            .acknowledgeSnapshot(
              snapReader,
              chapterId: 'c1',
              isLastChapter: true,
            );
        expect(devAPreBaseline.isEmpty, isFalse);

        final devB = const ComicUpdateState.empty().observe(snapReader).state;

        final merged = devAPreBaseline.merge(devB);
        expect(merged.hasNewUpdate, isFalse);
        expect(
          merged.acknowledgedChapterKeys,
          contains(snapReader.chapterKeyFor('c1')),
        );
      },
    );

    test('merge is commutative, associative, and idempotent', () {
      final s1 = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
      }, updateTime: '2026-07-01');
      final a = const ComicUpdateState.empty().observe(s1).state;

      final s2 = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
        'c2': '2',
      }, updateTime: '2026-07-02');
      final b = a.observe(s2).state;

      final s3 = ComicUpdateSnapshot.fromChapters({
        'c1': '1',
        'c3': '3',
      }, updateTime: '2026-07-03');
      final c = a.observe(s3).state;

      final states = [
        a,
        b,
        c,
        ComicUpdateState.fromLegacy(updateTime: 'broken-a'),
        ComicUpdateState.fromLegacy(updateTime: 'broken-b', unread: true),
      ];
      for (final first in states) {
        expect(first.merge(first), equals(first));
        for (final second in states) {
          expect(first.merge(second), equals(second.merge(first)));
          for (final third in states) {
            expect(
              first.merge(second).merge(third),
              equals(first.merge(second.merge(third))),
            );
          }
        }
      }
    });

    test('multi-device merge does not drop discoveries or swallow updates', () {
      final s1 = ComicUpdateSnapshot.fromChapters({'c1': '1'});
      final baseline = const ComicUpdateState.empty().observe(s1).state;

      final devA = baseline
          .observe(ComicUpdateSnapshot.fromChapters({'c1': '1', 'c2': '2'}))
          .state;

      final devB = baseline
          .observe(ComicUpdateSnapshot.fromChapters({'c1': '1', 'c3': '3'}))
          .state;

      final merged = devA.merge(devB);
      expect(merged.hasNewUpdate, isTrue);
      expect(merged.updatedChapterKeys.length, 2);
    });
  });

  group('Strict serialization schema', () {
    test(
      'toJson produces version 1 and fromJson roundtrips deterministically',
      () {
        final snap = ComicUpdateSnapshot.fromChapters(
          {'c1': '1', 'c2': '2'},
          updateTime: '2026-07-01',
          maxPage: 40,
          chapterPageCounts: {'c1': 20, 'c2': 20},
        );
        final state = const ComicUpdateState.empty().observe(snap).state;

        final json = state.toJson();
        expect(json['version'], 1);

        final restored = ComicUpdateState.fromJson(json);
        expect(restored, equals(state));

        final jsonStr1 = jsonEncode(state.toJson());
        final jsonStr2 = jsonEncode(restored.toJson());
        expect(jsonStr1, equals(jsonStr2));
      },
    );

    test('fromJson rejects unknown versions and non-Map inputs', () {
      expect(
        () => ComicUpdateState.fromJson('string-not-map'),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => ComicUpdateState.fromJson({'version': 2}),
        throwsA(isA<FormatException>()),
      );

      expect(
        () => ComicUpdateState.fromJson({'version': '1'}),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'fromJson rejects invalid types, negative counts, and invalid chapter keys',
      () {
        expect(
          () => ComicUpdateState.fromJson({'version': 1, 'maxPage': -5}),
          throwsA(isA<FormatException>()),
        );

        expect(
          () => ComicUpdateState.fromJson({'version': 1, 'maxPage': 0}),
          throwsA(isA<FormatException>()),
        );

        expect(
          () => ComicUpdateState.fromJson({
            'version': 1,
            'knownChapterKeys': ['not-json-encoded-key'],
          }),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'sparse, unknown, and duplicate chapterPageCounts keys roundtrip safely',
      () {
        final snap = ComicUpdateSnapshot.fromChapters(
          {
            'A': {'1': 'Ch 1'},
            'B': {'1': 'Extra 1', '2': 'Ch 2'},
          },
          maxPage: 50,
          chapterPageCounts: {
            '2': 25, // unique chapter in catalog -> normalized
            '1': 30, // ambiguous duplicate chapter without group -> ignored
            'unknown_id': 99, // unknown ID not in catalog -> ignored
            'negative_id': -10, // nonpositive -> ignored
            'zero_id': 0, // nonpositive -> ignored
          },
        );

        final state = const ComicUpdateState.empty().observe(snap).state;
        final json = state.toJson();

        // fromJson strictly validates all keys and must not throw FormatException
        final restored = ComicUpdateState.fromJson(json);
        expect(restored, equals(state));
        final grown = ComicUpdateSnapshot.fromChapters(
          {
            'A': {'1': 'Ch 1'},
            'B': {'1': 'Extra 1', '2': 'Ch 2'},
          },
          maxPage: 50,
          chapterPageCounts: {'2': 26},
        );
        final update = restored.observe(grown);
        expect(update.status, ComicUpdateCheckStatus.updated);
        expect(update.state.hasNewUpdate, isTrue);
        expect(
          update.state
              .acknowledgeSnapshot(
                grown,
                chapterId: '2',
                groupId: 'B',
                isLastChapter: true,
              )
              .hasNewUpdate,
          isFalse,
        );
      },
    );
  });
}
