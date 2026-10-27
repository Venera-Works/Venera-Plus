import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_shell/app_shell.dart';
import 'package:venera_plus/foundation/log.dart';

void main() {
  setUp(() => Log.isMuted = true);
  tearDown(() => Log.isMuted = false);

  testWidgets('draws loading before initialization and gates the real app', (
    tester,
  ) async {
    final localReady = Completer<void>();
    var startedAfterFrame = false;
    await tester.pumpWidget(
      StartupPage(
        initialize: () {
          startedAfterFrame = find
              .byType(CircularProgressIndicator)
              .evaluate()
              .isNotEmpty;
          return localReady.future;
        },
        child: const MaterialApp(home: Text('Authentication Required')),
      ),
    );

    expect(startedAfterFrame, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Authentication Required'), findsNothing);

    localReady.complete();
    await tester.pumpAndSettle();
    expect(find.text('Authentication Required'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('shows failure and retries before exposing the app', (
    tester,
  ) async {
    var attempts = 0;
    final retry = Completer<void>();
    await tester.pumpWidget(
      StartupPage(
        initialize: () {
          if (++attempts == 1) throw StateError('Local storage unavailable');
          return retry.future;
        },
        child: const MaterialApp(home: Text('Local library')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Startup failed'), findsOneWidget);
    expect(
      find.textContaining('Local storage unavailable', findRichText: true),
      findsWidgets,
    );
    expect(find.text('Local library'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(attempts, 2);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    retry.complete();
    await tester.pumpAndSettle();
    expect(find.text('Local library'), findsOneWidget);
  });
}
