import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/global_state.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/features/reader/gallery_page_plan.dart';
import 'auto_reading.dart';

class ComicImage extends StatefulWidget {
  /// Modified from flutter Image
  ComicImage({
    required ImageProvider image,
    super.key,
    double scale = 1.0,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.filterQuality = FilterQuality.medium,
    this.isAntiAlias = false,
    this.splitWideImage = false,
    this.splitWideImageInvert = false,
    this.wideImagePart,
    this.onImageSize,
    Map<String, String>? headers,
    int? cacheWidth,
    int? cacheHeight,
    this.onInit,
    this.onDispose,
    this.onRetry,
    this.zoomController,
    this.showDimensions = false,
  }) : image = ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, image),
       assert(cacheWidth == null || cacheWidth > 0),
       assert(cacheHeight == null || cacheHeight > 0);

  final ImageProvider image;

  final String? semanticLabel;

  final bool excludeFromSemantics;

  final double? width;

  final double? height;

  final bool gaplessPlayback;

  final bool matchTextDirection;

  final Rect? centerSlice;

  final ImageRepeat repeat;

  final AlignmentGeometry alignment;

  final BoxFit? fit;

  final BlendMode? colorBlendMode;

  final FilterQuality filterQuality;

  final Animation<double>? opacity;

  final Color? color;

  final bool isAntiAlias;

  final bool splitWideImage;

  final bool splitWideImageInvert;
  final GalleryImagePart? wideImagePart;

  final void Function(Size size)? onImageSize;

  final void Function(State<ComicImage> state)? onInit;

  final void Function(State<ComicImage> state)? onDispose;

  final VoidCallback? onRetry;

  final PhotoViewController? zoomController;
  final bool showDimensions;

  static void clear() => ComicImageState.clear();

  static Size? getCachedImageSize(ImageProvider provider) =>
      ComicImageState._cachedImageSize(provider);

  @visibleForTesting
  static const imageSizeCacheCapacity = 128;

  @visibleForTesting
  static void debugCacheImageSize(ImageProvider provider, Size size) =>
      ComicImageState._recordImageSize(provider, size);

  @override
  State<ComicImage> createState() => ComicImageState();
}

bool shouldSplitWideImage(Size imageSize) => imageSize.width > imageSize.height;

@visibleForTesting
Size splitWideImageDisplaySize(Size imageSize) {
  if (!shouldSplitWideImage(imageSize)) {
    return imageSize;
  }
  return Size(imageSize.width / 2, imageSize.height * 2);
}

@visibleForTesting
List<Rect> splitWideImageSourceRects(Size imageSize, {required bool invert}) {
  final halfWidth = imageSize.width / 2;
  final left = Rect.fromLTWH(0, 0, halfWidth, imageSize.height);
  final right = Rect.fromLTWH(
    imageSize.width - halfWidth,
    0,
    halfWidth,
    imageSize.height,
  );
  return invert ? [left, right] : [right, left];
}

@visibleForTesting
Rect wideImagePartSourceRect(Size imageSize, GalleryImagePart part) {
  final halfWidth = imageSize.width / 2;
  switch (part) {
    case GalleryImagePart.left:
      return Rect.fromLTWH(0, 0, halfWidth, imageSize.height);
    case GalleryImagePart.right:
      return Rect.fromLTWH(
        imageSize.width - halfWidth,
        0,
        halfWidth,
        imageSize.height,
      );
    case GalleryImagePart.full:
      return Rect.fromLTWH(0, 0, imageSize.width, imageSize.height);
  }
}

@visibleForTesting
Size wideImagePartDisplaySize(Size imageSize, GalleryImagePart? part) {
  if (part == null ||
      part == GalleryImagePart.full ||
      !shouldSplitWideImage(imageSize)) {
    return imageSize;
  }
  return Size(imageSize.width / 2, imageSize.height);
}

@visibleForTesting
bool shouldNotifyImageSize({
  required Size? lastReportedSize,
  required Object? lastReportedKey,
  required Size currentSize,
  required Object currentKey,
}) {
  return lastReportedKey != currentKey || lastReportedSize != currentSize;
}

