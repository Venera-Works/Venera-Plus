import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/local_comics/downloading_page.dart';
import 'download.dart';
import 'package:venera_plus/features/local_comics/local.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/local_comics/import_export/import_export.dart';
import 'package:venera_plus/features/search/library_tag_picker.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'local_bangumi_tags.dart';
import 'local_category_picker.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key, this.isRoot = false, this.isActive = true});

  final bool isRoot;
  final bool isActive;
  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

class _LocalComicsPageState extends State<LocalComicsPage> {
  late List<LocalComic> comics;
  late List<LocalComicCategory> _categories;

  late LocalSortType sortType;

  final _searchController = TextEditingController();
  var _categoryId = LocalManager.allCategories;
  Set<String> _selectedTags = {};

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalComic, bool> selectedComics = {};

  List<LocalComic> get visibleComics {
    final filter = comicKeywordFilter();
    return comics
        .where((comic) => matchComicKeyword(comic, filter: filter) == null)
        .toList();
  }

  void reconcileSelection() {
    final identities = {
      for (final entry in selectedComics.entries)
        if (entry.value) (entry.key.id, entry.key.comicType.value),
    };
    selectedComics = {
      for (final comic in visibleComics)
        if (identities.contains((comic.id, comic.comicType.value))) comic: true,
    };
    if (selectedComics.isEmpty) multiSelectMode = false;
  }

  void onSettingsChanged() {
    if (mounted) setState(reconcileSelection);
  }

  void update() {
    if (!mounted) return;
    setState(() {
      _loadComics();
      reconcileSelection();
    });
  }

  void _loadComics() {
    final manager = LocalManager();
    _categories = manager.comicCategories;
    if (_categoryId > LocalManager.uncategorized &&
        !_categories.any((category) => category.id == _categoryId)) {
      _categoryId = LocalManager.uncategorized;
    }
    comics = manager.search(
      _searchController.text,
      sortType: sortType,
      categoryId: _categoryId,
      tags: _selectedTags,
    );
  }

  void _closeSearch() {
    searchMode = false;
    _searchController.clear();
    update();
  }

  Future<void> _pickCategory() async {
    final id = await showLocalCategoryPicker(
      context,
      selectedCategory: _categoryId,
    );
    if (!mounted || id == null || id == _categoryId) return;
    _categoryId = id;
    update();
  }

  Future<void> _pickTags() async {
    final tags = await showLibraryTagPicker(
      context,
      availableTags: LocalManager().availableTags(_categoryId),
      selectedTags: _selectedTags,
    );
    if (!mounted || tags == null) return;
    _selectedTags = tags;
    update();
  }

  Future<void> _moveComicsToCategory(
    List<LocalComic> comics, {
    bool fromSelection = false,
  }) async {
    final id = await showLocalCategoryPicker(
      context,
      selectedCategory: _categoryId,
      moving: true,
    );
    if (!mounted || id == null) return;
    final candidates = {
      for (final comic in fromSelection ? selectedComics.keys : visibleComics)
        (comic.id, comic.comicType): comic,
    };
    for (final comic in comics) {
      final current = candidates[(comic.id, comic.comicType)];
      if (current == null ||
          (comic.comicType == ComicType.local &&
              (current.directory != comic.directory ||
                  current.createdAt != comic.createdAt))) {
        return;
      }
    }
    LocalManager().moveComicsToCategory(comics, id);
    setState(() {
      multiSelectMode = false;
      selectedComics.clear();
    });
  }

