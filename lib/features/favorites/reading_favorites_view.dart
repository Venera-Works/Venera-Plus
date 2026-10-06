import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';

const _asyncDataFetchLimit = 500;

/// Home page view displaying "在读" (Currently reading) favorites.
class ReadingFavoritesView extends StatefulWidget {
  const ReadingFavoritesView({super.key});

  @override
  State<ReadingFavoritesView> createState() => _ReadingFavoritesViewState();
}

class _ReadingFavoritesViewState extends State<ReadingFavoritesView> {
  List<FavoriteItem> comics = [];
  bool isLoading = false;
  String? loadError;
  int _loadGeneration = 0;
  final ScrollController _scrollController = ScrollController();

  LocalFavoritesManager get manager => LocalFavoritesManager();

  void updateComics() {
    unawaited(loadComics());
  }

  Future<void> loadComics() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final managerGen = manager.generation;
    final folder = manager.readingFolder;
    if (folder == null || !manager.existsFolder(folder)) {
      setState(() {
        comics = [];
        isLoading = false;
        loadError = null;
      });
      return;
    }

    final folderCount = manager.folderComics(folder);
    if (folderCount < _asyncDataFetchLimit) {
      setState(() {
        comics = manager.getFolderComics(folder);
        isLoading = false;
        loadError = null;
      });
      return;
    }

    setState(() {
      isLoading = true;
      loadError = null;
    });

    final future = manager.getFolderComicsAsync(folder);
    try {
      final value = await future;
      if (mounted &&
          _loadGeneration == generation &&
          manager.isCurrentGeneration(managerGen) &&
          manager.readingFolder == folder) {
        setState(() {
          isLoading = false;
          comics = value;
          loadError = null;
        });
      }
    } catch (error, stackTrace) {
      Log.error("ReadingFavoritesView.loadComics", error, stackTrace);
      if (mounted &&
          _loadGeneration == generation &&
          manager.isCurrentGeneration(managerGen) &&
          manager.readingFolder == folder) {
        setState(() {
          isLoading = false;
          comics = [];
          loadError = "Failed to load comics".tl;
        });
        context.showMessage(message: "Failed to load comics".tl);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    loadComics();
    manager.addListener(updateComics);
  }

  @override
  void dispose() {
    manager.removeListener(updateComics);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    int updatedCount = 0;
    int errorCount = 0;
    String? lastError;
    String? refreshedFolder;
    try {
      await manager.reconcileReadingFolderBinding();
      if (!mounted) return;
      final folder = manager.readingFolder;
      refreshedFolder = folder;
      if (folder == null || !manager.existsFolder(folder)) {
        if (mounted) {
          context.showMessage(message: "Reading folder not found".tl);
        }
        return;
      }

      await for (var progress in updateFolder(folder, true)) {
        updatedCount = progress.updated;
        errorCount = progress.errors;
        if (progress.errorMessage != null) {
          lastError = progress.errorMessage;
        }
      }
      if (mounted && manager.readingFolder == refreshedFolder) {
        if (errorCount > 0 && updatedCount > 0) {
          context.showMessage(
            message: "Updated @c comics, @e failed".tlParams({
              'c': updatedCount,
              'e': errorCount,
            }),
          );
        } else if (updatedCount > 0) {
          context.showMessage(
            message: "Updated @c comics".tlParams({'c': updatedCount}),
          );
        } else if (errorCount > 0) {
          context.showMessage(
            message: lastError != null && errorCount == 1
                ? "Failed to check for updates: @e".tlParams({'e': lastError})
                : "Failed to check for updates".tl,
          );
        }
      }
    } catch (e, s) {
      Log.error("ReadingFavoritesView._onRefresh", e, s);
      if (mounted) {
        final errorText = e is StateError ? e.message : e.toString();
        context.showMessage(
          message: "Failed to check for updates: @e".tlParams({'e': errorText}),
        );
      }
    } finally {
      if (mounted) {
        await loadComics();
      }
    }
  }

  void _onComicTap(Comic c, int heroID) {
    if (appdata.settings["onClickFavorite"] == "viewDetail") {
      App.mainNavigatorKey?.currentContext?.to(
        () => ComicPage(
          id: c.id,
          sourceKey: c.sourceKey,
          cover: c.cover,
          title: c.title,
          heroID: heroID,
        ),
      );
    } else {
      App.mainNavigatorKey?.currentContext?.to(
        () => ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
      );
    }
  }

  List<MenuEntry> _buildMenu(Comic c) {
    final item = c as FavoriteItem;
    final folder = manager.readingFolder;
    return [
      if (appdata.settings["onClickFavorite"] == "viewDetail")
        MenuEntry(
          icon: Icons.menu_book_outlined,
          text: "Read".tl,
          onClick: () {
            App.mainNavigatorKey?.currentContext?.to(
              () => ReaderWithLoading(id: item.id, sourceKey: item.sourceKey),
            );
          },
        )
      else
        MenuEntry(
          icon: Icons.info_outline,
          text: "View Detail".tl,
          onClick: () {
            App.mainNavigatorKey?.currentContext?.to(
              () => ComicPage(
                id: item.id,
                sourceKey: item.sourceKey,
                cover: item.cover,
                title: item.title,
                heroID: item.id.hashCode,
              ),
            );
          },
        ),
      if (manager.hasNewUpdate(item.id, item.type))
        MenuEntry(
          icon: Icons.done_all,
          text: "Mark as read".tl,
          onClick: () {
            manager.markAsRead(item.id, item.type);
          },
        ),
      if (folder != null)
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            manager.deleteComicWithId(folder, item.id, item.type);
          },
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    Widget sliverContent;
    if (isLoading) {
      sliverContent = const SliverToBoxAdapter(
        child: SizedBox(
          height: 240,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    } else if (loadError != null) {
      sliverContent = SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                loadError!,
                style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 16),
              Button.filled(onPressed: loadComics, child: Text("Retry".tl)),
            ],
          ),
        ),
      );
    } else if (comics.isEmpty) {
      final isFolderMissing =
          manager.readingFolder == null ||
          !manager.existsFolder(manager.readingFolder!);
      sliverContent = SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              const SizedBox(height: 16),
              Text(
                (isFolderMissing
                        ? "Reading folder not found"
                        : "No reading comics")
                    .tl,
                style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      sliverContent = SliverGridComics(
        comics: comics,
        useFavoriteDisplaySettings: true,
        menuBuilder: _buildMenu,
        onTap: _onComicTap,
      );
    }

    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: SmoothCustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          sliverContent,
          SliverPadding(
            padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
          ),
        ],
      ),
    );
  }
}
