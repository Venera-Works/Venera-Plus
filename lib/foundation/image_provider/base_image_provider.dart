import 'dart:async'
    show
        Completer,
        Future,
        StreamController,
        Timer,
        scheduleMicrotask,
        unawaited;
import 'dart:io' show FileSystemException;
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/reader_diagnostics.dart';
import 'package:venera_plus/foundation/missing_download_page.dart';
import 'package:venera_plus/network/remote_storage/remote_file_store.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static final Expando<Future<void>> _cancelSignals = Expando<Future<void>>();

  static Future<void> cancelSignalOf(void Function() checkStop) {
    return _cancelSignals[checkStop] ?? Completer<void>().future;
  }

  @visibleForTesting
  static Future<void> debugWaitForRetryDelay(
    Duration duration,
    Future<void> cancelSignal,
  ) {
    return _waitForRetryDelay(duration, cancelSignal);
  }

  static Future<void> _waitForRetryDelay(
    Duration duration,
    Future<void> cancelSignal,
  ) {
    final delay = Completer<void>();
    final timer = Timer(duration, delay.complete);
    return Future.any([delay.future, cancelSignal]).whenComplete(timer.cancel);
  }

  static const int maxImagePixel = 2560 * 1440;

  @protected
  TargetImageSize getTargetSize(int width, int height) {
    // ignore invalid size
    if (width <= 0 || height <= 0) {
      return TargetImageSize(width: width, height: height);
    }
    // ignore too wide or too tall image
    final imageRatio = width / height;
    if (imageRatio > 2 || imageRatio < 0.5) {
      return TargetImageSize(width: width, height: height);
    }
    // resize if too large
    if (width * height > maxImagePixel) {
      final ratio = sqrt(maxImagePixel / (width * height));
      return TargetImageSize(
        width: (width * ratio).round(),
        height: (height * ratio).round(),
      );
    }
    return TargetImageSize(width: width, height: height);
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    final stopCompleter = Completer<void>();
    void stopLoading() {
      if (!stopCompleter.isCompleted) stopCompleter.complete();
    }

    chunkEvents.onCancel = stopLoading;
    var evicted = false;
    void evict() {
      if (evicted) return;
      evicted = true;
      PaintingBinding.instance.imageCache.evict(key);
    }

    return _BaseImageStreamCompleter(
      cacheKey: key,
      codec: _loadBufferAsync(chunkEvents, decode, stopCompleter, evict),
      chunkEvents: chunkEvents,
      onAbandoned: () {
        stopLoading();
        evict();
      },
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
    Completer<void> stopCompleter,
    VoidCallback evict,
  ) async {
    try {
      int retryTime = 1;

      void checkStop() {
        if (stopCompleter.isCompleted) {
          throw const _ImageLoadingStopException();
        }
      }

      BaseImageProvider._cancelSignals[checkStop] = stopCompleter.future;

      Uint8List? data;
      var emptyRetries = 0;

      while (data == null && !stopCompleter.isCompleted) {
        try {
          final loaded = await load(chunkEvents, checkStop);
          checkStop();
          if (loaded.isEmpty) {
            if (emptyRetries++ >= 2) throw const _EmptyImageDataException();
            await _waitForRetryDelay(
              Duration(milliseconds: 150 * emptyRetries),
              stopCompleter.future,
            );
            continue;
          }
          data = loaded;
        } on _ImageLoadingStopException {
          rethrow;
        } on _EmptyImageDataException {
          rethrow;
        } catch (e) {
          checkStop();
          if (e is MissingDownloadPage ||
              e is StateError ||
              (e is DioException && CancelToken.isCancel(e)) ||
              (e is RemoteStorageException &&
                  (e.isNotFound ||
                      e.isRateLimited ||
                      e.isAuthorizationFailure))) {
            rethrow;
          }
          // Local IO already has bounded retries. Network cache failures keep
          // the existing retry policy.
          if (e is FileSystemException && !retryFileSystemErrors) rethrow;
          final message = e.toString();
          if (message.contains('Comic source not found') ||
              message.toLowerCase().contains('object not found') ||
              message.contains('Invalid Status Code: 404') ||
              message.contains('Invalid Status Code: 403')) {
            rethrow;
          }
          if (message.contains('handshake')) {
            if (retryTime < 5) {
              retryTime = 5;
            }
          }
          retryTime <<= 1;
          if (retryTime > (1 << 3)) {
            rethrow;
          }
          await _waitForRetryDelay(
            Duration(seconds: retryTime),
            stopCompleter.future,
          );
        }
      }

      checkStop();

      final bytes = data!;
      final diagnostics = ReaderDiagnostics.current;
      final codecSpan = diagnostics?.beginImageSpan(
        hashCode,
        ReaderDiagnosticStage.codecInitWait,
      );
      try {
        final buffer = await ImmutableBuffer.fromUint8List(bytes);
        if (stopCompleter.isCompleted) {
          buffer.dispose();
          checkStop();
        }
        final codec = await decode(
          buffer,
          getTargetSize: enableResize ? getTargetSize : null,
        );
        if (stopCompleter.isCompleted) {
          codec.dispose();
          checkStop();
        }
        codecSpan?.finish(bytes: bytes.length);
        unawaited(
          cacheImageAfterDecoding().catchError((
            Object error,
            StackTrace stack,
          ) {
            Log.warning('Image cache', '$error\n$stack');
          }),
        );
        return diagnostics == null
            ? codec
            : ReaderDiagnosticCodec(codec, diagnostics, hashCode);
      } on _ImageLoadingStopException {
        codecSpan?.finish(success: false);
        rethrow;
      } catch (e) {
        codecSpan?.finish(success: false);
        await evictDiskCache();
        if (bytes.length < 2 * 1024) {
          // data is too short, it's likely that the data is text, not image
          try {
            var text = const Utf8Codec(
              allowMalformed: false,
            ).decoder.convert(bytes);
            throw Exception("Expected image data, but got text: $text");
          } catch (e) {
            // ignore
          }
        }
        rethrow;
      }
    } on _ImageLoadingStopException {
      scheduleMicrotask(evict);
      rethrow;
    } catch (e, s) {
      scheduleMicrotask(evict);
      Log.error("Image Loading", e, s);
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  );

  /// Persist completed image data only after the decoder accepts it.
  @protected
  Future<void> cacheImageAfterDecoding() async {}

  @protected
  Future<void> evictDiskCache() => CacheManager().delete(diskCacheKey);

  String get key;

  /// Key used for disk cache operations (e.g. deletion on decode failure).
  /// Defaults to [key]. Subclasses may override this to return their disk cache key.
  String get diskCacheKey => key;

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }

  bool get enableResize => false;

  bool get retryFileSystemErrors => true;
}

