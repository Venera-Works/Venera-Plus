import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/search/library_tag_picker.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

import 'remote_library_engine.dart';

class RemoteLibrarySearchPage extends StatefulWidget {
  const RemoteLibrarySearchPage({
    super.key,
    required this.sourceKey,
    this.initialKeyword = '',
    this.initialTag,
  });

  final String sourceKey;
  final String initialKeyword;
  final String? initialTag;

  @override
  State<RemoteLibrarySearchPage> createState() =>
      _RemoteLibrarySearchPageState();
}

class _RemoteLibrarySearchPageState extends State<RemoteLibrarySearchPage> {
  RemoteLibraryEngine? _engine;
  late final SearchBarController _searchController;
  late String _keyword;
  late Set<String> _tags;
  Timer? _searchDebounce;
  bool _pickingTags = false;
  var _listKey = GlobalKey<ComicListState>();

  @override
  void initState() {
    super.initState();
    _keyword = widget.initialKeyword.trim();
    _tags = {?widget.initialTag};
    _searchController = SearchBarController(
      currentText: _keyword,
      onSearch: _applyQuery,
    );
    _engine = RemoteLibraryEngines.forSearch(widget.sourceKey);
    _engine?.contentVersion.addListener(_onContentChanged);
    ComicSourceManager().addListener(_onSourcesChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    ComicSourceManager().removeListener(_onSourcesChanged);
    _engine?.contentVersion.removeListener(_onContentChanged);
    super.dispose();
  }

  void _onSourcesChanged() {
    final engine = RemoteLibraryEngines.forSearch(widget.sourceKey);
    if (identical(engine, _engine)) return;
    _engine?.contentVersion.removeListener(_onContentChanged);
    engine?.contentVersion.addListener(_onContentChanged);
    setState(() {
      _engine = engine;
      _listKey = GlobalKey<ComicListState>();
    });
  }

  void _onContentChanged() {
    setState(() {});
    unawaited(_listKey.currentState?.reload(queueIfLoading: true));
  }

  void _scheduleSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 240),
      () => _applyQuery(value),
    );
  }

  void _applyQuery(String value, {Set<String>? tags}) {
    _searchDebounce?.cancel();
    final keyword = value.trim();
    final nextTags = tags ?? _tags;
    if (_keyword == keyword && setEquals(_tags, nextTags)) return;
    setState(() {
      _keyword = keyword;
      _tags = nextTags;
      _listKey = GlobalKey<ComicListState>();
    });
  }

  Future<void> _pickTags(RemoteLibraryEngine engine) async {
    setState(() => _pickingTags = true);
    try {
      final result = await engine.availableTags();
      if (!mounted || !identical(_engine, engine)) return;
      final error = result.errorMessage;
      if (error != null) {
        context.showMessage(message: error.tl);
        return;
      }
      final selected = await showLibraryTagPicker(
        context,
        availableTags: result.data,
        selectedTags: _tags,
      );
      if (mounted && identical(_engine, engine) && selected != null) {
        _applyQuery(_searchController.text, tags: selected);
      }
    } finally {
      if (mounted) setState(() => _pickingTags = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final keyword = _keyword;
    final tags = _tags;
    final statusMessage = engine?.statusMessage;
    return Scaffold(
      body: Column(
        children: [
          AppSearchBar(
            controller: _searchController,
            hintText: engine == null
                ? null
                : 'Search @library'.tlParams({'library': engine.library.name}),
            onChanged: _scheduleSearch,
            action: IconButton(
              tooltip: 'Tags'.tl,
              icon: const Icon(Icons.filter_alt_outlined),
              selectedIcon: const Icon(Icons.filter_alt),
              isSelected: tags.isNotEmpty,
              onPressed: engine == null || _pickingTags
                  ? null
                  : () => _pickTags(engine),
            ),
          ),
          if (tags.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                spacing: 8,
                children: [
                  for (final tag in tags)
                    InputChip(
                      label: Text(tag),
                      onDeleted: () => _applyQuery(
                        _searchController.text,
                        tags: {...tags}..remove(tag),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: engine == null
                ? Center(child: Text('Source unavailable'.tl))
                : ComicList(
                    key: _listKey,
                    preserveScrollPosition: true,
                    loadPage: (page) => engine.loadComics(
                      page,
                      keyword: keyword,
                      tags: tags,
                      showAuthor: true,
                    ),
                    leadingSliver: statusMessage == null
                        ? null
                        : SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(statusMessage),
                            ),
                          ),
                    emptySliver: SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('No search results found'.tl)),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
