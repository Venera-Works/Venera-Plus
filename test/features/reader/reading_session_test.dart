import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/reader/reader.dart';

void main() {
  tearDown(ReadingSessionTracker.debugResetForTesting);

  test(
    'shutdown drains a session already disposing before its final writer runs',
    () async {
      var elapsed = Duration.zero;
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final firstWrite = Completer<void>();
      final secondWrite = Completer<void>();
      addTearDown(() {
        if (!firstWrite.isCompleted) firstWrite.complete();
        if (!secondWrite.isCompleted) secondWrite.complete();
      });
      final recorded = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          recorded.add(duration);
          if (recorded.length == 1) {
            firstStarted.complete();
            await firstWrite.future;
          } else {
            secondStarted.complete();
            await secondWrite.future;
          }
        },
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      final checkpoint = tracker.checkpoint();
      await firstStarted.future;
      elapsed = const Duration(seconds: 15);
      final disposing = tracker.dispose();
      expect(tracker.dispose(), same(disposing));
      var finished = false;
      final shutdown = ReadingSessionTracker.finishAll().then(
        (_) => finished = true,
      );
      expect(tracker.isRunning, isFalse);
      expect(finished, isFalse);
      firstWrite.complete();
      await secondStarted.future;
      expect(recorded, const [Duration(seconds: 10), Duration(seconds: 5)]);
      expect(finished, isFalse);
      secondWrite.complete();
      await Future.wait([checkpoint, disposing, shutdown]);
      expect(finished, isTrue);
    },
  );

  test(
    'an old pause completion cannot unregister a restarted session',
    () async {
      var elapsed = Duration.zero;
      final firstStarted = Completer<void>();
      final firstWrite = Completer<void>();
      addTearDown(() {
        if (!firstWrite.isCompleted) firstWrite.complete();
      });
      final recorded = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          recorded.add(duration);
          if (recorded.length == 1) {
            firstStarted.complete();
            await firstWrite.future;
          }
        },
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      final checkpoint = tracker.checkpoint();
      await firstStarted.future;
      elapsed = const Duration(seconds: 15);
      final pause = tracker.pause();
      tracker.start();
      elapsed = const Duration(seconds: 20);
      firstWrite.complete();
      await Future.wait([checkpoint, pause]);
      expect(tracker.isRunning, isTrue);
      await ReadingSessionTracker.finishAll();
      expect(recorded, const [
        Duration(seconds: 10),
        Duration(seconds: 5),
        Duration(seconds: 5),
      ]);
      expect(tracker.isRunning, isFalse);
    },
  );

  test(
    'a reported checkpoint failure blocks shutdown without retrying duration',
    () async {
      var elapsed = Duration.zero;
      var writes = 0;
      final failure = StateError('duration write failed');
      final reported = <Object>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (_) async {
          writes++;
          throw failure;
        },
        onError: (error, _) => reported.add(error),
      );
      tracker.start();
      elapsed = const Duration(seconds: 10);
      await tracker.checkpoint();
      expect(reported, [same(failure)]);
      await expectLater(
        ReadingSessionTracker.finishAll(),
        throwsA(same(failure)),
      );
      await expectLater(
        ReadingSessionTracker.finishAll(),
        throwsA(same(failure)),
      );
      expect(writes, 1);
      expect(reported, [same(failure)]);
    },
  );
  test(
    'reading session records checkpoints and excludes paused time',
    () async {
      var elapsed = Duration.zero;
      final recorded = <Duration>[];
      final tracker = ReadingSessionTracker(
        elapsedNow: () => elapsed,
        checkpointInterval: const Duration(days: 1),
        onDuration: (duration) async {
          recorded.add(duration);
        },
      );

      tracker.start();
      elapsed = const Duration(seconds: 45);
      await tracker.checkpoint();
      elapsed = const Duration(minutes: 1);
      await tracker.pause();

      elapsed = const Duration(minutes: 10);
      tracker.start();
      elapsed = const Duration(minutes: 10, seconds: 30);
      await tracker.dispose();

      expect(recorded, const [
        Duration(seconds: 45),
        Duration(seconds: 15),
        Duration(seconds: 30),
      ]);
    },
  );

  test('reading session start and dispose are idempotent', () async {
    var elapsed = Duration.zero;
    final recorded = <Duration>[];
    final tracker = ReadingSessionTracker(
      elapsedNow: () => elapsed,
      checkpointInterval: const Duration(days: 1),
      onDuration: (duration) async {
        recorded.add(duration);
      },
    );

    tracker.start();
    tracker.start();
    elapsed = const Duration(seconds: 20);
    await tracker.dispose();
    elapsed = const Duration(seconds: 40);
    tracker.start();
    await tracker.dispose();

    expect(recorded, const [Duration(seconds: 20)]);
    expect(tracker.isRunning, isFalse);
  });
}
