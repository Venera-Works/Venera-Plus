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
import 'comic_update_state.dart';
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

Widget _refreshButton({
  required bool loading,
  required VoidCallback onPressed,
}) {
  return IconButton(
    tooltip: (loading ? 'Loading' : 'Refresh').tl,
    icon: loading
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.refresh),
    onPressed: loading ? null : onPressed,
  );
}

Future<void> _refreshFolderDetails({
  required BuildContext context,
  required List<Comic> folderComics,
  required ComicListState? listState,
  required bool Function() isCancelled,
  required void Function() onStateChanged,
  String? paginationError,
}) async {
  if (isCancelled()) return;
  if (folderComics.isEmpty) {
    if (paginationError == null) {
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

  final uniqueComics = <(String, String), Comic>{};
  for (final comic in folderComics) {
    uniqueComics[(comic.sourceKey, comic.id)] = comic;
  }

  int updatedCount = 0;
  int errorCount = 0;
  int unchangedCount = 0;
  int baselineCount = 0;
  int unknownCount = 0;
  int newChaptersCount = 0;
  String? firstError;

  final results = <(Comic, ComicRefreshResult)>[];
  await runThrottledTasks(
    uniqueComics.values.toList(),
    concurrency: 5,
    throttleEvery: 5,
    run: (comic) async {
      if (isCancelled()) return;
      final res = await refreshComic(
        comic.id,
        ComicType.fromKey(comic.sourceKey),
        fallbackAuthor: comic.subtitle,
      );
      results.add((comic, res));
    },
  );

  if (isCancelled()) return;

  for (final (comic, res) in results) {
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
      errorCount++;
      firstError ??= res.errorMessage;
    } else {
      switch (res.status) {
        case ComicUpdateCheckStatus.updated:
          updatedCount++;
          newChaptersCount += res.newChapterCount;
          break;
        case ComicUpdateCheckStatus.unchanged:
          unchangedCount++;
          break;
        case ComicUpdateCheckStatus.baseline:
          baselineCount++;
          break;
        case ComicUpdateCheckStatus.unknown:
          unknownCount++;
          break;
      }
    }
  }
  if (isCancelled()) return;

  // Persist one owned snapshot after the metadata batch, not one per comic.
  listState?.storeState();
  onStateChanged();

  if (!context.mounted) return;

  final summary = buildRefreshSummary(
    total: uniqueComics.length,
    updated: updatedCount,
    unchanged: unchangedCount,
    baseline: baselineCount,
    unknown: unknownCount,
    errors: errorCount,
    newChapters: newChaptersCount,
    firstError: firstError,
    prefixMessage: paginationError?.tl,
  );
  context.showMessage(message: summary);
}

Future<bool> _deleteComic(
  String cid,
  String? fid,
  String sourceKey,
  String? favId,
) async {
  final remove = ComicSource.find(sourceKey)?.favoriteData?.addOrDelFavorite;
  if (remove == null) return false;
  return _showNetworkFavoriteMutation(
    context: App.rootContext,
    title: 'Remove'.tl,
    content: Text('Remove comic from favorite?'.tl).paddingHorizontal(16),
    submit: () => remove(cid, fid ?? '', false, favId),
    successMessage: 'Deleted'.tl,
    destructive: true,
  );
}

Future<bool> _showNetworkFavoriteMutation({
  required BuildContext context,
  required String title,
  required Widget content,
  required Future<Res<bool>> Function() submit,
  required String successMessage,
  String confirmText = 'Confirm',
  bool destructive = false,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  late final NetworkFavoriteDialogRoute<bool> route;
  route = NetworkFavoriteDialogRoute<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        void cancel() {
          if (route.isCurrent && !route.blockPop) context.pop();
        }

        return ContentDialog(
          title: title,
          dismissible: !route.blockPop,
          onClose: cancel,
          content: content,
          actions: [
            TextButton(
              onPressed: route.blockPop ? null : cancel,
              child: Text('Cancel'.tl),
            ),
            Button.filled(
              isLoading: route.blockPop,
              color: destructive ? context.colorScheme.error : null,
              onPressed: () async {
                if (route.blockPop || !route.isCurrent) return;
                setState(() => route.blockPop = true);
                String? errorMessage;
                try {
                  final result = await submit();
                  if (result.error || result.dataOrNull != true) {
                    errorMessage = result.errorMessage ?? 'Failed'.tl;
                  }
                } catch (error) {
                  errorMessage = error.toString();
                }
                if (!context.mounted || !route.isActive) return;
                if (errorMessage != null) {
                  setState(() => route.blockPop = false);
                  context.showMessage(message: errorMessage);
                  return;
                }
                route.blockPop = false;
                NetworkCacheManager().clear();
                context.showMessage(message: successMessage);
                if (route.isCurrent) {
                  context.pop(true);
                } else {
                  navigator.removeRoute(route, true);
                }
              },
              child: Text(confirmText.tl),
            ),
          ],
        );
      },
    ),
  );
  return await navigator.push(route) ?? false;
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
    final operation = _doRefreshScope(gen).whenComplete(() {
      if (mounted && _refreshGeneration == gen) {
        setState(() => _activeRefreshOperation = null);
      }
    });
    setState(() => _activeRefreshOperation = operation);
    return operation;
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
    final data = widget.data;
    final narrow = context.width <= favoritesTwoPanelChangeWidth;
    final leading = narrow
        ? IconButton(
            tooltip: 'Folders'.tl,
            icon: const Icon(Icons.menu),
            color: context.colorScheme.primary,
            onPressed: widget.showFolders,
          )
        : const SizedBox.shrink();
    final title = GestureDetector(
      onTap: narrow ? widget.showFolders : null,
      child: Text(widget.data.title),
    );
    final refreshButton = _refreshButton(
      loading: _activeRefreshOperation != null,
      onPressed: _refreshScope,
    );
    return AppRefreshIndicator(
      onRefresh: _refreshScope,
      child: ComicList(
        key: comicListKey,
        hideFavoriteBadge: true,
        leadingSliver: SliverAppbar(
          style: context.width < changePoint
              ? AppbarStyle.shadow
              : AppbarStyle.blur,
          leading: leading,
          title: title,
          actions: [
            const FavoriteDisplayButton(),
            refreshButton,
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
          leading: leading,
          title: title,
          actions: [refreshButton],
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
                final removed = await _deleteComic(
                  comic.id,
                  null,
                  comic.sourceKey,
                  comic.favoriteId,
                );
                if (removed &&
                    mounted &&
                    identical(widget.data, data) &&
                    identical(getEnabledNetworkFavoriteData(data.key), data)) {
                  final listState = comicListKey.currentState;
                  if (listState == null) return;
                  listState.remove(comic);
                  listState.storeState();
                  if (_activeRefreshOperation != null) {
                    await listState.reload(queueIfLoading: true);
                  }
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

  void _reloadAfterMutation(FavoriteData data) {
    if (!mounted ||
        !identical(widget.data, data) ||
        !identical(getEnabledNetworkFavoriteData(data.key), data)) {
      return;
    }
    // 变更前发出的目录请求不能覆盖新结果。
    _activeFolderLoad = null;
    _loadFolders();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final narrow = context.width <= favoritesTwoPanelChangeWidth;
    final leading = narrow
        ? IconButton(
            tooltip: 'Folders'.tl,
            icon: const Icon(Icons.menu),
            color: context.colorScheme.primary,
            onPressed: widget.showFolders,
          )
        : const SizedBox.shrink();
    final title = GestureDetector(
      onTap: narrow ? widget.showFolders : null,
      child: Text(widget.data.title),
    );
    final actions = [
      _refreshButton(
        loading: _loading,
        onPressed: () => _loadFolders(invalidateCache: true),
      ),
    ];
    var sliverAppBar = SliverAppbar(
      style: context.width < changePoint
          ? AppbarStyle.shadow
          : AppbarStyle.blur,
      leading: leading,
      title: title,
      actions: actions,
    );

    var appBar = Appbar(leading: leading, title: title, actions: actions);

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
      final allId = data.allFavoritesId;
      final entries = folders!.entries.toList();
      final deleteFolder = data.deleteFolder;
      final addFolder = data.addFolder;

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
            if (entries.isEmpty && allId == null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text("Empty".tl)),
              )
            else
              SliverGridViewWithFixedItemHeight(
                delegate: SliverChildBuilderDelegate((context, index) {
                  if (allId != null && index == 0) {
                    return _FolderTile(
                      name: 'All'.tl,
                      onTap: () => openFolder(allId, 'All'.tl),
                    );
                  }
                  final MapEntry(key: id, value: name) =
                      entries[allId == null ? index : index - 1];
                  return _FolderTile(
                    name: name,
                    onTap: () => openFolder(id, name),
                    onDelete: deleteFolder == null
                        ? null
                        : () async {
                            final deleted = await _showNetworkFavoriteMutation(
                              context: context,
                              title: 'Delete'.tl,
                              content: Text(
                                'Delete folder?'.tl,
                              ).paddingHorizontal(16),
                              submit: () => deleteFolder(id),
                              successMessage: 'Deleted'.tl,
                              destructive: true,
                            );
                            if (deleted) _reloadAfterMutation(data);
                          },
                  );
                }, childCount: entries.length + (allId == null ? 0 : 1)),
                maxCrossAxisExtent: 450,
                itemHeight: 52,
              ),
            if (addFolder != null)
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
                      onPressed: () async {
                        var name = '';
                        final created = await _showNetworkFavoriteMutation(
                          context: context,
                          title: 'Create a folder'.tl,
                          content: TextField(
                            decoration: InputDecoration(
                              border: const OutlineInputBorder(),
                              labelText: 'name'.tl,
                            ),
                            onChanged: (value) => name = value,
                          ).paddingHorizontal(16),
                          submit: () => addFolder(name),
                          successMessage: 'Created successfully'.tl,
                          confirmText: 'Submit',
                        );
                        if (created) _reloadAfterMutation(data);
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
  const _FolderTile({required this.name, required this.onTap, this.onDelete});

  final String name;
  final VoidCallback? onDelete;
  final VoidCallback onTap;

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
              if (onDelete != null)
                IconButton(
                  tooltip: 'Delete Folder'.tl,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                )
              else
                const Icon(Icons.arrow_right),
            ],
          ),
        ),
      ),
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
    final operation = _doRefreshScope(gen).whenComplete(() {
      if (mounted && _refreshGeneration == gen) {
        setState(() => _activeRefreshOperation = null);
      }
    });
    setState(() => _activeRefreshOperation = operation);
    return operation;
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
    final data = widget.data;
    final folderId = widget.folderID;
    final refreshButton = _refreshButton(
      loading: _activeRefreshOperation != null,
      onPressed: _refreshScope,
    );
    return AppRefreshIndicator(
      onRefresh: _refreshScope,
      child: ComicList(
        key: comicListKey,
        hideFavoriteBadge: true,
        enablePageStorage: true,
        leadingSliver: SliverAppbar(
          title: Text(widget.title),
          actions: [
            const FavoriteDisplayButton(),
            refreshButton,
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
        errorLeading: Appbar(
          title: Text(widget.title),
          actions: [refreshButton],
        ),
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
                final removed = await _deleteComic(
                  comic.id,
                  folderId,
                  comic.sourceKey,
                  comic.favoriteId,
                );
                if (removed &&
                    mounted &&
                    identical(widget.data, data) &&
                    widget.folderID == folderId &&
                    identical(getEnabledNetworkFavoriteData(data.key), data)) {
                  final listState = comicListKey.currentState;
                  if (listState == null) return;
                  listState.remove(comic);
                  listState.storeState();
                  if (_activeRefreshOperation != null) {
                    await listState.reload(queueIfLoading: true);
                  }
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
