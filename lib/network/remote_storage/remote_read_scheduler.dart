import 'dart:async';
import 'dart:io' show HttpDate, HttpException;

import 'package:dio/dio.dart';

enum RemoteReadPriority { foreground, cover, preload }

/// The mutable priority shared by requests for one image or archive operation.
class RemoteReadContext {
  RemoteReadContext({
    RemoteReadPriority priority = RemoteReadPriority.foreground,
  }) : _priority = priority;

  static final _zoneKey = Object();
  static RemoteReadContext get current =>
      Zone.current[_zoneKey] as RemoteReadContext? ?? RemoteReadContext();

  RemoteReadPriority _priority;
  RemoteReadPriority get priority => _priority;

  void promote(RemoteReadPriority priority) {
    if (priority.index < _priority.index) _priority = priority;
  }

  T run<T>(T Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: this});
}

/// Spaces and limits requests sharing one remote account.
class RemoteReadScheduler {
  RemoteReadScheduler({
    this.maxConcurrent = 2,
    this.minInterval = const Duration(milliseconds: 300),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (maxConcurrent < 1) {
      throw RangeError.value(maxConcurrent, 'maxConcurrent');
    }
    if (minInterval.isNegative) {
      throw ArgumentError.value(minInterval, 'minInterval');
    }
  }

  final int maxConcurrent;
  final Duration minInterval;
  final DateTime Function() _now;
  final _queue = <_RemoteReadRequest<dynamic>>[];
  var _active = 0;
  var _pumpScheduled = false;
  Timer? _timer;
  DateTime? _nextStart;
  DateTime? _cooldownUntil;

  Future<T> run<T>(
    Future<T> Function() action, {
    CancelToken? cancelToken,
    RemoteReadContext? context,
  }) {
    if (cancelToken?.isCancelled == true) {
      return Future<T>.error(cancelToken!.cancelError!);
    }
    final request = _RemoteReadRequest(
      action,
      cancelToken,
      context ?? RemoteReadContext.current,
    );
    _queue.add(request);
    final reference = WeakReference(request);
    cancelToken?.whenCancel.then((error) {
      final current = reference.target;
      if (current == null || current.result.isCompleted) return;
      current.cancel(error);
      if (_queue.remove(current)) _schedulePump();
    });
    _schedulePump();
    return request.result.future;
  }

  /// Delays every new request, including requests for other archives.
  /// Call this before the failing action returns so a freed slot stays paused.
  void defer({String? retryAfter, int attempt = 0}) {
    final now = _now();
    final value = retryAfter?.trim();
    DateTime? deadline;
    if (value != null) {
      if (RegExp(r'^[0-9]+$').hasMatch(value)) {
        final seconds = int.tryParse(value);
        if (seconds != null) {
          try {
            deadline = now.add(Duration(seconds: seconds));
          } on RangeError {
            // A delay outside DateTime's supported range is invalid.
          }
        }
      } else {
        try {
          deadline = HttpDate.parse(value);
        } on HttpException {
          // Invalid headers use the bounded exponential fallback below.
        }
      }
    }
    deadline ??= now.add(
      Duration(
        seconds: attempt <= 0
            ? 1
            : attempt == 1
            ? 2
            : 4,
      ),
    );
    if (deadline.isBefore(now)) deadline = now;
    if (_cooldownUntil == null || deadline.isAfter(_cooldownUntil!)) {
      _cooldownUntil = deadline;
    }
    _schedulePump();
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  void _pump() {
    _timer?.cancel();
    _timer = null;
    for (var i = _queue.length - 1; i >= 0; i--) {
      final token = _queue[i].cancelToken;
      if (token?.isCancelled == true) {
        _queue.removeAt(i).cancel(token!.cancelError!);
      }
    }
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final now = _now();
      var readyAt = _nextStart;
      if (_cooldownUntil != null &&
          (readyAt == null || _cooldownUntil!.isAfter(readyAt))) {
        readyAt = _cooldownUntil;
      }
      if (readyAt != null && readyAt.isAfter(now)) {
        _timer = Timer(readyAt.difference(now), () {
          _timer = null;
          _schedulePump();
        });
        return;
      }
      var next = 0;
      for (var i = 1; i < _queue.length; i++) {
        if (_queue[i].context.priority.index <
            _queue[next].context.priority.index) {
          next = i;
        }
      }
      final request = _queue.removeAt(next);
      _active++;
      _nextStart = now.add(minInterval);
      unawaited(_execute(request));
    }
  }

  Future<void> _execute(_RemoteReadRequest<dynamic> request) async {
    try {
      await request.execute();
    } finally {
      _active--;
      _schedulePump();
    }
  }
}

class _RemoteReadRequest<T> {
  _RemoteReadRequest(this.action, this.cancelToken, this.context);

  final Future<T> Function() action;
  final CancelToken? cancelToken;
  final RemoteReadContext context;
  final result = Completer<T>();

  void cancel(DioException error) {
    if (!result.isCompleted) result.completeError(error, error.stackTrace);
  }

  Future<void> execute() async {
    try {
      final value = await context.run(action);
      if (cancelToken?.isCancelled == true) {
        cancel(cancelToken!.cancelError!);
      } else if (!result.isCompleted) {
        result.complete(value);
      }
    } catch (error, stackTrace) {
      if (!result.isCompleted) result.completeError(error, stackTrace);
    }
  }
}
