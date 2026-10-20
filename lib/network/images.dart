import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/consts.dart';
import 'package:venera_plus/foundation/image_processing.dart';
import 'package:venera_plus/foundation/log.dart';

import 'app_dio.dart';

typedef ThumbnailLoadingConfigResolver =
    FutureOr<Map<String, dynamic>> Function(String sourceKey, String url);

typedef ThumbnailCoverResolver =
    FutureOr<String?> Function(String sourceKey, String cid);

enum ComicImageTargetFit {
  contain,
  fitWidth,
  fitHeight;

  static ComicImageTargetFit fromString(String? value) {
    return switch (value) {
      'fitWidth' => ComicImageTargetFit.fitWidth,
      'fitHeight' => ComicImageTargetFit.fitHeight,
      _ => ComicImageTargetFit.contain,
    };
  }
}

@immutable
class ComicImageLoadTarget {
  final double? logicalWidth;
  final double? logicalHeight;
  final double devicePixelRatio;
  final ComicImageTargetFit fit;
  final bool splitWideImage;

  ComicImageLoadTarget({
    double? logicalWidth,
    double? logicalHeight,
    double devicePixelRatio = 1.0,
    this.fit = ComicImageTargetFit.contain,
    this.splitWideImage = false,
  }) : logicalWidth =
           (logicalWidth != null && logicalWidth.isFinite && logicalWidth > 0)
           ? logicalWidth
           : null,
       logicalHeight =
           (logicalHeight != null &&
               logicalHeight.isFinite &&
               logicalHeight > 0)
           ? logicalHeight
           : null,
       devicePixelRatio = (devicePixelRatio.isFinite && devicePixelRatio > 0)
           ? devicePixelRatio
           : 1.0;

  const ComicImageLoadTarget.raw({
    this.logicalWidth,
    this.logicalHeight,
    this.devicePixelRatio = 1.0,
    this.fit = ComicImageTargetFit.contain,
    this.splitWideImage = false,
  });

  double get normalizedDevicePixelRatio =>
      (devicePixelRatio.isFinite && devicePixelRatio > 0)
      ? devicePixelRatio
      : 1.0;

  int? get physicalWidth {
    final w = logicalWidth;
    if (w == null || !w.isFinite || w <= 0) {
      return null;
    }
    final pw = (w * normalizedDevicePixelRatio).round();
    return pw > 0 ? pw : null;
  }

  int? get physicalHeight {
    final h = logicalHeight;
    if (h == null || !h.isFinite || h <= 0) {
      return null;
    }
    final ph = (h * normalizedDevicePixelRatio).round();
    return ph > 0 ? ph : null;
  }

  String get cacheIdentity {
    final pw = physicalWidth;
    final ph = physicalHeight;
    final wStr = pw != null ? 'w$pw' : 'wnull';
    final hStr = ph != null ? 'h$ph' : 'hnull';
    return '$wStr-$hStr-dpr$normalizedDevicePixelRatio-${fit.name}-split$splitWideImage';
  }

  Map<String, dynamic> toJson() {
    final w =
        (logicalWidth != null && logicalWidth!.isFinite && logicalWidth! > 0)
        ? logicalWidth
        : null;
    final h =
        (logicalHeight != null && logicalHeight!.isFinite && logicalHeight! > 0)
        ? logicalHeight
        : null;
    return {
      'logicalWidth': w,
      'logicalHeight': h,
      'devicePixelRatio': normalizedDevicePixelRatio,
      'fit': fit.name,
      'splitWideImage': splitWideImage,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ComicImageLoadTarget &&
        physicalWidth == other.physicalWidth &&
        physicalHeight == other.physicalHeight &&
        normalizedDevicePixelRatio == other.normalizedDevicePixelRatio &&
        fit == other.fit &&
        splitWideImage == other.splitWideImage;
  }

  @override
  int get hashCode {
    return Object.hash(
      physicalWidth,
      physicalHeight,
      normalizedDevicePixelRatio,
      fit,
      splitWideImage,
    );
  }

  @override
  String toString() =>
      'ComicImageLoadTarget(physical: ${physicalWidth}x$physicalHeight, dpr: $normalizedDevicePixelRatio, fit: ${fit.name}, split: $splitWideImage)';
}

typedef ComicImageLoadingConfigResolver =
    FutureOr<Map<String, dynamic>> Function(
      String sourceKey,
      String imageKey,
      String cid,
      String eid, {
      ComicImageLoadTarget? target,
    });

typedef ComicImageDebugLoader =
    Stream<ImageDownloadProgress> Function(
      String imageKey,
      String? sourceKey,
      String cid,
      String eid, {
      ComicImageLoadTarget? target,
    });

/// Loads image bytes for a built-in source and cancels its underlying work.
typedef ComicImageBytesLoader =
    Future<Uint8List> Function(CancelToken cancelToken);

typedef ComicImageTransport =
    FutureOr<dynamic> Function(String url, Map<String, dynamic> configs);

abstract class ImageDownloader {
  // Keep accepted bytes available while their disk write is in progress.
  static final _pendingProcessedImages =
      <String, ({Uint8List bytes, Future<void> written})>{};

