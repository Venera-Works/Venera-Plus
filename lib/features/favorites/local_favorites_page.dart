import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/flyout.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/components/select.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorite_actions.dart';
import 'package:venera_plus/features/favorites/favorites_display.dart';
import 'package:venera_plus/features/favorites/favorites_constants.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/features/favorites/reorder_comics_page.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/routing/comic_navigation.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/consts.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/opencc.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

/// If the number of comics in a folder exceeds this limit, it will be
/// fetched asynchronously.
const _asyncDataFetchLimit = 500;

class LocalFavoritesPage extends StatefulWidget {
  const LocalFavoritesPage({
    required this.folder,
    required this.showFolders,
    required this.onFolderSelected,
    required this.updateFolderList,
    this.isActive = true,
    super.key,
  });

  final String folder;
  final VoidCallback showFolders;
  final void Function(bool isNetwork, String? folder) onFolderSelected;
  final VoidCallback updateFolderList;
  final bool isActive;
  @override
  State<LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<LocalFavoritesPage> {
  late List<FavoriteItem> comics;
  bool _historyDirty = false;
  ModalRoute<dynamic>? _route;
  bool _tickerModeEnabled = true;

  bool get _isVisible =>
      widget.isActive && _tickerModeEnabled && (_route?.isCurrent ?? true);

  String? networkSource;
  String? networkFolder;

  Map<FavoriteItem, bool> selectedComics = {};

  var selectedLocalFolders = <String>{};

  late List<String> added = [];

  String keyword = "";
  bool searchHasUpper = false;

  bool searchMode = false;

  bool multiSelectMode = false;

  FavoriteItem? lastSelectedComic;

  bool get isAllFolder => widget.folder == localAllFolderLabel;

  LocalFavoritesManager get manager => LocalFavoritesManager();

  bool isLoading = false;
  String? loadError;
  int _loadGeneration = 0;
  late String readFilterSelect;

  var searchResults = <FavoriteItem>[];

  List<FavoriteItem> get displayedComics => filterComics(
    searchMode ? searchResults : comics,
  ).where((comic) => isBlocked(comic) == null).toList();

  List<FavoriteItem> get selectedMembers =>
      displayedComics.where(selectedComics.containsKey).toList();

  void _refreshComics() {
    _historyDirty = false;
    _updateSearchResults();
  }

  void _updateSearchResults() {
    searchResults = keyword.trim().isEmpty
        ? comics
        : comics
              .where(
                (comic) =>
                    matchKeyword(keyword, comic) ||
                    matchKeywordT(keyword, comic) ||
                    matchKeywordS(keyword, comic),
              )
              .toList();
    _retainDisplayedSelection();
  }

  void _retainDisplayedSelection() {
    final visible = displayedComics;
    selectedComics = {
      for (final comic in visible)
        if (selectedComics.containsKey(comic)) comic: true,
    };
    if (selectedComics.isEmpty) multiSelectMode = false;
    if (!visible.contains(lastSelectedComic)) lastSelectedComic = null;
  }

  void updateSearchResult() {
    setState(_updateSearchResults);
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    setState(_retainDisplayedSelection);
  }

  void _onHistoryChanged() {
    if (!mounted) return;
    _historyDirty = true;
    if (_isVisible) setState(_refreshComics);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    if (_isVisible && _historyDirty) _refreshComics();
  }

  void updateComics() {
    unawaited(loadComics());
  }

  Future<void> loadComics() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final managerGen = manager.generation;

    if (isAllFolder) {
      final totalComics = manager.totalComics;
      if (totalComics < _asyncDataFetchLimit) {
        comics = manager.getAllComics();
        isLoading = false;
        loadError = null;
        _refreshComics();
        if (mounted) setState(() {});
        return;
      }

      setState(() {
        isLoading = true;
        loadError = null;
      });

      final future = manager.getAllComicsAsync();
      try {
        final value = await future;
        if (mounted &&
            _loadGeneration == generation &&
            manager.isCurrentGeneration(managerGen) &&
            isAllFolder) {
          setState(() {
            isLoading = false;
            comics = value;
            loadError = null;
            _refreshComics();
          });
        }
      } catch (error, stackTrace) {
        Log.error("LocalFavoritesPage.loadComics", error, stackTrace);
        if (mounted &&
            _loadGeneration == generation &&
            manager.isCurrentGeneration(managerGen) &&
            isAllFolder) {
          setState(() {
            isLoading = false;
            comics = [];
            loadError = "Failed to load comics".tl;
            _refreshComics();
          });
          context.showMessage(message: "Failed to load comics".tl);
        }
      }
    } else {
      if (!manager.existsFolder(widget.folder)) {
        comics = [];
        isLoading = false;
        loadError = null;
        _refreshComics();
        if (mounted) setState(() {});
        return;
      }

      final folderComics = manager.folderComics(widget.folder);
      if (folderComics < _asyncDataFetchLimit) {
        comics = manager.getFolderComics(widget.folder);
        isLoading = false;
        loadError = null;
        _refreshComics();
        if (mounted) setState(() {});
        return;
      }

      setState(() {
        isLoading = true;
        loadError = null;
      });

      final targetFolder = widget.folder;
      final future = manager.getFolderComicsAsync(targetFolder);
      try {
        final value = await future;
        if (mounted &&
            _loadGeneration == generation &&
            manager.isCurrentGeneration(managerGen) &&
            !isAllFolder &&
            widget.folder == targetFolder &&
            manager.existsFolder(targetFolder)) {
          setState(() {
            isLoading = false;
            comics = value;
            loadError = null;
            _refreshComics();
          });
        }
      } catch (error, stackTrace) {
        Log.error("LocalFavoritesPage.loadComics", error, stackTrace);
        if (mounted &&
            _loadGeneration == generation &&
            manager.isCurrentGeneration(managerGen) &&
            !isAllFolder &&
            widget.folder == targetFolder) {
          setState(() {
            isLoading = false;
            comics = [];
            loadError = "Failed to load comics".tl;
            _refreshComics();
          });
          context.showMessage(message: "Failed to load comics".tl);
        }
      }
    }
  }

