import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/history/reading_progress.dart';

void main() {
  group('ReadingProgress join semantics', () {
    test('maximum joins are idempotent, commutative, and associative', () {
      final first = ReadingProgress.seed(
        const ReadingPosition(ep: 1, page: 8),
        time: 900,
      );
      final second = ReadingProgress.seed(
        const ReadingPosition(ep: 2, page: 3),
        time: 100,
      );
      final third = ReadingProgress.seed(
        const ReadingPosition(ep: 3, page: 1),
        time: 500,
      );

      expect(first.merge(first).toJson(), first.toJson());
      expect(first.merge(second).toJson(), second.merge(first).toJson());
      expect(
        first.merge(second).merge(third).toJson(),
        first.merge(second.merge(third)).toJson(),
      );
      expect(first.merge(second).maximumPositions, const [
        ReadingPosition(ep: 2, page: 3),
      ]);
      expect(first.merge(second).time, 900);
    });

    test(
      'catalog insertion rebases stable chapters and conflict stays visible',
      () {
        final oldCatalog = ReadingCatalog(const [
          ReadingChapter(id: 'a', ep: 1),
          ReadingChapter(id: 'b', ep: 2),
        ]);
        final progress = ReadingProgress.seed(
          const ReadingPosition(ep: 2, page: 4, chapterId: 'b'),
          catalog: oldCatalog,
        );
        final insertedCatalog = ReadingCatalog(const [
          ReadingChapter(id: 'x', ep: 1),
          ReadingChapter(id: 'a', ep: 2),
          ReadingChapter(id: 'b', ep: 3),
        ]);
        final rebased = progress.rebaseCatalog(insertedCatalog);
        expect(rebased.maximumPositions.single.ep, 3);
        expect(rebased.maximumPositions.single.chapterId, 'b');

        final reordered = ReadingCatalog(const [
          ReadingChapter(id: 'b', ep: 1),
          ReadingChapter(id: 'a', ep: 2),
        ]);
        final conflict = progress.merge(
          ReadingProgress.seed(
            const ReadingPosition(ep: 2, page: 4, chapterId: 'a'),
            catalog: reordered,
          ),
        );
        expect(conflict.hasOrderConflict, isTrue);
        expect(conflict.resumePosition, isNull);
        expect(
          conflict.maximumPositions
              .map((position) => position.chapterId)
              .toSet(),
          {'a', 'b'},
        );

        final resolved = conflict.rebaseCatalog(oldCatalog);
        expect(resolved.hasOrderConflict, isFalse);
        expect(resolved.resumePosition?.chapterId, 'b');

        final singleChapterCatalog = ReadingCatalog(const [
          ReadingChapter(id: 'only', ep: 1),
        ]);
        final single = ReadingProgress.seed(
          const ReadingPosition(ep: 1, page: 6, chapterId: 'only'),
          catalog: singleChapterCatalog,
        );
        expect(single.resumePosition?.ep, 1);
        expect(single.resumePosition?.page, 6);
      },
    );
  });

  group('ReadingProgress reread lifecycle', () {
    test(
      'forward joins one round; a genuine rewind replaces it; end is final',
      () {
        const anchor = ReadingPosition(ep: 10, page: 1);
        final maximum = ReadingProgress.seed(anchor, time: 100);
        final firstRound = maximum.record(
          const ReadingPosition(ep: 2, page: 2),
          source: ReadingNavigationSource.userBackward,
          newRoundId: 'round-a',
          time: 200,
        );
        expect(firstRound.maximumPositions, const [anchor]);
        expect(
          firstRound.resumePosition,
          const ReadingPosition(ep: 2, page: 2),
        );

        final forward = firstRound.record(
          const ReadingPosition(ep: 2, page: 5),
          source: ReadingNavigationSource.userSeek,
          sessionRoundId: 'round-a',
          newRoundId: 'not-a-rewind',
          time: 50,
        );
        expect(forward.activeRoundId, 'round-a');
        expect(forward.resumePosition, const ReadingPosition(ep: 2, page: 5));
        expect(forward.maximumPositions, const [anchor]);

        final secondRound = forward.record(
          const ReadingPosition(ep: 2, page: 3),
          source: ReadingNavigationSource.userBackward,
          sessionRoundId: 'round-a',
          newRoundId: 'round-b',
          time: 300,
          observedRoundIds: const ['round-a'],
        );
        expect(secondRound.activeRoundId, 'round-b');
        expect(secondRound.toJson()['retired'], ['round-a']);
        expect(secondRound.maximumPositions, const [anchor]);

        final delayedFirstRound = secondRound.merge(firstRound);
        expect(delayedFirstRound.activeRoundId, 'round-b');
        expect(delayedFirstRound.toJson()['retired'], ['round-a']);

        final ended = delayedFirstRound.record(
          anchor,
          source: ReadingNavigationSource.automatic,
          sessionRoundId: 'round-b',
          time: 400,
        );
        expect(ended.activeRoundId, isNull);
        expect(ended.toJson()['ended'], ['round-b']);
        expect(ended.resumePosition, anchor);
        expect(ended.merge(secondRound).activeRoundId, isNull);
      },
    );

    test(
      'a normal session cannot adopt an imported round and seek ends only observed roots',
      () {
        final maximum = ReadingProgress.seed(
          const ReadingPosition(ep: 10, page: 1),
        );
        final observed = maximum.record(
          const ReadingPosition(ep: 2, page: 1),
          source: ReadingNavigationSource.userBackward,
          newRoundId: 'observed',
        );
        final concurrent = maximum.record(
          const ReadingPosition(ep: 3, page: 1),
          source: ReadingNavigationSource.userBackward,
          newRoundId: 'concurrent',
        );
        final merged = observed.merge(concurrent);
        final oldSession = merged.record(
          const ReadingPosition(ep: 4, page: 1),
          source: ReadingNavigationSource.automatic,
        );
        expect(oldSession.activeRoundIds.toSet(), {'concurrent', 'observed'});

        final seekToMaximum = oldSession.record(
          const ReadingPosition(ep: 10, page: 1),
          source: ReadingNavigationSource.userSeek,
          observedRoundIds: const ['observed'],
        );
        expect(seekToMaximum.activeRoundIds.toSet(), {'concurrent'});
        expect(seekToMaximum.toJson()['ended'], ['observed']);
      },
    );

    test(
      'confirming a visible position is not a rewind and ends only observed rounds',
      () {
        final maximum = ReadingProgress.seed(
          const ReadingPosition(ep: 1, page: 10),
        );
        final reread = maximum
            .record(
              const ReadingPosition(ep: 1, page: 2),
              source: ReadingNavigationSource.userBackward,
              newRoundId: 'reread',
            )
            .record(
              const ReadingPosition(ep: 1, page: 4),
              source: ReadingNavigationSource.userForward,
              sessionRoundId: 'reread',
            );
        final confirmed = reread.record(
          const ReadingPosition(ep: 1, page: 3),
          source: ReadingNavigationSource.userConfirm,
          sessionRoundId: 'reread',
          newRoundId: 'not-a-rewind',
        );
        expect(confirmed.activeRoundIds.toList(), ['reread']);
        expect(confirmed.resumePosition?.page, 4);
        final concurrent = maximum.record(
          const ReadingPosition(ep: 1, page: 5),
          source: ReadingNavigationSource.userBackward,
          newRoundId: 'unobserved',
        );
        final ended = confirmed
            .merge(concurrent)
            .record(
              const ReadingPosition(ep: 1, page: 10),
              source: ReadingNavigationSource.userConfirm,
              observedRoundIds: const ['reread'],
            );
        expect(ended.activeRoundIds.toList(), ['unobserved']);
        expect(ended.toJson()['ended'], ['reread']);
      },
    );

    test('unknown integer wire versions are protocol incompatibility', () {
      expect(
        () => ReadingProgress.fromJson({'version': 2}),
        throwsA(isA<UnsupportedReadingProgressVersionException>()),
      );
    });
  });
}
