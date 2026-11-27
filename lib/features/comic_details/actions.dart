import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/side_bar.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/routing/comic_source_switch.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_details/archive_download.dart';
import 'package:venera_plus/features/comic_details/comments_page.dart';
import 'package:venera_plus/features/comic_details/cover_viewer.dart';
import 'package:venera_plus/features/comic_details/favorite.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/search/search_shortcuts.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/image_provider/cached_image.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/network/cache.dart';
import 'package:venera_plus/routing/page_jump_target.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';

abstract mixin class ComicPageActions {
  BuildContext get context;
  void update();

  Future<void> refreshDetails({bool coverOnly = false});

  bool get isRemoteLibraryComic =>
      RemoteLibraryEngines.find(comic.sourceKey) != null ||
      comic.sourceKey == RemoteLibrarySource.sourceKey;

  bool get hasRemoteCustomCover =>
      isRemoteLibraryComic &&
      comic.cover.trim().isNotEmpty &&
      _hasRemoteCustomCover(comic, comic.cover);

  bool _hasRemoteCustomCover(ComicDetails target, String cover) {
    final engine = RemoteLibraryEngines.find(target.sourceKey);
    return engine?.hasCustomCover(target.id, cover) ??
        (target.sourceKey == RemoteLibrarySource.sourceKey &&
            RemoteLibrarySource.hasCustomCover(target.id, cover));
  }

  bool _isUpdatingCover = false;

  Future<ComicCoverUpdate?> replaceRemoteCover() =>
      _updateRemoteCover(restore: false);

  Future<ComicCoverUpdate?> restoreRemoteDefaultCover() =>
      _updateRemoteCover(restore: true);

  Future<ComicCoverUpdate?> _updateRemoteCover({required bool restore}) async {
    if (_isUpdatingCover || !isRemoteLibraryComic) return null;
    final target = comic;
    final engine = RemoteLibraryEngines.find(target.sourceKey);
    final pageContext = context;
    final rootContext = App.rootContext;
    final errorMessage = restore
        ? 'Could not restore default cover. @error'
        : 'Could not replace cover. @error';
    LoadingDialogController? loading;
    var coverChanged = false;
    _isUpdatingCover = true;
    try {
      Uint8List? bytes;
      final Res<RemoteLibraryCoverUpdateResult> response;
      if (restore) {
        var confirmed = false;
        await showConfirmDialog(
          context: rootContext,
          title: 'Restore default cover'.tl,
          content:
              'This will delete the custom cover files in the cloud and restore the default cover.'
                  .tl,
          onConfirm: () => confirmed = true,
        );
        if (!confirmed || !pageContext.mounted || !rootContext.mounted) {
          return null;
        }
        loading = showLoadingDialog(
          rootContext,
          barrierDismissible: false,
          allowCancel: false,
          message: 'Restoring default cover...'.tl,
        );
        response =
            await (engine?.restoreDefaultCover(target.id) ??
                RemoteLibrarySource.restoreDefaultCover(target.id));
      } else {
        final file = await selectFile(
          ext: comicImageExtensions.toList(),
          mimeType: 'image/*',
          allowUnknownExtension: true,
        );
        if (file == null || !pageContext.mounted || !rootContext.mounted) {
          return null;
        }
        bytes = await file.readAsBytes();
        if (!pageContext.mounted || !rootContext.mounted) return null;
        final fileType = detectFileType(bytes);
        final detectedExtension = fileType.ext.substring(1).toLowerCase();
        if (bytes.isEmpty ||
            !fileType.mime.startsWith('image/') ||
            !comicImageExtensions.contains(detectedExtension)) {
          rootContext.showMessage(message: 'Select a supported image file.'.tl);
          return null;
        }
        final selectedExtension = comicFileExtension(file.name);
        final extension =
            comicImageExtensions.contains(selectedExtension) &&
                FileType.fromExtension(selectedExtension).mime == fileType.mime
            ? selectedExtension
            : detectedExtension;
        loading = showLoadingDialog(
          rootContext,
          barrierDismissible: false,
          allowCancel: false,
          message: 'Uploading cover...'.tl,
        );
        response =
            await (engine?.replaceCover(
                  target.id,
                  localPath: file.path,
                  extension: extension,
                ) ??
                RemoteLibrarySource.replaceCover(
                  target.id,
                  localPath: file.path,
                  extension: extension,
                ));
      }

      if (response.error) {
        if (rootContext.mounted) {
          rootContext.showMessage(
            message: errorMessage.tlParams({
              'error': (response.errorMessage ?? 'Error').tl,
            }),
          );
        }
        return null;
      }
      final result = response.data;
      coverChanged = result.changed;
      if (result.changed || result.previousCover != result.cover) {
        await _syncRemoteCover(target, result, bytes);
      }
      if (pageContext.mounted) await refreshDetails(coverOnly: true);
      if (rootContext.mounted) {
        final message = switch (result) {
          RemoteLibraryCoverUpdateResult(changed: false) =>
            'Already using default cover'.tl,
          _ when restore => 'Default cover restored'.tl,
          RemoteLibraryCoverUpdateResult(failedOldCoverRemovals: final files)
              when files.isNotEmpty =>
            'Cover updated, but some old cover files could not be deleted (@files).'
                .tlParams({'files': files.join(', ')}),
          _ => 'Cover updated'.tl,
        };
        rootContext.showMessage(message: message);
      }
      return (
        imageProvider: result.cover.isEmpty
            ? null
            : CachedImageProvider(
                result.cover,
                sourceKey: target.sourceKey,
                cid: target.id,
              ),
        hasCustomCover: _hasRemoteCustomCover(target, result.cover),
      );
    } catch (error, stackTrace) {
      Log.error('Remote Library cover update', error, stackTrace);
      if (rootContext.mounted) {
        final message = coverChanged
            ? 'The cloud cover changed, but the local update failed. @error'
            : errorMessage;
        rootContext.showMessage(message: message.tlParams({'error': error}));
      }
      return null;
    } finally {
      loading?.close();
      _isUpdatingCover = false;
    }
  }

  Future<void> _syncRemoteCover(
    ComicDetails target,
    RemoteLibraryCoverUpdateResult result,
    Uint8List? bytes,
  ) async {
    final sourceKey = target.sourceKey;
    final id = target.id;
    final cache = CacheManager();
    final imageCache = PaintingBinding.instance.imageCache;
    final paths = result.invalidatedCoverPaths
        .where((path) => path.trim().isNotEmpty)
        .toSet();
    List<String> cacheKeys(String path) => [
      '$path@$sourceKey@$id',
      '$path@$sourceKey',
    ];

    for (final path in paths) {
      for (final key in cacheKeys(path)) {
        await cache.delete(key);
      }
    }
    if (bytes != null && result.cover.isNotEmpty) {
      for (final key in cacheKeys(result.cover)) {
        await cache.writeCache(key, bytes);
      }
    }
    NetworkCacheManager().clear();
    for (final path in paths) {
      imageCache.evict(
        CachedImageProvider(path, sourceKey: sourceKey, cid: id),
      );
      imageCache.evict(CachedImageProvider(path, sourceKey: sourceKey));
    }

    final histories = HistoryManager();
    final history = histories.find(id, target.comicType);
    if (history != null) {
      imageCache.evict(HistoryImageProvider(history));
      await histories.updateCover(history, result.cover);
    }
    LocalFavoritesManager().updateCover(id, target.comicType, result.cover);
  }

  bool _isRetryingMetadataScrape = false;

  Future<void> retryMetadataScrape() async {
    if (_isRetryingMetadataScrape) return;
    if (!BangumiService().isConnected) {
      App.rootContext.showMessage(
        message: 'Connect Bangumi in Settings first'.tl,
      );
      return;
    }
    _isRetryingMetadataScrape = true;
    final loadingController = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      allowCancel: false,
      message: 'Rescraping metadata...'.tl,
    );
    try {
      final engine = RemoteLibraryEngines.find(comic.sourceKey);
      final res =
          await (engine?.retryMetadataScrape(comic.id) ??
              RemoteLibrarySource.retryMetadataScrape(comic.id));
      if (!context.mounted) return;
      if (res.error) {
        App.rootContext.showMessage(message: (res.errorMessage ?? 'Error').tl);
      } else {
        switch (res.data) {
          case RemoteLibraryMetadataScrapeResult.matched:
            await refreshDetails();
            break;
          case RemoteLibraryMetadataScrapeResult.noMatch:
            App.rootContext.showMessage(message: 'No match found'.tl);
            break;
          case RemoteLibraryMetadataScrapeResult.notNeeded:
            App.rootContext.showMessage(
              message:
                  'Existing metadata does not need automatic scraping. Use manual binding to adjust.'
                      .tl,
            );
            break;
        }
      }
    } finally {
      loadingController.close();
      _isRetryingMetadataScrape = false;
    }
  }

  ComicDetails get comic;

  ComicSource get comicSource => ComicSource.find(comic.sourceKey)!;

  History? get history;

  bool isLiking = false;

  bool isLiked = false;

  void likeOrUnlike() async {
    if (isLiking) return;
    isLiking = true;
    update();
    var res = await comicSource.likeOrUnlikeComic!(comic.id, isLiked);
    if (res.error) {
      App.rootContext.showMessage(message: res.errorMessage!);
    } else {
      isLiked = !isLiked;
    }
    isLiking = false;
    update();
  }

  /// whether the comic is added to local favorite
  bool isAddToLocalFav = false;

  /// whether the comic is favorite on the server
  bool isFavorite = false;

  FavoriteItem _toFavoriteItem() {
    var tags = <String>[];
    for (var e in comic.tags.entries) {
      tags.addAll(e.value.map((tag) => '${e.key}:$tag'));
    }
    return FavoriteItem(
      id: comic.id,
      name: comic.title,
      coverPath: comic.cover,
      author: comic.subTitle ?? comic.uploader ?? '',
      type: comic.comicType,
      tags: tags,
    );
  }

  void openFavPanel() {
    final updateSnapshot = ComicUpdateSnapshot.fromChapters(
      comic.chapters?.toJson(),
      updateTime: comic.findUpdateTime(),
      maxPage: comic.maxPage,
      chapterPageCounts: comic.chapterPageCounts,
    );
    showSideBar(
      App.rootContext,
      ComicFavoritePanel(
        cid: comic.id,
        type: comic.comicType,
        isFavorite: isFavorite,
        onFavorite: (local, network) {
          if (network != null) {
            isFavorite = network;
            if (network) {
              final manager = LocalFavoritesManager();
              manager.saveUpdateState(
                comic.id,
                comic.comicType,
                manager
                    .getUpdateState(comic.id, comic.comicType)
                    .observe(updateSnapshot)
                    .state,
              );
            }
          }
          if (local != null) {
            isAddToLocalFav = local;
          }
          update();
        },
        favoriteItem: _toFavoriteItem(),
        updateSnapshot: updateSnapshot,
      ),
    );
  }

  bool _switchingSource = false;

  Future<void> changeSource() async {
    if (_switchingSource) return;
    _switchingSource = true;
    try {
      final selected = await switchComicSource(
        context,
        id: comic.id,
        sourceKey: comic.sourceKey,
        title: comic.title,
      );
      if (selected != null && context.mounted) {
        replaceSourcePage(selected);
      }
    } finally {
      _switchingSource = false;
    }
  }

  void replaceSourcePage(ComicDetails selected, {bool read = false}) {
    context.toReplacement(
      () => ComicPage(
        id: selected.id,
        sourceKey: selected.sourceKey,
        title: selected.title,
        cover: selected.cover,
        continueReading: read,
      ),
    );
  }

  void openBangumiProgress() {
    showSideBar(
      App.rootContext,
      BangumiProgressPanel(
        sourceKey: comic.sourceKey,
        comicId: comic.id,
        comicTitle: comic.title,
        initialSubjectId: int.tryParse(comic.externalIds['bangumi'] ?? ''),
        chapters: comic.chapters,
        history: history,
      ),
    );
  }

  void quickFavorite() {
    var folder = appdata.settings['quickFavorite'];
    if (folder is! String) {
      return;
    }
    LocalFavoritesManager().addComic(
      folder,
      _toFavoriteItem(),
      null,
      ComicUpdateSnapshot.fromChapters(
        comic.chapters?.toJson(),
        updateTime: comic.findUpdateTime(),
        maxPage: comic.maxPage,
        chapterPageCounts: comic.chapterPageCounts,
      ),
    );
    isAddToLocalFav = true;
    update();
    App.rootContext.showMessage(
      message: "Added to @folder".tlParams({"folder": folder}),
    );
  }

  void share() {
    var text = comic.title;
    if (comic.url != null) {
      text += '\n${comic.url}';
    }
    Share.shareText(text);
  }

  /// read the comic
  ///
  /// [ep] the episode number, start from 1
  ///
  /// [page] the page number, start from 1
  ///
  /// [group] the chapter group number, start from 1
  void read([int? ep, int? page, int? group]) {
    final currentHistory =
        HistoryManager().find(comic.id, comic.comicType) ??
        History.fromModel(model: comic, ep: 0, page: 0);
    final hasExplicitTarget = ep != null || page != null || group != null;
    final updateSnapshot = ComicUpdateSnapshot.fromChapters(
      comic.chapters?.toJson(),
      updateTime: comic.findUpdateTime(),
      maxPage: comic.maxPage,
      chapterPageCounts: comic.chapterPageCounts,
    );
    App.rootContext
        .to<ComicDetails>(
          () => Reader(
            returnSourceChanges: true,
            type: comic.comicType,
            cid: comic.id,
            name: comic.title,
            chapters: comic.chapters,
            initialChapter: ep,
            initialPage: page,
            initialChapterGroup: group,
            initialNavigationSource: hasExplicitTarget
                ? ReadingNavigationSource.userSeek
                : ReadingNavigationSource.restore,
            history: currentHistory,
            author: comic.findAuthor() ?? '',
            tags: comic.plainTags,
            updateSnapshot: updateSnapshot,
          ),
        )
        .then((selected) {
          if (!context.mounted) return;
          if (selected != null) {
            replaceSourcePage(selected, read: true);
          } else {
            onReadEnd();
          }
        });
  }

  void continueRead() {
    read();
  }

  void onReadEnd();

  void download() async {
    if (LocalManager().isDownloading(comic.id, comic.comicType)) {
      App.rootContext.showMessage(message: "The comic is downloading".tl);
      return;
    }
    if (comic.chapters == null &&
        LocalManager().isDownloaded(comic.id, comic.comicType, 0)) {
      App.rootContext.showMessage(message: "The comic is downloaded".tl);
      return;
    }

    if (comicSource.archiveDownloader != null) {
      bool useNormalDownload = false;
      List<ArchiveInfo>? archives;
      int selected = -1;
      bool isLoading = false;
      bool isGettingLink = false;
      String? archiveLoadError;
      await showDialog(
        context: App.rootContext,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setState) {
              Future<void> loadArchives() async {
                if (isLoading) return;
                isLoading = true;
                archives = null;
                archiveLoadError = null;
                selected = -1;
                setState(() {});
                final value = await loadArchiveOptions(
                  comicSource.archiveDownloader!,
                  comic.id,
                );
                if (value.success) {
                  archives = value.dataOrNull ?? [];
                  if (archives!.isEmpty) {
                    archiveLoadError = "No archive options available".tl;
                  }
                } else {
                  archives = [];
                  archiveLoadError =
                      (value.errorMessage ?? "Failed to load archive options")
                          .tl;
                }
                isLoading = false;
                if (context.mounted) {
                  setState(() {});
                }
              }

              return ContentDialog(
                title: "Download".tl,
                content: RadioGroup<int>(
                  groupValue: selected,
                  onChanged: (v) {
                    setState(() {
                      selected = v ?? selected;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RadioListTile<int>(value: -1, title: Text("Normal".tl)),
                      ExpansionTile(
                        title: Text("Archive".tl),
                        shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        collapsedShape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        onExpansionChanged: (b) {
                          if (b &&
                              (archives == null || archiveLoadError != null)) {
                            loadArchives();
                          }
                        },
                        children: [
                          if (archives == null)
                            const ListLoadingIndicator().toCenter()
                          else if (archiveLoadError != null)
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(title: Text(archiveLoadError!)),
                                Button.text(
                                  onPressed: loadArchives,
                                  child: Text("Retry".tl),
                                ),
                              ],
                            )
                          else
                            for (int i = 0; i < archives!.length; i++)
                              RadioListTile<int>(
                                value: i,
                                title: Text(archives![i].title),
                                subtitle: Text(archives![i].description),
                              ),
                        ],
                      ),
                    ],
                  ),
                ),
                actions: [
                  Button.filled(
                    isLoading: isGettingLink,
                    onPressed: () async {
                      if (selected == -1) {
                        useNormalDownload = true;
                        context.pop();
                        return;
                      }
                      setState(() {
                        isGettingLink = true;
                      });
                      if (archives == null ||
                          selected < 0 ||
                          selected >= archives!.length) {
                        App.rootContext.showMessage(
                          message: "Select an archive option".tl,
                        );
                      } else {
                        final res = await loadArchiveDownloadLink(
                          comicSource.archiveDownloader!,
                          comic.id,
                          archives![selected].id,
                        );
                        if (res.error) {
                          App.rootContext.showMessage(
                            message: (res.errorMessage ?? "Error").tl,
                          );
                        } else if (context.mounted) {
                          LocalManager().addTask(
                            ArchiveDownloadTask(res.data, comic),
                          );
                          App.rootContext.showMessage(
                            message: "Download started".tl,
                          );
                          context.pop();
                        }
                      }
                      if (context.mounted) {
                        isGettingLink = false;
                        setState(() {});
                      }
                    },
                    child: Text("Confirm".tl),
                  ),
                ],
              );
            },
          );
        },
      );
      if (!useNormalDownload) {
        return;
      }
    }

    await downloadComicChapters(App.rootContext, comic);
    update();
  }

  void onTapTag(String tag, String namespace) {
    searchTargetForTag(tag, namespace)?.jump(context);
  }

  PageJumpTarget? searchTargetForTag(String tag, String namespace) {
    return comicSource.handleClickTagEvent?.call(namespace, tag);
  }

  void showTagMenu(
    String tag,
    String namespace,
    BuildContext tagContext, {
    Offset? location,
  }) {
    if (location == null) {
      final renderBox = tagContext.findRenderObject() as RenderBox;
      final offset = renderBox.localToGlobal(Offset.zero);
      location = Offset(
        offset.dx + renderBox.size.width / 2 - 121,
        offset.dy + renderBox.size.height - 8,
      );
    }

    final target = searchTargetForTag(tag, namespace);
    final entries = [
      if (target != null)
        MenuEntry(
          icon: Icons.remove_red_eye,
          text: 'View'.tl,
          onClick: () => target.jump(context),
        ),
      MenuEntry(
        icon: Icons.copy,
        text: 'Copy'.tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: tag));
          tagContext.showMessage(message: 'Copied'.tl);
        },
      ),
    ];
    if (target != null) {
      final shortcut = SearchShortcut(
        kind: isAuthorNamespace(namespace)
            ? SearchShortcutKind.author
            : SearchShortcutKind.tag,
        sourceKey: comic.sourceKey,
        namespace: namespace,
        value: tag,
      );
      final manager = SearchShortcutManager.instance;
      final saved = manager.contains(shortcut);
      entries.add(
        MenuEntry(
          icon: saved ? Icons.bookmark_remove : Icons.bookmark_add,
          text: saved
              ? (shortcut.isAuthor
                    ? 'Unfavorite author'.tl
                    : 'Remove tag shortcut'.tl)
              : (shortcut.isAuthor
                    ? 'Favorite author'.tl
                    : 'Save tag shortcut'.tl),
          onClick: () {
            manager.toggle(shortcut);
            tagContext.showMessage(
              message: saved
                  ? 'Search shortcut removed'.tl
                  : 'Search shortcut saved'.tl,
            );
          },
        ),
      );
    }
    showMenuX(tagContext, location, entries);
  }

  void showMoreActions() {
    var context = App.rootContext;
    final location = Offset(context.width - 16, context.padding.top + 52);
    showMenuX(context, location, [
      MenuEntry(
        icon: Icons.swap_horiz,
        text: 'Switch source'.tl,
        onClick: changeSource,
      ),
      if (isRemoteLibraryComic) ...[
        MenuEntry(
          icon: Icons.auto_awesome,
          text: 'Rescrape metadata'.tl,
          onClick: retryMetadataScrape,
        ),
        MenuEntry(
          icon: Icons.add_photo_alternate_outlined,
          text: 'Replace cover'.tl,
          onClick: replaceRemoteCover,
        ),
        if (hasRemoteCustomCover)
          MenuEntry(
            icon: Icons.restore,
            text: 'Restore default cover'.tl,
            onClick: restoreRemoteDefaultCover,
          ),
      ],
      MenuEntry(icon: Icons.share, text: 'Share'.tl, onClick: share),
      MenuEntry(
        icon: Icons.copy,
        text: "Copy Title".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.title));
          context.showMessage(message: "Copied".tl);
        },
      ),
      MenuEntry(
        icon: Icons.copy_rounded,
        text: "Copy ID".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.id));
          context.showMessage(message: "Copied".tl);
        },
      ),
      if (comic.url != null)
        MenuEntry(
          icon: Icons.link,
          text: "Copy URL".tl,
          onClick: () {
            Clipboard.setData(ClipboardData(text: comic.url!));
            context.showMessage(message: "Copied".tl);
          },
        ),
      if (comic.url != null)
        MenuEntry(
          icon: Icons.open_in_browser,
          text: "Open in Browser".tl,
          onClick: () {
            launchUrlString(comic.url!);
          },
        ),
    ]);
  }

  void showComments() {
    showSideBar(
      App.rootContext,
      CommentsPage(data: comic, source: comicSource),
    );
  }

  void starRating() {
    if (!comicSource.isLogged) {
      return;
    }
    var rating = 1.0;
    var isLoading = false;
    showDialog(
      context: App.rootContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => SimpleDialog(
          title: Text("Rating".tl),
          alignment: Alignment.center,
          children: [
            SizedBox(
              height: 100,
              child: Center(
                child: SizedBox(
                  width: 210,
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      RatingWidget(
                        padding: 2,
                        onRatingUpdate: (value) => rating = value,
                        value: rating,
                        selectable: true,
                        size: 40,
                      ),
                      const Spacer(),
                      Button.filled(
                        isLoading: isLoading,
                        onPressed: () {
                          setState(() {
                            isLoading = true;
                          });
                          comicSource.starRatingFunc!(comic.id, rating.round())
                              .then((value) {
                                if (value.success) {
                                  App.rootContext.showMessage(
                                    message: "Success".tl,
                                  );
                                  Navigator.of(dialogContext).pop();
                                } else {
                                  App.rootContext.showMessage(
                                    message: value.errorMessage!,
                                  );
                                  setState(() {
                                    isLoading = false;
                                  });
                                }
                              });
                        },
                        child: Text("Submit".tl),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