  Widget _buildFilters() {
    final categoryName = switch (_categoryId) {
      LocalManager.allCategories => 'All Comics'.tl,
      LocalManager.uncategorized => 'Uncategorized'.tl,
      _ =>
        _categories.firstWhere((category) => category.id == _categoryId).name,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _pickCategory,
                icon: const Icon(Icons.folder_outlined),
                label: Text(
                  categoryName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _pickTags,
            icon: Badge.count(
              count: _selectedTags.length,
              isLabelVisible: _selectedTags.isNotEmpty,
              child: const Icon(Icons.sell_outlined),
            ),
            label: Text('Tags'.tl),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "name";
    sortType = LocalSortType.fromString(sort);
    _loadComics();
    LocalManager().addListener(update);
    appdata.settings.addListener(onSettingsChanged);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    appdata.settings.removeListener(onSettingsChanged);
    _searchController.dispose();
    super.dispose();
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Name".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date Desc".tl),
                      value: LocalSortType.timeDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget buildMultiSelectMenu() {
    final selection = selectedComics.keys.toList();
    bool isCurrent() =>
        mounted &&
        listEquals(selectedComics.keys.toList(), selection) &&
        selection.every((comic) => matchComicKeyword(comic) == null);
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            if (!isCurrent()) return;
            deleteComics(selection, isCurrent: isCurrent).then((value) {
              if (value && mounted) {
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            if (isCurrent()) addFavorite(selection);
          },
        ),
        if (selection.isNotEmpty)
          MenuEntry(
            icon: Icons.drive_file_move_outlined,
            text: 'Move to category'.tl,
            onClick: () {
              if (isCurrent()) {
                _moveComicsToCategory(selection, fromSelection: true);
              }
            },
          ),
        if (selection.length == 1 &&
            selection.single.comicType == ComicType.local)
          MenuEntry(
            icon: Icons.sell_outlined,
            text: 'Match Bangumi tags'.tl,
            onClick: () {
              if (isCurrent()) {
                showLocalBangumiTagMatch(context, selection.single);
              }
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              if (isCurrent()) openComicFolder(selection.single);
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              if (!isCurrent()) return;
              context.to(
                () => ComicPage(
                  id: selection.single.id,
                  sourceKey: selection.single.sourceKey,
                ),
              );
            },
          ),
        if (selectedComics.isNotEmpty)
          MenuEntry(
            icon: Icons.cloud_upload_outlined,
            text: "Archive to Remote Storage".tl,
            onClick: () {
              if (!isCurrent()) return;
              archiveComics(selection).then((value) {
                if (value && mounted) {
                  setState(() {
                    multiSelectMode = false;
                    selectedComics.clear();
                  });
                }
              });
            },
          ),
        if (selectedComics.isNotEmpty)
          ...exportActions(selection, isCurrent: isCurrent),
      ],
    );
  }

  void selectAll() {
    setState(() {
      selectedComics = {for (final comic in visibleComics) comic: true};
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      selectedComics = {
        for (final comic in visibleComics)
          if (selectedComics[comic] != true) comic: true,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasSearch =
        _searchController.text.trim().isNotEmpty || _selectedTags.isNotEmpty;
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    final isWide = context.width >= 600;

    List<Widget> normalActions;
    if (isWide) {
      normalActions = [
        const PdfImportTasksButton(),
        Tooltip(
          message: "Search".tl,
          child: IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              setState(() {
                searchMode = true;
              });
            },
          ),
        ),
        Tooltip(
          message: "Sort".tl,
          child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
        ),
        Tooltip(
          message: "Downloading".tl,
          child: IconButton(
            icon: const Icon(Icons.download),
            onPressed: () {
              showPopUpWidget(context, const DownloadingPage());
            },
          ),
        ),
        if (BackupConfig.fromSettings().isValid)
          Tooltip(
            message: "Archive".tl,
            child: IconButton(
              icon: const Icon(Icons.archive_outlined),
              onPressed: () {
                context.to(() => const ComicArchivePage());
              },
            ),
          ),
        Tooltip(
          message: "Import".tl,
          child: IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              showImportComicsDialog(context);
            },
          ),
        ),
      ];
    } else {
      normalActions = [
        const PdfImportTasksButton(),
        Tooltip(
          message: "Search".tl,
          child: IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              setState(() {
                searchMode = true;
              });
            },
          ),
        ),
        Tooltip(
          message: "Import".tl,
          child: IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              showImportComicsDialog(context);
            },
          ),
        ),
        MenuButton(
          entries: [
            MenuEntry(icon: Icons.sort, text: "Sort".tl, onClick: sort),
            MenuEntry(
              icon: Icons.download,
              text: "Downloading".tl,
              onClick: () {
                showPopUpWidget(context, const DownloadingPage());
              },
            ),
            if (BackupConfig.fromSettings().isValid)
              MenuEntry(
                icon: Icons.archive_outlined,
                text: "Archive".tl,
                onClick: () {
                  context.to(() => const ComicArchivePage());
                },
              ),
            MenuEntry(
              icon: Icons.picture_as_pdf_outlined,
              text: "PDF import tasks".tl,
              onClick: () {
                showPdfImportTasksDialog(context: context);
              },
            ),
          ],
        ),
      ];
    }

    var body = Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => update(),
        child: SmoothCustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (!searchMode)
              SliverAppbar(
                leading: multiSelectMode
                    ? Tooltip(
                        message: "Cancel".tl,
                        child: IconButton(
                          onPressed: () {
                            setState(() {
                              multiSelectMode = false;
                              selectedComics.clear();
                            });
                          },
                          icon: const Icon(Icons.close),
                        ),
                      )
                    : (widget.isRoot
                          ? const SizedBox.shrink()
                          : (context.canPop()
                                ? Tooltip(
                                    message: "Back".tl,
                                    child: IconButton(
                                      onPressed: () {
                                        context.pop();
                                      },
                                      icon: const Icon(Icons.arrow_back),
                                    ),
                                  )
                                : const SizedBox.shrink())),
                title: multiSelectMode
                    ? Text(selectedComics.length.toString())
                    : Text("Local Comics".tl),
                actions: multiSelectMode ? selectActions : normalActions,
              )
            else
              SliverAppbar(
                leading: Tooltip(
                  message: "Cancel".tl,
                  child: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      if (multiSelectMode) {
                        setState(() {
                          multiSelectMode = false;
                          selectedComics.clear();
                        });
                      } else {
                        _closeSearch();
                      }
                    },
                  ),
                ),
                title: multiSelectMode
                    ? Text(selectedComics.length.toString())
                    : TextField(
                        controller: _searchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: "Search".tl,
                          border: InputBorder.none,
                        ),
                        onChanged: (_) => update(),
                      ),
                actions: multiSelectMode ? selectActions : null,
              ),
            if (!multiSelectMode) SliverToBoxAdapter(child: _buildFilters()),
            if (comics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_open_outlined,
                        size: 64,
                        color: context.colorScheme.outlineVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        hasSearch ? "No Comics Found".tl : "No Comics".tl,
                        style: const TextStyle(fontSize: 16),
                      ),
                      if (!hasSearch) ...[
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          icon: const Icon(Icons.add),
                          label: Text("Import".tl),
                          onPressed: () => showImportComicsDialog(context),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else
              SliverGridComics(
                showHiddenCount: true,
                badgeBuilder: (comic) =>
                    comic is LocalComic && comic.isIncomplete
                    ? 'Incomplete: @a missing pages'.tlParams({
                        'a': comic.missingImageCount,
                      })
                    : null,
                comics: comics,
                selections: selectedComics,
                onLongPressed: (c, heroID) {
                  setState(() {
                    multiSelectMode = true;
                    selectedComics[c as LocalComic] = true;
                  });
                },
                onTap: (c, heroID) {
                  if (multiSelectMode) {
                    setState(() {
                      if (selectedComics.containsKey(c as LocalComic)) {
                        selectedComics.remove(c);
                      } else {
                        selectedComics[c] = true;
                      }
                      if (selectedComics.isEmpty) {
                        multiSelectMode = false;
                      }
                    });
                  } else {
                    // prevent dirty data
                    var comic = LocalManager().find(
                      c.id,
                      (c as LocalComic).comicType,
                    )!;
                    comic.read();
                  }
                },
                menuBuilder: (comic) {
                  final c = comic as LocalComic;
                  return [
                    if (c.isIncomplete)
                      MenuEntry(
                        icon: Icons.download_outlined,
                        text: 'Retry missing images'.tl,
                        onClick: () {
                          try {
                            final manager = LocalManager();
                            final task = manager.downloadingTasks
                                .where(
                                  (task) =>
                                      task.id == c.id &&
                                      task.comicType == c.comicType,
                                )
                                .firstOrNull;
                            if (task != null) {
                              manager.resumeTask(task);
                            } else {
                              manager.addTask(ImagesDownloadTask.repair(c));
                            }
                          } catch (error) {
                            context.showMessage(message: error.toString());
                          }
                        },
                      ),
                    MenuEntry(
                      icon: Icons.menu_book_outlined,
                      text: "Read".tl,
                      onClick: () {
                        var localComic = LocalManager().find(
                          c.id,
                          c.comicType,
                        )!;
                        localComic.read();
                      },
                    ),
                    MenuEntry(
                      icon: Icons.info_outline,
                      text: "Details".tl,
                      onClick: () {
                        context.to(
                          () => ComicPage(
                            id: c.id,
                            sourceKey: c.sourceKey,
                            title: c.title,
                            cover: c.cover,
                          ),
                        );
                      },
                    ),
                    MenuEntry(
                      icon: Icons.folder_open,
                      text: "Open Folder".tl,
                      onClick: () {
                        openComicFolder(c);
                      },
                    ),
                    MenuEntry(
                      icon: Icons.drive_file_move_outlined,
                      text: 'Move to category'.tl,
                      onClick: () => _moveComicsToCategory([c]),
                    ),
                    if (c.comicType == ComicType.local)
                      MenuEntry(
                        icon: Icons.sell_outlined,
                        text: 'Match Bangumi tags'.tl,
                        onClick: () => showLocalBangumiTagMatch(context, c),
                      ),
                    MenuEntry(
                      icon: Icons.delete,
                      text: "Delete".tl,
                      onClick: () {
                        deleteComics([c]).then((value) {
                          if (value && multiSelectMode) {
                            setState(() {
                              multiSelectMode = false;
                              selectedComics.clear();
                            });
                          }
                        });
                      },
                    ),
                    MenuEntry(
                      icon: Icons.cloud_upload_outlined,
                      text: "Archive to Remote Storage".tl,
                      onClick: () {
                        archiveComics([c]);
                      },
                    ),
                    ...exportActions([c]),
                  ];
                },
              ),
          ],
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
          _closeSearch();
        }
      },
      child: body,
    );
  }

  Future<bool> deleteComics(
    List<LocalComic> comics, {
    bool Function()? isCurrent,
  }) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeComicFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(
          builder: (context, state) {
            return ContentDialog(
              title: "Delete".tl,
              content: Column(
                children: [
                  CheckboxListTile(
                    title: Text("Remove local favorite and history".tl),
                    value: removeFavoriteAndHistory,
                    onChanged: (v) {
                      state(() {
                        removeFavoriteAndHistory = !removeFavoriteAndHistory;
                      });
                    },
                  ),
                  CheckboxListTile(
                    title: Text("Also remove files on disk".tl),
                    value: removeComicFile,
                    onChanged: (v) {
                      state(() {
                        removeComicFile = !removeComicFile;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                if (comics.length == 1 && comics.first.hasChapters)
                  TextButton(
                    child: Text("Delete Chapters".tl),
                    onPressed: () {
                      context.pop();
                      showDeleteChaptersPopWindow(context, comics.first);
                    },
                  ),
                FilledButton(
                  onPressed: () {
                    if (isCurrent?.call() == false) {
                      context.pop();
                      return;
                    }
                    context.pop();
                    LocalManager().batchDeleteComics(
                      comics,
                      removeComicFile,
                      removeFavoriteAndHistory,
                    );
                    isDeleted = true;
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
    return isDeleted;
  }

  Future<bool> archiveComics(List<LocalComic> comics) async {
    if (comics.isEmpty) return false;
    if (!BackupConfig.fromSettings().isValid) {
      context.showMessage(message: 'Invalid WebDAV archive configuration'.tl);
      return false;
    }
    final result = await showComicArchiveTransferDialog(
      context,
      title: 'Archive to Remote Storage'.tl,
      batch: ComicBackupManager.createBackupBatch(comics),
    );
    return result.success > 0;
  }

  List<MenuEntry> exportActions(
    List<LocalComic> comics, {
    bool Function()? isCurrent,
  }) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          if (isCurrent?.call() != false) {
            unawaited(exportComics(comics, CBZ.export, ".cbz"));
          }
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () {
          if (isCurrent?.call() != false) {
            unawaited(exportComics(comics, createPdfFromComicIsolate, ".pdf"));
          }
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () {
          if (isCurrent?.call() != false) {
            unawaited(exportComics(comics, createEpubWithLocalComic, ".epub"));
          }
        },
      ),
    ];
  }

  /// Export given comics to a file
  Future<void> exportComics(
    List<LocalComic> comics,
    ExportComicFunc export,
    String ext,
  ) async {
    if (comics.isEmpty) return;
    final isBatch = comics.length > 1;
    var canceled = false;
    final loadingController = showLoadingDialog(
      context,
      allowCancel: true,
      message: "${"Exporting".tl} 0/${comics.length}",
      withProgress: isBatch,
      onCancel: () {
        canceled = true;
      },
    );
    Directory? workspace;
    try {
      final exportDirectory = await Directory(
        App.cachePath,
      ).createTemp('comics-export-');
      workspace = exportDirectory;
      final outputDirectory = isBatch
          ? await Directory(
              FilePath.join(exportDirectory.path, 'comics'),
            ).create()
          : exportDirectory;
      if (canceled || !mounted) return;

      for (final (index, comic) in comics.indexed) {
        final filename = sanitizeFileName(comic.title, maxLength: 100) + ext;
        final file = await export(
          comic,
          FilePath.join(outputDirectory.path, filename),
        );
        if (canceled || !mounted) return;
        if (!isBatch) {
          await saveFile(file: file, filename: filename);
          return;
        }
        final current = index + 1;
        loadingController.setMessage(
          "${"Exporting".tl} $current/${comics.length}",
        );
        loadingController.setProgress(current / comics.length);
      }

      loadingController.setProgress(null);
      loadingController.setMessage("Compressing".tl);
      const filename = 'comics_export.zip';
      final archive = File(FilePath.join(exportDirectory.path, filename));
      await ZipFile.compressFolderAsync(outputDirectory.path, archive.path);
      if (canceled || !mounted) return;
      await saveFile(file: archive, filename: filename);
    } catch (error, stack) {
      Log.error("Export Comics", error, stack);
      if (mounted && !canceled) {
        context.showMessage(message: error.toString());
      }
    } finally {
      loadingController.close();
      await workspace?.deleteIgnoreError(recursive: true);
    }
  }
}

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  try {
    final folderPath = comic.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: '${"Failed to open folder".tl}: $e');
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var selectedChapters = <String>[];
  final available = {
    ...comic.downloadedChapters,
    ...comic.incompleteChapters.keys,
  };
  final chapterIds = <String>[];
  if (comic.chapters != null) {
    for (final id in comic.chapters!.ids) {
      if (available.remove(id)) {
        chapterIds.add(id);
      }
    }
  }
  chapterIds.addAll(available);

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: chapterIds.length,
                  itemBuilder: (context, index) {
                    var id = chapterIds[index];
                    var chapter = comic.chapters?[id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: selectedChapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            selectedChapters.add(id);
                          } else {
                            selectedChapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        Future.delayed(const Duration(milliseconds: 200), () {
                          LocalManager().deleteComicChapters(
                            comic,
                            selectedChapters,
                          );
                        });
                        if (App.rootNavigatorKey.currentContext != null) {
                          App.rootContext.pop();
                        } else {
                          context.pop();
                        }
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
