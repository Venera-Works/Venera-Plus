import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorite_actions.dart';
import 'package:venera_plus/features/favorites/favorites_constants.dart';
import 'package:venera_plus/features/favorites/favorites_display.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/features/follow_updates/follow_updates.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/consts.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/throttled_task_runner.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/network/cache.dart';

class _RemoteComicBaseline {
  final String? updateTime;
  final bool hasUpdate;
  final int readRevision;

  const _RemoteComicBaseline({
    this.updateTime,
    this.hasUpdate = false,
    this.readRevision = 0,
  });
}

String? _buildComicBadge(
  Map<String, _RemoteComicBaseline> baselines,
  Comic comic,
) {
  final localManager = LocalFavoritesManager();
  final comicType = ComicType.fromKey(comic.sourceKey);
  if (localManager.isExist(comic.id, comicType)) {
    return null;
  }
  final baseline = baselines[comic.id];
  if (baseline != null && baseline.hasUpdate) {
    if (localManager.readRevision(comic.id, comicType) !=
        baseline.readRevision) {
      baselines[comic.id] = _RemoteComicBaseline(
        updateTime: baseline.updateTime,
        hasUpdate: false,
        readRevision: localManager.readRevision(comic.id, comicType),
      );
      return null;
    }
    return "UPDATED".tl;
  }
  return null;
}

Future<void> _refreshFolderDetails({
  required BuildContext context,
  required List<Comic> folderComics,
  required ComicListState? listState,
  required Map<String, _RemoteComicBaseline> baselines,
  required bool Function() isCancelled,
  required void Function() onStateChanged,
  String? paginationError,
}) async {
  if (isCancelled()) return;
  if (folderComics.isEmpty) {
    if (paginationError == null) {
      baselines.clear();
      onStateChanged();
    }
    if (context.mounted) {
      if (paginationError != null) {
        context.showMessage(message: paginationError.tl);
      } else {
        context.showMessage(message: "Folder is empty".tl);
      }
    }
    return;
  }

  final localManager = LocalFavoritesManager();

  final uniqueComics = <(String, String), Comic>{};
  for (final comic in folderComics) {
    uniqueComics[(comic.sourceKey, comic.id)] = comic;
  }

  final startRevisions = <(String, String), int>{};
  for (final comic in uniqueComics.values) {
    final comicType = ComicType.fromKey(comic.sourceKey);
    startRevisions[(comic.sourceKey, comic.id)] = localManager.readRevision(
      comic.id,
      comicType,
    );
  }

  int updatedCount = 0;
  int errorCount = 0;
  int unsupportedCount = 0;
  int unknownTimestampCount = 0;
  int firstBaselineCount = 0;
  String? firstError;

  final results = <(Comic, ComicRefreshResult)>[];
  await runThrottledTasks(
    uniqueComics.values.toList(),
    concurrency: 5,
    throttleEvery: 5,
    run: (comic) async {
      if (isCancelled()) return;
      final res = await refreshComic(comic);
      results.add((comic, res));
    },
  );

  if (isCancelled()) return;

  for (final (comic, res) in results) {
    final comicType = ComicType.fromKey(comic.sourceKey);
    final isLocal = localManager.isExist(comic.id, comicType);
    final startRev = startRevisions[(comic.sourceKey, comic.id)] ?? 0;
    final currentRev = localManager.readRevision(comic.id, comicType);
    final readDuringRequest = currentRev != startRev;

    if (res.item != null && listState != null && !isCancelled()) {
      listState.updateComicMetadata(
        comic.id,
        sourceKey: comic.sourceKey,
        title: res.item!.name,
        cover: res.item!.coverPath,
        subtitle: res.item!.author,
        tags: res.item!.tags,
      );
    }

    if (res.errorMessage != null) {
      if (res.errorMessage == 'Comic source does not support loading info') {
        unsupportedCount++;
      } else {
        errorCount++;
        firstError ??= res.errorMessage;
      }
      continue;
    }

    if (res.updateTime == null) {
      unknownTimestampCount++;
      continue;
    }

    if (isLocal) {
      if (res.updated && !readDuringRequest) {
        updatedCount++;
      }
    } else {
      final previous = baselines[comic.id];
      final readSincePrevious =
          previous != null && currentRev != previous.readRevision;

      bool hasUpdate = false;
      if (previous == null) {
        firstBaselineCount++;
        hasUpdate = false;
      } else {
        final timeChanged =
            previous.updateTime != null &&
            res.updateTime != previous.updateTime;
        if (timeChanged && !readDuringRequest) {
          hasUpdate = true;
          updatedCount++;
        } else if (!readSincePrevious && !readDuringRequest) {
          hasUpdate = previous.hasUpdate;
        } else {
          hasUpdate = false;
        }
      }

      baselines[comic.id] = _RemoteComicBaseline(
        updateTime: res.updateTime,
        hasUpdate: hasUpdate,
        readRevision: currentRev,
      );
    }
  }

  if (isCancelled()) return;

  if (paginationError == null) {
    final currentIds = uniqueComics.keys.map((k) => k.$2).toSet();
    baselines.removeWhere((id, _) => !currentIds.contains(id));
  }

  // Persist one owned snapshot after the metadata batch, not one per comic.
  listState?.storeState();
  onStateChanged();

  if (!context.mounted) return;

  final messages = <String>[];
  if (paginationError != null) messages.add(paginationError.tl);
  if (updatedCount > 0) {
    messages.add(
      "Updated @count comics".tlParams({'count': updatedCount.toString()}),
    );
  }
  if (errorCount > 0) {
    messages.add(
      "Failed to refresh @count comics: @error".tlParams({
        'count': errorCount.toString(),
        'error': (firstError ?? "Failed to refresh details").tl,
      }),
    );
  }
  if (unsupportedCount > 0) {
    messages.add(
      "$unsupportedCount: ${'Comic source does not support loading info'.tl}",
    );
  }
  if (unknownTimestampCount > 0) {
    messages.add(
      "$unknownTimestampCount: ${'Source does not provide update timestamps'.tl}",
    );
  }
  if (firstBaselineCount > 0) {
    messages.add(
      "Baseline established for @count comics".tlParams({
        'count': firstBaselineCount.toString(),
      }),
    );
  }
  if (messages.isEmpty) messages.add("No updates found".tl);
  context.showMessage(message: messages.join('\n'));
}

