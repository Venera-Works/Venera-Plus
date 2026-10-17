import 'dart:async';

import 'package:venera_plus/foundation/log.dart';

class ReaderImagePreload {
  const ReaderImagePreload({
    required this.key,
    required this.decode,
    required this.load,
  });

  final Object key;
  final bool decode;
  final Future<void> Function() load;
}

/// Prepares nearby pages first, with at most two tasks and one distant download.
class ReaderImagePreloader {
  Map<Object, ReaderImagePreload> _wanted = {};
  final _active = <Object, ReaderImagePreload>{};
  final _finished = <Object, bool>{};
  bool _paused = false;
  bool _disposed = false;

  /// Let active requests finish, but keep new work out of page animations.
  void setPaused(bool paused) {
    _paused = paused;
    _drain();
  }

  void update(List<ReaderImagePreload> tasks) {
    if (_disposed) return;
    _wanted = {};
    for (final task in tasks) {
      // The first occurrence has the highest priority (including split pages).
      _wanted.putIfAbsent(task.key, () => task);
    }
    _finished.removeWhere((key, _) => !_wanted.containsKey(key));
    _drain();
  }

  void _drain() {
    if (_disposed || _paused) return;
    for (final task in _wanted.values) {
      if (_active.length >= 2) break;
      if (_active.containsKey(task.key)) continue;
      final finished = _finished[task.key];
      if (finished == true || finished == task.decode) continue;
      if (!task.decode && _active.values.any((active) => !active.decode)) {
        continue;
      }
      _active[task.key] = task;
      unawaited(_run(task));
    }
  }

  Future<void> _run(ReaderImagePreload task) async {
    try {
      await task.load();
    } catch (error, stack) {
      Log.warning('Reader preload', '$error\n$stack');
    } finally {
      _active.remove(task.key);
      if (!_disposed && _wanted.containsKey(task.key)) {
        // A failed preload is retried when it re-enters the window or the user
        // retries the image, rather than looping in the background.
        _finished[task.key] = task.decode;
      }
      _drain();
    }
  }

  void dispose() {
    _disposed = true;
    _wanted.clear();
    _finished.clear();
  }
}