  static Future<void> cacheProcessedImage(String key, Uint8List bytes) {
    final pending = _pendingProcessedImages[key];
    if (pending != null) return pending.written;
    final written = Future<void>(() async {
      try {
        await CacheManager().writeCache(key, bytes);
      } catch (error, stack) {
        Log.warning('Reader image cache', '$error\n$stack');
      } finally {
        _pendingProcessedImages.remove(key);
      }
    });
    _pendingProcessedImages[key] = (bytes: bytes, written: written);
    return written;
  }

  static Future<void> deleteComicImageCache(String key) async {
    await _pendingProcessedImages[key]?.written;
    await CacheManager().delete(key);
  }

  @visibleForTesting
  static Future<void> debugFlushImageCacheWrites() async {
    await Future.wait(
      _pendingProcessedImages.values.map((entry) => entry.written),
    );
  }

  static ThumbnailLoadingConfigResolver? _thumbnailLoadingConfigResolver;

  static ThumbnailCoverResolver? _thumbnailCoverResolver;

  static ComicImageLoadingConfigResolver? _comicImageLoadingConfigResolver;

  static void configureSourceImageLoading({
    ThumbnailLoadingConfigResolver? thumbnailLoadingConfig,
    ThumbnailCoverResolver? thumbnailCover,
    ComicImageLoadingConfigResolver? comicImageLoadingConfig,
  }) {
    _thumbnailLoadingConfigResolver = thumbnailLoadingConfig;
    _thumbnailCoverResolver = thumbnailCover;
    _comicImageLoadingConfigResolver = comicImageLoadingConfig;
  }

  @visibleForTesting
  static void debugResetSourceImageLoading() {
    configureSourceImageLoading();
    _debugLoadComicImageUnwrapped = null;
    _debugComicImageTransport = null;
  }

  static ComicImageTransport? _debugComicImageTransport;

  @visibleForTesting
  static ComicImageTransport? get debugComicImageTransport =>
      _debugComicImageTransport;

  @visibleForTesting
  static set debugComicImageTransport(ComicImageTransport? transport) {
    _debugComicImageTransport = transport;
  }

  static ComicImageDebugLoader? _debugLoadComicImageUnwrapped;

  @visibleForTesting
  static ComicImageDebugLoader? get debugLoadComicImageUnwrapped =>
      _debugLoadComicImageUnwrapped;

  @visibleForTesting
  static set debugLoadComicImageUnwrapped(ComicImageDebugLoader? loader) {
    _debugLoadComicImageUnwrapped = loader;
  }

  /// Generate a stable cache key for comic images.
  /// Used for active deduplication and existing target-specific disk entries.
  static String getComicImageCacheKey(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) {
    final base = "$imageKey@$sourceKey@$cid@$eid";
    if (target != null) {
      return "$base@${target.cacheIdentity}";
    }
    return base;
  }

  /// Alias for building comic image cache key.
  static String buildComicImageCacheKey(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) => getComicImageCacheKey(imageKey, sourceKey, cid, eid, target: target);

  @visibleForTesting
  static bool debugShouldRetryImageLoad({
    required int retriesRemaining,
    required bool hasOnLoadFailed,
  }) {
    return _shouldRetryImageLoad(
      retriesRemaining: retriesRemaining,
      hasOnLoadFailed: hasOnLoadFailed,
    );
  }

