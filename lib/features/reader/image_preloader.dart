import 'dart:async';

import 'package:venera_plus/foundation/log.dart';

class ReaderImagePreload {
  const ReaderImagePreload({
    required this.key,
    required this.load,
    this.isCached,
  });

  final Object key;
  final Future<void> Function() load;
  final bool Function()? isCached;
}

/// Prepares pages in window order, with at most two tasks at a time.
class ReaderImagePreloader {
  Map<Object, ReaderImagePreload> _wanted = {};
  final _active = <Object>{};
  final _finished = <Object>{};
  final _failures = <Object, int>{};
  final _retryTimers = <Object, Timer>{};
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
    // Recheck on window updates so cache pressure cannot cause a decode loop.
    _finished.removeWhere((key) {
      final task = _wanted[key];
      return task == null || task.isCached?.call() == false;
    });
    _failures.removeWhere((key, _) => !_wanted.containsKey(key));
    _retryTimers.removeWhere((key, timer) {
      if (_wanted.containsKey(key)) return false;
      timer.cancel();
      return true;
    });
    _drain();
  }

  void _drain() {
    if (_disposed || _paused) return;
    for (final task in _wanted.values) {
      if (_active.length >= 2) break;
      if (_active.contains(task.key) || _finished.contains(task.key)) continue;
      if ((_failures[task.key] ?? 0) >= 2 ||
          _retryTimers.containsKey(task.key)) {
        continue;
      }
      _active.add(task.key);
      unawaited(_run(task));
    }
  }

  Future<void> _run(ReaderImagePreload task) async {
    var succeeded = false;
    try {
      await task.load();
      succeeded = true;
    } catch (error, stack) {
      Log.warning('Reader preload', '$error\n$stack');
    } finally {
      _active.remove(task.key);
      if (!_disposed && _wanted.containsKey(task.key)) {
        if (succeeded) {
          _finished.add(task.key);
          _failures.remove(task.key);
        } else {
          final failures = (_failures[task.key] ?? 0) + 1;
          _failures[task.key] = failures;
          // Retry once without occupying a slot or looping on a broken image.
          if (failures < 2) {
            _retryTimers[task.key] = Timer(const Duration(seconds: 1), () {
              _retryTimers.remove(task.key);
              _drain();
            });
          }
        }
      }
      _drain();
    }
  }

  void dispose() {
    _disposed = true;
    _wanted.clear();
    _finished.clear();
    _failures.clear();
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
  }
}
