import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Drains native work and any earlier writes created in the widget's fake zone.
Future<void> runWidgetIo(
  WidgetTester tester,
  Future<void> Function() work,
) async {
  var completed = false;
  Object? failure;
  StackTrace? failureStack;
  final stopwatch = Stopwatch()..start();
  await tester.runAsync(() async {
    unawaited(
      Future<void>.sync(work).then(
        (_) {
          completed = true;
        },
        onError: (Object error, StackTrace stackTrace) {
          failure = error;
          failureStack = stackTrace;
          completed = true;
        },
      ),
    );
  });
  while (!completed && stopwatch.elapsed < const Duration(seconds: 10)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  if (!completed) {
    throw TestFailure('Native widget I/O did not settle within 10 seconds.');
  }
  if (failure != null) {
    Error.throwWithStackTrace(failure!, failureStack!);
  }
}