Future<bool> _deleteComic(
  String cid,
  String? fid,
  String sourceKey,
  String? favId,
) async {
  var source = ComicSource.find(sourceKey);
  if (source == null) {
    return false;
  }

  var result = false;

  await showDialog(
    context: App.rootContext,
    builder: (context) {
      bool loading = false;
      return StatefulBuilder(
        builder: (context, setState) {
          return ContentDialog(
            title: "Remove".tl,
            content: Text(
              "Remove comic from favorite?".tl,
            ).paddingHorizontal(16),
            actions: [
              Button.filled(
                isLoading: loading,
                color: context.colorScheme.error,
                onPressed: () async {
                  setState(() {
                    loading = true;
                  });
                  var res = await source.favoriteData!.addOrDelFavorite!(
                    cid,
                    fid ?? '',
                    false,
                    favId,
                  );
                  if (res.success) {
                    NetworkCacheManager().clear();
                    context.showMessage(message: "Deleted".tl);
                    result = true;
                    context.pop();
                  } else {
                    setState(() {
                      loading = false;
                    });
                    context.showMessage(message: res.errorMessage!);
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

  return result;
}

class NetworkFavoritePage extends StatelessWidget {
  const NetworkFavoritePage(this.data, {super.key, required this.showFolders});

  final FavoriteData data;
  final VoidCallback showFolders;

  @override
  Widget build(BuildContext context) {
    return data.multiFolder
        ? _MultiFolderFavoritesPage(data, showFolders: showFolders)
        : _NormalFavoritePage(data, showFolders: showFolders);
  }
}

class _NormalFavoritePage extends StatefulWidget {
  const _NormalFavoritePage(this.data, {required this.showFolders});

  final FavoriteData data;
  final VoidCallback showFolders;

  @override
  State<_NormalFavoritePage> createState() => _NormalFavoritePageState();
}

class _NormalFavoritePageState extends State<_NormalFavoritePage> {
  final comicListKey = GlobalKey<ComicListState>();
  int _refreshGeneration = 0;
  Future<void>? _activeRefreshOperation;

  final Map<String, _RemoteComicBaseline> _baselines = {};

  @override
  void initState() {
    super.initState();
    LocalFavoritesManager().addListener(_onLocalFavoritesChanged);
  }

  @override
  void didUpdateWidget(covariant _NormalFavoritePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _refreshGeneration++;
      _activeRefreshOperation = null;
      _baselines.clear();
      comicListKey.currentState?.refresh();
    }
  }

  @override
  void dispose() {
    _refreshGeneration++;
    LocalFavoritesManager().removeListener(_onLocalFavoritesChanged);
    super.dispose();
  }

  void _onLocalFavoritesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshScope() {
    if (_activeRefreshOperation != null) {
      return _activeRefreshOperation!;
    }
    final gen = ++_refreshGeneration;
    final operation = _doRefreshScope(gen);
    _activeRefreshOperation = operation;
    return operation.whenComplete(() {
      if (_refreshGeneration == gen) {
        _activeRefreshOperation = null;
      }
    });
  }

  Future<void> _doRefreshScope(int generation) async {
    NetworkCacheManager().clear();

    final listState = comicListKey.currentState;
    if (listState == null) return;

    try {
      final folderComics = await listState.reloadAll();
      if (!mounted || _refreshGeneration != generation) return;
      await _refreshFolderDetails(
        context: context,
        folderComics: folderComics,
        listState: listState,
        baselines: _baselines,
        isCancelled: () => !mounted || _refreshGeneration != generation,
        onStateChanged: () {
          if (mounted && _refreshGeneration == generation) {
            setState(() {});
          }
        },
        paginationError: listState.error,
      );
    } catch (error) {
      if (mounted && _refreshGeneration == generation) {
        context.showMessage(
          message:
              (error is StateError
                      ? error.message.toString()
                      : error.toString())
                  .tl,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppRefreshIndicator(
      onRefresh: _refreshScope,
      child: ComicList(
        key: comicListKey,
        badgeBuilder: (comic) => _buildComicBadge(_baselines, comic),
        leadingSliver: SliverAppbar(
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
                : null,
          ),
          title: GestureDetector(
            onTap: context.width < favoritesTwoPanelChangeWidth
                ? widget.showFolders
                : null,
            child: Text(widget.data.title),
          ),
          actions: [
            const FavoriteDisplayButton(),
            Tooltip(
              message: "Refresh".tl,
              child: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshScope,
              ),
            ),
            MenuButton(
              entries: [
                MenuEntry(
                  icon: Icons.sync,
                  text: "Convert to local".tl,
                  onClick: () {
                    importNetworkFolder(widget.data.key, 9999999, null, null);
                  },
                ),
              ],
            ),
          ],
        ),
        errorLeading: Appbar(
          leading: Tooltip(
            message: "Folders".tl,
            child: context.width <= favoritesTwoPanelChangeWidth
                ? IconButton(
                    icon: const Icon(Icons.menu),
                    color: context.colorScheme.primary,
                    onPressed: widget.showFolders,
                  )
                : null,
          ),
          title: GestureDetector(
            onTap: context.width < favoritesTwoPanelChangeWidth
                ? widget.showFolders
                : null,
            child: Text(widget.data.title),
          ),
        ),
        loadPage: widget.data.loadComic == null
            ? null
            : (i) => widget.data.loadComic!(i),
        loadNext: widget.data.loadNext == null
            ? null
            : (next) => widget.data.loadNext!(next),
        menuBuilder: (comic) {
          return [
            MenuEntry(
              icon: Icons.delete_outline,
              text: "Remove".tl,
              onClick: () async {
                var res = await _deleteComic(
                  comic.id,
                  null,
                  comic.sourceKey,
                  comic.favoriteId,
                );
                if (res) {
                  comicListKey.currentState!.remove(comic);
                }
              },
            ),
          ];
        },
        enablePageStorage: true,
        useFavoriteDisplaySettings: true,
      ),
    );
  }
}

class _MultiFolderFavoritesPage extends StatefulWidget {
  const _MultiFolderFavoritesPage(this.data, {required this.showFolders});

  final FavoriteData data;
  final VoidCallback showFolders;

  @override
  State<_MultiFolderFavoritesPage> createState() =>
      _MultiFolderFavoritesPageState();
}

class _MultiFolderFavoritesPageState extends State<_MultiFolderFavoritesPage> {
  bool _loading = true;
  String? _errorMessage;
  Map<String, String>? folders;
  int _catalogGeneration = 0;
  Future<void>? _activeFolderLoad;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  @override
  void didUpdateWidget(covariant _MultiFolderFavoritesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _catalogGeneration++;
      _activeFolderLoad = null;
      folders = null;
      _loadFolders();
    }
  }

  Future<void> _loadFolders({bool invalidateCache = false}) {
    final active = _activeFolderLoad;
    if (active != null) return active;
    final generation = ++_catalogGeneration;
    late Future<void> future;
    future = _doLoadFolders(generation, invalidateCache).whenComplete(() {
      if (identical(_activeFolderLoad, future)) _activeFolderLoad = null;
    });
    _activeFolderLoad = future;
    return future;
  }

  Future<void> _doLoadFolders(int generation, bool invalidateCache) async {
    if (!mounted) return;
    if (invalidateCache) NetworkCacheManager().clear();
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final loader = widget.data.loadFolders;
      if (loader == null) {
        throw StateError("Comic source does not support folders".tl);
      }
      final result = await loader();
      if (!mounted || generation != _catalogGeneration) return;
      if (result.error) {
        _errorMessage = (result.errorMessage ?? "Failed to load folders").tl;
      } else {
        folders = result.data;
      }
    } catch (error) {
      if (mounted && generation == _catalogGeneration) {
        _errorMessage =
            (error is StateError ? error.message.toString() : error.toString())
                .tl;
      }
    } finally {
      if (mounted && generation == _catalogGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void openFolder(String key, String title) {
    context.to(() => _FavoriteFolder(widget.data, key, title));
  }

  @override
  Widget build(BuildContext context) {
    var sliverAppBar = SliverAppbar(
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
            : null,
      ),
      title: GestureDetector(
        onTap: context.width < favoritesTwoPanelChangeWidth
            ? widget.showFolders
            : null,
        child: Text(widget.data.title),
      ),
      actions: [
        Tooltip(
          message: "Refresh".tl,
          child: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadFolders(invalidateCache: true),
          ),
        ),
      ],
    );

    var appBar = Appbar(
      leading: Tooltip(
        message: "Folders".tl,
        child: context.width <= favoritesTwoPanelChangeWidth
            ? IconButton(
                icon: const Icon(Icons.menu),
                color: context.colorScheme.primary,
                onPressed: widget.showFolders,
              )
            : null,
      ),
      title: GestureDetector(
        onTap: context.width < favoritesTwoPanelChangeWidth
            ? widget.showFolders
            : null,
        child: Text(widget.data.title),
      ),
      actions: [
        Tooltip(
          message: "Refresh".tl,
          child: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadFolders(invalidateCache: true),
          ),
        ),
      ],
    );

    if (_loading && folders == null) {
      return Column(
        children: [
          appBar,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    } else if (_errorMessage != null && folders == null) {
      return AppRefreshIndicator(
        onRefresh: () => _loadFolders(invalidateCache: true),
        child: SmoothCustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            sliverAppBar,
            SliverFillRemaining(
              hasScrollBody: false,
              child: NetworkError(
                message: _errorMessage!,
                withAppbar: false,
                retry: () => _loadFolders(invalidateCache: true),
              ),
            ),
          ],
        ),
      );
    } else {
      var length = folders!.length;
      if (widget.data.allFavoritesId != null) length++;
      final keys = folders!.keys.toList();

      return AppRefreshIndicator(
        onRefresh: () => _loadFolders(invalidateCache: true),
        child: SmoothCustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            sliverAppBar,
            if (_errorMessage != null)
              SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(child: Text(_errorMessage!)),
                    IconButton(
                      tooltip: "Retry".tl,
                      onPressed: () => _loadFolders(invalidateCache: true),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
            if (folders!.isEmpty && widget.data.allFavoritesId == null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text("Empty".tl)),
              )
            else
              SliverGridViewWithFixedItemHeight(
                delegate: SliverChildBuilderDelegate(childCount: length, (
                  context,
                  i,
                ) {
                  if (widget.data.allFavoritesId != null) {
                    if (i == 0) {
                      return _FolderTile(
                        name: "All".tl,
                        onTap: () =>
                            openFolder(widget.data.allFavoritesId!, "All".tl),
                      );
                    } else {
                      i--;
                      return _FolderTile(
                        name: folders![keys[i]]!,
                        onTap: () => openFolder(keys[i], folders![keys[i]]!),
                        deleteFolder: widget.data.deleteFolder == null
                            ? null
                            : () => widget.data.deleteFolder!(keys[i]),
                        updateState: () => _loadFolders(invalidateCache: true),
                      );
                    }
                  } else {
                    return _FolderTile(
                      name: folders![keys[i]]!,
                      onTap: () => openFolder(keys[i], folders![keys[i]]!),
                      deleteFolder: widget.data.deleteFolder == null
                          ? null
                          : () => widget.data.deleteFolder!(keys[i]),
                      updateState: () => _loadFolders(invalidateCache: true),
                    );
                  }
                }),
                maxCrossAxisExtent: 450,
                itemHeight: 52,
              ),
            if (widget.data.addFolder != null)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 60,
                  width: double.infinity,
                  child: Center(
                    child: TextButton(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text("Create a folder".tl),
                          const Icon(Icons.add, size: 18),
                        ],
                      ),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) {
                            return _CreateFolderDialog(
                              widget.data,
                              () => _loadFolders(invalidateCache: true),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.name,
    required this.onTap,
    this.deleteFolder,
    this.updateState,
  });

  final String name;

  final Future<Res<bool>> Function()? deleteFolder;

  final void Function()? updateState;

  final void Function() onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      child: ClickInkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Icon(
                Icons.folder,
                size: 28,
                color: Theme.of(context).colorScheme.secondary,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (deleteFolder != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onDeleteFolder(context),
                )
              else
                const Icon(Icons.arrow_right),
            ],
          ),
        ),
      ),
    );
  }

  void onDeleteFolder(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        bool loading = false;
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Delete".tl,
              content: Text("Delete folder?".tl).paddingHorizontal(16),
              actions: [
                Button.filled(
                  isLoading: loading,
                  color: context.colorScheme.error,
                  onPressed: () async {
                    setState(() {
                      loading = true;
                    });
                    var res = await deleteFolder!();
                    if (res.success) {
                      NetworkCacheManager().clear();
                      context.showMessage(message: "Deleted".tl);
                      context.pop();
                      updateState?.call();
                    } else {
                      setState(() {
                        loading = false;
                      });
                      context.showMessage(message: res.errorMessage!);
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
  }
}

class _CreateFolderDialog extends StatefulWidget {
  const _CreateFolderDialog(this.data, this.updateState);

  final FavoriteData data;

  final void Function() updateState;

  @override
  State<_CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<_CreateFolderDialog> {
  var controller = TextEditingController();
  bool loading = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Create a folder".tl,
      content: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: "name".tl,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
      actions: [
        Button.filled(
          isLoading: loading,
          onPressed: () {
            setState(() {
              loading = true;
            });
            widget.data.addFolder!(controller.text).then((b) {
              if (b.error) {
                context.showMessage(message: b.errorMessage!);
                setState(() {
                  loading = false;
                });
              } else {
                NetworkCacheManager().clear();
                context.pop();
                context.showMessage(message: "Created successfully".tl);
                widget.updateState();
              }
            });
          },
          child: Text("Submit".tl),
        ),
      ],
    );
  }
}

class _FavoriteFolder extends StatefulWidget {
  const _FavoriteFolder(this.data, this.folderID, this.title);

  final FavoriteData data;
  final String folderID;
  final String title;

  @override
  State<_FavoriteFolder> createState() => _FavoriteFolderState();
}

class _FavoriteFolderState extends State<_FavoriteFolder> {
  final comicListKey = GlobalKey<ComicListState>();
  int _refreshGeneration = 0;
  Future<void>? _activeRefreshOperation;

  final Map<String, _RemoteComicBaseline> _baselines = {};

  @override
  void initState() {
    super.initState();
    LocalFavoritesManager().addListener(_onLocalFavoritesChanged);
  }

  @override
  void didUpdateWidget(covariant _FavoriteFolder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data) ||
        oldWidget.folderID != widget.folderID) {
      _refreshGeneration++;
      _activeRefreshOperation = null;
      _baselines.clear();
      comicListKey.currentState?.refresh();
    }
  }

  @override
  void dispose() {
    _refreshGeneration++;
    LocalFavoritesManager().removeListener(_onLocalFavoritesChanged);
    super.dispose();
  }

  void _onLocalFavoritesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshScope() {
    if (_activeRefreshOperation != null) {
      return _activeRefreshOperation!;
    }
    final gen = ++_refreshGeneration;
    final operation = _doRefreshScope(gen);
    _activeRefreshOperation = operation;
    return operation.whenComplete(() {
      if (_refreshGeneration == gen) {
        _activeRefreshOperation = null;
      }
    });
  }

  Future<void> _doRefreshScope(int generation) async {
    NetworkCacheManager().clear();

    final listState = comicListKey.currentState;
    if (listState == null) return;

    try {
      final folderComics = await listState.reloadAll();
      if (!mounted || _refreshGeneration != generation) return;
      await _refreshFolderDetails(
        context: context,
        folderComics: folderComics,
        listState: listState,
        baselines: _baselines,
        isCancelled: () => !mounted || _refreshGeneration != generation,
        onStateChanged: () {
          if (mounted && _refreshGeneration == generation) {
            setState(() {});
          }
        },
        paginationError: listState.error,
      );
    } catch (error) {
      if (mounted && _refreshGeneration == generation) {
        context.showMessage(
          message:
              (error is StateError
                      ? error.message.toString()
                      : error.toString())
                  .tl,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppRefreshIndicator(
      onRefresh: _refreshScope,
      child: ComicList(
        key: comicListKey,
        badgeBuilder: (comic) => _buildComicBadge(_baselines, comic),
        enablePageStorage: true,
        leadingSliver: SliverAppbar(
          title: Text(widget.title),
          actions: [
            const FavoriteDisplayButton(),
            Tooltip(
              message: "Refresh".tl,
              child: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshScope,
              ),
            ),
            MenuButton(
              entries: [
                MenuEntry(
                  icon: Icons.sync,
                  text: "Convert to local".tl,
                  onClick: () {
                    importNetworkFolder(
                      widget.data.key,
                      9999999,
                      widget.title,
                      widget.folderID,
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        errorLeading: Appbar(title: Text(widget.title)),
        loadPage: widget.data.loadComic == null
            ? null
            : (i) => widget.data.loadComic!(i, widget.folderID),
        loadNext: widget.data.loadNext == null
            ? null
            : (next) => widget.data.loadNext!(next, widget.folderID),
        menuBuilder: (comic) {
          return [
            MenuEntry(
              icon: Icons.delete_outline,
              text: "Remove".tl,
              onClick: () async {
                var res = await _deleteComic(
                  comic.id,
                  widget.folderID,
                  comic.sourceKey,
                  comic.favoriteId,
                );
                if (res) {
                  comicListKey.currentState!.remove(comic);
                }
              },
            ),
          ];
        },
        useFavoriteDisplaySettings: true,
      ),
    );
  }
}
