import 'dart:async';
import 'dart:io' show HttpDate;

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/network/remote_storage/remote_read_scheduler.dart';

void main() {
  test('context propagates synchronously and through asynchronous work', () {
    fakeAsync((async) {
      final context = RemoteReadContext(priority: RemoteReadPriority.preload);
      expect(context.run(() => RemoteReadContext.current), same(context));
      expect(context.run(() => 42), 42);
      RemoteReadContext? afterAwait;
      context.run(() async {
        await Future<void>.value();
        afterAwait = RemoteReadContext.current;
      });
      async.flushMicrotasks();
      expect(afterAwait, same(context));
      expect(RemoteReadContext.current.priority, RemoteReadPriority.foreground);
      expect(
        identical(RemoteReadContext.current, RemoteReadContext.current),
        isFalse,
      );
      context.promote(RemoteReadPriority.cover);
      context.promote(RemoteReadPriority.preload);
      expect(context.priority, RemoteReadPriority.cover);
      context.promote(RemoteReadPriority.foreground);
      context.promote(RemoteReadPriority.cover);
      expect(context.priority, RemoteReadPriority.foreground);
    });
  });

  test('keeps four slots occupied until their complete operations finish', () {
    fakeAsync((async) {
      final scheduler = RemoteReadScheduler(
        minInterval: Duration.zero,
        now: () => _initialTime.add(async.elapsed),
      );
      final gates = List.generate(6, (_) => Completer<void>());
      final started = <int>[];
      var active = 0;
      var peak = 0;
      for (var i = 0; i < gates.length; i++) {
        scheduler.run(() async {
          started.add(i);
          active++;
          if (active > peak) peak = active;
          await gates[i].future;
          active--;
        });
      }
      async.flushMicrotasks();
      expect(started, [0, 1, 2, 3]);
      gates[0].complete();
      async.flushMicrotasks();
      expect(started, [0, 1, 2, 3, 4]);
      gates[1].complete();
      async.flushMicrotasks();
      expect(started, [0, 1, 2, 3, 4, 5]);
      for (final gate in gates.skip(2)) {
        gate.complete();
      }
      async.flushMicrotasks();
      expect(peak, 4);
      expect(active, 0);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('spaces starts by 150ms even when the previous operation is done', () {
    fakeAsync((async) {
      final scheduler = RemoteReadScheduler(
        now: () => _initialTime.add(async.elapsed),
      );
      final starts = <Duration>[];
      for (var i = 0; i < 3; i++) {
        scheduler.run(() async => starts.add(async.elapsed));
      }
      async.flushMicrotasks();
      expect(starts, [Duration.zero]);
      async.elapse(const Duration(milliseconds: 149));
      expect(starts, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(starts, [Duration.zero, const Duration(milliseconds: 150)]);
      async.elapse(const Duration(milliseconds: 150));
      expect(starts.last, const Duration(milliseconds: 300));
      expect(async.pendingTimers, isEmpty);
    });
  });

  test(
    'starts foreground before covers and preloads with FIFO within each priority',
    () {
      fakeAsync((async) {
        final scheduler = _scheduler(
          async,
          maxConcurrent: 1,
          minInterval: Duration.zero,
        );
        final gate = Completer<void>();
        scheduler.run(() => gate.future);
        async.flushMicrotasks();
        final started = <String>[];
        for (final entry in [
          ('preload', RemoteReadPriority.preload),
          ('foreground-1', RemoteReadPriority.foreground),
          ('cover-1', RemoteReadPriority.cover),
          ('foreground-2', RemoteReadPriority.foreground),
          ('cover-2', RemoteReadPriority.cover),
        ]) {
          final context = RemoteReadContext(priority: entry.$2);
          context.run(
            () => scheduler.run(() async {
              expect(RemoteReadContext.current, same(context));
              started.add(entry.$1);
            }),
          );
        }
        gate.complete();
        async.flushMicrotasks();
        expect(started, [
          'foreground-1',
          'foreground-2',
          'cover-1',
          'cover-2',
          'preload',
        ]);
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('uses a promoted context when the start interval expires', () {
    fakeAsync((async) {
      final scheduler = _scheduler(async);
      scheduler.run(() async {});
      async.flushMicrotasks();
      final shared = RemoteReadContext(priority: RemoteReadPriority.preload);
      final started = <String>[];
      scheduler.run(() async => started.add('shared'), context: shared);
      scheduler.run(
        () async => started.add('cover'),
        context: RemoteReadContext(priority: RemoteReadPriority.cover),
      );
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 100));
      shared.promote(RemoteReadPriority.foreground);
      async.elapse(const Duration(milliseconds: 50));
      expect(started, ['shared']);
      async.elapse(const Duration(milliseconds: 150));
      expect(started, ['shared', 'cover']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  for (final entry in <(String?, int, int)>[
    ('3', 0, 3),
    ('0', 0, 0),
    (null, 0, 1),
    (null, 1, 2),
    (null, 99, 4),
    ('invalid', 1, 2),
    ('-1', 2, 4),
    ('1.5', 0, 1),
  ]) {
    test(
      'Retry-After ${entry.$1} at attempt ${entry.$2} waits ${entry.$3}s',
      () {
        fakeAsync((async) {
          final scheduler = _scheduler(async, minInterval: Duration.zero);
          scheduler.defer(retryAfter: entry.$1, attempt: entry.$2);
          var started = false;
          scheduler.run(() async => started = true);
          async.flushMicrotasks();
          if (entry.$3 > 0) {
            expect(started, isFalse);
            async.elapse(Duration(milliseconds: entry.$3 * 1000 - 1));
            expect(started, isFalse);
            async.elapse(const Duration(milliseconds: 1));
          }
          expect(started, isTrue);
          expect(async.pendingTimers, isEmpty);
        });
      },
    );
  }

  test('honors an HTTP date and accepts a past date without fallback', () {
    fakeAsync((async) {
      final scheduler = _scheduler(async, minInterval: Duration.zero);
      scheduler.defer(
        retryAfter: HttpDate.format(
          _initialTime.add(const Duration(seconds: 5)),
        ),
      );
      final starts = <Duration>[];
      scheduler.run(() async => starts.add(async.elapsed));
      async.elapse(const Duration(milliseconds: 4999));
      expect(starts, isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      expect(starts, [const Duration(seconds: 5)]);
      scheduler.defer(retryAfter: HttpDate.format(_initialTime));
      scheduler.run(() async => starts.add(async.elapsed));
      async.flushMicrotasks();
      expect(starts, [const Duration(seconds: 5), const Duration(seconds: 5)]);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a shorter cooldown never shortens an existing deadline', () {
    fakeAsync((async) {
      final scheduler = _scheduler(async, minInterval: Duration.zero);
      scheduler.defer(retryAfter: '5');
      var started = false;
      scheduler.run(() async => started = true);
      async.elapse(const Duration(seconds: 1));
      scheduler.defer(retryAfter: '1');
      async.elapse(const Duration(milliseconds: 3999));
      expect(started, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(started, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('extending a cooldown reschedules pending requests', () {
    fakeAsync((async) {
      final scheduler = _scheduler(async, minInterval: Duration.zero);
      scheduler.defer(retryAfter: '1');
      var started = false;
      scheduler.run(() async => started = true);
      async.elapse(const Duration(milliseconds: 500));
      scheduler.defer(retryAfter: '2');
      async.elapse(const Duration(milliseconds: 1999));
      expect(started, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(started, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test(
    'defer inside one operation pauses other requests before releasing its slot',
    () {
      fakeAsync((async) {
        final scheduler = _scheduler(async, minInterval: Duration.zero);
        final started = <String>[];
        final errors = <Object>[];
        _captureError(
          scheduler.run<void>(() async {
            started.add('limited');
            scheduler.defer(retryAfter: '2');
            throw StateError('rate limited');
          }),
          errors,
        );
        scheduler.run(() async => started.add('another archive'));
        scheduler.run(() async => started.add('retry'));
        async.flushMicrotasks();
        expect(started, ['limited']);
        expect(errors.single, isA<StateError>());
        async.elapse(const Duration(milliseconds: 1999));
        expect(started, ['limited']);
        async.elapse(const Duration(milliseconds: 1));
        expect(started, ['limited', 'another archive', 'retry']);
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('Retry-After zero still preserves the normal start interval', () {
    fakeAsync((async) {
      final scheduler = _scheduler(async);
      final starts = <Duration>[];
      scheduler.run(() async => starts.add(async.elapsed));
      async.flushMicrotasks();
      scheduler.defer(retryAfter: '0');
      scheduler.run(() async => starts.add(async.elapsed));
      async.elapse(const Duration(milliseconds: 149));
      expect(starts, [Duration.zero]);
      async.elapse(const Duration(milliseconds: 1));
      expect(starts, [Duration.zero, const Duration(milliseconds: 150)]);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('independent instances do not share cooldowns or slots', () {
    fakeAsync((async) {
      final limited = _scheduler(async);
      final other = _scheduler(async);
      limited.defer(retryAfter: '3');
      final starts = <String>[];
      limited.run(() async => starts.add('limited'));
      other.run(() async => starts.add('other'));
      async.flushMicrotasks();
      expect(starts, ['other']);
      async.elapse(const Duration(seconds: 3));
      expect(starts, ['other', 'limited']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('a cancelled queued request never starts or consumes a slot', () {
    fakeAsync((async) {
      final scheduler = _scheduler(
        async,
        maxConcurrent: 1,
        minInterval: Duration.zero,
      );
      final gate = Completer<void>();
      scheduler.run(() => gate.future);
      async.flushMicrotasks();
      final token = CancelToken();
      final errors = <Object>[];
      final starts = <String>[];
      _captureError(
        scheduler.run(() async => starts.add('cancelled'), cancelToken: token),
        errors,
      );
      scheduler.run(() async => starts.add('live'));
      token.cancel('reader closed');
      async.flushMicrotasks();
      expect(errors.single, _cancelled);
      expect(starts, isEmpty);
      gate.complete();
      async.flushMicrotasks();
      expect(starts, ['live']);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test(
    'cancellation before the dispatch microtask also prevents execution',
    () {
      fakeAsync((async) {
        final scheduler = _scheduler(async);
        final token = CancelToken();
        final errors = <Object>[];
        var started = false;
        _captureError(
          scheduler.run(() async => started = true, cancelToken: token),
          errors,
        );
        token.cancel('reader closed');
        async.flushMicrotasks();
        expect(started, isFalse);
        expect(errors.single, _cancelled);
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('cancelling the last cooldown waiter removes its timer', () {
    fakeAsync((async) {
      final scheduler = _scheduler(async);
      scheduler.defer(retryAfter: '3');
      final token = CancelToken();
      final errors = <Object>[];
      var started = false;
      _captureError(
        scheduler.run(() async => started = true, cancelToken: token),
        errors,
      );
      async.flushMicrotasks();
      expect(async.nonPeriodicTimerCount, 1);
      token.cancel('reader closed');
      async.flushMicrotasks();
      expect(errors.single, _cancelled);
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 10));
      expect(started, isFalse);
      scheduler.run(() async => started = true);
      async.flushMicrotasks();
      expect(started, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test(
    'active cancellation holds its slot until the actual operation ends',
    () {
      fakeAsync((async) {
        final scheduler = _scheduler(
          async,
          maxConcurrent: 1,
          minInterval: Duration.zero,
        );
        final token = CancelToken();
        final gate = Completer<void>();
        final errors = <Object>[];
        _captureError(
          scheduler.run(() => gate.future, cancelToken: token),
          errors,
        );
        var nextStarted = false;
        scheduler.run(() async => nextStarted = true);
        async.flushMicrotasks();
        token.cancel('reader closed');
        async.flushMicrotasks();
        expect(errors.single, _cancelled);
        expect(nextStarted, isFalse);
        gate.completeError(StateError('transport shutdown'));
        async.flushMicrotasks();
        expect(nextStarted, isTrue);
        expect(errors, hasLength(1));
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('a synchronous action failure releases its slot', () {
    fakeAsync((async) {
      final scheduler = _scheduler(
        async,
        maxConcurrent: 1,
        minInterval: Duration.zero,
      );
      final errors = <Object>[];
      _captureError(
        scheduler.run<int>(() => throw StateError('failed before awaiting')),
        errors,
      );
      int? value;
      scheduler.run(() async => 42).then((result) => value = result);
      async.flushMicrotasks();
      expect(errors.single, isA<StateError>());
      expect(value, 42);
      expect(async.pendingTimers, isEmpty);
    });
  });
}

final _initialTime = DateTime.utc(2026, 10, 23, 10);
final _cancelled = isA<DioException>().having(
  (error) => error.type,
  'type',
  DioExceptionType.cancel,
);

RemoteReadScheduler _scheduler(
  FakeAsync async, {
  int maxConcurrent = 4,
  Duration minInterval = const Duration(milliseconds: 150),
}) => RemoteReadScheduler(
  maxConcurrent: maxConcurrent,
  minInterval: minInterval,
  now: () => _initialTime.add(async.elapsed),
);

void _captureError<T>(Future<T> future, List<Object> errors) {
  future.then<void>(
    (_) => fail('Expected the operation to fail'),
    onError: (Object error, StackTrace _) {
      errors.add(error);
    },
  );
}
