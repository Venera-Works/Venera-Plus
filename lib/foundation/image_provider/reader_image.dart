import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/js_engine.dart';
import 'package:venera_plus/foundation/log.dart';
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

  @override
  final bool enableResize;

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
            _pendingCacheBytes[this] =
                appdata.settings['enableCustomImageProcessing'] == true
                ? Uint8List.fromList(imageBytes!)
                : imageBytes;
          }
          break;
        }
      }
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    if (appdata.settings['enableCustomImageProcessing']) {
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
    try {
      await CacheManager().writeCache(_processedCacheKey, bytes);
      _diskCacheKeys[this] = _processedCacheKey;
    } catch (error, stack) {
      Log.warning('Reader image cache', '$error\n$stack');
    }
  }

  @override
  String get key => target != null
      ? "$imageKey@$sourceKey@$cid@$eid@$enableResize@${target!.cacheIdentity}"
      : "$imageKey@$sourceKey@$cid@$eid@$enableResize";

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
