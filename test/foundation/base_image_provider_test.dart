import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/image_provider/base_image_provider.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/remote_storage/remote_file_store.dart';

class _TestImage extends BaseImageProvider<_TestImage> {
  _TestImage({this.emptyCount = 1, this.cacheWrite, this.beforeLoad});
  final int emptyCount;
  final Future<void>? cacheWrite;
  final FutureOr<void> Function(int attempt, void Function() checkStop)?
  beforeLoad;
  int attempts = 0;
  @override
  String get key => 'test-${identityHashCode(hash)}';
  final Object hash = Object();
  @override
  Future<_TestImage> obtainKey(ImageConfiguration configuration) async => this;
  @override
  Future<void> cacheImageAfterDecoding() => cacheWrite ?? Future.value();
  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    final attempt = ++attempts;
    if (beforeLoad case final prepare?) await prepare(attempt, checkStop);
    if (attempt <= emptyCount) return Uint8List(0);
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Object?> resolveImage(_TestImage provider) async {
    final result = Completer<Object?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (image, synchronous) {
        image.dispose();
        if (!result.isCompleted) result.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!result.isCompleted) result.complete(error);
      },
    );
    stream.addListener(listener);
    try {
      return await result.future.timeout(const Duration(seconds: 5));
    } finally {
      stream.removeListener(listener);
      await provider.evict();
    }
  }

  test('empty bytes retry automatically and eventually decode', () async {
    final provider = _TestImage();
    expect(await resolveImage(provider), isNull);
    expect(provider.attempts, 2);
  });

  test('first image frame does not wait for cache persistence', () async {
    final write = Completer<void>();
    final provider = _TestImage(emptyCount: 0, cacheWrite: write.future);
    try {
      expect(await resolveImage(provider), isNull);
      expect(write.isCompleted, isFalse);
    } finally {
      write.complete();
    }
  });

  test('permanently empty bytes stop after three attempts', () async {
    final provider = _TestImage(emptyCount: 99);
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);
    final error = await resolveImage(provider);
    expect(error.toString(), contains('Empty image data'));
    expect(provider.attempts, 3);
  });

  test('retry delay completes when cancel signal fires', () async {
    final cancel = Completer<void>();
    var completed = false;

    final wait =
        BaseImageProvider.debugWaitForRetryDelay(
          const Duration(seconds: 30),
          cancel.future,
        ).then((_) {
          completed = true;
        });

    await pumpEventQueue();
    expect(completed, isFalse);

    cancel.complete();
    await wait.timeout(const Duration(seconds: 1));

    expect(completed, isTrue);
  });

  test('retry delay still completes normally without cancel', () async {
    await BaseImageProvider.debugWaitForRetryDelay(
      Duration.zero,
      Completer<void>().future,
    ).timeout(const Duration(seconds: 1));
  });

  test('移除最后一个界面监听后取消挂起图片，重新解析可出图', () async {
    final started = Completer<void>();
    final cancelled = Completer<void>();
    final release = Completer<void>();
    final provider = _TestImage(
      emptyCount: 0,
      beforeLoad: (attempt, checkStop) async {
        if (attempt != 1) return;
        unawaited(
          BaseImageProvider.cancelSignalOf(checkStop).then((_) {
            cancelled.complete();
          }),
        );
        started.complete();
        await release.future;
        checkStop();
      },
    );
    final errors = <FlutterErrorDetails>[];
    final previousErrorHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    final cache = PaintingBinding.instance.imageCache;
    final stream = provider.resolve(ImageConfiguration.empty);
    final listeners = List.generate(
      2,
      (_) => ImageStreamListener((info, _) => info.dispose()),
    );
    for (final listener in listeners) {
      stream.addListener(listener);
    }

    try {
      await started.future.timeout(const Duration(seconds: 5));
      expect(cache.statusForKey(provider).pending, isTrue);

      stream.removeListener(listeners.removeLast());
      await pumpEventQueue();
      expect(cancelled.isCompleted, isFalse);
      expect(cache.statusForKey(provider).pending, isTrue);

      stream.removeListener(listeners.removeLast());
      expect(cache.statusForKey(provider).pending, isTrue);
      await cancelled.future.timeout(const Duration(seconds: 5));
      expect(cache.statusForKey(provider).pending, isFalse);
      release.complete();
      await pumpEventQueue();
      expect(errors, isEmpty);

      expect(await resolveImage(provider), isNull);
      expect(provider.attempts, 2);
      expect(errors, isEmpty);
    } finally {
      for (final listener in listeners) {
        stream.removeListener(listener);
      }
      if (!release.isCompleted) release.complete();
      await pumpEventQueue();
      await provider.evict();
      FlutterError.onError = previousErrorHandler;
    }
  });

  test('远端缺失、限流、鉴权失败、取消和漫画源缺失均不重试', () async {
    final muted = Log.isMuted;
    Log.isMuted = true;
    addTearDown(() => Log.isMuted = muted);

    const notFound = RemoteStorageException('failed get dir: object not found');
    expect(notFound.isNotFound, isTrue);
    final token = CancelToken()..cancel('主动取消');
    final failures = <Object>[
      notFound,
      const RemoteStorageException('请求暂缓', code: '429'),
      const RemoteStorageException('凭据失效', code: '401'),
      token.cancelError!,
      'Comic source not found.',
    ];

    for (final failure in failures) {
      final provider = _TestImage(beforeLoad: (_, _) => throw failure);
      expect(await resolveImage(provider), same(failure));
      expect(provider.attempts, 1, reason: failure.toString());
    }
  });
}
