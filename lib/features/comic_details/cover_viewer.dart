import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:venera_plus/components/effects.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

typedef ComicCoverUpdate = ({
  ImageProvider? imageProvider,
  bool hasCustomCover,
});

class ComicCoverViewer extends StatefulWidget {
  const ComicCoverViewer({
    super.key,
    required this.imageProvider,
    required this.title,
    required this.heroTag,
    this.onReplaceCover,
    this.onRestoreDefaultCover,
    this.initialCanRestoreDefaultCover = false,
  });

  final ImageProvider imageProvider;
  final String title;
  final String heroTag;
  final Future<ComicCoverUpdate?> Function()? onReplaceCover;
  final Future<ComicCoverUpdate?> Function()? onRestoreDefaultCover;
  final bool initialCanRestoreDefaultCover;

  @override
  State<ComicCoverViewer> createState() => _ComicCoverViewerState();
}

class _ComicCoverViewerState extends State<ComicCoverViewer> {
  bool isAppBarShow = true;
  late ImageProvider? _imageProvider = widget.imageProvider;
  late bool _canRestoreDefaultCover = widget.initialCanRestoreDefaultCover;
  bool _isUpdatingCover = false;
  int _coverRevision = 0;

  @override
  Widget build(BuildContext context) {
    final imageProvider = _imageProvider;
    return PopScope(
      canPop: !_isUpdatingCover,
      child: Scaffold(
        backgroundColor: context.colorScheme.surface,
        body: Stack(
          children: [
            Positioned.fill(
              child: imageProvider == null
                  ? const Center(
                      child: Icon(Icons.image_not_supported_outlined),
                    )
                  : PhotoView(
                      key: ValueKey(_coverRevision),
                      imageProvider: imageProvider,
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
                            value:
                                event == null ||
                                    event.expectedTotalBytes == null
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
                      heroAttributes: PhotoViewHeroAttributes(
                        tag: widget.heroTag,
                      ),
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
    final replaceCover = widget.onReplaceCover;
    final restoreCover = widget.onRestoreDefaultCover;
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
                onPressed: _isUpdatingCover
                    ? null
                    : () => Navigator.of(context).pop(),
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
                onPressed: _isUpdatingCover || _imageProvider == null
                    ? null
                    : _saveCover,
              ),
              if (replaceCover != null)
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  tooltip: 'Replace cover'.tl,
                  onPressed: _isUpdatingCover
                      ? null
                      : () => _updateCover(replaceCover),
                ),
              if (_canRestoreDefaultCover && restoreCover != null)
                IconButton(
                  icon: const Icon(Icons.restore),
                  tooltip: 'Restore default cover'.tl,
                  onPressed: _isUpdatingCover
                      ? null
                      : () => _updateCover(restoreCover),
                ),
              const SizedBox(width: 8),
            ],
          ),
        ).paddingTop(context.padding.top),
      ),
    );
  }

  Future<void> _updateCover(Future<ComicCoverUpdate?> Function() action) async {
    if (_isUpdatingCover) return;
    setState(() => _isUpdatingCover = true);
    try {
      final result = await action();
      if (!mounted || result == null) return;
      setState(() {
        _imageProvider = result.imageProvider;
        _canRestoreDefaultCover = result.hasCustomCover;
        _coverRevision++;
      });
    } finally {
      if (mounted) setState(() => _isUpdatingCover = false);
    }
  }

  void _saveCover() async {
    final imageProvider = _imageProvider;
    if (imageProvider == null) return;
    try {
      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<Uint8List>();

      imageStream.addListener(
        ImageStreamListener((ImageInfo info, bool _) async {
          final byteData = await info.image.toByteData(
            format: ImageByteFormat.png,
          );
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          }
        }),
      );

      final data = await completer.future;
      final fileType = detectFileType(data);
      await saveFile(
        filename: "cover_${widget.title}${fileType.ext}",
        data: data,
      );
    } catch (e) {
      if (mounted) {
        context.showMessage(message: "Error".tl);
      }
    }
  }
}
