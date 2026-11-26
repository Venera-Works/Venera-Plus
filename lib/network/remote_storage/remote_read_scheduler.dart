import 'dart:async';
import 'dart:io' show HttpDate, HttpException;

import 'package:dio/dio.dart';

import 'remote_file_store.dart';

enum RemoteReadPriority { foreground, cover, preload, background }

/// 同一图片或归档操作的请求共享优先级和取消信号。
class RemoteReadContext {
  RemoteReadContext({
    RemoteReadPriority priority = RemoteReadPriority.foreground,
    this.cancelToken,
  }) : _priority = priority;

  static final _zoneKey = Object();
  static RemoteReadContext get current =>
      Zone.current[_zoneKey] as RemoteReadContext? ?? RemoteReadContext();

  final CancelToken? cancelToken;
  RemoteReadPriority _priority;
  Set<void Function()>? _promotionListeners;
  RemoteReadPriority get priority => _priority;

  void promote(RemoteReadPriority priority) {
    if (priority.index >= _priority.index) return;
    _priority = priority;
    for (final listener in _promotionListeners ?? const <void Function()>{}) {
      listener();
    }
  }

  T run<T>(T Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: this});
}

/// 控制同一远端账号的请求间隔和并发数。
class RemoteReadScheduler {
  RemoteReadScheduler({
    this.maxConcurrent = 4,
    this.minInterval = const Duration(milliseconds: 150),
    this.backgroundMinInterval,
    this.rateLimitDelay = const Duration(seconds: 1),
    List<Duration>? cooldownSteps,
    this.failDuringCooldown = false,
    DateTime? cooldownUntil,
    this.onCooldown,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _cooldownSteps = List.unmodifiable(cooldownSteps ?? const <Duration>[]),
       _cooldownUntil = cooldownUntil {
    if (maxConcurrent < 1) {
      throw RangeError.value(maxConcurrent, 'maxConcurrent');
    }
    if (minInterval.isNegative) {
      throw ArgumentError.value(minInterval, 'minInterval');
    }
    if (backgroundMinInterval?.isNegative == true) {
      throw ArgumentError.value(backgroundMinInterval, 'backgroundMinInterval');
    }
    _needsProbe = this.cooldownUntil != null;
  }

  static final _schedulerZoneKey = Object();
  final int maxConcurrent;
  final Duration minInterval;
  final Duration? backgroundMinInterval;
  final Duration rateLimitDelay;
  final List<Duration> _cooldownSteps;
  final bool failDuringCooldown;
  final Future<void> Function(DateTime until)? onCooldown;
  final DateTime Function() _now;
  final _queue = <_RemoteReadRequest<dynamic>>[];
  final _waitingOnBackgroundInterval = <RemoteReadContext>{};
  var _active = 0;
  var _pumpScheduled = false;
  var _consecutiveRateLimits = 0;
  late bool _needsProbe;
  var _probeInFlight = false;
  Timer? _timer;
  Timer? _cooldownTimer;
  DateTime? _nextStart;
  DateTime? _nextBackgroundStart;
  DateTime? _cooldownUntil;
  StreamController<DateTime?>? _cooldownChanges;

  DateTime? get cooldownUntil =>
      _cooldownUntil?.isAfter(_now()) == true ? _cooldownUntil : null;

  /// 通知冷却截止时间变化，冷却结束时发送 null。
  Stream<DateTime?> get cooldownChanges =>
      (_cooldownChanges ??= StreamController<DateTime?>.broadcast(
        onListen: _publishCooldown,
        onCancel: () => _cooldownTimer?.cancel(),
      )).stream;

  void _publishCooldown() {
    _cooldownTimer?.cancel();
    _cooldownTimer = null;
    final changes = _cooldownChanges;
    if (changes == null || !changes.hasListener) return;
    final until = cooldownUntil;
    changes.add(until);
    if (until != null) {
      _cooldownTimer = Timer(until.difference(_now()), _publishCooldown);
    }
  }

  void throwIfCoolingDown() {
    final until = cooldownUntil;
    if (until != null) {
      throw RemoteStorageException(
        '网盘访问已暂停，请在 ${until.toLocal()} 后重试',
        code: 'rate_limited',
        retryAt: until,
      );
    }
  }

  Future<void> recordFailure(Object error) async {
    if (error is RemoteStorageException &&
        error.isRateLimited &&
        error.retryAt == null) {
      final execution =
          Zone.current[_schedulerZoneKey]
              as (RemoteReadScheduler, _RemoteReadRequest<dynamic>)?;
      if (execution != null && identical(execution.$1, this)) {
        // 文件存储与调度器都能收到同一错误，只推进一次阶梯冷却。
        final request = execution.$2;
        if (identical(request.recordedRateLimit, error)) return;
        request.recordedRateLimit = error;
      }
      await defer(retryAfter: error.retryAfter);
    }
  }

  /// 同一账号的扫描和阅读复用同一实例，在单次底层读取处排队。
  /// 调度范围应限于底层 I/O，避免嵌套调度占满并发槽位。
  Future<T> run<T>(
    Future<T> Function() action, {
    CancelToken? cancelToken,
    RemoteReadContext? context,
  }) {
    if (cancelToken?.isCancelled == true) {
      return Future<T>.error(cancelToken!.cancelError!);
    }
    if (failDuringCooldown && cooldownUntil != null) {
      return Future<T>.error(_cooldownError());
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

  /// 在限流请求释放并发槽位前暂停同账号的新请求。
  Future<void> defer({String? retryAfter, int attempt = 0}) async {
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
            // 超出 DateTime 范围的等待时间无效。
          }
        }
      } else {
        try {
          deadline = HttpDate.parse(value);
        } on HttpException {
          // 无效响应头使用本地退避策略。
        }
      }
    }
    if (deadline == null) {
      if (_cooldownSteps.isNotEmpty) {
        final index = _consecutiveRateLimits.clamp(
          0,
          _cooldownSteps.length - 1,
        );
        deadline = now.add(_cooldownSteps[index]);
        _consecutiveRateLimits++;
      } else {
        deadline = now.add(
          rateLimitDelay *
              (attempt <= 0
                  ? 1
                  : attempt == 1
                  ? 2
                  : 4),
        );
      }
    }
    if (deadline.isBefore(now)) deadline = now;
    if (_cooldownUntil == null || deadline.isAfter(_cooldownUntil!)) {
      _cooldownUntil = deadline;
      if (deadline.isAfter(now)) _needsProbe = true;
      _publishCooldown();
      _schedulePump();
      await onCooldown?.call(deadline);
    }
    _schedulePump();
  }

