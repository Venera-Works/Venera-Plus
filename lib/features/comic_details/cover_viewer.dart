import 'dart:async';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_plus/components/effects.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart' show saveFile;
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/image_provider/cached_image.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

Future<void> saveComicCover(
  ImageProvider imageProvider, {
  String filename = 'cover',
}) async {
  while (imageProvider is ResizeImage) {
    imageProvider = imageProvider.imageProvider;
  }

  final data = switch (imageProvider) {
    CachedImageProvider provider => await provider.loadOriginalBytes(),
    FileImage(:final file) => await file.readAsBytes(),
    MemoryImage(:final bytes) => bytes,
    _ => await _encodeCoverAsPng(imageProvider),
  };
  if (data.isEmpty) {
    throw StateError('Cover image data is empty.');
  }

  var extension = detectFileType(data).ext;
  if (extension == '.') {
    extension = '';
    if (imageProvider case CachedImageProvider(:final url)) {
      final path = url.startsWith('file://')
          ? url.substring(7)
          : Uri.tryParse(url)?.path ?? '';
      final ext = comicFileExtension(path);
      if (comicImageExtensions.contains(ext)) {
        extension = '.$ext';
      }
    }
  }
  final safeFilename = sanitizeFileNameWithSuffix(
    filename.replaceAll(RegExp(r'[\x00-\x1f]'), ' '),
    extension: extension,
    fallback: 'cover',
  ).replaceFirst(RegExp(r'[. ]+$'), '');
  await saveFile(filename: safeFilename, data: data);
}

Future<Uint8List> _encodeCoverAsPng(ImageProvider imageProvider) async {
  final stream = imageProvider.resolve(const ImageConfiguration());
  final completer = Completer<ImageInfo>();
  final listener = ImageStreamListener(
    (info, _) {
      if (completer.isCompleted) {
        info.dispose();
        return;
      }
      completer.complete(info);
    },
    onError: (error, stackTrace) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    },
  );

  final ImageInfo info;
  try {
    stream.addListener(listener);
    info = await completer.future;
  } finally {
    stream.removeListener(listener);
  }

  try {
    final bytes = await info.image.toByteData(format: ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('Failed to encode cover as PNG.');
    }
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    info.dispose();
  }
}

class ComicCoverViewer extends StatefulWidget {
  const ComicCoverViewer({
    super.key,
    required this.imageProvider,
    required this.title,
    required this.heroTag,
  });

  final ImageProvider imageProvider;
  final String title;
  final String heroTag;

  @override
  State<ComicCoverViewer> createState() => _ComicCoverViewerState();
}

class _ComicCoverViewerState extends State<ComicCoverViewer> {
  bool isAppBarShow = true;
  bool _isSavingCover = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: context.colorScheme.surface,
        body: Stack(
          children: [
            Positioned.fill(
              child: PhotoView(
                imageProvider: widget.imageProvider,
                minScale: PhotoViewComputedScale.contained * 1.0,
                maxScale: PhotoViewComputedScale.covered * 3.0,
                backgroundDecoration: BoxDecoration(
                  color: context.colorScheme.surface,
                ),
                loadingBuilder: (context, event) => Center(
                  child: SizedBox(
                    width: 24.0,
                    height: 24.0,
                    child: CircularProgressIndicator(
                      value: event == null || event.expectedTotalBytes == null
                          ? null
                          : event.cumulativeBytesLoaded /
                                event.expectedTotalBytes!,
                    ),
                  ),
                ),
                onTapUp: (context, details, controllerValue) {
                  setState(() {
                    isAppBarShow = !isAppBarShow;
                  });
                },
                heroAttributes: PhotoViewHeroAttributes(tag: widget.heroTag),
              ),
            ),
            AnimatedPositioned(
              top: isAppBarShow ? 0 : -(context.padding.top + 52),
              left: 0,
              right: 0,
              duration: const Duration(milliseconds: 180),
              child: _buildAppBar(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Material(
      color: context.colorScheme.surface.toOpacity(0.72),
      child: BlurEffect(
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: context.colorScheme.outlineVariant,
                width: 0.5,
              ),
            ),
          ),
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(fontSize: 18),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.save_alt),
                onPressed: _saveCover,
              ),
              const SizedBox(width: 8),
            ],
          ),
        ).paddingTop(context.padding.top),
      ),
    );
  }

  Future<void> _saveCover() async {
    if (_isSavingCover) return;
    _isSavingCover = true;
    try {
      await saveComicCover(
        widget.imageProvider,
        filename: 'cover_${widget.title}',
      );
    } catch (_) {
      if (mounted) {
        context.showMessage(message: "Error".tl);
      }
    } finally {
      _isSavingCover = false;
    }
  }
}
