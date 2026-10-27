import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera_plus/foundation/log.dart';

/// Serializes native changes, including a reader closing while another opens.
class ReaderScreenAwakeController {
  ReaderScreenAwakeController({this.supported = true, this.apply = _apply});

  final bool supported;
  final Future<void> Function(bool) apply;
  static ReaderScreenAwakeController? _owner;
  static Future<void> _pending = Future.value();
  static bool _applied = false;
  bool _enabled = false;
  bool _disposed = false;

  static Future<void> _apply(bool enabled) => const MethodChannel(
    'venera/method_channel',
  ).invokeMethod<void>('setScreenOn', {'set': enabled});

  Future<void> setEnabled(bool enabled) {
    if (!supported || _disposed || _enabled == enabled) return _pending;
    _enabled = enabled;
    if (enabled) {
      _owner = this;
    } else if (identical(_owner, this)) {
      _owner = null;
    }
    _pending = _pending
        .then((_) async {
          final next = _owner != null;
          if (_applied == next) return;
          await apply(next);
          _applied = next;
        })
        .catchError((Object error, StackTrace stack) {
          Log.warning('Reader screen', '$error\n$stack');
        });
    return _pending;
  }

  Future<void> dispose() {
    final pending = setEnabled(false);
    _disposed = true;
    return pending;
  }
}
