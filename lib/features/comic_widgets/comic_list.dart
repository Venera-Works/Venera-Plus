import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'comic_tile.dart';
import 'keyword_comic_filter.dart';
import 'keyword_hidden_notice.dart';

class SliverGridComics extends StatefulWidget {
  const SliverGridComics({
    super.key,
    required this.comics,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onLongPressed,
    this.selections,
    this.useFavoriteDisplaySettings = false,
    this.hideFavoriteBadge = false,
    this.showHiddenCount = false,
  });

  final List<Comic> comics;

  final Map<Comic, bool>? selections;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

  final bool useFavoriteDisplaySettings;

  final bool hideFavoriteBadge;
  final bool showHiddenCount;

  @override
  State<SliverGridComics> createState() => _SliverGridComicsState();
}

class _SliverGridComicsState extends State<SliverGridComics> {
  List<Comic> comics = [];
  List<int> heroIDs = [];
  List<Object> _identities = [];
  List<Comic> _sourceComics = [];
  List<KeywordRule> _blockedRules = [];
  ModalRoute<dynamic>? _route;
  bool _tickerModeEnabled = true;
  bool _needsContentCheck = true;
  bool _presentationDirty = true;
  Widget? _presentation;

  bool get _isVisible => _tickerModeEnabled && (_route?.isCurrent ?? true);

  static int _nextHeroID = 0;

  void generateHeroID() {
    heroIDs.clear();
    for (var i = 0; i < comics.length; i++) {
      heroIDs.add(_nextHeroID++);
    }
  }

  @override
  void initState() {
    super.initState();
    addComicWidgetStateListener(_onPresentationChanged);
    appdata.settings.addListener(_onSettingsChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    // Block actions can mutate the words in place without a settings event.
    _needsContentCheck = true;
    _refreshIfVisible();
  }

  @override
  void didUpdateWidget(covariant SliverGridComics oldWidget) {
    super.didUpdateWidget(oldWidget);
    _needsContentCheck = true;
    _presentationDirty = true;
    _refreshIfVisible();
  }

  @override
  void dispose() {
    removeComicWidgetStateListener(_onPresentationChanged);
    appdata.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    _needsContentCheck = true;
    _onPresentationChanged();
  }

  void _onPresentationChanged() {
    _presentationDirty = true;
    if (_isVisible) setState(_refreshIfVisible);
  }

  void _refreshIfVisible() {
    if (!_isVisible || (!_needsContentCheck && !_presentationDirty)) return;
    if (_needsContentCheck) {
      final filter = comicKeywordFilter();
      // Comic equality only compares source/id; new objects may carry new data.
      final sourceChanged =
          _sourceComics.length != widget.comics.length ||
          _sourceComics.indexed.any(
            (entry) => !identical(entry.$2, widget.comics[entry.$1]),
          );
      if (sourceChanged || !listEquals(_blockedRules, filter.rules)) {
        final filtered = widget.comics
            .where((comic) => matchComicKeyword(comic, filter: filter) == null)
            .toList();
        // Hero IDs follow identity and order, independently of metadata.
        final identities = filtered
            .map(comicWidgetIdentity)
            .toList(growable: false);
        comics = filtered;
        if (!listEquals(_identities, identities)) {
          _identities = identities;
          generateHeroID();
        }
        _sourceComics = List<Comic>.of(widget.comics);
        _blockedRules = filter.rules;
      }
      _needsContentCheck = false;
    }
    _presentationDirty = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVisible && _presentation != null) return _presentation!;
    final favoriteDisplayState = comicFavoriteDisplayState();
    final favoriteDisplayMode = widget.useFavoriteDisplaySettings
        ? (favoriteDisplayState.isGallery
              ? ComicTileDisplayMode.gallery
              : ComicTileDisplayMode.detailed)
        : null;
    final grid = _SliverGridComics(
      comics: comics,
      heroIDs: heroIDs,
      selection: widget.selections,
      onLastItemBuild: widget.onLastItemBuild,
      badgeBuilder: widget.badgeBuilder,
      menuBuilder: widget.menuBuilder,
      onTap: widget.onTap,
      onLongPressed: widget.onLongPressed,
      onBlocked: _onSettingsChanged,
      hideFavoriteBadge: widget.hideFavoriteBadge,
      favoriteDisplayMode: favoriteDisplayMode,
      galleryColumns: favoriteDisplayMode == ComicTileDisplayMode.gallery
          ? favoriteDisplayState.galleryColumns
          : null,
    );
    final hidden = _sourceComics.length - comics.length;
    return _presentation = !widget.showHiddenCount || hidden == 0
        ? grid
        : SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: KeywordHiddenNotice(
                    count: hidden,
                    comics: () => widget.comics,
                  ),
                ),
              ),
              grid,
            ],
          );
  }
}