class _BaseImageStreamCompleter extends MultiFrameImageStreamCompleter {
  _BaseImageStreamCompleter({
    required this.cacheKey,
    required this.chunkEvents,
    required this.onAbandoned,
    required super.codec,
    super.informationCollector,
  }) : super(scale: 1.0, chunkEvents: chunkEvents.stream);

  final Object cacheKey;
  final StreamController<ImageChunkEvent> chunkEvents;
  final VoidCallback onAbandoned;
  final _loadingListeners = <ImageStreamListener>[];
  bool _abandoned = false;

  @override
  void addListener(ImageStreamListener listener) {
    if (!chunkEvents.isClosed) _loadingListeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    final hadExternalListener = _loadingListeners.length > 1;
    final removed = _loadingListeners.remove(listener);
    super.removeListener(listener);
    if (!removed ||
        !hadExternalListener ||
        _loadingListeners.length > 1 ||
        chunkEvents.isClosed) {
      return;
    }

    final cache = PaintingBinding.instance.imageCache;
    if (!cache.statusForKey(cacheKey).pending) return;
    // 等待同一轮界面更新中重新挂上的监听器，只取消仍由缓存单独持有的加载。
    scheduleMicrotask(() {
      if (!chunkEvents.isClosed &&
          _loadingListeners.length <= 1 &&
          cache.statusForKey(cacheKey).pending &&
          identical(cache.putIfAbsent(cacheKey, () => this), this)) {
        _abandoned = true;
        onAbandoned();
      }
    });
  }

  @override
  void reportError({
    DiagnosticsNode? context,
    required Object exception,
    StackTrace? stack,
    InformationCollector? informationCollector,
    bool silent = false,
  }) {
    if (_abandoned && exception is _ImageLoadingStopException) return;
    super.reportError(
      context: context,
      exception: exception,
      stack: stack,
      informationCollector: informationCollector,
      silent: silent,
    );
  }
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);

class _ImageLoadingStopException implements Exception {
  const _ImageLoadingStopException();
}

class _EmptyImageDataException implements Exception {
  const _EmptyImageDataException();

  @override
  String toString() => 'Empty image data after 3 attempts';
}
