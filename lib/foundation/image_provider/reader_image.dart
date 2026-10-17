import 'dart:async' show Future;
import 'dart:math' as math;
import 'dart:ui' show TargetImageSize;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/network/images.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera_plus/foundation/appdata.dart';

final Object _imageProcessingCanceled = Object();

@visibleForTesting
Future<dynamic> debugWaitForReaderImageProcessingResult(
  Future<dynamic> image,
  void Function() onCancel,
  void Function() checkStop, {
  Future<void>? cancelSignal,
}) {
  return _waitForReaderImageProcessingResult(
    image,
    onCancel,
    checkStop,
    cancelSignal: cancelSignal,
  );
}

Future<dynamic> _waitForReaderImageProcessingResult(
  Future<dynamic> image,
  void Function() onCancel,
  void Function() checkStop, {
  Future<void>? cancelSignal,
}) async {
  final result = await Future.any<dynamic>([
    image,
    (cancelSignal ?? BaseImageProvider.cancelSignalOf(checkStop)).then(
      (_) => _imageProcessingCanceled,
    ),
  ]);
  if (identical(result, _imageProcessingCanceled)) {
    onCancel();
    checkStop();
  }
  return result ?? Uint8List(0);
}

class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.chapter,
    this.enableResize = false,
    this.target,
    this.decodeScale = 1.0,
  });

  static final _diskCacheKeys = Expando<String>();
  static final _pendingCacheBytes = Expando<Uint8List>();

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  final int? chapter;

  final ComicImageLoadTarget? target;

  /// Changes the memory decode size without changing the source request/cache.
  final double decodeScale;

  ReaderImageProvider withDecodeScale(double scale) => ReaderImageProvider(
    imageKey,
    sourceKey,
    cid,
    eid,
    page,
    chapter: chapter,
    enableResize: enableResize,
    target: target,
    decodeScale: scale,
  );

  @override
  final bool enableResize;

  @override
  TargetImageSize getTargetSize(int width, int height) {
    final size = target;
    if (size == null || width <= 0 || height <= 0) {
      return super.getTargetSize(width, height);
    }
    final scale = decodeScale.isFinite && decodeScale > 0 ? decodeScale : 1.0;
    final split = size.splitWideImage && width > height;
    final displayWidth = split ? width / 2 : width.toDouble();
    final targetWidth = size.physicalWidth;
    final targetHeight = size.physicalHeight;
    var ratio = 1.0;
    switch (size.fit) {
      case ComicImageTargetFit.fitWidth:
        if (targetWidth != null) ratio = targetWidth * scale / displayWidth;
      case ComicImageTargetFit.fitHeight:
        if (targetHeight != null) ratio = targetHeight * scale / height;
      case ComicImageTargetFit.contain:
        if (targetWidth != null) ratio = targetWidth * scale / displayWidth;
        if (targetHeight != null) {
          ratio = math.min(ratio, targetHeight * scale / height);
        }
    }
    ratio = math.min(ratio, 1.0);
    return TargetImageSize(
      width: math.max(1, (width * ratio).round()),
      height: math.max(1, (height * ratio).round()),
    );
  }

  @override
  bool get retryFileSystemErrors => !imageKey.startsWith('file://');
  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    _pendingCacheBytes[this] = null;
    Uint8List? imageBytes;
    if (imageKey.startsWith('file://')) {
      var file = File(imageKey.substring(7));
      if (await file.exists()) {
        imageBytes = await readFileBytesChecked(
          file,
          requireNonEmpty: true,
          checkStop: checkStop,
          cancelSignal: BaseImageProvider.cancelSignalOf(checkStop),
        );
      } else {
        throw FileSystemException('File not found', file.path);
      }
    } else {
      await for (var event in ImageDownloader.loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
        target: target,
      )) {
        checkStop();
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        );
        if (event.imageBytes != null) {
          _diskCacheKeys[this] = event.diskCacheKey;
          imageBytes = event.imageBytes;
          if (event.diskCacheKey != _processedCacheKey) {
            // Keep the source-processed bytes before applying the user's
            // processing script, which still runs on subsequent cache hits.
            _pendingCacheBytes[this] = imageBytes;
          }
          break;
        }
      }
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    if (appdata.settings['enableCustomImageProcessing']) {
      // User scripts may mutate their input; preserve shared/cache bytes.
      imageBytes = Uint8List.fromList(imageBytes);
      var script = appdata.settings['customImageProcessing'].toString();
      if (!script.contains('function processImage')) {
        return imageBytes;
      }
      var func = JsEngine().runCode('''
        (() => {
          $script
          return processImage;
        })()
      ''');
      if (func is JSInvokable) {
        var autoFreeFunc = JSAutoFreeFunction(func);
        var result = autoFreeFunc([imageBytes, cid, eid, page, sourceKey]);
        if (result is Uint8List) {
          imageBytes = result;
        } else if (result is Future) {
          var futureResult = await result;
          if (futureResult is Uint8List) {
            imageBytes = futureResult;
          }
        } else if (result is Map) {
          var image = result['image'];
          if (image is Uint8List) {
            imageBytes = image;
          } else if (image is Future) {
            JSAutoFreeFunction? onCancel;
            if (result['onCancel'] is JSInvokable) {
              onCancel = JSAutoFreeFunction(result['onCancel']);
            }
            if (onCancel == null) {
              var futureImage = await image;
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            } else {
              final cancelImageProcessing = onCancel;
              final futureImage = await _waitForReaderImageProcessingResult(
                image,
                () => cancelImageProcessing([]),
                checkStop,
              );
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            }
          }
        }
      }
    }
    return imageBytes;
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  Future<void> cacheImageAfterDecoding() async {
    final bytes = _pendingCacheBytes[this];
    _pendingCacheBytes[this] = null;
    if (bytes == null) return;
    final write = ImageDownloader.cacheProcessedImage(
      _processedCacheKey,
      bytes,
    );
    _diskCacheKeys[this] = _processedCacheKey;
    await write;
  }

  @override
  Future<void> evictDiskCache() =>
      ImageDownloader.deleteComicImageCache(diskCacheKey);

  @override
  String get key {
    final base = target != null
        ? "$imageKey@$sourceKey@$cid@$eid@$enableResize@${target!.cacheIdentity}"
        : "$imageKey@$sourceKey@$cid@$eid@$enableResize";
    return decodeScale == 1.0 ? base : '$base@decode$decodeScale';
  }

  @override
  String get diskCacheKey => _diskCacheKeys[this] ?? _processedCacheKey;

  String get _processedCacheKey => ImageDownloader.getComicImageCacheKey(
    imageKey,
    sourceKey,
    cid,
    eid,
    target: target,
  );
}