  static bool _shouldRetryImageLoad({
    required int retriesRemaining,
    required bool hasOnLoadFailed,
  }) {
    return retriesRemaining > 0 && hasOnLoadFailed;
  }

  @visibleForTesting
  static Future<List<int>> debugApplyImageResponseCallback(
    JSInvokable onResponse,
    List<int> buffer,
  ) {
    return _applyImageResponseCallback(onResponse, buffer);
  }

  static Future<List<int>> _applyImageResponseCallback(
    JSInvokable onResponse,
    List<int> buffer,
  ) async {
    try {
      dynamic result = onResponse([Uint8List.fromList(buffer)]);
      if (result is Future) {
        result = await result;
      }
      if (result is List<int>) {
        return result;
      }
      throw "Error: Invalid onResponse result.";
    } finally {
      onResponse.free();
    }
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> debugResolveImageLoadFailure(
    JSInvokable onLoadFailed,
  ) {
    return _resolveImageLoadFailure(onLoadFailed);
  }

  static Future<Map<String, dynamic>?> _resolveImageLoadFailure(
    JSInvokable onLoadFailed,
  ) async {
    try {
      dynamic result = onLoadFailed([]);
      if (result is Future) {
        result = await result;
      }
      return _normalizeImageLoadConfig(result);
    } finally {
      onLoadFailed.free();
    }
  }

  static Map<String, dynamic>? _normalizeImageLoadConfig(dynamic result) {
    if (result is! Map) {
      return null;
    }
    final config = <String, dynamic>{};
    for (final entry in result.entries) {
      final key = entry.key;
      if (key is! String) {
        return null;
      }
      config[key] = entry.value;
    }
    return config;
  }

  @visibleForTesting
  static Map<String, dynamic> debugResolveImageHeaders(
    Map<String, dynamic> configs,
  ) {
    return _resolveImageHeaders(configs['headers']);
  }

  static Map<String, dynamic> _resolveImageHeaders(dynamic rawHeaders) {
    if (rawHeaders == null) {
      return <String, dynamic>{'user-agent': webUA};
    }
    if (rawHeaders is! Map) {
      throw ArgumentError(
        'Invalid image headers: expected Map<String, dynamic>?, got ${rawHeaders.runtimeType}',
      );
    }
    final headers = <String, dynamic>{};
    var hasUserAgent = false;
    for (final entry in rawHeaders.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError(
          'Invalid header key: expected String, got $key (${key.runtimeType})',
        );
      }
      if (key.toLowerCase() == 'user-agent') {
        hasUserAgent = true;
      }
      headers[key] = entry.value;
    }
    if (!hasUserAgent) {
      headers['user-agent'] = webUA;
    }
    return headers;
  }

  static Stream<ImageDownloadProgress> loadThumbnail(
    String url,
    String? sourceKey, [
    String? cid,
  ]) {
    final cancelToken = CancelToken();
    return _StreamWrapper<ImageDownloadProgress>(
      _loadThumbnail(url, sourceKey, cid, cancelToken),
      (_) {},
      onCancel: cancelToken.cancel,
    ).stream;
  }

