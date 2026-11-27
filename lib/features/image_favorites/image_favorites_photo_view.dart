import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:venera_plus/components/effects.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

Future<void> confirmImageFavoriteDeletion(
  BuildContext context,
  int count,
  VoidCallback onConfirm,
) {
  return showConfirmDialog(
    context: context,
    title: 'Delete'.tl,
    content:
        (count == 1
                ? 'Delete @count favorite image?'
                : 'Delete @count favorite images?')
            .tlParams({'count': count}),
    confirmText: 'Delete',
    btnColor: context.colorScheme.error,
    onConfirm: onConfirm,
  );
}

class ImageFavoritesPhotoView extends StatefulWidget {
  const ImageFavoritesPhotoView({
    super.key,
    required this.comic,
    required this.imageFavorite,
  });

  final ImageFavoritesComic comic;
  final ImageFavorite imageFavorite;

  @override
  State<ImageFavoritesPhotoView> createState() =>
      _ImageFavoritesPhotoViewState();
}

class _ImageFavoritesPhotoViewState extends State<ImageFavoritesPhotoView> {
  late final PageController controller;
  late List<ImageFavorite> images;

  int currentPage = 0;

  bool isAppBarShow = false;

  @override
  void initState() {
    super.initState();
    images = widget.comic.images.toList();
    final index = images.indexOf(widget.imageFavorite);
    currentPage = index < 0 ? 0 : index;
    controller = PageController(initialPage: currentPage);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _removeImage(ImageFavorite image) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    final index = images.indexOf(image);
    if (index < 0) return;
    final manager = ImageFavoriteManager();
    manager.deleteImageFavorite([image]);
    final remaining =
        manager.find(image.id, image.sourceKey)?.images.toList() ?? [];
    if (remaining.isEmpty) {
      context.pop();
      return;
    }

    // 取消最后一张手动收藏时，同章节的自动封面也可能被移除。
    final surviving = remaining.toSet();
    final neighbor =
        images.skip(index + 1).where(surviving.contains).firstOrNull ??
        images.take(index).where(surviving.contains).lastOrNull;
    final nextPage = neighbor == null ? 0 : remaining.indexOf(neighbor);
    setState(() {
      images = remaining;
      currentPage = nextPage;
    });
    if (controller.hasClients) controller.jumpToPage(nextPage);
  }

  PhotoViewGalleryPageOptions _buildItem(BuildContext context, int index) {
    var image = images[index];
    return PhotoViewGalleryPageOptions(
      // 图片加载器 支持本地、网络
      imageProvider: ImageFavoritesProvider(image),
      // 初始化大小 全部展示
      minScale: PhotoViewComputedScale.contained * 1.0,
      maxScale: PhotoViewComputedScale.covered * 10.0,
      onTapUp: (context, details, controllerValue) {
        setState(() {
          isAppBarShow = !isAppBarShow;
        });
      },
      heroAttributes: PhotoViewHeroAttributes(tag: image),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (!controller.hasClients ||
            HardwareKeyboard.instance.isControlPressed) {
          return;
        }
        if (event is PointerScrollEvent) {
          final page = controller.page;
          if (page == null) return;
          if (event.scrollDelta.dy > 0) {
            if (page >= images.length - 1) {
              return;
            }
            controller.nextPage(
              duration: Duration(milliseconds: 180),
              curve: Curves.ease,
            );
          } else {
            if (page <= 0) {
              return;
            }
            controller.previousPage(
              duration: Duration(milliseconds: 180),
              curve: Curves.ease,
            );
          }
        }
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: PhotoViewGallery.builder(
              backgroundDecoration: BoxDecoration(
                color: context.colorScheme.surface,
              ),
              builder: _buildItem,
              itemCount: images.length,
              loadingBuilder: (context, event) => Center(
                child: SizedBox(
                  width: 20.0,
                  height: 20.0,
                  child: CircularProgressIndicator(
                    backgroundColor: context.colorScheme.surfaceContainerHigh,
                    value: event == null || event.expectedTotalBytes == null
                        ? null
                        : event.cumulativeBytesLoaded /
                              event.expectedTotalBytes!,
                  ),
                ),
              ),
              pageController: controller,
              onPageChanged: (index) {
                if (index >= images.length) return;
                setState(() {
                  currentPage = index;
                });
              },
            ),
          ),
          buildPageInfo(),
          AnimatedPositioned(
            top: isAppBarShow ? 0 : -(context.padding.top + 52),
            left: 0,
            right: 0,
            duration: Duration(milliseconds: 180),
            child: buildAppBar(),
          ),
        ],
      ),
    );
  }

  Widget buildPageInfo() {
    var text = "${currentPage + 1}/${images.length}";
    return Positioned(
      height: 40,
      left: 0,
      right: 0,
      bottom: 0,
      child: Center(
        child: Stack(
          children: [
            Text(
              text,
              style: TextStyle(
                fontSize: 14,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.onInverseSurface,
              ),
            ),
            Text(text),
          ],
        ),
      ),
    );
  }

  Widget buildAppBar() {
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
                icon: Icon(Icons.close),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.comic.title, style: TextStyle(fontSize: 18)),
              ),
              IconButton(icon: Icon(Icons.more_vert), onPressed: showMenu),
              const SizedBox(width: 8),
            ],
          ),
        ).paddingTop(context.padding.top),
      ),
    );
  }

  void showMenu() {
    final index = currentPage;
    final image = images[index];
    final location = Offset(context.width, context.padding.top + 52);
    showMenuX(context, location, [
      MenuEntry(
        icon: Icons.image_outlined,
        text: "Save Image".tl,
        onClick: () async {
          var imageProvider = ImageFavoritesProvider(image);
          var data = await imageProvider.load(null, null);
          var fileType = detectFileType(data);
          var fileName = "${index + 1}.${fileType.ext}";
          await saveFile(filename: fileName, data: data);
        },
      ),
      MenuEntry(
        icon: Icons.menu_book_outlined,
        text: "Read".tl,
        onClick: () async {
          var comic = widget.comic;
          App.rootContext.to(
            () => ReaderWithLoading(
              id: comic.id,
              sourceKey: comic.sourceKey,
              initialEp: image.ep,
              initialPage: image.page,
              initialNavigationSource: ReadingNavigationSource.userSeek,
            ),
          );
        },
      ),
      MenuEntry(
        icon: Icons.favorite_border,
        text: 'Remove from favorites'.tl,
        color: context.colorScheme.error,
        onClick: () =>
            confirmImageFavoriteDeletion(context, 1, () => _removeImage(image)),
      ),
    ]);
  }
}
