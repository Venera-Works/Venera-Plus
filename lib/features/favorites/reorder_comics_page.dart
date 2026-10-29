import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites_display.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/translations.dart';

class ReorderComicsPage extends StatefulWidget {
  const ReorderComicsPage(this.name, {super.key});

  final String name;

  @override
  State<ReorderComicsPage> createState() => _ReorderComicsPageState();
}

class _ReorderComicsPageState extends State<ReorderComicsPage> {
  final _key = GlobalKey();
  var reorderWidgetKey = UniqueKey();
  final _scrollController = ScrollController();
  late var comics = LocalFavoritesManager().getFolderComics(widget.name);
  bool changed = false;

  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_onDisplaySettingsChanged);
  }

  void _onDisplaySettingsChanged() {
    if (mounted) setState(() {});
  }

  static int _floatToInt8(double x) {
    return (x * 255.0).round() & 0xff;
  }

  Color lightenColor(Color color, double lightenValue) {
    int red = (_floatToInt8(color.r) + ((255 - color.r) * lightenValue))
        .round();
    int green = (_floatToInt8(color.g) * 255 + ((255 - color.g) * lightenValue))
        .round();
    int blue = (_floatToInt8(color.b) * 255 + ((255 - color.b) * lightenValue))
        .round();

    return Color.fromARGB(_floatToInt8(color.a), red, green, blue);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onDisplaySettingsChanged);
    _scrollController.dispose();
    if (changed) {
      // Delay to ensure navigation is completed
      Future.delayed(const Duration(milliseconds: 200), () {
        LocalFavoritesManager().reorder(comics, widget.name);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gallery = isFavoriteGalleryMode();
    final displayMode = gallery
        ? ComicTileDisplayMode.gallery
        : ComicTileDisplayMode.detailed;
    var tiles = comics.map((e) {
      var comicSource = e.type.comicSource;
      return Padding(
        key: Key(e.hashCode.toString()),
        padding: const EdgeInsets.all(4),
        child: ComicTile(
          enableLongPressed: false,
          displayMode: displayMode,
          comic: Comic(
            e.name,
            e.coverPath,
            e.id,
            e.author,
            e.tags,
            "${e.time} | ${comicSource?.name ?? "Unknown"}",
            comicSource?.key ??
                (e.type == ComicType.local ? "local" : "Unknown"),
            null,
            null,
          ),
        ),
      );
    }).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Reorder".tl),
        actions: [
          Tooltip(
            message: "Information".tl,
            child: IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                showInfoDialog(
                  context: context,
                  title: "Reorder".tl,
                  content: "Long press and drag to reorder.".tl,
                );
              },
            ),
          ),
          Tooltip(
            message: "Reverse".tl,
            child: IconButton(
              icon: const Icon(Icons.swap_vert),
              onPressed: () {
                setState(() {
                  comics = comics.reversed.toList();
                  changed = true;
                });
              },
            ),
          ),
        ],
      ),
      body: ReorderableBuilder<FavoriteItem>(
        key: reorderWidgetKey,
        scrollController: _scrollController,
        longPressDelay: App.isDesktop
            ? const Duration(milliseconds: 100)
            : const Duration(milliseconds: 500),
        onReorder: (reorderFunc) {
          changed = true;
          setState(() {
            comics = reorderFunc(comics);
          });
        },
        dragChildBoxDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: lightenColor(
            Theme.of(context).splashColor.withAlpha(255),
            0.2,
          ),
        ),
        builder: (children) {
          return GridView(
            key: _key,
            controller: _scrollController,
            gridDelegate: SliverGridDelegateWithComics(
              galleryColumns: gallery ? favoriteGalleryColumns() : null,
              forceDetailed: !gallery,
            ),
            children: children,
          );
        },
        children: tiles,
      ),
    );
  }
}