  List<FavoriteItem> filterComics(List<FavoriteItem> currentComics) {
    return currentComics.where((group) {
      final comic = group;
      var history = HistoryManager().find(comic.id, comic.type);
      if (readFilterSelect == "UnCompleted") {
        return history == null || history.page != history.maxPage;
      } else if (readFilterSelect == "Completed") {
        return history != null && history.page == history.maxPage;
      }
      return true;
    }).toList();
  }

  bool matchKeyword(String keyword, FavoriteItem comic) {
    var list = keyword.split(" ");
    for (var k in list) {
      if (k.isEmpty) continue;
      if (checkKeyWordMatch(k, comic.title, false)) {
        continue;
      } else if (comic.subtitle != null &&
          checkKeyWordMatch(k, comic.subtitle!, false)) {
        continue;
      } else if (comic.tags.any((tag) {
        if (checkKeyWordMatch(k, tag, true)) {
          return true;
        } else if (tag.contains(':') &&
            checkKeyWordMatch(k, tag.split(':')[1], true)) {
          return true;
        } else if (App.locale.languageCode != 'en' &&
            checkKeyWordMatch(k, tag.translateTagsToCN, true)) {
          return true;
        }
        return false;
      })) {
        continue;
      } else if (checkKeyWordMatch(k, comic.author, true)) {
        continue;
      }
      return false;
    }
    return true;
  }

  bool checkKeyWordMatch(String keyword, String compare, bool needEqual) {
    String temp = compare;
    // 没有大写的话, 就转成小写比较, 避免搜索需要注意大小写
    if (!searchHasUpper) {
      temp = temp.toLowerCase();
    }
    if (needEqual) {
      return keyword == temp;
    }
    return temp.contains(keyword);
  }

