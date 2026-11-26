import 'dart:async' show Completer, Future, FutureOr, StreamController;
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/network/images.dart';
import 'base_image_provider.dart';
import 'cached_image.dart' as image_provider;

class CachedImageProvider
    extends BaseImageProvider<image_provider.CachedImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const CachedImageProvider(
    this.url, {
    this.headers,
    this.sourceKey,
    this.cid,
    this.fallback,
  });

  final String url;

  final Map<String, String>? headers;

  final String? sourceKey;

  final String? cid;

  final FutureOr<Uint8List?> Function()? fallback;

  static int loadingCount = 0;

  static const _kMaxLoadingCount = 8;

  static final _thumbnailLoadSlots = _AsyncSemaphore(_kMaxLoadingCount + 1);

  @visibleForTesting
  static Future<T> debugRunWithThumbnailSlot<T>(
    Future<T> Function() task, {
    void Function()? checkStop,
  }) {
    return _runWithThumbnailSlot(task, checkStop: checkStop);
  }

  static Future<T> _runWithThumbnailSlot<T>(
    Future<T> Function() task, {
    void Function()? checkStop,
  }) {
    return _thumbnailLoadSlots.run(() async {
      checkStop?.call();
      loadingCount++;
      try {
        return await task();
      } finally {
        loadingCount--;
      }
    });
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    return _runWithThumbnailSlot(
      () => _loadImage(
        chunkEvents: chunkEvents,
        checkStop: checkStop,
        allowEmpty: true, // BaseImageProvider retries empty data.
      ),
      checkStop: checkStop,
    );
  }

  /// Reads the encoded image bytes without decoding or resizing the image.
  Future<Uint8List> loadOriginalBytes() => _runWithThumbnailSlot(_loadImage);

  Future<Uint8List> _loadImage({
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? checkStop,
    bool allowEmpty = false,
  }) async {
    try {
      Uint8List? data;
      if (url.startsWith("file://")) {
        data = await File(url.substring(7)).readAsBytes();
      } else {
        await for (final progress in ImageDownloader.loadThumbnail(
          url,
          sourceKey,
          cid,
          checkStop == null
              ? null
              : BaseImageProvider.cancelSignalOf(checkStop),
        )) {
          checkStop?.call();
          chunkEvents?.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: progress.currentBytes,
              expectedTotalBytes: progress.totalBytes,
            ),
          );
          data = progress.imageBytes;
          if (data != null) break;
        }
      }
      if (data != null && (allowEmpty || data.isNotEmpty)) {
        return data;
      }
      checkStop?.call();
      throw "Error: Empty response body.";
    } catch (_) {
      checkStop?.call();
      final fallbackImage = await fallback?.call();
      if (fallbackImage != null && fallbackImage.isNotEmpty) {
        return fallbackImage;
      }
      rethrow;
    }
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => url + (sourceKey ?? "") + (cid ?? "");
}

class _AsyncSemaphore {
  final int maxConcurrent;

  int _active = 0;

  final _waiters = Queue<Completer<void>>();

  _AsyncSemaphore(this.maxConcurrent);

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
      return;
    }
    _active--;
  }
}
