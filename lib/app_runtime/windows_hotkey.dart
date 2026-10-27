import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/window_hotkey.dart';
import 'package:venera_plus/foundation/window_hotkey_controller.dart';

/// Kept outside appdata and the explicitly selected files in .venera archives.
WindowHotkeyController createWindowsHotkeyController() {
  final file = File('${App.dataPath}/windows_hotkey.json');
  final backup = File('${file.path}.previous');
  return WindowHotkeyController(
    backend: WindowsHotkeyBackend(),
    load: () {
      final source = file.existsSync() ? file : backup;
      return source.existsSync()
          ? WindowHotkeyConfiguration.fromJson(
              jsonDecode(source.readAsStringSync()),
            )
          : const WindowHotkeyConfiguration();
    },
    persist: (next, previous) async {
      final pending = File('${file.path}.pending');
      await pending.writeAsString(jsonEncode(next.toJson()), flush: true);
      var moved = false;
      try {
        if (await file.exists()) {
          if (await backup.exists()) await backup.delete();
          await file.rename(backup.path);
          moved = true;
        }
        await pending.rename(file.path);
      } catch (error) {
        if (moved) await backup.rename(file.path);
        throw WindowHotkeyFailure('hotkey_save_failed', error);
      }
    },
    onError: (error, stack) => Log.error('Window hotkey', error, stack),
  );
}

class WindowsHotkeyBackend implements WindowHotkeyBackend {
  WindowsHotkeyBackend({
    this.channel = const MethodChannel('venera/window_hotkey'),
  });
  final MethodChannel channel;

  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw WindowHotkeyFailure(error.code, error);
    }
  }

  @override
  Future<int> open() async => await _call<int>('open') ?? 0;
  @override
  Future<void> stage(int owner, WindowHotkey? hotkey) => _call<void>('stage', {
    'owner': owner,
    'modifiers': hotkey?.modifiers ?? 0,
    'keyCode': hotkey?.keyCode ?? 0,
  });
  @override
  Future<void> commit(int owner) => _call<void>('commit', {'owner': owner});
  @override
  Future<void> cancel(int owner) => _call<void>('cancel', {'owner': owner});
  @override
  Future<void> suspend(int owner, bool value) =>
      _call<void>('suspend', {'owner': owner, 'value': value});
  @override
  Future<void> close(int owner) => _call<void>('close', {'owner': owner});
}
