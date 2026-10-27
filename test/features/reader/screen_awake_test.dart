import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/reader/screen_awake.dart';

void main() {
  test('a late native enable is followed by disable on exit', () async {
    final gate = Completer<void>();
    final calls = <bool>[];
    final controller = ReaderScreenAwakeController(
      apply: (enabled) async {
        calls.add(enabled);
        if (enabled) await gate.future;
      },
    );
    final enabling = controller.setEnabled(true);
    await pumpEventQueue();
    final closing = controller.dispose();
    gate.complete();
    await enabling;
    await closing;
    expect(calls, [true, false]);
  });

  test(
    'closing an old reader preserves the current reader screen lease',
    () async {
      final calls = <bool>[];
      Future<void> apply(bool enabled) async {
        calls.add(enabled);
      }

      final first = ReaderScreenAwakeController(apply: apply);
      final second = ReaderScreenAwakeController(apply: apply);
      await first.setEnabled(true);
      await second.setEnabled(true);
      await first.dispose();
      expect(calls, [true]);
      await second.dispose();
      expect(calls, [true, false]);
    },
  );
}
