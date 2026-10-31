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
import 'package:venera_plus/foundation/missing_download_page.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/reader_diagnostics.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera_plus/foundation/appdata.dart';

final Object _imageProcessingCanceled = Object();

TargetImageSize _readerImageTargetSize(
  int width,
  int height,
  ComicImageLoadTarget target,
  double decodeScale,
  int maxDecodePixels,
) {
  final scale = decodeScale.isFinite && decodeScale > 0 ? decodeScale : 1.0;
  final split = target.splitWideImage && width > height;
  final displayWidth = split ? width / 2 : width.toDouble();
  final targetWidth = target.physicalWidth;
  final targetHeight = target.physicalHeight;
  var ratio = 1.0;
  switch (target.fit) {
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
  final targetPixelWidth = math.max(1, (width * ratio).round());
  final targetPixelHeight = math.max(1, (height * ratio).round());
  if (targetPixelWidth * targetPixelHeight > maxDecodePixels) {
    return _limitReaderImagePixels(width, height, maxDecodePixels);
  }
  return TargetImageSize(width: targetPixelWidth, height: targetPixelHeight);
}

TargetImageSize _limitReaderImagePixels(
  int width,
  int height,
  int maxDecodePixels,
) {
  if (width * height <= maxDecodePixels) {
    return TargetImageSize(width: width, height: height);
  }
  final ratio = math.sqrt(maxDecodePixels / (width * height));
  var limitedWidth = math.max(1, (width * ratio).floor());
  var limitedHeight = math.max(1, (height * ratio).floor());
  // One side can reach one pixel before an extreme aspect ratio fits.
  if (limitedWidth * limitedHeight > maxDecodePixels) {
    if (limitedWidth > limitedHeight) {
      limitedWidth = maxDecodePixels ~/ limitedHeight;
    } else {
      limitedHeight = maxDecodePixels ~/ limitedWidth;
    }
  }
  return TargetImageSize(width: limitedWidth, height: limitedHeight);
}

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
    this.maxDecodePixels = defaultMaxDecodePixels,
  }) : assert(maxDecodePixels > 0),
       _baseProvider = null,
       _decodeSize = null;

  /// 16 Mi pixels give a 64 MiB four-byte RGBA frame, below Flutter's default
  /// 100 MiB image-cache limit. This bounds decoder output, not encoded data,
  /// processing scripts or all cached frames.
  static const int defaultMaxDecodePixels = 16 * 1024 * 1024;

  ReaderImageProvider._withDecodeSize(
    ReaderImageProvider base,
    this._decodeSize,
  ) : imageKey = base.imageKey,
      sourceKey = base.sourceKey,
      cid = base.cid,
      eid = base.eid,
      page = base.page,
      chapter = base.chapter,
      enableResize = base.enableResize,
      target = base.target,
      maxDecodePixels = base.maxDecodePixels,
      _baseProvider = base;

  static final _diskCacheKeys = Expando<String>();
  static final _pendingCacheBytes = Expando<Uint8List>();
  static final _sourceSizes = Expando<Size>();

  /// The encoded size after source and user processing, shared by cache hits.
  static Size? sourceSizeOf(ImageStreamCompleter? completer) =>
      completer == null ? null : _sourceSizes[completer];

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  final int? chapter;

  final ComicImageLoadTarget? target;
  final int maxDecodePixels;

  final ReaderImageProvider? _baseProvider;
  final TargetImageSize? _decodeSize;

  /// Changes only the memory decode size, once the encoded size is known.
  ReaderImageProvider withDecodeScale(double scale, Size sourceSize) {
    final base = _baseProvider ?? this;
    final size = base.target;
    if (!base.enableResize || size == null) return base;
    final width = sourceSize.width.toInt();
    final height = sourceSize.height.toInt();
    final baseSize = _readerImageTargetSize(
      width,
      height,
      size,
      1.0,
      base.maxDecodePixels,
    );
    final decodeSize = _readerImageTargetSize(
      width,
      height,
      size,
      scale,
      base.maxDecodePixels,
    );
    if (decodeSize.width == baseSize.width &&
        decodeSize.height == baseSize.height) {
      return base;
    }
    return ReaderImageProvider._withDecodeSize(base, decodeSize);
  }

  @override
  final bool enableResize;

  @override
  ImageStreamCompleter loadImage(
    ReaderImageProvider key,
    ImageDecoderCallback decode,
  ) {
    late final ImageStreamCompleter completer;
    completer = super.loadImage(key, (buffer, {getTargetSize}) {
      return decode(
        buffer,
        getTargetSize: (width, height) {
          _sourceSizes[completer] = Size(width.toDouble(), height.toDouble());
          return getTargetSize?.call(width, height) ??
              _limitReaderImagePixels(width, height, maxDecodePixels);
        },
      );
    });
    return completer;
  }

  @override
  TargetImageSize getTargetSize(int width, int height) {
    final size = target;
    if (size == null || width <= 0 || height <= 0) {
      final fallback = super.getTargetSize(width, height);
      return _limitReaderImagePixels(
        fallback.width ?? width,
        fallback.height ?? height,
        maxDecodePixels,
      );
    }
    return _decodeSize ??
        _readerImageTargetSize(width, height, size, 1.0, maxDecodePixels);
  }

  @override
  bool get retryFileSystemErrors => !imageKey.startsWith('file://');
  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    if (imageKey.startsWith(missingDownloadPagePrefix)) {
      throw MissingDownloadPage(
        'This page has not been downloaded. Retry missing images from Downloads.'
            .tl,
      );
    }
    _pendingCacheBytes[this] = null;
    Uint8List? imageBytes;
    final diagnostics = ReaderDiagnostics.current;
    final readSpan = diagnostics?.beginImageSpan(
      hashCode,
      imageKey.startsWith('file://')
          ? ReaderDiagnosticStage.localRead
          : ReaderDiagnosticStage.sourceRead,
    );
    try {
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
      readSpan?.finish(bytes: imageBytes.length);
    } catch (_) {
      readSpan?.finish(success: false);
      rethrow;
    }
    final processingSpan =
        appdata.settings['enableCustomImageProcessing'] == true
        ? diagnostics?.beginImageSpan(
            hashCode,
            ReaderDiagnosticStage.processingWait,
          )
        : null;
    try {
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
    } catch (_) {
      processingSpan?.finish(success: false);
      rethrow;
    } finally {
      processingSpan?.finish(bytes: imageBytes?.length);
    }
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
    final budgetKey = maxDecodePixels == defaultMaxDecodePixels
        ? base
        : '$base@pixels$maxDecodePixels';
    final size = _decodeSize;
    return size == null
        ? budgetKey
        : '$budgetKey@decode${size.width}x${size.height}';
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