  RemoteStorageException _cooldownError() => RemoteStorageException(
    '网盘访问已暂停，请在 ${_cooldownUntil!.toLocal()} 后重试',
    code: 'rate_limited',
    retryAt: _cooldownUntil,
  );

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
    for (final context in _waitingOnBackgroundInterval) {
      context._promotionListeners?.remove(_schedulePump);
    }
    _waitingOnBackgroundInterval.clear();
    if (failDuringCooldown && cooldownUntil != null) {
      final error = _cooldownError();
      for (final request in _queue) {
        request.result.completeError(error);
      }
      _queue.clear();
      return;
    }
    for (var i = _queue.length - 1; i >= 0; i--) {
      final token = _queue[i].cancelToken;
      if (token?.isCancelled == true) {
        _queue.removeAt(i).cancel(token!.cancelError!);
      }
    }
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      if (_probeInFlight) return;
      final now = _now();
      final until = _cooldownUntil;
      var readyAt = _nextStart;
      if (until != null && (readyAt == null || until.isAfter(readyAt))) {
        readyAt = until;
      }
      final backgroundStart = _nextBackgroundStart;
      final backgroundReadyAt =
          backgroundStart != null &&
              (readyAt == null || backgroundStart.isAfter(readyAt))
          ? backgroundStart
          : readyAt;
      var next = -1;
      DateTime? earliest;
      for (var i = 0; i < _queue.length; i++) {
        final priority = _queue[i].context.priority;
        final start = priority == RemoteReadPriority.background
            ? backgroundReadyAt
            : readyAt;
        if (start != null && start.isAfter(now)) {
          if (earliest == null || start.isBefore(earliest)) earliest = start;
        } else if (next == -1 ||
            priority.index < _queue[next].context.priority.index) {
          next = i;
        }
      }
      if (next == -1) {
        if (earliest == backgroundReadyAt && backgroundReadyAt != readyAt) {
          // 后台请求提升优先级后重新排队，无需等到后台间隔结束。
          for (final request in _queue) {
            final context = request.context;
            if (_waitingOnBackgroundInterval.add(context)) {
              (context._promotionListeners ??= {}).add(_schedulePump);
            }
          }
        }
        _timer = Timer(earliest!.difference(now), () {
          _timer = null;
          _schedulePump();
        });
        return;
      }
      final request = _queue.removeAt(next);
      _active++;
      final nextStart = now.add(minInterval);
      _nextStart = nextStart;
      if (request.context.priority == RemoteReadPriority.background) {
        _nextBackgroundStart = now.add(backgroundMinInterval ?? minInterval);
      } else if (_nextBackgroundStart?.isAfter(nextStart) != true) {
        _nextBackgroundStart = nextStart;
      }
      _probeInFlight = _needsProbe;
      unawaited(_execute(request, isProbe: _probeInFlight));
    }
  }

  Future<void> _execute<T>(
    _RemoteReadRequest<T> request, {
    required bool isProbe,
  }) async {
    final deadline = _cooldownUntil;
    Future<T> performRequest() async {
      try {
        return await request.action();
      } catch (error) {
        await recordFailure(error);
        rethrow;
      }
    }

    try {
      final value = await request.context.run(
        () => runZoned(
          performRequest,
          zoneValues: {_schedulerZoneKey: (this, request)},
        ),
      );
      final token = request.cancelToken;
      if (token?.isCancelled == true) {
        request.cancel(token!.cancelError!);
        return;
      }
      _consecutiveRateLimits = 0;
      // 探针在途时，其他请求可能开启了新一轮冷却。
      if (isProbe && _cooldownUntil == deadline) _needsProbe = false;
      request.result.complete(value);
    } catch (error, stackTrace) {
      if (!request.result.isCompleted) {
        request.result.completeError(error, stackTrace);
      }
    } finally {
      if (isProbe) _probeInFlight = false;
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
  RemoteStorageException? recordedRateLimit;

  void cancel(DioException error) {
    if (!result.isCompleted) result.completeError(error, error.stackTrace);
  }
}