class _SliverGridComics extends StatelessWidget {
  const _SliverGridComics({
    required this.comics,
    required this.heroIDs,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onLongPressed,
    this.onBlocked,
    this.selection,
    this.favoriteDisplayMode,
    this.galleryColumns,
    required this.hideFavoriteBadge,
  });

  final List<Comic> comics;

  final List<int> heroIDs;

  final Map<Comic, bool>? selection;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

  final VoidCallback? onBlocked;

  final ComicTileDisplayMode? favoriteDisplayMode;

  final int? galleryColumns;

  final bool hideFavoriteBadge;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index == comics.length - 1) {
          onLastItemBuild?.call();
        }
        var badge = badgeBuilder?.call(comics[index]);
        var isSelected = selection == null
            ? false
            : selection![comics[index]] ?? false;
        var comic = ComicTile(
          comic: comics[index],
          badge: badge,
          menuOptions: menuBuilder?.call(comics[index]),
          onTap: onTap != null
              ? () => onTap!(comics[index], heroIDs[index])
              : null,
          onLongPressed: onLongPressed != null
              ? () => onLongPressed!(comics[index], heroIDs[index])
              : null,
          onBlocked: onBlocked,
          heroID: heroIDs[index],
          displayMode: favoriteDisplayMode,
          hideFavoriteBadge: hideFavoriteBadge,
        );
        if (selection == null) {
          return comic;
        }
        return AnimatedContainer(
          key: ValueKey(comicWidgetIdentity(comics[index])),
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(
                    context,
                  ).colorScheme.secondaryContainer.toOpacity(0.72)
                : null,
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(4),
          child: comic,
        );
      }, childCount: comics.length),
      gridDelegate: SliverGridDelegateWithComics(
        galleryColumns: galleryColumns,
        forceDetailed: favoriteDisplayMode == ComicTileDisplayMode.detailed,
      ),
    );
  }
}

class ComicList extends StatefulWidget {
  const ComicList({
    super.key,
    this.loadPage,
    this.loadNext,
    this.leadingSliver,
    this.trailingSliver,
    this.errorLeading,
    this.menuBuilder,
    this.controller,
    this.refreshHandlerCallback,
    this.reloadHandlerCallback,
    this.enablePageStorage = false,
    this.useFavoriteDisplaySettings = false,
    this.hideFavoriteBadge = false,
    this.badgeBuilder,
    this.onTap,
    this.initialPage = 1,
    this.onVisiblePageChanged,
  });

  final Future<Res<List<Comic>>> Function(int page)? loadPage;

  final Future<Res<List<Comic>>> Function(String? next)? loadNext;

  final Widget? leadingSliver;

  final Widget? trailingSliver;

  final Widget? errorLeading;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final ScrollController? controller;

  final void Function(VoidCallback c)? refreshHandlerCallback;

  final void Function(VoidCallback c)? reloadHandlerCallback;

  final bool enablePageStorage;

  final bool useFavoriteDisplaySettings;

  final bool hideFavoriteBadge;
  final String? Function(Comic)? badgeBuilder;
  final void Function(Comic, int heroID)? onTap;

  final int initialPage;
  final ValueChanged<int>? onVisiblePageChanged;

  @override
  State<ComicList> createState() => ComicListState();
}

class ComicListState extends State<ComicList> {
  int? _maxPage;

  final Map<int, List<Comic>> _data = {};

  int _page = 1;

  String? _error;

  final Map<int, bool> _loading = {};

  bool _isReloading = false;

  String? _nextUrl;

  late bool enablePageStorage = widget.enablePageStorage;

  final ScrollController _pageController = ScrollController();
  final Map<int, GlobalKey> _pageHeaders = {};
  final Map<int, double> _pageStarts = {};
  int _firstPage = 1;
  int? _reportedVisiblePage;
  int? _paintedPage;
  int? _pendingRevealPage;
  bool _visibilityScheduled = false;
  bool _restoringCursor = false;
  bool _restorePaused = false;
  bool _loadsCancelled = false;

