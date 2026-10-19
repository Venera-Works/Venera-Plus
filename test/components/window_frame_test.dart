import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/app_exit.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';

Widget _app() => MaterialApp(
  navigatorKey: App.rootNavigatorKey,
  builder: (_, child) => WindowFrame(OverlayWidget(child!)),
  home: const SizedBox.shrink(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Log.isMuted = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
  });

  tearDown(() {
    configureAppExitPreparation(null);
    debugExitProcess = null;
    Log.clear();
    Log.isMuted = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  for (final readerRegisteredFirst in [false, true]) {
    testWidgets(
      'reader veto precedes sync regardless of registration order (readerFirst=$readerRegisteredFirst)',
      (tester) async {
        final events = <String>[];
        configureAppExitPreparation(() async => events.add('prepare'));
        debugExitProcess = (_) => events.add('exit');
        await tester.pumpWidget(_app());
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        final frame = WindowFrame.of(App.rootContext);
        late WindowCloseListener sync;
        sync = () {
          events.add('sync');
          frame.removeCloseListener(sync);
          return true;
        };
        late WindowCloseListener reader;
        reader = () {
          events.add('reader');
          frame.removeCloseListener(reader);
          return false;
        };
        if (readerRegisteredFirst) {
          frame.addCloseListener(reader, runFirst: true);
          frame.addCloseListener(sync);
        } else {
          frame.addCloseListener(sync);
          frame.addCloseListener(reader, runFirst: true);
        }

        await tester.tap(find.byType(WindowButton).last);
        await tester.pump();
        expect(events, ['reader']);
        await tester.tap(find.byType(WindowButton).last);
        await tester.pump();
        expect(events, ['reader', 'sync', 'prepare', 'exit']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('repeated close waits for one preparation before exiting', (
    tester,
  ) async {
    final saved = Completer<void>();
    addTearDown(() {
      if (!saved.isCompleted) saved.complete();
    });
    var preparations = 0;
    var exits = 0;
    configureAppExitPreparation(() {
      preparations++;
      return saved.future;
    });
    debugExitProcess = (_) => exits++;
    await tester.pumpWidget(_app());
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.tap(find.byType(WindowButton).last);
    await tester.tap(find.byType(WindowButton).last);
    expect(preparations, 1);
    expect(exits, 0);
    final closing = exitApp();
    saved.complete();
    await closing;
    await tester.pump();
    expect(exits, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save failure keeps the window responsive to another close', (
    tester,
  ) async {
    var preparations = 0;
    var exits = 0;
    configureAppExitPreparation(() async {
      preparations++;
      throw StateError('history write failed');
    });
    debugExitProcess = (_) => exits++;
    await tester.pumpWidget(_app());
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.tap(find.byType(WindowButton).last);
    await tester.pump();
    expect(preparations, 1);
    expect(exits, 0);
    expect(find.text('Saved Failed'.tl), findsOneWidget);
    await tester.tap(find.byType(WindowButton).last);
    await tester.pump();
    expect(preparations, 2);
    expect(exits, 0);
    expect(tester.takeException(), isNull);
  });
}
