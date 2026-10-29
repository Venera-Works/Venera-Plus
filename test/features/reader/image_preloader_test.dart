import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/reader/image_preloader.dart';
import 'package:venera_plus/foundation/log.dart';

void main() {
  late ReaderImagePreloader preloader;
  late List<String> started;
  late Map<String, Completer<void>> gates;

  ReaderImagePreload task(
    String key, {
    bool decode = false,
    bool Function()? isCached,
  }) => ReaderImagePreload(
    key: key,
    decode: decode,
    isCached: isCached,
    load: () {
      final name = '$key:$decode';
      started.add(name);
      return (gates[name] = Completer<void>()).future;
    },
  );

  Future<void> finish(String name) async {
    gates[name]!.complete();
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
    'nearby pages run first and distant downloads run one at a time',
    () async {
      final window = [
        task('next', decode: true),
        task('next-2', decode: true),
        task('previous', decode: true),
        task('far-1'),
        task('far-2'),
      ];
      preloader.update(window);
      expect(started, ['next:true', 'next-2:true']);
      await finish('next:true');
      expect(started.last, 'previous:true');
      await finish('next-2:true');
      expect(started.last, 'far-1:false');
      await finish('previous:true');
      expect(started, hasLength(4));
      preloader.update(window);
      expect(started, hasLength(4));
      await finish('far-1:false');
      expect(started.last, 'far-2:false');
      await finish('far-2:false');
      preloader.update(window);
      expect(started, hasLength(5));
    },
  );

  test(
    'fast navigation replaces queued pages and leaves capacity for next page',
    () async {
      preloader.update([task('old-active'), task('old-queued')]);
      preloader.update([task('new-next', decode: true), task('new-far')]);
      expect(started, ['old-active:false', 'new-next:true']);
      await finish('old-active:false');
      expect(started.last, 'new-far:false');
      expect(started, isNot(contains('old-queued:false')));
    },
  );

  test('an active download is decoded once when it becomes adjacent', () async {
    preloader.update([task('page')]);
    preloader.update([task('page', decode: true)]);
    expect(started, ['page:false']);
    await finish('page:false');
    expect(started, ['page:false', 'page:true']);
    await finish('page:true');
    preloader.update([task('page', decode: true), task('page')]);
    expect(started, hasLength(2));
  });

  test(
    'scrolling pauses queued work until the final page is selected',
    () async {
      preloader.update([task('active'), task('old-queued')]);
      preloader.setPaused(true);
      await finish('active:false');
      expect(started, ['active:false']);

      preloader.update([task('midpoint', decode: true)]);
      expect(started, ['active:false']);
      preloader.update([task('final-next', decode: true), task('final-far')]);
      preloader.setPaused(false);
      expect(started, ['active:false', 'final-next:true', 'final-far:false']);
    },
  );

  test(
    'a download completed during scrolling is decoded after resume',
    () async {
      preloader.update([task('page')]);
      preloader.setPaused(true);
      preloader.update([task('page', decode: true)]);
      await finish('page:false');
      expect(started, ['page:false']);
      preloader.setPaused(false);
      expect(started, ['page:false', 'page:true']);
      await finish('page:true');
      preloader.setPaused(true);
      preloader.setPaused(false);
      expect(started, hasLength(2));
    },
  );

  test('failed preloads do not loop or block subsequent pages', () async {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    preloader.update([task('bad'), task('next')]);
    gates['bad:false']!.completeError(StateError('download failed'));
    await pumpEventQueue();
    expect(started, ['bad:false', 'next:false']);
    preloader.update([task('bad'), task('next')]);
    expect(started, hasLength(2));
    await finish('next:false');
    expect(started, hasLength(2));
  });

  test(
    'evicted decoded images are prepared again on a window update',
    () async {
      var cached = true;
      final window = [task('page', decode: true, isCached: () => cached)];
      preloader.update(window);
      await finish('page:true');
      preloader.update(window);
      expect(started, ['page:true']);

      cached = false;
      preloader.update(window);
      expect(started, ['page:true', 'page:true']);
      await finish('page:true');
      // Cache pressure must not cause an unbounded decode loop.
      expect(started, hasLength(2));
    },
  );

  test('failed preloads retry once after a delay without blocking pages', () {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    fakeAsync((async) {
      final window = [task('bad', decode: true), task('next')];
      preloader.update(window);
      gates['bad:true']!.completeError(StateError('download failed'));
      async.flushMicrotasks();
      expect(started, ['bad:true', 'next:false']);
      preloader.update(window);
      async.elapse(const Duration(milliseconds: 999));
      expect(started, hasLength(2));
      async.elapse(const Duration(milliseconds: 1));
      expect(started, ['bad:true', 'next:false', 'bad:true']);

      gates['bad:true']!.completeError(StateError('still unavailable'));
      async.flushMicrotasks();
      gates['next:false']!.complete();
      async.flushMicrotasks();
      preloader.update(window);
      async.elapse(const Duration(seconds: 10));
      expect(started, hasLength(3));
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('leaving the window cancels a pending retry', () {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    fakeAsync((async) {
      preloader.update([task('old', decode: true)]);
      gates['old:true']!.completeError(StateError('download failed'));
      async.flushMicrotasks();
      expect(async.nonPeriodicTimerCount, 1);
      preloader.update([task('new', decode: true)]);
      async.elapse(const Duration(seconds: 2));
      expect(started, ['old:true', 'new:true']);
      expect(async.pendingTimers, isEmpty);
      gates['new:true']!.complete();
      async.flushMicrotasks();
    });
  });

  test('disposing stops queued work', () async {
    preloader.update([task('active'), task('queued')]);
    preloader.dispose();
    await finish('active:false');
    expect(started, ['active:false']);
  });
}