  static Stream<ImageDownloadProgress> _loadThumbnail(
    String url,
    String? sourceKey,
    String? cid,
    CancelToken cancelToken,
  ) async* {
    try {
      final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
      final cache = await CacheManager().findCache(cacheKey);
      if (cancelToken.isCancelled) return;

      if (cache != null) {
        final data = await cache.readAsBytes();
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      }

      var configs = <String, dynamic>{};
      if (sourceKey != null) {
        configs =
            await _thumbnailLoadingConfigResolver?.call(sourceKey, url) ?? {};
      }
      if (cancelToken.isCancelled) return;
      final headers = _resolveImageHeaders(configs['headers']);
      final loadBytes = configs['loadBytes'] as ComicImageBytesLoader?;

      if (loadBytes == null &&
          ((configs['url'] as String?) ?? url).startsWith('cover.') &&
          sourceKey != null &&
          cid != null) {
        final coverUrl = await _thumbnailCoverResolver?.call(sourceKey, cid);
        if (cancelToken.isCancelled) return;
        if (coverUrl != null) {
          yield* _loadThumbnail(coverUrl, sourceKey, null, cancelToken);
          return;
        }
      }

      List<int> buffer;
      if (loadBytes != null) {
        buffer = await loadBytes(cancelToken);
      } else {
        final dio = AppDio(
          BaseOptions(
            headers: headers,
            method: configs['method'] ?? 'GET',
            responseType: ResponseType.stream,
          ),
        );

        String requestUrl = configs['url'] ?? url;
        if (requestUrl.startsWith('//')) {
          requestUrl = 'https:$requestUrl';
        }
        final req = await dio.request<ResponseBody>(
          requestUrl,
          data: configs['data'],
          cancelToken: cancelToken,
        );
        final stream =
            req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        final chunks = BytesBuilder(copy: false);
        await for (final data in stream) {
          if (cancelToken.isCancelled) return;
          chunks.add(data);
          if (expectedBytes != null) {
            yield ImageDownloadProgress(
              currentBytes: chunks.length,
              totalBytes: expectedBytes,
            );
          }
        }
        buffer = chunks.takeBytes();
      }
      if (cancelToken.isCancelled) return;

      if (configs['onResponse'] is JSInvokable) {
        buffer = await _applyImageResponseCallback(
          configs['onResponse'] as JSInvokable,
          buffer,
        );
      }
      if (cancelToken.isCancelled) return;

      await CacheManager().writeCache(cacheKey, buffer);
      yield ImageDownloadProgress(
        currentBytes: buffer.length,
        totalBytes: buffer.length,
        imageBytes: buffer is Uint8List ? buffer : Uint8List.fromList(buffer),
      );
    } catch (_) {
      if (cancelToken.isCancelled) return;
      rethrow;
    }
  }

