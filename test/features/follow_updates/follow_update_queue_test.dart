import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/follow_updates/follow_update_queue.dart';
import 'package:venera_plus/network/request_scope.dart';

void main() {
  test(
    'limits each source without pausing other sources after five starts',
    () {
      fakeAsync((async) {
        final scope = RequestScope();
        final started = <String>[];
        final responses = <String, Completer<void>>{};
        final activeBySource = <String, int>{};
        var active = 0;
        var maxActive = 0;
        var maxActivePerSource = 0;
        var completed = false;
        runFollowUpdateTasks(
          ['a1', 'a2', 'a3', 'b1', 'b2', 'c1', 'd1', 'e1', 'f1'],
          sourceKey: (task) => task[0],
          scope: scope,
          now: () => DateTime(2026).add(async.elapsed),
          run: (task) async {
            started.add(task);
            final source = task[0];
            active++;
            activeBySource[source] = (activeBySource[source] ?? 0) + 1;
            if (active > maxActive) maxActive = active;
            if (activeBySource[source]! > maxActivePerSource) {
              maxActivePerSource = activeBySource[source]!;
            }
            final response = responses[task] = Completer<void>();
            await response.future;
            active--;
            activeBySource[source] = activeBySource[source]! - 1;
          },
        ).then((_) => completed = true);
        async.flushMicrotasks();
        expect(started, ['a1', 'b1', 'c1', 'd1', 'e1']);

        responses['b1']!.complete();
        async.flushMicrotasks();
        expect(started.last, 'f1');
        expect(async.elapsed, Duration.zero);

        async.elapse(const Duration(milliseconds: 500));
        responses['c1']!.complete();
        async.flushMicrotasks();
        expect(started.last, 'a2');

        async.elapse(const Duration(milliseconds: 500));
        responses['d1']!.complete();
        async.flushMicrotasks();
        expect(started.last, 'b2');
        expect(started, isNot(contains('a3')));

        responses['a1']!.complete();
        async.flushMicrotasks();
        expect(started.last, 'a3');
        for (final response in responses.values) {
          if (!response.isCompleted) response.complete();
        }
        async.flushMicrotasks();
        expect(completed, isTrue);
        expect(maxActive, 5);
        expect(maxActivePerSource, 2);
        expect(active, 0);
        scope.dispose();
      });
    },
  );

  test('spaces requests to one source while spare slots remain available', () {
    fakeAsync((async) {
      final scope = RequestScope();
      final started = <Duration>[];
      var completed = false;
      runFollowUpdateTasks(
        [1, 2],
        sourceKey: (_) => 'source',
        scope: scope,
        now: () => DateTime(2026).add(async.elapsed),
        run: (_) async => started.add(async.elapsed),
      ).then((_) => completed = true);
      async.flushMicrotasks();
      expect(started, [Duration.zero]);

      async.elapse(const Duration(milliseconds: 499));
      expect(started, hasLength(1));
      async.elapse(const Duration(milliseconds: 1));
      expect(started, [Duration.zero, const Duration(milliseconds: 500)]);
      expect(completed, isTrue);
      scope.dispose();
    });
  });
}
