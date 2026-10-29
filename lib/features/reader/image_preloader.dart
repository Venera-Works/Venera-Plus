import 'dart:async';

import 'package:venera_plus/foundation/log.dart';

class ReaderImagePreload {
  const ReaderImagePreload({
    required this.key,
    required this.decode,
    required this.load,
    this.isCached,
  });

  final Object key;
  final bool decode;
  final Future<void> Function() load;
  final bool Function()? isCached;
}

/// Prepares nearby pages first, with at most two tasks and one distant download.
class ReaderImagePreloader {
  Map<Object, ReaderImagePreload> _wanted = {};
  final _active = <Object, ReaderImagePreload>{};
  final _finished = <Object, bool>{};
  final _failures = <(Object, bool), int>{};
  final _retryTimers = <(Object, bool), Timer>{};
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
    _finished.removeWhere((key, decoded) {
      final task = _wanted[key];
      return task == null ||
          (decoded && task.decode && task.isCached?.call() == false);
    });
    _failures.removeWhere((key, _) => _wanted[key.$1]?.decode != key.$2);
    _retryTimers.removeWhere((key, timer) {
      if (_wanted[key.$1]?.decode == key.$2) return false;
      timer.cancel();
      return true;
    });
    _drain();
  }

  void _drain() {
    if (_disposed || _paused) return;
    for (final task in _wanted.values) {
      if (_active.length >= 2) break;
      if (_active.containsKey(task.key)) continue;
      final finished = _finished[task.key];
      if (finished == true || finished == task.decode) continue;
      final attemptKey = (task.key, task.decode);
      if ((_failures[attemptKey] ?? 0) >= 2 ||
          _retryTimers.containsKey(attemptKey)) {
        continue;
      }
      if (!task.decode && _active.values.any((active) => !active.decode)) {
        continue;
      }
      _active[task.key] = task;
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
        final attemptKey = (task.key, task.decode);
        if (succeeded) {
          _finished[task.key] = task.decode;
          _failures.remove(attemptKey);
        } else if (_wanted[task.key]!.decode == task.decode) {
          final failures = (_failures[attemptKey] ?? 0) + 1;
          _failures[attemptKey] = failures;
          // Retry once without occupying a slot or looping on a broken image.
          if (failures < 2) {
            _retryTimers[attemptKey] = Timer(const Duration(seconds: 1), () {
              _retryTimers.remove(attemptKey);
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
