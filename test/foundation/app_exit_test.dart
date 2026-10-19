import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app_exit.dart';

void main() {
  tearDown(() {
    configureAppExitPreparation(null);
    debugExitProcess = null;
  });

  test(
    'concurrent exits share preparation and exit only after it finishes',
    () async {
      final saved = Completer<void>();
      addTearDown(() {
        if (!saved.isCompleted) saved.complete();
      });
      final events = <String>[];
      configureAppExitPreparation(() async {
        events.add('prepare');
        await saved.future;
        events.add('saved');
      });
      debugExitProcess = (code) => events.add('exit:$code');

      final first = exitApp();
      final second = exitApp();
      expect(second, same(first));
      expect(events, ['prepare']);
      saved.complete();
      await Future.wait([first, second]);
      expect(events, ['prepare', 'saved', 'exit:0']);
    },
  );

  for (final asynchronous in [false, true]) {
    test(
      'failed preparation releases the in-flight request (async=$asynchronous)',
      () async {
        final failure = StateError('history write failed');
        var exits = 0;
        configureAppExitPreparation(
          asynchronous ? () async => throw failure : () => throw failure,
        );
        debugExitProcess = (_) => exits++;

        await expectLater(exitApp(), throwsA(same(failure)));
        expect(exits, 0);
        var prepared = false;
        configureAppExitPreparation(() async {
          prepared = true;
        });
        await exitApp();
        expect(prepared, isTrue);
        expect(exits, 1);
      },
    );
  }
}