class ComicImageState extends State<ComicImage> with WidgetsBindingObserver {
  ImageStream? _imageStream;
  ImageInfo? _imageInfo;
  ImageChunkEvent? _loadingProgress;
  bool _isListeningToStream = false;
  late bool _invertColors;
  int? _frameNumber;
  bool _wasSynchronouslyLoaded = false;
  late DisposableBuildContext<State<ComicImage>> _scrollAwareContext;
  Object? _lastException;
  ImageStreamCompleterHandle? _completerHandle;
  Size? _lastReportedSize;
  Object? _lastReportedImageKey;
  Size? _layoutSize;
  Size? _sourceSize;
  ImageProvider? _resolvedImage;

  void _notifyImageSizeIfNeeded() {
    final currentSize = _layoutSize;
    if (currentSize == null) return;
    if (shouldNotifyImageSize(
      lastReportedSize: _lastReportedSize,
      lastReportedKey: _lastReportedImageKey,
      currentSize: currentSize,
      currentKey: widget.image,
    )) {
      _lastReportedSize = currentSize;
      _lastReportedImageKey = widget.image;
      widget.onImageSize?.call(currentSize);
    }
  }

  bool get readyForAutoReading => _imageInfo != null && _lastException == null;

  AutoReadingImageState get autoReadingImageState => _lastException != null
      ? AutoReadingImageState.failed
      : readyForAutoReading
      ? AutoReadingImageState.ready
      : AutoReadingImageState.loading;

  Object get autoReadingIdentity => _resolvedImage ?? widget.image;

  bool get visibleInReader {
    if (!mounted) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final bounds = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    final visible = bounds.intersect(screen);
    return visible.width > 1 && visible.height > 1;
  }

  static final _cache = LinkedHashMap<ImageProvider, Size>();

  static Size? _cachedImageSize(ImageProvider provider) {
    final size = _cache.remove(provider);
    if (size != null) _cache[provider] = size;
    return size;
  }

  static void _recordImageSize(ImageProvider provider, Size size) {
    _cache.remove(provider);
    _cache[provider] = size;
    if (_cache.length > ComicImage.imageSizeCacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
  }

  StreamSubscription<PhotoViewControllerValue>? _zoomSubscription;
  Timer? _decodeTimer;
  ImageStream? _pendingDecodeStream;
  ImageStreamListener? _pendingDecodeListener;
  double _requestedDecodeScale = 1.0;
  double _decodeScale = 1.0;

  // A short pause coalesces pinch/double-tap/press zoom steps without waiting
  // for the gesture to finish. One in-flight decode keeps only the latest need.
  static const _decodeDelay = Duration(milliseconds: 80);

  double _getDecodeScale(PhotoViewControllerValue value) {
    final initial = widget.zoomController?.getInitialScale?.call();
    if (initial == null || initial <= 0) return 1.0;
    return ((value.scale ?? initial) / initial - 0.01).ceilToDouble().clamp(
      1.0,
      double.infinity,
    );
  }

  void _listenForZoom() {
    _cancelDecodeRequest();
    _zoomSubscription?.cancel();
    final controller = widget.zoomController;
    _requestedDecodeScale = 1.0;
    _decodeScale = 1.0;
    _zoomSubscription = controller?.outputStateStream.listen(_onZoom);
    // PhotoView initializes its scale in a microtask after mounting its child.
    Future.microtask(() {
      if (mounted &&
          controller != null &&
          widget.zoomController == controller) {
        _onZoom(controller.value);
      }
    });
  }

  void _onZoom(PhotoViewControllerValue value) {
    final scale = _getDecodeScale(value);
    if (scale == _requestedDecodeScale) return;
    _requestedDecodeScale = scale;
    _queueDecodeRequest();
  }

  void _queueDecodeRequest() {
    _decodeTimer?.cancel();
    _decodeTimer = null;
    final image = widget.image;
    final sourceSize = _sourceSize;
    if (image is! ReaderImageProvider || sourceSize == null) return;
    final desired = image.withDecodeScale(_requestedDecodeScale, sourceSize);
    if (desired == _resolvedImage) {
      _decodeScale = _requestedDecodeScale;
      return;
    }
    if (desired == image) {
      _decodeScale = 1.0;
      _resolveImage(keepImage: true);
      return;
    }
    final controller = widget.zoomController;
    _decodeTimer = Timer(_decodeDelay, () {
      _decodeTimer = null;
      if (mounted &&
          widget.image == image &&
          widget.zoomController == controller) {
        _applyDecodeRequest();
      }
    });
  }

  void _applyDecodeRequest() {
    if (_pendingDecodeStream != null || _sourceSize == null) return;
    _decodeScale = _requestedDecodeScale;
    _resolveImage(keepImage: true);
  }

  void _watchDecode(ImageStream stream, ImageProvider image) {
    _pendingDecodeStream = stream;
    final listener = ImageStreamListener(
      (info, synchronousCall) {
        info.dispose();
        _finishDecode(stream, image);
      },
      onError: (Object error, StackTrace? stack) =>
          _finishDecode(stream, image),
    );
    _pendingDecodeListener = listener;
    stream.addListener(listener);
  }

  void _finishDecode(ImageStream stream, ImageProvider decodedImage) {
    if (_pendingDecodeStream != stream) return;
    stream.removeListener(_pendingDecodeListener!);
    _pendingDecodeStream = null;
    _pendingDecodeListener = null;
    final image = widget.image;
    final controller = widget.zoomController;
    Future.microtask(() {
      if (!mounted ||
          widget.image != image ||
          widget.zoomController != controller ||
          _decodeTimer != null) {
        return;
      }
      final sourceSize = _sourceSize;
      if (image is ReaderImageProvider &&
          sourceSize != null &&
          image.withDecodeScale(_requestedDecodeScale, sourceSize) !=
              decodedImage) {
        _applyDecodeRequest();
      }
    });
  }

  void _cancelDecodeRequest() {
    _decodeTimer?.cancel();
    _decodeTimer = null;
    final stream = _pendingDecodeStream;
    final listener = _pendingDecodeListener;
    _pendingDecodeStream = null;
    _pendingDecodeListener = null;
    if (listener != null) stream?.removeListener(listener);
  }

  void _scheduleDecodeUpgrade() {
    final image = widget.image;
    final controller = widget.zoomController;
    final stream = _imageStream;
    if (image is! ReaderImageProvider || _sourceSize == null) return;
    Future.microtask(() {
      if (!mounted ||
          widget.image != image ||
          widget.zoomController != controller ||
          _imageStream != stream) {
        return;
      }
      if (controller != null) {
        _requestedDecodeScale = _getDecodeScale(controller.value);
      }
      _queueDecodeRequest();
    });
  }

  static void clear() => _cache.clear();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollAwareContext = DisposableBuildContext<State<ComicImage>>(this);
    _listenForZoom();
    widget.onInit?.call(this);
  }

