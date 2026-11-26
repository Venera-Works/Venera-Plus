import 'dart:async' show Completer, Future, FutureOr, StreamController;
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
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
  static final _remoteThumbnailLoadSlots = <String, _AsyncSemaphore>{};

  @visibleForTesting
  static Future<T> debugRunWithThumbnailSlot<T>(
    Future<T> Function() task, {
    void Function()? checkStop,
  }) {
    return _runWithThumbnailSlot(task, checkStop: checkStop);
  }

  static Future<T> _runWithThumbnailSlot<T>(
    Future<T> Function() task, {
    Future<void>? cancelSignal,
    void Function()? checkStop,
  }) {
    return _thumbnailLoadSlots.run(
      () async {
        loadingCount++;
        try {
          return await task();
        } finally {
          loadingCount--;
        }
      },
      cancelSignal: cancelSignal,
      checkStop: checkStop,
    );
  }

  @override
  Future<Uint8List> load(chunkEvents, checkStop) {
    if (url.startsWith('file://')) {
      return _loadWithFallback(
        () => File(url.substring(7)).readAsBytes(),
        checkStop,
      );
    }

    final cancelSignal = BaseImageProvider.cancelSignalOf(checkStop);
    Future<Uint8List> loadImage() =>
        _loadImage(chunkEvents, checkStop, cancelSignal);

    final source = sourceKey;
    if (source == null ||
        (source != 'webdav_library' && !source.startsWith('remote_library_'))) {
      return _runWithThumbnailSlot(
        () => _loadWithFallback(loadImage, checkStop),
        cancelSignal: cancelSignal,
        checkStop: checkStop,
      );
    }

    return _loadWithFallback(() async {
      final cache = await CacheManager().findCache(diskCacheKey);
      checkStop();
      if (cache != null) return cache.readAsBytes();

      // 同一云端库先排自己的队，避免批量慢封面占满全局槽位。
      final slots = _remoteThumbnailLoadSlots.putIfAbsent(
        source,
        () => _AsyncSemaphore(3),
      );
      return slots.run(
        () => _runWithThumbnailSlot(
          loadImage,
          cancelSignal: cancelSignal,
          checkStop: checkStop,
        ),
        cancelSignal: cancelSignal,
        checkStop: checkStop,
      );
    }, checkStop);
  }

  Future<Uint8List> _loadWithFallback(
    Future<Uint8List> Function() load,
    void Function() checkStop,
  ) async {
    checkStop();
    try {
      return await load();
    } catch (_) {
      checkStop();
      final fallbackImage = await fallback?.call();
      if (fallbackImage != null) {
        if (fallbackImage.isNotEmpty) {
          return fallbackImage;
        }
      }
      rethrow;
    }
  }

  Future<Uint8List> _loadImage(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
    Future<void> cancelSignal,
  ) async {
    await for (final progress in ImageDownloader.loadThumbnail(
      url,
      sourceKey,
      cid,
      cancelSignal,
    )) {
      checkStop();
      chunkEvents.add(
        ImageChunkEvent(
          cumulativeBytesLoaded: progress.currentBytes,
          expectedTotalBytes: progress.totalBytes,
        ),
      );
      if (progress.imageBytes != null) return progress.imageBytes!;
    }
    checkStop();
    throw 'Error: Empty response body.';
  }

  @override
  Future<CachedImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => url + (sourceKey ?? "") + (cid ?? "");

  @override
  String get diskCacheKey => url.startsWith('file://')
      ? key
      : "$url@$sourceKey${cid != null ? '@$cid' : ''}";
}

class _AsyncSemaphore {
  final int maxConcurrent;

  int _active = 0;

  final _waiters = Queue<Completer<bool>>();

  _AsyncSemaphore(this.maxConcurrent);

  Future<T> run<T>(
    Future<T> Function() task, {
    Future<void>? cancelSignal,
    void Function()? checkStop,
  }) async {
    if (!await _acquire(cancelSignal)) {
      checkStop?.call();
      throw StateError('Thumbnail load was cancelled');
    }
    try {
      checkStop?.call();
      return await task();
    } finally {
      _release();
    }
  }

  Future<bool> _acquire(Future<void>? cancelSignal) {
    if (_active < maxConcurrent) {
      _active++;
      return Future.value(true);
    }
    final waiter = Completer<bool>();
    _waiters.add(waiter);
    cancelSignal?.then((_) {
      if (_waiters.remove(waiter)) waiter.complete(false);
    });
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(true);
      return;
    }
    _active--;
  }
}
