import 'dart:async';

import "package:flutter/material.dart";
import 'package:shimmer_animation/shimmer_animation.dart';
import "package:venera_plus/components/appbar.dart";
import "package:venera_plus/components/gesture.dart";
import "package:venera_plus/components/scroll.dart";
import "package:venera_plus/features/comic_widgets/comic_widgets.dart";
import "package:venera_plus/features/local_comics/local_comics.dart";
import "package:venera_plus/foundation/appdata.dart";
import "package:venera_plus/foundation/context.dart";
import "package:venera_plus/features/comic_source/comic_source.dart";
import "package:venera_plus/foundation/translations.dart";
import "package:venera_plus/foundation/widget_utils.dart";
import 'package:venera_plus/foundation/search_history.dart';

import 'search_filter.dart';
import 'search_options.dart';
import "search_result_page.dart";
import "search_targets.dart";

class AggregatedSearchPage extends StatefulWidget {
  const AggregatedSearchPage({
    super.key,
    required this.keyword,
    this.onComicTap,
  });

  final String keyword;
  final ValueChanged<Comic>? onComicTap;

  @override
  State<AggregatedSearchPage> createState() => _AggregatedSearchPageState();
}

class _AggregatedSearchPageState extends State<AggregatedSearchPage> {
  late final SearchBarController controller;

  var _keyword = "";

  void _remember() {
    if (_keyword.trim().isEmpty) return;
    unawaited(
      appdata
          .recordSearchHistory(
            SearchHistoryEntry(
              keyword: _keyword,
              sourceKey: SearchHistoryEntry.aggregatedSourceKey,
              sourceName: 'Aggregated Search',
            ),
          )
          .catchError((Object error) {
            if (mounted) context.showMessage(message: error.toString());
          }),
    );
  }

  @override
  void initState() {
    super.initState();
    _keyword = widget.keyword;
    _remember();
    controller = SearchBarController(
      currentText: widget.keyword,
      onSearch: (text) {
        setState(() {
          _keyword = text;
        });
        _remember();
      },
    );
    appdata.settings.addListener(_sourcesChanged);
    ComicSourceManager().addListener(_sourcesChanged);
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_sourcesChanged);
    ComicSourceManager().removeListener(_sourcesChanged);
    super.dispose();
  }

  void _sourcesChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final sources = <SearchTarget>[
      for (final target in enabledSearchTargets())
        if (widget.onComicTap == null || target.key != localSearchTargetKey)
          target,
    ];
    final results = SmoothCustomScrollView(
      slivers: [
        SliverSearchBar(controller: controller),
        if (sources.isEmpty)
          SliverFillRemaining(
            child: Center(child: Text('No searchable sources'.tl)),
          ),
        SliverList(
          key: ValueKey(_keyword),
          delegate: SliverChildBuilderDelegate((context, index) {
            final source = sources[index];
            return _SliverSearchResult(
              key: ValueKey(source.key),
              source: source,
              keyword: _keyword,
              onComicTap: widget.onComicTap,
            );
          }, childCount: sources.length),
        ),
      ],
    );
    return MouseDragScrollRegion(child: results);
  }
}

class _SliverSearchResult extends StatefulWidget {
  const _SliverSearchResult({
    required this.source,
    required this.keyword,
    this.onComicTap,
    super.key,
  });

  final SearchTarget source;

  final String keyword;
  final ValueChanged<Comic>? onComicTap;

  @override
  State<_SliverSearchResult> createState() => _SliverSearchResultState();
}

