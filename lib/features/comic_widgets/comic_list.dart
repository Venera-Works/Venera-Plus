import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

import 'comic_tile.dart';

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
  });

  final List<Comic> comics;

  final Map<Comic, bool>? selections;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

  final bool useFavoriteDisplaySettings;

  @override
  State<SliverGridComics> createState() => _SliverGridComicsState();
}

class _SliverGridComicsState extends State<SliverGridComics> {
  List<Comic> comics = [];
  List<int> heroIDs = [];

  static int _nextHeroID = 0;

  void generateHeroID() {
    heroIDs.clear();
    for (var i = 0; i < comics.length; i++) {
      heroIDs.add(_nextHeroID++);
    }
  }

  @override
  void didUpdateWidget(covariant SliverGridComics oldWidget) {
    if (oldWidget.useFavoriteDisplaySettings !=
        widget.useFavoriteDisplaySettings) {
      if (widget.useFavoriteDisplaySettings) {
        appdata.settings.addListener(_onSettingsChanged);
      } else {
        appdata.settings.removeListener(_onSettingsChanged);
      }
    }
    if (!comics.isEqualTo(widget.comics)) {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
      generateHeroID();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    for (var comic in widget.comics) {
      if (isBlocked(comic) == null) {
        comics.add(comic);
      }
    }
    generateHeroID();
    addComicWidgetStateListener(update);
    if (widget.useFavoriteDisplaySettings) {
      appdata.settings.addListener(_onSettingsChanged);
    }
    super.initState();
  }

  @override
  void dispose() {
    removeComicWidgetStateListener(update);
    if (widget.useFavoriteDisplaySettings) {
      appdata.settings.removeListener(_onSettingsChanged);
    }
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void update() {
    setState(() {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final favoriteDisplayState = comicFavoriteDisplayState();
    final favoriteDisplayMode = widget.useFavoriteDisplaySettings
        ? (favoriteDisplayState.isGallery
              ? ComicTileDisplayMode.gallery
              : ComicTileDisplayMode.detailed)
        : null;
    return _SliverGridComics(
      comics: comics,
      heroIDs: heroIDs,
      selection: widget.selections,
      onLastItemBuild: widget.onLastItemBuild,
      badgeBuilder: widget.badgeBuilder,
      menuBuilder: widget.menuBuilder,
      onTap: widget.onTap,
      onLongPressed: widget.onLongPressed,
      onBlocked: update,
      favoriteDisplayMode: favoriteDisplayMode,
      galleryColumns: favoriteDisplayMode == ComicTileDisplayMode.gallery
          ? favoriteDisplayState.galleryColumns
          : null,
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
        );
        if (selection == null) {
          return comic;
        }
        return AnimatedContainer(
          key: ValueKey(comics[index].id),
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

/// return the first blocked keyword, or null if not blocked
String? isBlocked(Comic item) {
  for (var word in appdata.settings['blockedWords']) {
    if (item.title.contains(word)) {
      return word;
    }
    if (item.subtitle?.contains(word) ?? false) {
      return word;
    }
    if (item.description.contains(word)) {
      return word;
    }
    for (var tag in item.tags ?? <String>[]) {
      if (tag == word) {
        return word;
      }
      if (tag.contains(':')) {
        tag = tag.split(':')[1];
        if (tag == word) {
          return word;
        }
      }
    }
  }
  return null;
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
    this.badgeBuilder,
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
  final String? Function(Comic)? badgeBuilder;

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

  bool _isCurrent(int generation) => mounted && _generation == generation;

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
    if (next == null) _maxPage = _data.length;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicListDisplayMode'];
    return type == 'paging' ? buildPagingMode() : buildContinuousMode();
  }

  Widget buildPagingMode() {
    if (_error != null) {
      return SmoothCustomScrollView(
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
      controller: widget.controller,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        if (_maxPage != 1) _buildSliverPageSelector(),
        SliverGridComics(
          comics: _data[_page] ?? const [],
          menuBuilder: widget.menuBuilder,
          badgeBuilder: widget.badgeBuilder,
          useFavoriteDisplaySettings: widget.useFavoriteDisplaySettings,
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
    if (_data[1] == null) {
      _loadPage(1);
      return SmoothCustomScrollView(
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
      controller: widget.controller,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        SliverGridComics(
          comics: _data.values.expand((element) => element).toList(),
          menuBuilder: widget.menuBuilder,
          badgeBuilder: widget.badgeBuilder,
          useFavoriteDisplaySettings: widget.useFavoriteDisplaySettings,
          onLastItemBuild: () {
            if (_error == null &&
                (_maxPage == null || _data.length < _maxPage!)) {
              _loadPage(_data.length + 1);
            }
          },
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
        else if (_maxPage == null || _data.length < _maxPage!)
          const SliverListLoadingIndicator(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }
}