  static final _loadingImages =
      <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values.toList()) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Preload a comic image from the network or cache.
  ///
  /// Consumes the shared stream from [loadComicImage] so that the active
  /// stream is not cancelled when UI listeners unmount or cancel.
  static Future<void> preloadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) async {
    final cacheKey = getComicImageCacheKey(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    );
    await for (final progress in loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    )) {
      final bytes = progress.imageBytes;
      if (bytes == null ||
          progress.diskCacheKey == null ||
          progress.diskCacheKey == cacheKey) {
        continue;
      }
      // Accept the encoded image without decoding its full pixel buffer.
      // Invalid responses remain for the display provider to report and evict.
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        descriptor.dispose();
      } catch (_) {
        continue;
      } finally {
        buffer.dispose();
      }
      await cacheProcessedImage(cacheKey, bytes);
    }
  }

  /// Load comic image bytes from the network or cache.
  ///
  /// Consumes the shared stream from [loadComicImage] and returns the
  /// final non-null [Uint8List]. Throws a [StateError] if the stream
  /// finishes without delivering image bytes.
  static Future<Uint8List> loadComicImageBytes(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) async {
    Uint8List? result;
    await for (final progress in loadComicImage(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    )) {
      if (progress.imageBytes != null) {
        result = progress.imageBytes;
      }
    }
    if (result != null) {
      return result;
    }
    throw StateError(
      'Comic image stream finished without delivering image bytes for $imageKey',
    );
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) {
    final cacheKey = getComicImageCacheKey(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    );
    final activeStream = _loadingImages[cacheKey];
    if (activeStream != null) {
      if (!activeStream.isClosed) {
        return activeStream.stream;
      }
      _loadingImages.remove(cacheKey);
    }
    final debugLoader = debugLoadComicImageUnwrapped;
    final cancelToken = CancelToken();
    final stream = _StreamWrapper<ImageDownloadProgress>(
      debugLoader?.call(imageKey, sourceKey, cid, eid, target: target) ??
          _loadComicImage(
            imageKey,
            sourceKey,
            cid,
            eid,
            target: target,
            cancelToken: cancelToken,
          ),
      (wrapper) {
        if (identical(_loadingImages[cacheKey], wrapper)) {
          _loadingImages.remove(cacheKey);
        }
      },
      onCancel: cancelToken.cancel,
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
  }) {
    final debugLoader = debugLoadComicImageUnwrapped;
    if (debugLoader != null) {
      return debugLoader(imageKey, sourceKey, cid, eid, target: target);
    }
    final cancelToken = CancelToken();
    return _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
        target: target,
        cancelToken: cancelToken,
      ),
      (_) {},
      onCancel: cancelToken.cancel,
    ).stream;
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    ComicImageLoadTarget? target,
    required CancelToken cancelToken,
  }) async* {
    final cacheKey = getComicImageCacheKey(
      imageKey,
      sourceKey,
      cid,
      eid,
      target: target,
    );
    final pending = _pendingProcessedImages[cacheKey];
    if (pending != null) {
      yield ImageDownloadProgress(
        currentBytes: pending.bytes.length,
        totalBytes: pending.bytes.length,
        imageBytes: pending.bytes,
        diskCacheKey: cacheKey,
      );
      return;
    }
    final cache = await CacheManager().findCache(cacheKey);
    if (cancelToken.isCancelled) return;

    if (cache != null) {
      final data = await cache.readAsBytes();
      yield ImageDownloadProgress(
        currentBytes: data.length,
        totalBytes: data.length,
        imageBytes: data,
        diskCacheKey: cacheKey,
      );
      return;
    }

    JSInvokable? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      configs =
          await _comicImageLoadingConfigResolver?.call(
            sourceKey,
            imageKey,
            cid,
            eid,
            target: target,
          ) ??
          {};
    }
    var retriesRemaining = 5;
    while (true) {
      String? requestCacheKey;
      try {
        final headers = _resolveImageHeaders(configs['headers']);
        final effectiveConfigs = <String, dynamic>{
          ...configs,
          'headers': headers,
        };

        final onLoadFailedConfig = effectiveConfigs['onLoadFailed'];
        onLoadFailed = onLoadFailedConfig is JSInvokable
            ? onLoadFailedConfig
            : null;
        if (cancelToken.isCancelled) return;
        final loadBytes =
            effectiveConfigs['loadBytes'] as ComicImageBytesLoader?;

        if (loadBytes != null) {
          // Native callbacks and temporary transport URLs are not cache identities.
          requestCacheKey = '$cacheKey@request:loadBytes';
        } else {
          try {
            final request = jsonEncode([
              effectiveConfigs['url'] ?? imageKey,
              effectiveConfigs['method'] ?? 'GET',
              SplayTreeMap<String, dynamic>.from(headers),
              effectiveConfigs['data'],
            ]);
            final base = getComicImageCacheKey(imageKey, sourceKey, cid, eid);
            requestCacheKey =
                '$base@request:${sha256.convert(utf8.encode(request))}';
          } on JsonUnsupportedObjectError {
            // Streamed request bodies retain their target-specific cache.
          }
        }
        final cached = requestCacheKey == null
            ? null
            : await CacheManager().findCache(requestCacheKey);
        if (cancelToken.isCancelled) return;
        List<int> buffer;
        if (cached != null) {
          buffer = await cached.readAsBytes();
        } else {
          Stream<List<int>> stream;
          int? expectedBytes;

          final transport = _debugComicImageTransport;
          if (loadBytes != null) {
            final bytes = await loadBytes(cancelToken);
            if (cancelToken.isCancelled) return;
            stream = Stream.value(bytes);
            expectedBytes = bytes.length;
          } else if (transport != null) {
            final transportResult = await transport(
              effectiveConfigs['url'] ?? imageKey,
              effectiveConfigs,
            );
            if (transportResult is Stream<List<int>>) {
              stream = transportResult;
              expectedBytes = null;
            } else if (transportResult is List<int>) {
              stream = Stream.value(transportResult);
              expectedBytes = transportResult.length;
            } else if (transportResult is ResponseBody) {
              stream = transportResult.stream;
              expectedBytes = transportResult.contentLength == -1
                  ? null
                  : transportResult.contentLength;
            } else {
              throw StateError(
                'Unsupported transport result: $transportResult',
              );
            }
          } else {
            var dio = AppDio(
              BaseOptions(
                headers: headers,
                method: effectiveConfigs['method'] ?? 'GET',
                responseType: ResponseType.stream,
              ),
            );

            var req = await dio.request<ResponseBody>(
              effectiveConfigs['url'] ?? imageKey,
              data: effectiveConfigs['data'],
              cancelToken: cancelToken,
            );
            stream = req.data?.stream ?? (throw "Error: Empty response body.");
            expectedBytes = req.data!.contentLength;
            if (expectedBytes == -1) {
              expectedBytes = null;
            }
          }
          final chunks = BytesBuilder(copy: false);
          final progressClock = Stopwatch()..start();
          var reportedProgress = false;
          await for (var data in stream) {
            if (cancelToken.isCancelled) return;
            chunks.add(data);
            if (!reportedProgress ||
                progressClock.elapsedMilliseconds >= 50 ||
                chunks.length == expectedBytes) {
              yield ImageDownloadProgress(
                currentBytes: chunks.length,
                totalBytes: expectedBytes,
              );
              reportedProgress = true;
              progressClock.reset();
            }
          }
          buffer = chunks.takeBytes();
          if (cancelToken.isCancelled) return;
          if (requestCacheKey != null) {
            await CacheManager().writeCache(requestCacheKey, buffer);
          }
        }
        if (cancelToken.isCancelled) return;

        if (effectiveConfigs['onResponse'] is JSInvokable) {
          buffer = await _applyImageResponseCallback(
            effectiveConfigs['onResponse'] as JSInvokable,
            buffer,
          );
        }

        if (cancelToken.isCancelled) return;
        Uint8List data;
        if (buffer is Uint8List) {
          data = buffer;
        } else {
          data = Uint8List.fromList(buffer);
          buffer.clear();
        }

        if (effectiveConfigs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            effectiveConfigs['modifyImage'],
          );
          data = newData;
        }

        if (cancelToken.isCancelled) return;
        if (requestCacheKey == null) {
          await CacheManager().writeCache(cacheKey, data);
        }
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
          diskCacheKey: requestCacheKey ?? cacheKey,
        );
        return;
      } catch (e) {
        if (cancelToken.isCancelled) return;
        if (requestCacheKey != null) {
          await CacheManager().delete(requestCacheKey);
        }
        if (cancelToken.isCancelled) return;
        final onLoadFailedCallback = onLoadFailed;
        if (onLoadFailedCallback == null ||
            !_shouldRetryImageLoad(
              retriesRemaining: retriesRemaining,
              hasOnLoadFailed: true,
            )) {
          rethrow;
        }
        retriesRemaining--;
        onLoadFailed = null;
        var newConfig = await _resolveImageLoadFailure(onLoadFailedCallback);
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
      } finally {
        final onLoadFailedCallback = onLoadFailed;
        if (onLoadFailedCallback != null) {
          onLoadFailed = null;
          onLoadFailedCallback.free();
        }
      }
    }
  }
}

