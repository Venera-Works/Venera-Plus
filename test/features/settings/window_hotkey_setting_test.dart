import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/settings/window_hotkey_setting.dart';
import 'package:venera_plus/foundation/window_hotkey.dart';
import 'package:venera_plus/foundation/window_hotkey_controller.dart';

import '../../support/window_hotkey_fixture.dart';

void main() {
  testWidgets(
    'recording, enabling and clearing a shortcut use the shared controller',
    (tester) async {
      final backend = FakeWindowHotkeyBackend();
      var saved = const WindowHotkeyConfiguration();
      final controller = WindowHotkeyController(
        backend: backend,
        load: () => saved,
        persist: (next, _) async {
          saved = next;
        },
      );
      addTearDown(controller.dispose);
      await controller.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WindowHotkeySetting(controller: controller)),
        ),
      );
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();
      expect(backend.suspended, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Ctrl + J'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved.hotkey?.keyCode, 0x4a);
      expect(saved.enabled, isFalse);
      expect(backend.suspended, isFalse);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(saved.enabled, isTrue);
      expect(backend.current, saved.hotkey);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(saved.hotkey, isNull);
      expect(backend.current, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      final closing = controller.close();
      await tester.pump();
      await closing;
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
