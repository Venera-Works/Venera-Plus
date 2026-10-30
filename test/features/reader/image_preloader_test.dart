import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/reader/image_preloader.dart';
import 'package:venera_plus/foundation/log.dart';

void main() {
  late ReaderImagePreloader preloader;
  late List<String> started;
  late Map<String, Completer<void>> gates;

  ReaderImagePreload task(String key, {bool Function()? isCached}) =>
      ReaderImagePreload(
        key: key,
        isCached: isCached,
        load: () {
          started.add(key);
          return (gates[key] = Completer<void>()).future;
        },
      );

  Future<void> finish(String key) async {
    gates[key]!.complete();
    await pumpEventQueue();
  }

  setUp(() {
    preloader = ReaderImagePreloader();
    started = [];
    gates = {};
  });

  tearDown(() async {
    preloader.dispose();
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await pumpEventQueue();
  });

  test(
    'prepares the full window in proximity order with two active pages',
    () async {
      final window = [
        task('next'),
        task('previous'),
        task('next-2'),
        task('next-3'),
        task('next-4'),
      ];
      preloader.update(window);
      expect(started, ['next', 'previous']);
      await finish('previous');
      expect(started, ['next', 'previous', 'next-2']);
      await finish('next');
      expect(started.last, 'next-3');
      await finish('next-2');
      expect(started.last, 'next-4');
      await finish('next-3');
      await finish('next-4');
      preloader.update(window);
      expect(started, ['next', 'previous', 'next-2', 'next-3', 'next-4']);
    },
  );

  test(
    'navigation replaces queued pages before another slot is released',
    () async {
      preloader.update([
        task('old-active'),
        task('other-active'),
        task('old-queued'),
      ]);
      preloader.update([
        task('new-next'),
        task('new-previous'),
        task('new-far'),
      ]);
      await finish('old-active');
      expect(started, ['old-active', 'other-active', 'new-next']);
      await finish('other-active');
      expect(started.last, 'new-previous');
      await finish('new-next');
      expect(started.last, 'new-far');
      expect(started, isNot(contains('old-queued')));
    },
  );

  test('split pages sharing one source are prepared only once', () async {
    final window = [task('split-source'), task('split-source'), task('next')];
    preloader.update(window);
    expect(started, ['split-source', 'next']);
    preloader.update(window);
    await finish('split-source');
    await finish('next');
    preloader.update(window);
    expect(started, ['split-source', 'next']);
  });

  test(
    'scrolling pauses queued work until the final page is selected',
    () async {
      preloader.update([task('first'), task('second'), task('old-queued')]);
      preloader.setPaused(true);
      await finish('first');
      await finish('second');
      expect(started, ['first', 'second']);
      preloader.update([task('midpoint')]);
      preloader.update([task('final-next'), task('final-previous')]);
      preloader.setPaused(false);
      expect(started, ['first', 'second', 'final-next', 'final-previous']);
    },
  );

  test('failed preloads do not loop or block subsequent pages', () async {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    preloader.update([task('bad'), task('next'), task('later')]);
    gates['bad']!.completeError(StateError('download failed'));
    await pumpEventQueue();
    expect(started, ['bad', 'next', 'later']);
    preloader.update([task('bad'), task('next'), task('later')]);
    await finish('next');
    expect(started, ['bad', 'next', 'later']);
  });

  test('evicted images are prepared again only on a window update', () async {
    var cached = true;
    final window = [task('page', isCached: () => cached)];
    preloader.update(window);
    await finish('page');
    preloader.update(window);
    expect(started, ['page']);
    cached = false;
    preloader.update(window);
    expect(started, ['page', 'page']);
    await finish('page');
    expect(started, ['page', 'page']);
  });

  test('failed preloads retry once after a delay without blocking pages', () {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    fakeAsync((async) {
      final window = [task('bad'), task('next')];
      preloader.update(window);
      gates['bad']!.completeError(StateError('download failed'));
      async.flushMicrotasks();
      expect(started, ['bad', 'next']);
      preloader.update(window);
      async.elapse(const Duration(milliseconds: 999));
      expect(started, ['bad', 'next']);
      async.elapse(const Duration(milliseconds: 1));
      expect(started, ['bad', 'next', 'bad']);
      gates['bad']!.completeError(StateError('still unavailable'));
      async.flushMicrotasks();
      gates['next']!.complete();
      async.flushMicrotasks();
      preloader.update(window);
      async.elapse(const Duration(seconds: 10));
      expect(started, ['bad', 'next', 'bad']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('leaving the window cancels a pending retry', () {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    fakeAsync((async) {
      preloader.update([task('old')]);
      gates['old']!.completeError(StateError('download failed'));
      async.flushMicrotasks();
      expect(async.nonPeriodicTimerCount, 1);
      preloader.update([task('new')]);
      async.elapse(const Duration(seconds: 2));
      expect(started, ['old', 'new']);
      expect(async.pendingTimers, isEmpty);
      gates['new']!.complete();
      async.flushMicrotasks();
    });
  });

  test('disposing stops queued work', () async {
    preloader.update([task('first'), task('second'), task('queued')]);
    preloader.dispose();
    await finish('first');
    await finish('second');
    expect(started, ['first', 'second']);
  });
}