/// Global helper to build comic image cache key.
String buildComicImageCacheKey(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  ComicImageLoadTarget? target,
}) => ImageDownloader.getComicImageCacheKey(
  imageKey,
  sourceKey,
  cid,
  eid,
  target: target,
);

/// Global helper to load comic image bytes from the shared stream.
Future<Uint8List> loadComicImageBytes(
  String imageKey,
  String? sourceKey,
  String cid,
  String eid, {
  ComicImageLoadTarget? target,
}) => ImageDownloader.loadComicImageBytes(
  imageKey,
  sourceKey,
  cid,
  eid,
  target: target,
);

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController<T>> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  final void Function()? onCancel;

  bool isClosed = false;

  StreamSubscription<T>? _subscription;

  _StreamWrapper(this._stream, this.onClosed, {this.onCancel}) {
    _listen();
  }

  void _listen() {
    _subscription = _stream.listen(
      (data) {
        if (isClosed) {
          return;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (isClosed) {
          return;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.addError(error, stackTrace);
          }
        }
      },
      onDone: _close,
    );
  }

  void _close() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    for (var controller in controllers) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    controllers.clear();
    _subscription = null;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
      if (controllers.isEmpty) {
        cancel();
      }
    };
    return controller.stream;
  }

  void cancel() {
    if (isClosed) {
      return;
    }
    isClosed = true;
    onCancel?.call();
    for (var controller in controllers) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    controllers.clear();
    final subscription = _subscription;
    _subscription = null;
    onClosed(this);
    if (subscription == null) {
      return;
    }
    unawaited(subscription.cancel());
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  /// Actual disk entry to evict if the completed image cannot be decoded.
  final String? diskCacheKey;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
    this.diskCacheKey,
  });
}