  bool get _tracksPages =>
      widget.onVisiblePageChanged != null || widget.initialPage > 1;
  ScrollController? get _scrollController =>
      widget.controller ?? (_tracksPages ? _pageController : null);

  @override
  void initState() {
    super.initState();
    _page = widget.initialPage < 1 ? 1 : widget.initialPage;
    _firstPage = widget.loadPage != null ? _page : 1;
    _restoringCursor =
        widget.loadPage == null && widget.loadNext != null && _page > 1;
    if (_restoringCursor) _pendingRevealPage = _page;
  }

  void _reportVisiblePage(int page) {
    if (!mounted || _reportedVisiblePage == page) return;
    _reportedVisiblePage = page;
    if (appdata.settings['comicListDisplayMode'] != 'paging') _page = page;
    widget.onVisiblePageChanged?.call(page);
  }

  void _pagePainted(int page) {
    if (!_tracksPages || _restoringCursor || _pendingRevealPage != null) return;
    if (_paintedPage == null || page < _paintedPage!) _paintedPage = page;
    if (_visibilityScheduled) return;
    _visibilityScheduled = true;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      final visible = _paintedPage;
      _paintedPage = null;
      if (_isCurrent(generation) &&
          visible != null &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        _reportVisiblePage(visible);
      }
    });
  }

  void _schedulePageReveal() {
    final target = _pendingRevealPage;
    if (target == null) return;
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrent(generation) || _pendingRevealPage != target) return;
      final render = _pageHeaders[target]?.currentContext?.findRenderObject();
      final controller = _scrollController;
      if (render != null && controller != null && controller.hasClients) {
        final viewport = RenderAbstractViewport.maybeOf(render);
        if (viewport != null) {
          controller.jumpTo(
            viewport
                .getOffsetToReveal(render, 0)
                .offset
                .clamp(
                  controller.position.minScrollExtent,
                  controller.position.maxScrollExtent,
                )
                .toDouble(),
          );
        }
      }
      _pendingRevealPage = null;
      _reportVisiblePage(target);
    });
  }

  void _cancelRestore() {
    _generation++;
    _activeCursorFetch = null;
    _activeCursorGeneration = null;
    _loading.clear();
    _pageLoadGenerations.clear();
    _restoringCursor = false;
    _pendingRevealPage = null;
    _restorePaused = true;
    _page = _data.isEmpty ? 1 : (_data.keys.toList()..sort()).last;
    storeState();
    setState(() {});
  }

  Widget _buildRestoreProgress() => SmoothCustomScrollView(
    controller: _scrollController,
    slivers: [
      if (widget.errorLeading != null) widget.errorLeading!.toSliver(),
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_restorePaused) const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _restorePaused
                    ? 'Search restoration cancelled'.tl
                    : 'Restoring search page @current / @target'.tlParams({
                        'current': _data.length,
                        'target': _page,
                      }),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _restorePaused
                    ? () => setState(() {
                        _restorePaused = false;
                        if (_data.isNotEmpty) _pendingRevealPage = _page;
                      })
                    : _cancelRestore,
                child: Text(
                  _restorePaused ? 'Continue search'.tl : 'Cancel'.tl,
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  Map<String, dynamic> get state => {
    'maxPage': _maxPage,
    'data': {
      for (final entry in _data.entries) entry.key: List<Comic>.of(entry.value),
    },
    'page': _page,
    'error': _error,
    'loading': Map<int, bool>.of(_loading),
    'nextUrl': _nextUrl,
  };

  String? get error => _error;

  int _generation = 0;
  int? _activeReloadGeneration;
  final Map<int, int> _pageLoadGenerations = {};

  final Map<(String, String), Map<String, dynamic>> _metadataOverlays = {};

  List<Comic> _applyOverlays(List<Comic> list) {
    for (var index = 0; index < list.length; index++) {
      final comic = list[index];
      final fields = _metadataOverlays[(comic.sourceKey, comic.id)];
      if (fields != null) list[index] = _withMetadata(comic, fields);
    }
    return list;
  }

  Comic _withMetadata(Comic comic, Map<String, dynamic> fields) =>
      Comic.fromJson({
        ...comic.toJson(),
        'stars': comic.stars,
        ...fields,
      }, comic.sourceKey);
  void restoreState(Map<String, dynamic>? state) {
    if (state == null || !enablePageStorage) {
      return;
    }
    _maxPage = state['maxPage'];
    final data = state['data'];
    if (!identical(data, _data)) {
      _data.clear();
      if (data is Map) {
        for (final entry in data.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is int && value is Iterable) {
            _data[key] = List<Comic>.from(value);
          }
        }
      }
    }
    _page = state['page'];
    _error = state['error'];
    _loading.clear();
    _nextUrl = state['nextUrl'];
    _seenCursors.clear();
    if (_nextUrl != null) _seenCursors.add(_nextUrl!);
  }

  void storeState() {
    if (enablePageStorage) {
      PageStorage.of(context).writeState(context, state);
    }
  }

  void refresh() {
    _loadsCancelled = false;
    _generation++;
    _activeReload = null;
    _activeReloadGeneration = null;
    _activeCursorFetch = null;
    _activeCursorGeneration = null;
    _seenCursors.clear();
    _isReloading = false;
    _loading.clear();
    _pageLoadGenerations.clear();
    _data.clear();
    _page = 1;
    _firstPage = 1;
    _restoringCursor = false;
    _restorePaused = false;
    _pendingRevealPage = null;
    _reportedVisiblePage = null;
    _pageHeaders.clear();
    _pageStarts.clear();
    _maxPage = null;
    _error = null;
    _nextUrl = null;
    _metadataOverlays.clear();
    if (mounted) {
      storeState();
      setState(() {});
    }
  }

  Future<List<Comic>>? _activeReload;
  bool _activeReloadAll = false;
  bool _activeReloadReset = false;
  Future<bool>? _activeCursorFetch;
  int? _activeCursorGeneration;
  final Set<String> _seenCursors = {};

  /// Invalidates in-flight work before a query or route is replaced.
  void cancelPendingLoads() {
    _loadsCancelled = true;
    _generation++;
    _activeCursorFetch = null;
    _activeCursorGeneration = null;
    _loading.clear();
    _pageLoadGenerations.clear();
  }

  bool _isCurrent(int generation) =>
      mounted && !_loadsCancelled && _generation == generation;

  /// Refresh only pages already loaded (or the current initial page).
  Future<void> reload({bool reset = false}) =>
      _reload(all: false, reset: reset).then<void>((_) {});

  /// Explicit full-folder refresh used by network favorites, not ordinary lists.
  Future<List<Comic>> reloadAll({bool reset = false}) =>
      _reload(all: true, reset: reset);

  Future<List<Comic>> _reload({required bool all, required bool reset}) {
    if (!mounted) return Future.value(const <Comic>[]);
    final active = _activeReload;
    if (active != null && _activeReloadGeneration == _generation) {
      if ((all && !_activeReloadAll) || (reset && !_activeReloadReset)) {
        final generation = _generation;
        return active.then<List<Comic>>(
          (_) => _isCurrent(generation)
              ? _reload(all: all, reset: reset)
              : const <Comic>[],
        );
      }
      return active;
    }

    final generation = ++_generation;
    _activeReloadGeneration = generation;
    _activeReloadAll = all;
    _activeReloadReset = reset;
    _isReloading = true;
    _error = null;
    _loading.clear();
    _pageLoadGenerations.clear();
    _metadataOverlays.clear();
    setState(() {});

    late Future<List<Comic>> future;
    future = _performReload(generation, all: all, reset: reset).whenComplete(
      () {
        if (_activeReloadGeneration == generation &&
            identical(_activeReload, future)) {
          _activeReload = null;
          _activeReloadGeneration = null;
          _isReloading = false;
        }
        if (_isCurrent(generation)) {
          storeState();
          setState(() {});
        }
      },
    );
    _activeReload = future;
    return future;
  }

  Future<List<Comic>> _performReload(
    int generation, {
    required bool all,
    required bool reset,
  }) async {
    try {
      if (widget.loadPage != null) {
        return await _reloadPages(generation, all: all, reset: reset);
      }
      if (widget.loadNext != null) {
        return await _reloadCursor(generation, all: all, reset: reset);
      }
      if (_isCurrent(generation)) {
        _error = "Comic source does not support loading favorites".tl;
      }
    } catch (error) {
      if (_isCurrent(generation)) _error = _errorText(error);
    }
    return const <Comic>[];
  }

  String _errorText(Object error) =>
      (error is StateError ? error.message.toString() : error.toString()).tl;

  void _commitReload(
    Map<int, List<Comic>> pages, {
    required int? maxPage,
    required String? next,
    required bool reset,
    Set<String> cursors = const {},
  }) {
    _data
      ..clear()
      ..addAll(pages);
    _maxPage = maxPage;
    _nextUrl = next;
    _seenCursors
      ..clear()
      ..addAll(cursors);
    _error = null;
    if (reset) _page = 1;
    if (reset) _firstPage = 1;
    if (_maxPage != null && _page > _maxPage!) _page = _maxPage!;
    if (_page < 1) _page = 1;
  }

  Future<List<Comic>> _reloadPages(
    int generation, {
    required bool all,
    required bool reset,
  }) async {
    final loader = widget.loadPage!;
    final pages = <int, List<Comic>>{};
    final comics = <Comic>[];
    final seen = <(String, String)>{};
    final targets = reset
        ? <int>[1]
        : (<int>{..._data.keys, _page}.toList()..sort());
    int? maxPage = all || reset ? null : _maxPage;
    var targetIndex = 0;
    var page = all ? 1 : targets.first;
    while (_isCurrent(generation)) {
      try {
        final result = await loader(page);
        if (!_isCurrent(generation)) return const <Comic>[];
        if (result.error) {
          _error =
              (result.errorMessage ??
                      "Failed to load page @page".tlParams({
                        'page': page.toString(),
                      }))
                  .tl;
          return comics;
        }
        final reportedMax = result.subData;
        if (reportedMax is int) {
          maxPage = reportedMax < 1 ? 1 : reportedMax;
        }
        final loaded = List<Comic>.from(result.data);
        final identities = loaded.map((comic) => (comic.sourceKey, comic.id));
        if (all &&
            maxPage == null &&
            loaded.isNotEmpty &&
            identities.every(seen.contains)) {
          _error = "Source repeated previous page results".tl;
          return comics;
        }
        pages[page] = loaded;
        for (final comic in loaded) {
          if (seen.add((comic.sourceKey, comic.id))) comics.add(comic);
        }
        if (loaded.isEmpty && (reportedMax is! int || maxPage == 1)) {
          if (reportedMax is! int) maxPage = page > 1 ? page - 1 : 1;
          if (page == 1) {
            pages
              ..clear()
              ..[1] = <Comic>[];
            comics.clear();
          }
          break;
        }
      } catch (error) {
        if (_isCurrent(generation)) _error = _errorText(error);
        return comics;
      }
      if (all) {
        if (maxPage != null && page >= maxPage) break;
        page++;
      } else {
        targetIndex++;
        if (targetIndex >= targets.length) break;
        page = targets[targetIndex];
        if (maxPage != null && page > maxPage) break;
      }
    }
    if (!_isCurrent(generation)) return const <Comic>[];
    if (maxPage != null) {
      pages.removeWhere((page, _) => page > maxPage!);
    }
    _commitReload(pages, maxPage: maxPage, next: null, reset: reset);
    return comics;
  }

  Future<List<Comic>> _reloadCursor(
    int generation, {
    required bool all,
    required bool reset,
  }) async {
    final loader = widget.loadNext!;
    final pages = <int, List<Comic>>{};
    final comics = <Comic>[];
    final identities = <(String, String)>{};
    final cursors = <String>{};
    final loadedThrough = _data.keys.fold<int>(
      _page,
      (last, page) => page > last ? page : last,
    );
    final limit = reset ? 1 : loadedThrough;
    String? next;
    var chunk = 0;
    while (_isCurrent(generation)) {
      try {
        final result = await loader(next);
        if (!_isCurrent(generation)) return const <Comic>[];
        if (result.error) {
          _error =
              (result.errorMessage ??
                      "Failed to load chunk @chunk".tlParams({
                        'chunk': '${chunk + 1}',
                      }))
                  .tl;
          return comics;
        }
        final loaded = List<Comic>.from(result.data);
        final following = result.subData as String?;
        if (loaded.isNotEmpty || pages.isEmpty || following != null) {
          pages[++chunk] = loaded;
          for (final comic in loaded) {
            if (identities.add((comic.sourceKey, comic.id))) comics.add(comic);
          }
        }
        if (following != null && !cursors.add(following)) {
          _error = "Repeated cursor encountered".tl;
          return comics;
        }
        next = following;
        if (next == null || (!all && chunk >= limit)) break;
      } catch (error) {
        if (_isCurrent(generation)) _error = _errorText(error);
        return comics;
      }
    }
    if (!_isCurrent(generation)) return const <Comic>[];
    _commitReload(
      pages,
      maxPage: next == null ? chunk : null,
      next: next,
      reset: reset,
      cursors: cursors,
    );
    return comics;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    restoreState(PageStorage.of(context).readState(context));
    widget.refreshHandlerCallback?.call(refresh);
    widget.reloadHandlerCallback?.call(() {
      unawaited(reload());
    });
  }

  @override
  void dispose() {
    _generation++;
    _activeReload = null;
    _activeReloadGeneration = null;
    _activeCursorFetch = null;
    _activeCursorGeneration = null;
    super.dispose();
    _pageController.dispose();
  }

  void remove(Comic c) {
    if (_data[_page] == null || !_data[_page]!.remove(c)) {
      for (var page in _data.values) {
        if (page.remove(c)) {
          break;
        }
      }
    }
    setState(() {});
  }

  /// Applies fresh detail fields without replacing remote favorite identifiers,
  /// ratings, descriptions or pagination metadata with a different comic model.
  bool updateComicMetadata(
    String id, {
    String? sourceKey,
    String? title,
    String? cover,
    String? subtitle,
    List<String>? tags,
    String? description,
    String? favoriteId,
  }) {
    if (!mounted) return false;
    final fields = <String, dynamic>{
      if (title != null && title.trim().isNotEmpty) 'title': title,
      if (cover != null && cover.trim().isNotEmpty) 'cover': cover,
      if (subtitle != null && subtitle.trim().isNotEmpty) 'subTitle': subtitle,
      if (tags != null && tags.isNotEmpty) 'tags': List<String>.from(tags),
      if (description != null && description.trim().isNotEmpty)
        'description': description,
      if (favoriteId != null && favoriteId.trim().isNotEmpty)
        'favoriteId': favoriteId,
    };
    if (fields.isEmpty) return false;
    var updated = false;
    if (sourceKey != null) {
      _metadataOverlays[(sourceKey, id)] = fields;
      updated = true;
    }
    for (final list in _data.values) {
      for (var index = 0; index < list.length; index++) {
        final comic = list[index];
        if (comic.id == id &&
            (sourceKey == null || comic.sourceKey == sourceKey)) {
          list[index] = _withMetadata(comic, fields);
          _metadataOverlays[(comic.sourceKey, comic.id)] = fields;
          updated = true;
        }
      }
    }
    if (updated) {
      setState(() {});
    }
    return updated;
  }

  Widget _buildPageSelector() {
    return Row(
      children: [
        FilledButton(
          onPressed: _page > 1
              ? () {
                  setState(() {
                    _error = null;
                    _page--;
                  });
                }
              : null,
          child: Text("Back".tl),
        ).fixWidth(84),
        Expanded(
          child: Center(
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
              child: ClickInkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  String value = '';
                  showDialog(
                    context: App.rootContext,
                    builder: (context) {
                      return ContentDialog(
                        title: "Jump to page".tl,
                        content: TextField(
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: "Page".tl),
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onChanged: (v) {
                            value = v;
                          },
                        ).paddingHorizontal(16),
                        actions: [
                          Button.filled(
                            onPressed: () {
                              Navigator.of(context).pop();
                              var page = int.tryParse(value);
                              if (page == null) {
                                context.showMessage(message: "Invalid page".tl);
                              } else {
                                if (page > 0 &&
                                    (_maxPage == null || page <= _maxPage!)) {
                                  setState(() {
                                    _error = null;
                                    _page = page;
                                  });
                                } else {
                                  context.showMessage(
                                    message: "Invalid page".tl,
                                  );
                                }
                              }
                            },
                            child: Text("Jump".tl),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Text(
                    "Page @page".tlParams({
                      "page": "$_page / ${_maxPage ?? '?'}",
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
        FilledButton(
          onPressed: _page < (_maxPage ?? (_page + 1))
              ? () {
                  setState(() {
                    _error = null;
                    _page++;
                  });
                }
              : null,
          child: Text("Next".tl),
        ).fixWidth(84),
      ],
    ).paddingVertical(8).paddingHorizontal(16);
  }

  Widget _buildSliverPageSelector() {
    return SliverToBoxAdapter(child: _buildPageSelector());
  }

  Future<void> _loadPage(int page) async {
    final generation = _generation;
    if (!mounted ||
        _loadsCancelled ||
        _isReloading ||
        _data.containsKey(page) ||
        _pageLoadGenerations[page] == generation) {
      return;
    }
    if (_maxPage != null && page > _maxPage!) return;
    _loading[page] = true;
    _pageLoadGenerations[page] = generation;
    try {
      final loader = widget.loadPage;
      if (loader != null) {
        final result = await Future.sync(() => loader(page));
        if (!_isCurrent(generation)) return;
        if (result.error) {
          throw StateError(result.errorMessage ?? "Unknown error".tl);
        }
        _data[page] = _applyOverlays(List<Comic>.from(result.data));
        if (result.subData is int) {
          final max = result.subData as int;
          _maxPage = max < 1 ? 1 : max;
        } else if (result.data.isEmpty) {
          _maxPage = page > 1 ? page - 1 : 1;
        }
      } else if (widget.loadNext != null) {
        while (_isCurrent(generation) && !_data.containsKey(page)) {
          if (_maxPage != null && page > _maxPage!) break;
          if (!await _fetchNext(generation)) break;
        }
      } else {
        _error = "Comic source does not support loading favorites".tl;
        await Future<void>.value();
      }
      if (_isCurrent(generation) && _maxPage != null && _page > _maxPage!) {
        _page = _maxPage!;
      }
    } catch (error) {
      if (_isCurrent(generation)) _error = _errorText(error);
    } finally {
      if (_pageLoadGenerations[page] == generation) {
        _loading.remove(page);
        _pageLoadGenerations.remove(page);
      }
      if (_isCurrent(generation)) {
        if (_restoringCursor) {
          _restoringCursor = false;
          _pendingRevealPage = _error == null ? _page : null;
          if (_error != null && _data.isNotEmpty) {
            _page = (_data.keys.toList()..sort()).last;
            _pendingRevealPage = _page;
          }
        }
        if (_tracksPages && _maxPage != null && _firstPage > _maxPage!) {
          _firstPage = _maxPage!;
        }
        if (_maxPage != null) _data.removeWhere((key, _) => key > _maxPage!);
        storeState();
        setState(() {});
      }
    }
  }

  Future<bool> _fetchNext(int generation) {
    final active = _activeCursorFetch;
    if (active != null && _activeCursorGeneration == generation) {
      return active;
    }
    late Future<bool> future;
    future = _fetchNextChunk(generation).whenComplete(() {
      if (_activeCursorGeneration == generation &&
          identical(_activeCursorFetch, future)) {
        _activeCursorFetch = null;
        _activeCursorGeneration = null;
      }
    });
    _activeCursorFetch = future;
    _activeCursorGeneration = generation;
    return future;
  }

  Future<bool> _fetchNextChunk(int generation) async {
    if (!_isCurrent(generation) ||
        (_maxPage != null && _data.length >= _maxPage!)) {
      return false;
    }
    final result = await widget.loadNext!(_nextUrl);
    if (!_isCurrent(generation)) return false;
    if (result.error) {
      throw StateError(result.errorMessage ?? "Unknown error".tl);
    }
    final next = result.subData as String?;
    if (next != null && !_seenCursors.add(next)) {
      throw StateError("Repeated cursor encountered".tl);
    }
    if (result.data.isNotEmpty || _data.isEmpty || next != null) {
      final page =
          _data.keys.fold<int>(0, (last, page) => page > last ? page : last) +
          1;
      _data[page] = _applyOverlays(List<Comic>.from(result.data));
    }
    _nextUrl = next;
    if (_restoringCursor) setState(() {});
    if (next == null) _maxPage = _data.length;
    return true;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) cancelPendingLoads();
    },
    child: _buildContent(context),
  );

  Widget _buildContent(BuildContext context) {
    final type = appdata.settings['comicListDisplayMode'];
    if (_restoringCursor) {
      _loadPage(_page);
      return _buildRestoreProgress();
    }
    if (_restorePaused) return _buildRestoreProgress();
    if (type == 'paging') {
      _pendingRevealPage = null;
      if (_data.containsKey(_page) && _error == null) {
        final generation = _generation;
        final page = _page;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isCurrent(generation) && _page == page) _reportVisiblePage(page);
        });
      }
      return buildPagingMode();
    }
    return buildContinuousMode();
  }

  Widget buildPagingMode() {
    if (_error != null) {
      return SmoothCustomScrollView(
        key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (widget.errorLeading != null) widget.errorLeading!.toSliver(),
          _buildSliverPageSelector(),
          SliverFillRemaining(
            hasScrollBody: false,
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
                unawaited(reload());
              },
            ),
          ),
        ],
      );
    }
    if (_data[_page] == null) {
      _loadPage(_page);
      return SmoothCustomScrollView(
        key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (widget.errorLeading != null) widget.errorLeading!.toSliver(),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        if (_maxPage != 1) _buildSliverPageSelector(),
        SliverGridComics(
          comics: _data[_page] ?? const [],
          menuBuilder: widget.menuBuilder,
          onTap: widget.onTap,
          badgeBuilder: widget.badgeBuilder,
          useFavoriteDisplaySettings: widget.useFavoriteDisplaySettings,
          hideFavoriteBadge: widget.hideFavoriteBadge,
        ),
        if (_data[_page]!.length > 6 && _maxPage != 1)
          _buildSliverPageSelector(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }

  Widget buildContinuousMode() {
    if (_error != null && _data.isEmpty) {
      return SmoothCustomScrollView(
        key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (widget.errorLeading != null) widget.errorLeading!.toSliver(),
          _buildSliverPageSelector(),
          SliverFillRemaining(
            hasScrollBody: false,
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
                unawaited(reload());
              },
            ),
          ),
        ],
      );
    }
    if (_data[_firstPage] == null) {
      _loadPage(_firstPage);
      return SmoothCustomScrollView(
        key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (widget.errorLeading != null) widget.errorLeading!.toSliver(),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }
    final pages = _data.keys.where((page) => page >= _firstPage).toList()
      ..sort();
    if (_tracksPages) _schedulePageReveal();
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        if (_tracksPages)
          for (final page in pages) ...[
            SliverLayoutBuilder(
              builder: (context, constraints) {
                _pageStarts[page] = constraints.precedingScrollExtent;
                return SliverToBoxAdapter(
                  child: Padding(
                    key: _pageHeaders.putIfAbsent(page, GlobalKey.new),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            'Page @page'.tlParams({'page': page}),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                  ),
                );
              },
            ),
            _VisiblePageSliver(
              onPaint: () => _pagePainted(page),
              sliver: SliverGridComics(
                comics: _data[page]!,
                menuBuilder: widget.menuBuilder,
                onTap: widget.onTap,
                badgeBuilder: widget.badgeBuilder,
                useFavoriteDisplaySettings: widget.useFavoriteDisplaySettings,
                hideFavoriteBadge: widget.hideFavoriteBadge,
                onLastItemBuild: page == pages.last
                    ? () => _preloadAfter(page)
                    : null,
              ),
            ),
          ]
        else
          SliverGridComics(
            comics: _data.values.expand((element) => element).toList(),
            menuBuilder: widget.menuBuilder,
            onTap: widget.onTap,
            badgeBuilder: widget.badgeBuilder,
            useFavoriteDisplaySettings: widget.useFavoriteDisplaySettings,
            hideFavoriteBadge: widget.hideFavoriteBadge,
            onLastItemBuild: () => _preloadAfter(_data.length),
          ),
        if (_error != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.error_outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, maxLines: 3)),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _error = null;
                      });
                      unawaited(reload());
                    },
                    child: Text("Retry".tl),
                  ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          )
        else if (_maxPage == null ||
            (pages.isNotEmpty && pages.last < _maxPage!))
          const SliverListLoadingIndicator(),
        if (_tracksPages && pages.isNotEmpty)
          SliverLayoutBuilder(
            builder: (context, constraints) {
              // Even a short last page can be restored below the pinned toolbar.
              final pageExtent =
                  constraints.precedingScrollExtent -
                  (_pageStarts[pages.last] ?? 0);
              final padding = (constraints.viewportMainAxisExtent - pageExtent)
                  .clamp(0.0, constraints.viewportMainAxisExtent)
                  .toDouble();
              return SliverToBoxAdapter(child: SizedBox(height: padding));
            },
          ),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }

  void _preloadAfter(int page) {
    if (_error == null && (_maxPage == null || page < _maxPage!)) {
      _loadPage(page + 1);
    }
  }
}

/// Reports painted slivers only; cache-extent layout and card preloading never
/// change the visible result page.
class _VisiblePageSliver extends SingleChildRenderObjectWidget {
  const _VisiblePageSliver({required Widget sliver, required this.onPaint})
    : super(child: sliver);
  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderVisiblePageSliver(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderVisiblePageSliver renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _RenderVisiblePageSliver extends RenderProxySliver {
  _RenderVisiblePageSliver(this.onPaint);
  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (geometry?.visible == true &&
        geometry!.paintExtent > constraints.overlap.clamp(0, double.infinity)) {
      onPaint();
    }
  }
}