  @override
  void dispose() {
    assert(_imageStream != null);
    WidgetsBinding.instance.removeObserver(this);
    _cancelDecodeRequest();
    _zoomSubscription?.cancel();
    _stopListeningToStream();
    _completerHandle?.dispose();
    _scrollAwareContext.dispose();
    _replaceImage(info: null);
    _lastReportedSize = null;
    _lastReportedImageKey = null;
    widget.onDispose?.call(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    _updateInvertColors();
    _resolveImage();

    if (TickerMode.valuesOf(context).enabled) {
      _listenToStream();
    } else {
      _stopListeningToStream(keepStreamAlive: true);
    }

    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(ComicImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _cancelDecodeRequest();
      _decodeScale = 1.0;
      _sourceSize = null;
      _layoutSize = null;
      _lastReportedSize = null;
      _lastReportedImageKey = null;
    }
    if (widget.zoomController != oldWidget.zoomController) {
      _listenForZoom();
    }
    if (widget.image != oldWidget.image ||
        widget.zoomController != oldWidget.zoomController) {
      _resolveImage(keepImage: widget.image == oldWidget.image);
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    super.didChangeAccessibilityFeatures();
    setState(() {
      _updateInvertColors();
    });
  }

  @override
  void reassemble() {
    _resolveImage(); // in case the image cache was flushed
    super.reassemble();
  }

  bool containsPoint(Offset point) {
    if (!mounted) {
      return false;
    }
    var renderBox = context.findRenderObject() as RenderBox;
    var localPoint = renderBox.globalToLocal(point);
    return renderBox.paintBounds.contains(localPoint);
  }

  void _updateInvertColors() {
    _invertColors =
        MediaQuery.maybeInvertColorsOf(context) ??
        SemanticsBinding.instance.accessibilityFeatures.invertColors;
  }

  void _resolveImage({bool keepImage = false}) {
    var image = widget.image;
    final sourceSize = _sourceSize;
    if (image is ReaderImageProvider && sourceSize != null) {
      image = image.withDecodeScale(_decodeScale, sourceSize);
    }
    final ScrollAwareImageProvider provider = ScrollAwareImageProvider<Object>(
      context: _scrollAwareContext,
      imageProvider: image,
    );
    final ImageStream newStream = provider.resolve(
      createLocalImageConfiguration(
        context,
        size: widget.width != null && widget.height != null
            ? Size(widget.width!, widget.height!)
            : null,
      ),
    );
    _updateSourceStream(newStream, image: image, keepImage: keepImage);
  }

  ImageStreamListener? _imageStreamListener;

  ImageStreamListener _getListener({bool recreateListener = false}) {
    if (_imageStreamListener == null || recreateListener) {
      _lastException = null;
      final stream = _imageStream;
      _imageStreamListener = ImageStreamListener(
        (imageInfo, synchronousCall) {
          if (!mounted || _imageStream != stream) {
            imageInfo.dispose();
            return;
          }
          _handleImageFrame(imageInfo, synchronousCall);
        },
        onChunk: (event) {
          if (mounted && _imageStream == stream) _handleImageChunk(event);
        },
        onError: (Object error, StackTrace? stackTrace) {
          if (!mounted || _imageStream != stream) return;
          setState(() {
            _lastException = error;
          });
        },
      );
    }
    return _imageStreamListener!;
  }

  void _handleImageFrame(ImageInfo imageInfo, bool synchronousCall) {
    final isFirstBaseFrame =
        _resolvedImage == widget.image && _layoutSize == null;
    if (isFirstBaseFrame) {
      _layoutSize = Size(
        imageInfo.image.width.toDouble(),
        imageInfo.image.height.toDouble(),
      );
      _recordImageSize(widget.image, _layoutSize!);
    }
    _notifyImageSizeIfNeeded();
    _sourceSize ??= ReaderImageProvider.sourceSizeOf(_imageStream?.completer);
    setState(() {
      _replaceImage(info: imageInfo);
      _loadingProgress = null;
      _lastException = null;
      _frameNumber = _frameNumber == null ? 0 : _frameNumber! + 1;
      _wasSynchronouslyLoaded = _wasSynchronouslyLoaded | synchronousCall;
    });
    if (isFirstBaseFrame) _scheduleDecodeUpgrade();
  }

  void _handleImageChunk(ImageChunkEvent event) {
    setState(() {
      _loadingProgress = event;
      _lastException = null;
    });
  }

  void _replaceImage({required ImageInfo? info}) {
    final ImageInfo? oldImageInfo = _imageInfo;
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => oldImageInfo?.dispose(),
    );
    _imageInfo = info;
  }

  // Updates _imageStream to newStream, and moves the stream listener
  // registration from the old stream to the new stream (if a listener was
  // registered).
  void _updateSourceStream(
    ImageStream newStream, {
    required ImageProvider image,
    bool keepImage = false,
  }) {
    if (_imageStream?.key == newStream.key) {
      return;
    }

    if (_isListeningToStream) {
      _imageStream!.removeListener(_getListener());
    }

    if (!widget.gaplessPlayback && !keepImage) {
      setState(() {
        _replaceImage(info: null);
      });
    }

    setState(() {
      _loadingProgress = null;
      _frameNumber = null;
      _wasSynchronouslyLoaded = false;
    });

    _imageStream = newStream;
    _resolvedImage = image;
    _imageStreamListener = null;
    if (image != widget.image && _pendingDecodeStream == null) {
      _watchDecode(newStream, image);
    }
    if (_isListeningToStream) {
      _imageStream!.addListener(_getListener());
    }
  }

  void _listenToStream() {
    if (_isListeningToStream) {
      return;
    }

    _imageStream!.addListener(_getListener());
    _completerHandle?.dispose();
    _completerHandle = null;

    _isListeningToStream = true;
  }

  /// Stops listening to the image stream, if this state object has attached a
  /// listener.
  ///
  /// If the listener from this state is the last listener on the stream, the
  /// stream will be disposed. To keep the stream alive, set `keepStreamAlive`
  /// to true, which create [ImageStreamCompleterHandle] to keep the completer
  /// alive and is compatible with the [TickerMode] being off.
  void _stopListeningToStream({bool keepStreamAlive = false}) {
    if (!_isListeningToStream) {
      return;
    }

    if (keepStreamAlive &&
        _completerHandle == null &&
        _imageStream?.completer != null) {
      _completerHandle = _imageStream!.completer!.keepAlive();
    }

    _imageStream!.removeListener(_getListener());
    _isListeningToStream = false;
  }

  @override
  Widget build(BuildContext context) {
    if (_lastException != null) {
      // display error and retry button on screen
      return SizedBox(
        height: widget.height == null ? 300 : null,
        width: widget.width == null ? 300 : null,
        child: Center(
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Text(_lastException.toString(), maxLines: 3),
                  ),
                ),
                const SizedBox(height: 4),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Listener(
                    onPointerDown: (details) {
                      GlobalState.find<ReaderGestureDetectorState>()
                          .ignoreNextTap();
                      if (widget.onRetry != null) {
                        widget.onRetry!();
                        return;
                      }
                      setState(() {
                        _loadingProgress = null;
                        _lastException = null;
                      });
                      _resolveImage();
                    },
                    child: SizedBox(
                      width: 84,
                      height: 36,
                      child: Center(
                        child: Text(
                          "Retry".tl,
                          style: TextStyle(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constrains) {
        var width = widget.width;
        var height = widget.height;

        final cacheSize = _layoutSize ?? _cachedImageSize(widget.image);
        if (cacheSize != null) {
          final isWide = shouldSplitWideImage(cacheSize);
          final hasSinglePart =
              widget.wideImagePart != null &&
              widget.wideImagePart != GalleryImagePart.full &&
              isWide;
          final displaySize = hasSinglePart
              ? wideImagePartDisplaySize(cacheSize, widget.wideImagePart)
              : (widget.splitWideImage
                    ? splitWideImageDisplaySize(cacheSize)
                    : cacheSize);
          if (width == double.infinity) {
            width = constrains.maxWidth;
            height = width * displaySize.height / displaySize.width;
          } else if (height == double.infinity) {
            height = constrains.maxHeight;
            width = height * displaySize.width / displaySize.height;
          } else if (width == null && height == null) {
            width = displaySize.width;
            height = displaySize.height;
          } else if (width == null) {
            width = height! * displaySize.width / displaySize.height;
          } else if (height == null) {
            height = width * displaySize.height / displaySize.width;
          }
        } else {
          if (width == double.infinity) {
            width = constrains.maxWidth;
            height = 300;
          } else if (height == double.infinity) {
            height = constrains.maxHeight;
            width = 300;
          }
        }

        if (_imageInfo != null) {
          final imageSize = Size(
            _imageInfo!.image.width.toDouble(),
            _imageInfo!.image.height.toDouble(),
          );
          final isWide = shouldSplitWideImage(cacheSize ?? imageSize);
          final hasSinglePart =
              widget.wideImagePart != null &&
              widget.wideImagePart != GalleryImagePart.full &&
              isWide;
          final shouldSplit = !hasSinglePart && widget.splitWideImage && isWide;
          // build image
          Widget result = hasSinglePart
              ? _SinglePartWideImage(
                  image: _imageInfo!.image,
                  part: widget.wideImagePart!,
                  width: width,
                  height: height,
                  color: widget.color,
                  opacity: widget.opacity,
                  colorBlendMode: widget.colorBlendMode,
                  fit: widget.fit,
                  alignment: widget.alignment,
                  matchTextDirection: widget.matchTextDirection,
                  invertColors: _invertColors,
                  isAntiAlias: widget.isAntiAlias,
                  filterQuality: widget.filterQuality,
                )
              : shouldSplit
              ? _SplitWideImage(
                  image: _imageInfo!.image,
                  width: width,
                  height: height,
                  color: widget.color,
                  opacity: widget.opacity,
                  colorBlendMode: widget.colorBlendMode,
                  fit: widget.fit,
                  alignment: widget.alignment,
                  matchTextDirection: widget.matchTextDirection,
                  invertColors: _invertColors,
                  isAntiAlias: widget.isAntiAlias,
                  filterQuality: widget.filterQuality,
                  splitInvert: widget.splitWideImageInvert,
                )
              : RawImage(
                  // Do not clone the image, because RawImage is a stateless wrapper.
                  // The image will be disposed by this state object when it is not needed
                  // anymore, such as when it is unmounted or when the image stream pushes
                  // a new image.
                  image: _imageInfo?.image,
                  debugImageLabel: _imageInfo?.debugLabel,
                  width: width,
                  height: height,
                  scale: _imageInfo?.scale ?? 1.0,
                  color: widget.color,
                  opacity: widget.opacity,
                  colorBlendMode: widget.colorBlendMode,
                  fit: widget.fit,
                  alignment: widget.alignment,
                  repeat: widget.repeat,
                  centerSlice: widget.centerSlice,
                  matchTextDirection: widget.matchTextDirection,
                  invertColors: _invertColors,
                  isAntiAlias: widget.isAntiAlias,
                  filterQuality: widget.filterQuality,
                );

          if (!widget.excludeFromSemantics) {
            result = Semantics(
              container: widget.semanticLabel != null,
              image: true,
              label: widget.semanticLabel ?? '',
              child: result,
            );
          }
          result = SizedBox(
            width: width,
            height: height,
            child: Center(child: result),
          );
          if (widget.showDimensions) {
            final size = _sourceSize ?? cacheSize ?? imageSize;
            final dimensions = '${size.width.round()} × ${size.height.round()}';
            result = Stack(
              children: [
                result,
                Positioned(
                  top: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        child: Text(
                          dimensions,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          return result;
        } else {
          // build progress
          return SizedBox(
            width: width,
            height: height,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  backgroundColor: context.colorScheme.surfaceContainer,
                  value:
                      (_loadingProgress != null &&
                          _loadingProgress!.expectedTotalBytes != null &&
                          _loadingProgress!.expectedTotalBytes! != 0)
                      ? _loadingProgress!.cumulativeBytesLoaded /
                            _loadingProgress!.expectedTotalBytes!
                      : 0,
                ),
              ),
            ),
          );
        }
      },
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DiagnosticsProperty<ImageStream>('stream', _imageStream));
    properties.add(DiagnosticsProperty<ImageInfo>('pixels', _imageInfo));
    properties.add(
      DiagnosticsProperty<ImageChunkEvent>('loadingProgress', _loadingProgress),
    );
    properties.add(DiagnosticsProperty<int>('frameNumber', _frameNumber));
    properties.add(
      DiagnosticsProperty<bool>(
        'wasSynchronouslyLoaded',
        _wasSynchronouslyLoaded,
      ),
    );
  }
}

class _SplitWideImage extends StatelessWidget {
  const _SplitWideImage({
    required this.image,
    required this.width,
    required this.height,
    required this.color,
    required this.opacity,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
    required this.splitInvert,
  });

  final ui.Image image;

  final double? width;

  final double? height;

  final Color? color;

  final Animation<double>? opacity;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final AlignmentGeometry alignment;

  final bool matchTextDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  final bool splitInvert;

  @override
  Widget build(BuildContext context) {
    Widget result = CustomPaint(
      size: Size(
        width ?? image.width.toDouble() / 2,
        height ?? image.height * 2,
      ),
      painter: _SplitWideImagePainter(
        image: image,
        color: color,
        colorBlendMode: colorBlendMode,
        fit: fit,
        alignment: alignment.resolve(Directionality.maybeOf(context)),
        matchTextDirection: matchTextDirection,
        textDirection: Directionality.maybeOf(context),
        invertColors: invertColors,
        isAntiAlias: isAntiAlias,
        filterQuality: filterQuality,
        splitInvert: splitInvert,
      ),
    );
    if (opacity != null) {
      result = FadeTransition(opacity: opacity!, child: result);
    }
    return SizedBox(width: width, height: height, child: result);
  }
}

class _SplitWideImagePainter extends CustomPainter {
  const _SplitWideImagePainter({
    required this.image,
    required this.color,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.textDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
    required this.splitInvert,
  });

  final ui.Image image;

  final Color? color;

  final BlendMode? colorBlendMode;

  final BoxFit? fit;

  final Alignment alignment;

  final bool matchTextDirection;

  final TextDirection? textDirection;

  final bool invertColors;

  final bool isAntiAlias;

  final FilterQuality filterQuality;

  final bool splitInvert;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final displaySize = splitWideImageDisplaySize(imageSize);
    final fitted = applyBoxFit(fit ?? BoxFit.scaleDown, displaySize, size);
    final destination = alignment.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    final halfHeight = destination.height / 2;
    final topDestination = Rect.fromLTWH(
      destination.left,
      destination.top,
      destination.width,
      halfHeight,
    );
    final bottomDestination = Rect.fromLTWH(
      destination.left,
      destination.top + halfHeight,
      destination.width,
      halfHeight,
    );
    final sources = splitWideImageSourceRects(
      imageSize,
      invert:
          splitInvert ^
          (matchTextDirection && textDirection == TextDirection.rtl),
    );
    final paint = Paint()
      ..isAntiAlias = isAntiAlias
      ..filterQuality = filterQuality
      ..invertColors = invertColors;
    if (color != null) {
      paint.colorFilter = ColorFilter.mode(
        color!,
        colorBlendMode ?? BlendMode.srcIn,
      );
    }

    canvas.drawImageRect(image, sources[0], topDestination, paint);
    canvas.drawImageRect(image, sources[1], bottomDestination, paint);
  }

  @override
  bool shouldRepaint(covariant _SplitWideImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.color != color ||
        oldDelegate.colorBlendMode != colorBlendMode ||
        oldDelegate.fit != fit ||
        oldDelegate.alignment != alignment ||
        oldDelegate.matchTextDirection != matchTextDirection ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.invertColors != invertColors ||
        oldDelegate.isAntiAlias != isAntiAlias ||
        oldDelegate.filterQuality != filterQuality ||
        oldDelegate.splitInvert != splitInvert;
  }
}

class _SinglePartWideImage extends StatelessWidget {
  const _SinglePartWideImage({
    required this.image,
    required this.part,
    required this.width,
    required this.height,
    required this.color,
    required this.opacity,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
  });

  final ui.Image image;
  final GalleryImagePart part;
  final double? width;
  final double? height;
  final Color? color;
  final Animation<double>? opacity;
  final BlendMode? colorBlendMode;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final bool matchTextDirection;
  final bool invertColors;
  final bool isAntiAlias;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    Widget result = CustomPaint(
      size: Size(
        width ?? image.width.toDouble() / 2,
        height ?? image.height.toDouble(),
      ),
      painter: _SinglePartWideImagePainter(
        image: image,
        part: part,
        color: color,
        colorBlendMode: colorBlendMode,
        fit: fit,
        alignment: alignment.resolve(Directionality.maybeOf(context)),
        matchTextDirection: matchTextDirection,
        textDirection: Directionality.maybeOf(context),
        invertColors: invertColors,
        isAntiAlias: isAntiAlias,
        filterQuality: filterQuality,
      ),
    );
    if (opacity != null) {
      result = FadeTransition(opacity: opacity!, child: result);
    }
    return SizedBox(width: width, height: height, child: result);
  }
}

class _SinglePartWideImagePainter extends CustomPainter {
  const _SinglePartWideImagePainter({
    required this.image,
    required this.part,
    required this.color,
    required this.colorBlendMode,
    required this.fit,
    required this.alignment,
    required this.matchTextDirection,
    required this.textDirection,
    required this.invertColors,
    required this.isAntiAlias,
    required this.filterQuality,
  });

  final ui.Image image;
  final GalleryImagePart part;
  final Color? color;
  final BlendMode? colorBlendMode;
  final BoxFit? fit;
  final Alignment alignment;
  final bool matchTextDirection;
  final TextDirection? textDirection;
  final bool invertColors;
  final bool isAntiAlias;
  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final sourceRect = wideImagePartSourceRect(imageSize, part);
    final displaySize = Size(sourceRect.width, sourceRect.height);
    final fitted = applyBoxFit(fit ?? BoxFit.scaleDown, displaySize, size);
    final destination = alignment.inscribe(
      fitted.destination,
      Offset.zero & size,
    );

    final paint = Paint()
      ..isAntiAlias = isAntiAlias
      ..filterQuality = filterQuality
      ..invertColors = invertColors;
    if (color != null) {
      paint.colorFilter = ColorFilter.mode(
        color!,
        colorBlendMode ?? BlendMode.srcIn,
      );
    }

    canvas.drawImageRect(image, sourceRect, destination, paint);
  }

  @override
  bool shouldRepaint(covariant _SinglePartWideImagePainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.part != part ||
        oldDelegate.color != color ||
        oldDelegate.colorBlendMode != colorBlendMode ||
        oldDelegate.fit != fit ||
        oldDelegate.alignment != alignment ||
        oldDelegate.matchTextDirection != matchTextDirection ||
        oldDelegate.textDirection != textDirection ||
        oldDelegate.invertColors != invertColors ||
        oldDelegate.isAntiAlias != isAntiAlias ||
        oldDelegate.filterQuality != filterQuality;
  }
}