  // Convert keyword to traditional Chinese to match comics
  bool matchKeywordT(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseSimplified(keyword)) {
      return false;
    }
    keyword = OpenCC.simplifiedToTraditional(keyword);
    return matchKeyword(keyword, comic);
  }

  // Convert keyword to simplified Chinese to match comics
  bool matchKeywordS(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseTraditional(keyword)) {
      return false;
    }
    keyword = OpenCC.traditionalToSimplified(keyword);
    return matchKeyword(keyword, comic);
  }

  @override
  void initState() {
    readFilterSelect =
        appdata.implicitData["local_favorites_read_filter"] ??
        readFilterList[0];
    if (!isAllFolder) {
      var (a, b) = LocalFavoritesManager().findLinked(widget.folder);
      networkSource = a;
      networkFolder = b;
    } else {
      networkSource = null;
      networkFolder = null;
    }
    comics = [];
    loadComics();
    LocalFavoritesManager().addListener(updateComics);
    appdata.settings.addListener(_onSettingsChanged);
    HistoryManager().addListener(_onHistoryChanged);
    super.initState();
  }

  @override
  void didUpdateWidget(covariant LocalFavoritesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isVisible && _historyDirty) _refreshComics();
    if (oldWidget.folder != widget.folder) {
      selectedComics.clear();
      multiSelectMode = false;
      lastSelectedComic = null;
      final linked = isAllFolder
          ? (null, null)
          : manager.findLinked(widget.folder);
      networkSource = linked.$1;
      networkFolder = linked.$2;
      loadComics();
    }
  }

  @override
  void dispose() {
    LocalFavoritesManager().removeListener(updateComics);
    appdata.settings.removeListener(_onSettingsChanged);
    HistoryManager().removeListener(_onHistoryChanged);
    scrollController.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    int updatedCount = 0;
    int errorCount = 0;
    String? lastError;
    final targetFolder = isAllFolder ? localAllFolderLabel : widget.folder;
    try {
      if (!isAllFolder && !LocalFavoritesManager().existsFolder(targetFolder)) {
        if (mounted) {
          context.showMessage(message: "Favorite folder no longer exists".tl);
        }
        return;
      }
      await for (var progress in updateFolder(targetFolder, true)) {
        updatedCount = progress.updated;
        errorCount = progress.errors;
        if (progress.errorMessage != null) {
          lastError = progress.errorMessage;
        }
      }
      final currentFolder = isAllFolder ? localAllFolderLabel : widget.folder;
      if (mounted && currentFolder == targetFolder) {
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
      Log.error("LocalFavoritesPage._onRefresh", e, s);
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

  void selectAll() {
    setState(() {
      selectedComics = {for (final group in displayedComics) group: true};
      multiSelectMode = selectedComics.isNotEmpty;
    });
  }

  void invertSelection() {
    setState(() {
      selectedComics = {
        for (final group in displayedComics)
          if (!selectedComics.containsKey(group)) group: true,
      };
      multiSelectMode = selectedComics.isNotEmpty;
    });
  }

  void _toggleSelection(FavoriteItem group) {
    setState(() {
      if (selectedComics.containsKey(group)) {
        selectedComics.remove(group);
      } else {
        selectedComics[group] = true;
      }
      multiSelectMode = selectedComics.isNotEmpty;
      lastSelectedComic = group;
    });
  }

  void _selectRange(FavoriteItem group) {
    setState(() {
      final visible = displayedComics;
      final start = visible.indexWhere((entry) => entry == lastSelectedComic);
      final end = visible.indexOf(group);
      if (!multiSelectMode || start < 0) {
        selectedComics[group] = true;
      } else {
        final from = start < end ? start : end;
        final to = start < end ? end : start;
        for (var index = from; index <= to; index++) {
          if (index == start) continue;
          final entry = visible[index];
          if (selectedComics.containsKey(entry)) {
            selectedComics.remove(entry);
          } else {
            selectedComics[entry] = true;
          }
        }
      }
      lastSelectedComic = group;
      multiSelectMode = selectedComics.isNotEmpty;
    });
  }

  bool downloadComic(FavoriteItem c) {
    var source = c.type.comicSource;
    if (source != null) {
      bool isDownloaded = LocalManager().isDownloaded(c.id, (c).type);
      if (isDownloaded) {
        return false;
      }
      LocalManager().addTask(
        ImagesDownloadTask(source: source, comicId: c.id, comicTitle: c.title),
      );
      return true;
    }
    return false;
  }

  Future<void> _downloadComics(List<FavoriteItem> groups) async {
    int count = 0;
    for (final group in groups) {
      if (downloadComic(group)) count++;
    }
    if (mounted && count > 0) {
      context.showMessage(
        message: "Added @c comics to download queue.".tlParams({"c": count}),
      );
    }
  }

  void downloadSelected() {
    unawaited(_downloadComics(selectedMembers));
  }

  void _openComic(FavoriteItem group, {required bool read, int? heroID}) {
    unawaited(
      openComic(
        App.mainNavigatorKey?.currentContext ?? context,
        group,
        read: read,
        heroID: heroID,
      ),
    );
  }

  var scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    final matchingComics = searchMode ? searchResults : comics;
    final readFilteredComics = filterComics(matchingComics);
    final readFilteredCount = matchingComics.length - readFilteredComics.length;
    final blockedCount = readFilteredComics.length - displayedComics.length;
    var title = widget.folder;
    if (title == localAllFolderLabel) {
      title = "All".tl;
    }

    Widget body = SmoothCustomScrollView(
      controller: scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (!searchMode && !multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Folders".tl,
              child: context.width <= favoritesTwoPanelChangeWidth
                  ? IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: widget.showFolders,
                    )
                  : const SizedBox(),
            ),
            title: GestureDetector(
              onTap: context.width < favoritesTwoPanelChangeWidth
                  ? widget.showFolders
                  : null,
              child: Text(title),
            ),
            actions: [
              if (networkSource != null && !isAllFolder)
                Tooltip(
                  message: "Sync".tl,
                  child: Flyout(
                    flyoutBuilder: (context) {
                      final GlobalKey<_SelectUpdatePageNumState>
                      selectUpdatePageNumKey =
                          GlobalKey<_SelectUpdatePageNumState>();
                      var updatePageWidget = _SelectUpdatePageNum(
                        networkSource: networkSource!,
                        networkFolder: networkFolder,
                        key: selectUpdatePageNumKey,
                      );
                      return FlyoutContent(
                        title: "Sync".tl,
                        content: updatePageWidget,
                        actions: [
                          Button.filled(
                            child: Text("Update".tl),
                            onPressed: () {
                              context.pop();
                              importNetworkFolder(
                                networkSource!,
                                selectUpdatePageNumKey
                                    .currentState!
                                    .updatePageNum,
                                widget.folder,
                                networkFolder!,
                              ).then((value) {
                                updateComics();
                              });
                            },
                          ),
                        ],
                      );
                    },
                    child: Builder(
                      builder: (context) {
                        return IconButton(
                          icon: const Icon(Icons.sync),
                          onPressed: () {
                            Flyout.of(context).show();
                          },
                        );
                      },
                    ),
                  ),
                ),
              const FavoriteDisplayButton(),
              Tooltip(
                message: "Filter".tl,
                child: IconButton(
                  icon: const Icon(Icons.sort_rounded),
                  color: readFilterSelect != readFilterList[0]
                      ? context.colorScheme.primaryContainer
                      : null,
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        return _LocalFavoritesFilterDialog(
                          initReadFilterSelect: readFilterSelect,
                          updateConfig: (readFilter) {
                            setState(() {
                              readFilterSelect = readFilter;
                            });
                            updateComics();
                          },
                        );
                      },
                    );
                  },
                ),
              ),
              Tooltip(
                message: "Search".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      keyword = "";
                      searchMode = true;
                      updateSearchResult();
                    });
                  },
                ),
              ),
              if (!isAllFolder)
                MenuButton(
                  entries: [
                    MenuEntry(
                      icon: Icons.edit_outlined,
                      text: "Rename".tl,
                      onClick: () {
                        showInputDialog(
                          context: App.rootContext,
                          title: "Rename".tl,
                          hintText: "New Name".tl,
                          onConfirm: (value) {
                            var err = validateFolderName(value.toString());
                            if (err != null) {
                              return err;
                            }
                            LocalFavoritesManager().rename(
                              widget.folder,
                              value.toString(),
                            );
                            widget.updateFolderList();
                            widget.onFolderSelected(false, value.toString());
                            return null;
                          },
                        );
                      },
                    ),
                    MenuEntry(
                      icon: manager.readingFolder == widget.folder
                          ? Icons.home
                          : Icons.home_outlined,
                      text:
                          (manager.readingFolder == widget.folder
                                  ? "Remove from Home Page"
                                  : "Show on Home Page")
                              .tl,
                      onClick: () {
                        unawaited(
                          manager.setReadingFolder(
                            manager.readingFolder == widget.folder
                                ? null
                                : widget.folder,
                          ),
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.reorder,
                      text: "Reorder".tl,
                      onClick: () {
                        context.to(() => ReorderComicsPage(widget.folder));
                      },
                    ),
                    MenuEntry(
                      icon: Icons.upload_file,
                      text: "Export".tl,
                      onClick: () {
                        var json = LocalFavoritesManager().folderToJson(
                          widget.folder,
                        );
                        saveFile(
                          data: utf8.encode(json),
                          filename: "${widget.folder}.json",
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.update,
                      text: "Update Comics Info".tl,
                      onClick: () {
                        updateComicsInfo(widget.folder).then((_) {
                          if (mounted) updateComics();
                        });
                      },
                    ),
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Folder".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        showConfirmDialog(
                          context: App.rootContext,
                          title: "Delete".tl,
                          content: "Delete folder '@f' ?".tlParams({
                            "f": widget.folder,
                          }),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            widget.onFolderSelected(false, null);
                            LocalFavoritesManager().deleteFolder(widget.folder);
                            widget.updateFolderList();
                          },
                        );
                      },
                    ),
                  ],
                ),
            ],
          )
        else if (multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    multiSelectMode = false;
                    selectedComics.clear();
                  });
                },
              ),
            ),
            title: Text(
              "Selected @c comics".tlParams({"c": selectedComics.length}),
            ),
            actions: [
              MenuButton(
                entries: [
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.drive_file_move,
                      text: "Move to folder".tl,
                      onClick: () => favoriteOption('move'),
                    ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.copy,
                      text: "Copy to folder".tl,
                      onClick: () => favoriteOption('add'),
                    ),
                  MenuEntry(
                    icon: Icons.select_all,
                    text: "Select All".tl,
                    onClick: selectAll,
                  ),
                  MenuEntry(
                    icon: Icons.deselect,
                    text: "Deselect".tl,
                    onClick: _cancel,
                  ),
                  MenuEntry(
                    icon: Icons.flip,
                    text: "Invert Selection".tl,
                    onClick: invertSelection,
                  ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Comic".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        showConfirmDialog(
                          context: context,
                          title: "Delete".tl,
                          content: "Delete @c comics?".tlParams({
                            "c": selectedComics.length,
                          }),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            _deleteComicWithId();
                          },
                        );
                      },
                    ),
                  MenuEntry(
                    icon: Icons.download,
                    text: "Download".tl,
                    onClick: downloadSelected,
                  ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.copy,
                      text: "Copy Title".tl,
                      onClick: () {
                        Clipboard.setData(
                          ClipboardData(text: selectedComics.keys.first.title),
                        );
                        context.showMessage(message: "Copied".tl);
                      },
                    ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.chrome_reader_mode_outlined,
                      text: "Read".tl,
                      onClick: () =>
                          _openComic(selectedMembers.single, read: true),
                    ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.arrow_forward_ios,
                      text: "Jump to Detail".tl,
                      onClick: () =>
                          _openComic(selectedMembers.single, read: false),
                    ),
                ],
              ),
            ],
          )
        else if (searchMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    setState(() {
                      searchMode = false;
                    });
                  });
                },
              ),
            ),
            title: TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: "Search".tl,
                border: UnderlineInputBorder(),
              ),
              onChanged: (v) {
                keyword = v;
                searchHasUpper = keyword.contains(RegExp(r'[A-Z]'));
                updateSearchResult();
              },
            ).paddingBottom(8).paddingRight(8),
          ),
        if (isLoading)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200,
              child: const Center(child: CircularProgressIndicator()),
            ),
          )
        else if (loadError != null)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      loadError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Button.filled(
                      onPressed: loadComics,
                      child: Text("Retry".tl),
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          if (readFilteredCount > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Hidden by reading-status filter: @a comics'.tlParams({
                    'a': readFilteredCount,
                  }),
                ),
              ),
            ),
          if (blockedCount > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  'Hidden by keyword filters: @a comics'.tlParams({
                    'a': blockedCount,
                  }),
                  style: TextStyle(color: context.colorScheme.secondary),
                ),
              ),
            ),
          SliverGridComics(
            comics: displayedComics,
            selections: selectedComics,
            useFavoriteDisplaySettings: true,
            hideFavoriteBadge: true,
            menuBuilder: (c) {
              final group = c as FavoriteItem;
              return [
                if (!isAllFolder)
                  MenuEntry(
                    icon: Icons.delete,
                    text: "Delete".tl,
                    onClick: () =>
                        manager.batchDeleteComics(widget.folder, [group]),
                  ),
                MenuEntry(
                  icon: Icons.check,
                  text: "Select".tl,
                  onClick: () => _toggleSelection(group),
                ),
                MenuEntry(
                  icon: Icons.download,
                  text: "Download".tl,
                  onClick: () => unawaited(_downloadComics([group])),
                ),
                MenuEntry(
                  icon: appdata.settings["onClickFavorite"] == "viewDetail"
                      ? Icons.menu_book_outlined
                      : Icons.info_outline,
                  text:
                      (appdata.settings["onClickFavorite"] == "viewDetail"
                              ? "Read"
                              : "View Detail")
                          .tl,
                  onClick: () => _openComic(
                    group,
                    read: appdata.settings["onClickFavorite"] == "viewDetail",
                  ),
                ),
                if (manager.hasNewUpdate(group.id, group.type))
                  MenuEntry(
                    icon: Icons.done_all,
                    text: 'Mark as read'.tl,
                    onClick: () => manager.markAsRead(group.id, group.type),
                  ),
              ];
            },
            onTap: (c, heroID) {
              final group = c as FavoriteItem;
              if (multiSelectMode) {
                _toggleSelection(group);
              } else {
                _openComic(
                  group,
                  read: appdata.settings["onClickFavorite"] != "viewDetail",
                  heroID: heroID,
                );
              }
            },
            onLongPressed: (c, heroID) => _selectRange(c as FavoriteItem),
          ),
        ],
      ],
    );
    body = AppRefreshIndicator(
      onRefresh: _onRefresh,
      child: AppScrollBar(
        topPadding: 48,
        controller: scrollController,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: body,
        ),
      ),
    );
    final canPopScope = widget.isActive
        ? (!multiSelectMode && !searchMode)
        : true;
    return PopScope(
      canPop: canPopScope,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !widget.isActive) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            updateComics();
          });
        }
      },
      child: body,
    );
  }

  void favoriteOption(String option) {
    selectedLocalFolders.clear();
    var targetFolders = LocalFavoritesManager().folderNames
        .where((folder) => folder != widget.folder)
        .toList();

    showPopUpWidget(
      App.rootContext,
      StatefulBuilder(
        builder: (context, setState) {
          return PopUpWidgetScaffold(
            title: widget.folder,
            body: Padding(
              padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
              child: Container(
                constraints: const BoxConstraints(
                  maxHeight: 700,
                  maxWidth: 500,
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: targetFolders.length + 1,
                        itemBuilder: (context, index) {
                          if (index == targetFolders.length) {
                            return SizedBox(
                              height: 36,
                              child: Center(
                                child: TextButton(
                                  onPressed: () {
                                    newFolder().then((_) {
                                      setState(() {
                                        targetFolders = LocalFavoritesManager()
                                            .folderNames
                                            .where(
                                              (folder) =>
                                                  folder != widget.folder,
                                            )
                                            .toList();
                                      });
                                    });
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.add, size: 20),
                                      const SizedBox(width: 4),
                                      Text("New Folder".tl),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                          var folder = targetFolders[index];
                          var disabled = false;
                          if (selectedLocalFolders.isNotEmpty) {
                            if (added.contains(folder) &&
                                !added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            } else if (!added.contains(folder) &&
                                added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            }
                          }
                          return CheckboxListTile(
                            title: Row(
                              children: [
                                Text(folder),
                                const SizedBox(width: 8),
                              ],
                            ),
                            value: selectedLocalFolders.contains(folder),
                            onChanged: disabled
                                ? null
                                : (v) {
                                    setState(() {
                                      if (v!) {
                                        selectedLocalFolders.add(folder);
                                      } else {
                                        selectedLocalFolders.remove(folder);
                                      }
                                    });
                                  },
                          );
                        },
                      ),
                    ),
                    Center(
                      child: FilledButton(
                        onPressed: () {
                          if (selectedLocalFolders.isEmpty) {
                            return;
                          }
                          final comics = selectedMembers;
                          final folders = selectedLocalFolders.toList();
                          for (final folder in folders) {
                            if (option == 'move' && folder == folders.last) {
                              manager.batchMoveFavorites(
                                widget.folder,
                                folder,
                                comics,
                              );
                            } else {
                              manager.batchCopyFavorites(
                                widget.folder,
                                folder,
                                comics,
                              );
                            }
                          }
                          App.rootContext.pop();
                          updateComics();
                          _cancel();
                        },
                        child: Text(option == 'move' ? "Move".tl : "Add".tl),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _cancel() {
    setState(() {
      selectedComics.clear();
      multiSelectMode = false;
      lastSelectedComic = null;
    });
  }

  void _deleteComicWithId() {
    LocalFavoritesManager().batchDeleteComics(widget.folder, selectedMembers);
    _cancel();
  }
}

class _SelectUpdatePageNum extends StatefulWidget {
  const _SelectUpdatePageNum({
    required this.networkSource,
    this.networkFolder,
    super.key,
  });

  final String? networkFolder;
  final String networkSource;

  @override
  State<_SelectUpdatePageNum> createState() => _SelectUpdatePageNumState();
}

class _SelectUpdatePageNumState extends State<_SelectUpdatePageNum> {
  int updatePageNum = 9999999;

  String get _allPageText => 'All'.tl;

  List<String> get pageNumList => [
    '1',
    '2',
    '3',
    '5',
    '10',
    '20',
    '50',
    '100',
    '200',
    _allPageText,
  ];

  @override
  void initState() {
    updatePageNum =
        appdata.implicitData["local_favorites_update_page_num"] ?? 9999999;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var source = ComicSource.find(widget.networkSource);
    var sourceName = source?.name ?? widget.networkSource;
    var text = "The folder is Linked to @source".tlParams({
      "source": sourceName,
    });
    if (widget.networkFolder != null && widget.networkFolder!.isNotEmpty) {
      text += "\n${"Source Folder".tl}: ${widget.networkFolder}";
    }

    return Column(
      children: [
        Row(children: [Text(text)]),
        Row(
          children: [
            Text("Update the page number by the latest collection".tl),
            Spacer(),
            Select(
              current: updatePageNum.toString() == '9999999'
                  ? _allPageText
                  : updatePageNum.toString(),
              values: pageNumList,
              minWidth: 48,
              onTap: (index) {
                setState(() {
                  updatePageNum = int.parse(
                    pageNumList[index] == _allPageText
                        ? '9999999'
                        : pageNumList[index],
                  );
                  appdata.implicitData["local_favorites_update_page_num"] =
                      updatePageNum;
                  appdata.writeImplicitData();
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _LocalFavoritesFilterDialog extends StatefulWidget {
  const _LocalFavoritesFilterDialog({
    required this.initReadFilterSelect,
    required this.updateConfig,
  });

  final String initReadFilterSelect;
  final Function updateConfig;

  @override
  State<_LocalFavoritesFilterDialog> createState() =>
      _LocalFavoritesFilterDialogState();
}

const readFilterList = ['All', 'UnCompleted', 'Completed'];

class _LocalFavoritesFilterDialogState
    extends State<_LocalFavoritesFilterDialog> {
  List<String> optionTypes = ['Filter'];
  late var readFilter = widget.initReadFilterSelect;
  @override
  Widget build(BuildContext context) {
    Widget tabBar = Material(
      borderRadius: BorderRadius.circular(8),
      child: AppTabBar(
        key: PageStorageKey(optionTypes),
        tabs: optionTypes.map((e) => Tab(text: e.tl, key: Key(e))).toList(),
      ),
    ).paddingTop(context.padding.top);
    return ContentDialog(
      content: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tabBar,
            TabViewBody(
              children: [
                Column(
                  children: [
                    ListTile(
                      title: Text("Filter reading status".tl),
                      trailing: Select(
                        current: readFilter.tl,
                        values: readFilterList.map((e) => e.tl).toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() {
                            readFilter = readFilterList[index];
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            appdata.implicitData["local_favorites_read_filter"] = readFilter;
            appdata.writeImplicitData();
            if (mounted) {
              Navigator.pop(context);
              widget.updateConfig(readFilter);
            }
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
