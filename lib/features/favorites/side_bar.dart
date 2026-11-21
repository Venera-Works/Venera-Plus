import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorite_actions.dart';
import 'package:venera_plus/features/favorites/favorites_constants.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/routing/settings.dart';

abstract interface class FolderList {
  void update();

  void updateFolders();
}

class FavoritesFolderSidebar extends StatefulWidget {
  const FavoritesFolderSidebar({
    super.key,
    required this.selectedFolder,
    required this.isNetworkSelected,
    required this.onFolderSelected,
    this.onFolderListReady,
    this.onSelected,
    this.withAppbar = false,
  });

  final String? selectedFolder;

  final bool isNetworkSelected;

  final void Function(bool isNetwork, String? folder) onFolderSelected;

  final ValueChanged<FolderList>? onFolderListReady;

  final VoidCallback? onSelected;

  final bool withAppbar;

  @override
  State<FavoritesFolderSidebar> createState() => _FavoritesFolderSidebarState();
}

class _FavoritesFolderSidebarState extends State<FavoritesFolderSidebar>
    implements FolderList {
  var folders = <FavoriteFolder>[];
  final _collapsed = <String>{};
  var _showSearch = false;
  var _folderQuery = '';

  var networkFolders = <String>[];

  void findNetworkFolders() {
    networkFolders.clear();
    var all = ComicSource.all()
        .where((e) => e.favoriteData != null)
        .map((e) => e.favoriteData!.key)
        .toList();
    var settings = appdata.settings['favorites'] as List;
    for (var p in settings) {
      if (all.contains(p) && !networkFolders.contains(p)) {
        networkFolders.add(p);
      }
    }
  }

  @override
  void initState() {
    widget.onFolderListReady?.call(this);
    folders = LocalFavoritesManager().folders;
    findNetworkFolders();
    appdata.settings.addListener(updateFolders);
    LocalFavoritesManager().addListener(updateFolders);
    super.initState();
  }

  @override
  void didUpdateWidget(covariant FavoritesFolderSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isNetworkSelected ||
        widget.selectedFolder == oldWidget.selectedFolder) {
      return;
    }
    for (final folder in folders) {
      if (folder.name == widget.selectedFolder) {
        _collapsed.remove(folder.parentId);
        break;
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    appdata.settings.removeListener(updateFolders);
    LocalFavoritesManager().removeListener(updateFolders);
  }

  @override
  Widget build(BuildContext context) {
    final favoriteParents = {for (final folder in folders) ?folder.parentId};
    final hasQuery = _folderQuery.trim().isNotEmpty;
    final visibleFolders = folders.where((folder) {
      return hasQuery
          ? folder.matchesPath(_folderQuery)
          : !_collapsed.contains(folder.parentId);
    }).toList();
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Column(
        children: [
          if (widget.withAppbar)
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  const CloseButton(),
                  const SizedBox(width: 8),
                  Text("Folders".tl, style: ts.s18),
                ],
              ),
            ).paddingTop(context.padding.top),
          Expanded(
            child: ListView.builder(
              padding: widget.withAppbar
                  ? EdgeInsets.zero
                  : EdgeInsets.only(top: context.padding.top),
              itemCount:
                  visibleFolders.length +
                  networkFolders.length +
                  3 +
                  (_showSearch ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return buildLocalTitle();
                }
                index--;
                if (_showSearch) {
                  if (index == 0) {
                    return FavoriteFolderSearchField(
                      autofocus: true,
                      onChanged: (query) =>
                          setState(() => _folderQuery = query),
                    );
                  }
                  index--;
                }
                if (index == 0) {
                  return buildLocalFolder(localAllFolderLabel);
                }
                index--;
                if (index < visibleFolders.length) {
                  final folder = visibleFolders[index];
                  return buildLocalFolder(
                    folder.name,
                    displayName: hasQuery ? folder.path : folder.name,
                    isChild: folder.parentId != null && !hasQuery,
                    expandableId:
                        !hasQuery && favoriteParents.contains(folder.id)
                        ? folder.id
                        : null,
                  );
                }
                index -= visibleFolders.length;
                if (index == 0) {
                  return buildNetworkTitle();
                }
                index--;
                return buildNetworkFolder(networkFolders[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget buildLocalTitle() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.local_activity, color: context.colorScheme.secondary),
          const SizedBox(width: 12),
          Text("Local".tl),
          const Spacer(),
          IconButton(
            tooltip: 'Search folders'.tl,
            icon: Icon(_showSearch ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              _folderQuery = '';
            }),
          ),
          MenuButton(
            entries: [
              MenuEntry(
                icon: Icons.add,
                text: 'Create Folder'.tl,
                onClick: newFolder,
              ),
              MenuEntry(
                icon: Icons.reorder,
                text: 'Sort'.tl,
                onClick: sortFolders,
              ),
            ],
          ),
        ],
      ).paddingHorizontal(16),
    );
  }

  Widget buildNetworkTitle() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud, color: context.colorScheme.secondary),
          const SizedBox(width: 12),
          Text("Network".tl),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              showPopUpWidget(App.rootContext, setFavoritesPagesWidget());
            },
          ),
        ],
      ).paddingHorizontal(16),
    );
  }

  Widget buildLocalFolder(
    String name, {
    String? displayName,
    bool isChild = false,
    String? expandableId,
  }) {
    bool isSelected =
        name == widget.selectedFolder && !widget.isNetworkSelected;
    int count = 0;
    if (name == localAllFolderLabel) {
      count = LocalFavoritesManager().totalComics;
    } else {
      count = LocalFavoritesManager().folderComics(name);
    }
    var folderName = name == localAllFolderLabel
        ? "All".tl
        : displayName ?? name;
    return ClickInkWell(
      onTap: () {
        if (isSelected) {
          return;
        }
        widget.onFolderSelected(false, name);
        widget.onSelected?.call();
      },
      child: Container(
        height: 42,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: isSelected
              ? context.colorScheme.primaryContainer.toOpacity(0.36)
              : null,
          border: Border(
            left: BorderSide(
              color: isSelected
                  ? context.colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: EdgeInsets.only(left: isChild ? 32 : 16),
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: folderName,
                child: Text(
                  folderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (expandableId != null)
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 42,
                ),
                tooltip:
                    (_collapsed.contains(expandableId) ? 'Expand' : 'Collapse')
                        .tl,
                icon: Icon(
                  _collapsed.contains(expandableId)
                      ? Icons.chevron_right
                      : Icons.expand_more,
                ),
                onPressed: () => setState(() {
                  if (!_collapsed.remove(expandableId)) {
                    _collapsed.add(expandableId);
                  }
                }),
              ),
            Container(
              margin: EdgeInsets.only(right: 8),
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(count.toString()),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildNetworkFolder(String key) {
    var data = getFavoriteDataOrNull(key);
    if (data == null) {
      return const SizedBox();
    }
    bool isSelected = key == widget.selectedFolder && widget.isNetworkSelected;
    return ClickInkWell(
      onTap: () {
        if (isSelected) {
          return;
        }
        widget.onFolderSelected(true, key);
        widget.onSelected?.call();
      },
      child: Container(
        height: 42,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: isSelected
              ? context.colorScheme.primaryContainer.toOpacity(0.36)
              : null,
          border: Border(
            left: BorderSide(
              color: isSelected
                  ? context.colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.only(left: 16),
        child: Text(data.title),
      ),
    );
  }

  @override
  void update() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void updateFolders() {
    if (!mounted) return;
    setState(() {
      folders = LocalFavoritesManager().folders;
      findNetworkFolders();
    });
  }
}