class _SliverSearchResultState extends State<_SliverSearchResult>
    with AutomaticKeepAliveClientMixin {
  bool isLoading = true;

  static const _kComicHeight = 162.0;

  double get _comicWidth => _kComicHeight * 0.7;

  static const _kLeftPadding = 16.0;

  List<Comic>? comics;

  String? error;
  Object? _activeRequest;
  bool _refreshQueued = false;

  Future<void> load() async {
    if (_activeRequest != null) {
      // 每个来源只保留一次待刷新，避免扫描期间重复查询同一书库。
      _refreshQueued = true;
      return;
    }
    final request = Object();
    _activeRequest = request;
    try {
      final data = widget.source.searchPageData;
      final options = defaultSearchOptions(data.searchOptions ?? []);
      final keyword = applySearchLanguageFilter(
        widget.keyword,
        sourceKey: widget.source.key,
        setting: appdata.settings['autoAddLanguageFilter'] ?? 'none',
      );
      final result = data.loadPage != null
          ? await data.loadPage!(keyword, 1, options)
          : await data.loadNext!(keyword, null, options);
      if (!mounted || !identical(_activeRequest, request)) return;
      setState(() {
        isLoading = false;
        error = result.error ? result.errorMessage ?? 'Unknown error'.tl : null;
        comics = result.error ? null : result.data;
      });
    } catch (exception) {
      if (!mounted || !identical(_activeRequest, request)) return;
      setState(() {
        isLoading = false;
        error = '$exception';
      });
    } finally {
      if (mounted && identical(_activeRequest, request)) {
        _activeRequest = null;
        if (_refreshQueued) {
          _refreshQueued = false;
          _onContentChanged();
        }
      }
    }
  }

  void _onContentChanged() => unawaited(load());

  @override
  void initState() {
    super.initState();
    widget.source.searchPageData.changeListenable?.addListener(
      _onContentChanged,
    );
    _onContentChanged();
  }

  @override
  void didUpdateWidget(covariant _SliverSearchResult oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldChanges = oldWidget.source.searchPageData.changeListenable;
    final changes = widget.source.searchPageData.changeListenable;
    if (identical(oldChanges, changes)) return;
    oldChanges?.removeListener(_onContentChanged);
    changes?.addListener(_onContentChanged);
    _activeRequest = null;
    _refreshQueued = false;
    comics = null;
    error = null;
    isLoading = true;
    _onContentChanged();
  }

  @override
  void dispose() {
    widget.source.searchPageData.changeListenable?.removeListener(
      _onContentChanged,
    );
    super.dispose();
  }

  Widget buildPlaceHolder() {
    return Container(
      height: _kComicHeight,
      width: _comicWidth,
      margin: const EdgeInsets.only(left: _kLeftPadding),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  Widget buildComic(Comic c) {
    final onComicTap = widget.onComicTap;
    return SimpleComicTile(
      comic: c,
      onTap: onComicTap != null
          ? () => onComicTap(c)
          : c is LocalComic
          ? c.read
          : null,
      withTitle: true,
    ).paddingLeft(_kLeftPadding).paddingBottom(2);
  }

  @override
  Widget build(BuildContext context) {
    if (error != null && error!.startsWith("CloudflareException")) {
      error = "Cloudflare verification required".tl;
    }
    super.build(context);
    var visibleComics = comics;
    if (visibleComics != null && visibleComics.isNotEmpty) {
      final filter = comicKeywordFilter();
      if (filter.rules.isNotEmpty) {
        visibleComics = visibleComics
            .where((comic) => matchComicKeyword(comic, filter: filter) == null)
            .toList();
      }
    }
    return ClickInkWell(
      onTap: () {
        context.to(
          () => SearchResultPage(
            text: widget.keyword,
            sourceKey: widget.source.key,
            onComicTap: widget.onComicTap,
          ),
        );
      },
      child: Column(
        children: [
          ListTile(
            mouseCursor: SystemMouseCursors.click,
            title: Text(widget.source.name),
          ),
          if (isLoading)
            SizedBox(
              height: _kComicHeight,
              width: double.infinity,
              child: Shimmer(
                child: LayoutBuilder(
                  builder: (context, constrains) {
                    var itemWidth = _comicWidth + _kLeftPadding;
                    var items = (constrains.maxWidth / itemWidth).ceil();
                    return Stack(
                      children: [
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          child: Row(
                            children: List.generate(
                              items,
                              (index) => buildPlaceHolder(),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            )
          else if (error != null ||
              visibleComics == null ||
              visibleComics.isEmpty)
            SizedBox(
              height: _kComicHeight,
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          error ?? "No search results found".tl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                ],
              ).paddingHorizontal(16),
            )
          else
            SizedBox(
              height: _kComicHeight,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final comic in visibleComics) buildComic(comic),
                ],
              ),
            ),
        ],
      ).paddingBottom(16),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
