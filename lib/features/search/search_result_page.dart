import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/select.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/global_state.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/foundation/search_history.dart';

import 'library_tag_picker.dart';
import 'search_filter.dart';
import 'search_page.dart';
import 'search_options.dart';
import 'search_targets.dart';

class SearchResultPage extends StatefulWidget {
  const SearchResultPage({
    super.key,
    required this.text,
    required this.sourceKey,
    this.options,
    this.onComicTap,
    this.historyEntry,
  });

  final String text;

  final String sourceKey;

  final List<String>? options;
  final ValueChanged<Comic>? onComicTap;
  final SearchHistoryEntry? historyEntry;

  @override
  State<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends State<SearchResultPage> {
  late SearchBarController controller;
  late String sourceKey;
  late List<String> options;
  late String text;
  late String _query;
  late _SuggestionsController suggestionsController;
  late final FocusNode _searchFocusNode;
  bool _keyboardVisible = false;
  int _initialPage = 1;
  int _revision = 0;
  Timer? _historyTimer;
  SearchHistoryEntry? _pendingHistory;
  GlobalKey<ComicListState> _listKey = GlobalKey<ComicListState>();
  Listenable? _contentChanges;

  OverlayEntry? get suggestionOverlay => suggestionsController.entry;

  SearchTarget? get _target =>
      widget.onComicTap != null && sourceKey == localSearchTargetKey
      ? null
      : findSearchTarget(sourceKey);

  List<SearchTarget> get _selectableTargets => [
    for (final target in enabledSearchTargets())
      if (widget.onComicTap == null || target.key != localSearchTargetKey)
        target,
  ];

  void _save(SearchHistoryEntry entry) {
    unawaited(
      appdata.recordSearchHistory(entry).catchError((Object error) {
        if (mounted) {
          context.showMessage(message: error.toString());
        } else {
          FlutterError.reportError(FlutterErrorDetails(exception: error));
        }
      }),
    );
  }

  void _flushHistory() {
    _historyTimer?.cancel();
    _historyTimer = null;
    final pending = _pendingHistory;
    _pendingHistory = null;
    if (pending != null) _save(pending);
  }

  SearchHistoryEntry? _entry() {
    if (text.trim().isEmpty) return null;
    final source = _target;
    if (source == null) return null;
    return SearchHistoryEntry(
      keyword: text,
      sourceKey: sourceKey,
      sourceName: source.name,
      options: options,
      page: _initialPage,
    );
  }

  void _remember() {
    final entry = _entry();
    if (entry != null) _save(entry);
  }

  void _visiblePage(SearchHistoryEntry entry, int revision, int page) {
    if (!mounted || revision != _revision) return;
    _initialPage = page;
    _pendingHistory = entry.copyWith(page: page);
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(milliseconds: 350), _flushHistory);
  }

  void search([String? value]) {
    if (value == null) return;
    _flushHistory();
    _listKey.currentState?.cancelPendingLoads();
    _listKey = GlobalKey<ComicListState>();
    suggestionsController.remove();
    setState(() {
      text = value;
      _query = _applyConfiguredLanguageFilter(text);
      _initialPage = 1;
      _revision++;
      controller.currentText = text;
    });
    _remember();
  }

  void onChanged(String s) {
    if (ComicSource.find(sourceKey)?.enableTagsSuggestions != true) return;
    suggestionsController.findSuggestions();
    if (suggestionOverlay != null) {
      if (suggestionsController.suggestions.isEmpty) {
        suggestionsController.remove();
      } else {
        suggestionsController.updateWidget();
      }
    } else if (suggestionsController.suggestions.isNotEmpty) {
      suggestionsController.entry = OverlayEntry(
        builder: (context) => Positioned(
          top: context.padding.top + SliverSearchBar.toolbarHeight,
          left: 0,
          right: 0,
          bottom: MediaQuery.viewInsetsOf(context).bottom,
          child: TextFieldTapRegion(
            child: Material(
              child: _Suggestions(controller: suggestionsController),
            ),
          ),
        ),
      );
      Overlay.of(context).insert(suggestionOverlay!);
    }
  }

  void _onSearchFocusChanged() {
    if (!_searchFocusNode.hasFocus) suggestionsController.remove();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    // 系统收起软键盘时，搜索框可能仍保有焦点。
    if (_keyboardVisible && !keyboardVisible) suggestionsController.remove();
    _keyboardVisible = keyboardVisible;
  }

  @override
  void dispose() {
    _revision++;
    _flushHistory();
    ComicSourceManager().removeListener(_sourcesChanged);
    _contentChanges?.removeListener(_reloadContent);
    _searchFocusNode.dispose();
    Future.microtask(suggestionsController.remove);
    super.dispose();
  }

  void _sourcesChanged() {
    final target = _target;
    final changed = _listenForContentChanges(target?.searchPageData);
    if (target == null || changed) {
      _listKey.currentState?.cancelPendingLoads();
      _listKey = GlobalKey<ComicListState>();
      _revision++;
      suggestionsController.remove();
    }
    if (mounted) setState(() {});
  }

  bool _listenForContentChanges(SearchPageData? data) {
    final next = data?.changeListenable;
    if (identical(next, _contentChanges)) return false;
    _contentChanges?.removeListener(_reloadContent);
    _contentChanges = next;
    next?.addListener(_reloadContent);
    return true;
  }

  void _reloadContent() {
    unawaited(_listKey.currentState?.reload(queueIfLoading: true));
  }

  String _applyConfiguredLanguageFilter(String value) =>
      applySearchLanguageFilter(
        value,
        sourceKey: sourceKey,
        setting: appdata.settings['autoAddLanguageFilter'] ?? 'none',
      );

  @override
  void initState() {
    super.initState();
    sourceKey = widget.sourceKey;
    text = widget.historyEntry?.keyword ?? widget.text;
    _query = _applyConfiguredLanguageFilter(text);
    controller = SearchBarController(currentText: text, onSearch: search);
    options = List.of(
      widget.historyEntry?.options ?? widget.options ?? const [],
    );
    _initialPage = widget.historyEntry?.page ?? 1;
    final changed = validateOptions();
    if (changed && widget.historyEntry != null) {
      _initialPage = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.showMessage(
            message:
                'Search options have changed. Using current defaults from page 1.'
                    .tl,
          );
        }
      });
    }
    suggestionsController = _SuggestionsController(controller, sourceKey);
    _searchFocusNode = FocusNode()..addListener(_onSearchFocusChanged);
    _listenForContentChanges(_target?.searchPageData);
    ComicSourceManager().addListener(_sourcesChanged);
    _remember();
  }

  bool validateOptions() {
    final data = _target?.searchPageData;
    if (data == null || data.loadTags != null) return false;
    final definitions = data.searchOptions ?? [];
    final valid = validatedSearchOptions(definitions, options);
    options = valid ?? defaultSearchOptions(definitions);
    return valid == null;
  }

  @override
  Widget build(BuildContext context) {
    final source = _target;
    if (source == null) {
      return Scaffold(
        appBar: AppBar(title: Text(text)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'This search source is unavailable. Choose another source.'
                      .tl,
                ),
                const SizedBox(height: 16),
                buildAction(),
              ],
            ),
          ),
        ),
      );
    }
    final keyword = _query;
    final selectedOptions = List<String>.unmodifiable(options);
    final entry = _entry();
    final revision = _revision;
    final data = source.searchPageData;
    final onComicTap = widget.onComicTap;
    return Scaffold(
      body: ComicList(
        onTap: onComicTap != null
            ? (comic, _) => onComicTap(comic)
            : source.key == localSearchTargetKey
            ? (comic, _) => (comic as LocalComic).read()
            : null,
        key: _listKey,
        initialPage: _initialPage,
        preserveScrollPosition: data.changeListenable != null,
        onVisiblePageChanged: entry == null
            ? null
            : (page) => _visiblePage(entry, revision, page),
        errorLeading: AppSearchBar(
          controller: controller,
          action: buildAction(),
        ),
        leadingSliver: SliverSearchBar(
          controller: controller,
          onChanged: onChanged,
          action: buildAction(),
          focusNode: _searchFocusNode,
        ),
        emptySliver: SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('No search results found'.tl)),
        ),
        loadPage: data.loadPage == null
            ? null
            : (page) => data.loadPage!(keyword, page, selectedOptions),
        loadNext: data.loadNext == null
            ? null
            : (next) => data.loadNext!(keyword, next, selectedOptions),
      ),
    );
  }

  Widget buildAction() => IconButton(
    tooltip: 'Settings'.tl,
    icon: const Icon(Icons.tune),
    onPressed: () async {
      suggestionsController.remove();
      final hadSource = _target != null;
      final selection = await showDialog<(String, List<String>)>(
        context: context,
        useRootNavigator: true,
        builder: (context) => _SearchSettingsDialog(state: this),
      );
      if (!mounted || selection == null) return;
      final (nextSourceKey, nextOptions) = selection;
      if (sourceKey == nextSourceKey && options.isEqualTo(nextOptions)) return;
      if (!_selectableTargets.any((target) => target.key == nextSourceKey)) {
        return;
      }

      _listKey.currentState?.cancelPendingLoads();
      _flushHistory();
      setState(() {
        _listKey = GlobalKey<ComicListState>();
        sourceKey = nextSourceKey;
        options = nextOptions;
        if (hadSource) text = controller.text;
        _query = _applyConfiguredLanguageFilter(text);
        controller.currentText = text;
        suggestionsController = _SuggestionsController(controller, sourceKey);
        validateOptions();
        _listenForContentChanges(_target?.searchPageData);
        _initialPage = 1;
        _revision++;
      });
      _remember();
    },
  );
}

class _SuggestionsController {
  _SuggestionsState? _state;

  final SearchBarController controller;

  final String sourceKey;

  OverlayEntry? entry;

  void updateWidget() {
    _state?.update();
  }

  void remove() {
    final overlay = entry;
    entry = null;
    _state = null;
    overlay?.remove();
    overlay?.dispose();
  }

  var suggestions = <Pair<String, TranslationType>>[];

  void findSuggestions() {
    var text = controller.text.split(" ").last;
    var suggestions = this.suggestions;

    suggestions.clear();

    bool check(String text, String key, String value) {
      if (text.removeAllBlank == "") {
        return false;
      }
      if (key.length >= text.length && key.substring(0, text.length) == text ||
          (key.contains(" ") &&
              key.split(" ").last.length >= text.length &&
              key.split(" ").last.substring(0, text.length) == text)) {
        return true;
      } else if (value.length >= text.length && value.contains(text)) {
        return true;
      }
      return false;
    }

    void find(Map<String, String> map, TranslationType type) {
      for (var element in map.entries) {
        if (suggestions.length > 200) {
          break;
        }
        if (check(text, element.key, element.value)) {
          suggestions.add(Pair(element.key, type));
        }
      }
    }

    find(TagsTranslation.femaleTags, TranslationType.female);
    find(TagsTranslation.maleTags, TranslationType.male);
    find(TagsTranslation.parodyTags, TranslationType.parody);
    find(TagsTranslation.characterTranslations, TranslationType.character);
    find(TagsTranslation.otherTags, TranslationType.other);
    find(TagsTranslation.mixedTags, TranslationType.mixed);
    find(TagsTranslation.languageTranslations, TranslationType.language);
    find(TagsTranslation.artistTags, TranslationType.artist);
    find(TagsTranslation.groupTags, TranslationType.group);
    find(TagsTranslation.cosplayerTags, TranslationType.cosplayer);
  }

  _SuggestionsController(this.controller, this.sourceKey);
}

class _Suggestions extends StatefulWidget {
  const _Suggestions({required this.controller});

  final _SuggestionsController controller;

  @override
  State<_Suggestions> createState() => _SuggestionsState();
}

class _SuggestionsState extends State<_Suggestions> {
  void update() {
    setState(() {});
  }

  @override
  void initState() {
    widget.controller._state = this;
    super.initState();
  }

  @override
  void didUpdateWidget(covariant _Suggestions oldWidget) {
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._state = null;
      widget.controller._state = this;
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return buildSuggestions(context);
  }

  Widget buildSuggestions(BuildContext context) {
    bool showMethod = MediaQuery.of(context).size.width < 600;
    bool showTranslation = App.locale.languageCode == "zh";

    Widget buildItem(Pair<String, TranslationType> value) {
      var subTitle = TagsTranslation.translationTagWithNamespace(
        value.left,
        value.right.name,
      );
      return ListTile(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(child: Text(value.left, maxLines: 2)),
            if (!showMethod) const SizedBox(width: 12),
            if (!showMethod && showTranslation)
              Text(
                subTitle,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
          ],
        ),
        subtitle: (showMethod && showTranslation) ? Text(subTitle) : null,
        trailing: Text(value.right.name, style: const TextStyle(fontSize: 13)),
        onTap: () => onSelected(value.left, value.right),
      );
    }

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.hub_outlined),
          title: Text("Suggestions".tl),
          trailing: Tooltip(
            message: "Clear".tl,
            child: IconButton(
              icon: const Icon(Icons.clear_all),
              onPressed: () {
                widget.controller.suggestions.clear();
                widget.controller.remove();
              },
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: widget.controller.suggestions.length,
            itemBuilder: (context, index) =>
                buildItem(widget.controller.suggestions[index]),
          ),
        ),
      ],
    );
  }

  bool check(String text, String key, String value) {
    if (text.removeAllBlank == "") {
      return false;
    }
    if (key.length >= text.length && key.substring(0, text.length) == text ||
        (key.contains(" ") &&
            key.split(" ").last.length >= text.length &&
            key.split(" ").last.substring(0, text.length) == text)) {
      return true;
    } else if (value.length >= text.length && value.contains(text)) {
      return true;
    }
    return false;
  }

  void onSelected(String text, TranslationType? type) {
    var controller = widget.controller.controller;
    var words = controller.text.split(" ");
    if (words.length >= 2 &&
        check(
          "${words[words.length - 2]} ${words[words.length - 1]}",
          text,
          text.translateTagsToCN,
        )) {
      controller.text = controller.text.replaceLast(
        "${words[words.length - 2]} ${words[words.length - 1]}",
        "",
      );
    } else {
      controller.text = controller.text.replaceLast(
        words[words.length - 1],
        "",
      );
    }
    final source = ComicSource.find(widget.controller.sourceKey);
    String insert;
    if (source?.onTagSuggestionSelected != null) {
      insert = source!.onTagSuggestionSelected!(type?.name ?? '', text);
    } else {
      var t = text;
      if (t.contains(' ')) t = "'$t'";
      insert = type != null ? "${type.name}:$t" : t;
    }
    controller.text += "$insert ";
    widget.controller.suggestions.clear();
    widget.controller.remove();
  }
}

class _SearchSettingsDialog extends StatefulWidget {
  const _SearchSettingsDialog({required this.state});

  final _SearchResultPageState state;

  @override
  State<_SearchSettingsDialog> createState() => _SearchSettingsDialogState();
}

class _SearchSettingsDialogState extends State<_SearchSettingsDialog> {
  late String searchTarget;

  late List<String> options;

  @override
  void initState() {
    searchTarget = widget.state.sourceKey;
    options = List.of(widget.state.options);
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final sources = widget.state._selectableTargets;
    final selected = sources
        .where((target) => target.key == searchTarget)
        .firstOrNull;
    return ContentDialog(
      title: "Settings".tl,
      content: Column(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text("Search in".tl),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: sources.map((e) {
              return OptionChip(
                text: e.name.tl,
                isSelected: searchTarget == e.key,
                onTap: () {
                  if (searchTarget == e.key) return;
                  setState(() {
                    searchTarget = e.key;
                    options = defaultSearchOptions(
                      e.searchPageData.searchOptions ?? [],
                    );
                  });
                },
              );
            }).toList(),
          ).fixWidth(double.infinity).paddingHorizontal(16),
          if (selected != null) buildSearchOptions(selected.searchPageData),
        ],
      ).fixWidth(double.infinity),
      actions: [
        FilledButton(
          onPressed: selected == null
              ? null
              : () => Navigator.of(context).pop((searchTarget, options)),
          child: Text('Confirm'.tl),
        ),
      ],
    );
  }

  Widget buildSearchOptions(SearchPageData data) {
    final loadTags = data.loadTags;
    if (loadTags != null) {
      return LibrarySearchTagFilter(
        key: ValueKey(searchTarget),
        loadTags: loadTags,
        selected: options,
        onChanged: (tags) => setState(() => options = tags),
      );
    }
    var children = <Widget>[];

    final searchOptions = data.searchOptions ?? <SearchOptions>[];
    options =
        validatedSearchOptions(searchOptions, options) ??
        defaultSearchOptions(searchOptions);
    if (searchOptions.isEmpty) {
      return const SizedBox();
    }
    for (int i = 0; i < searchOptions.length; i++) {
      final option = searchOptions[i];
      children.add(
        SearchOptionWidget(
          option: option,
          value: options[i],
          onChanged: (value) {
            setState(() {
              options[i] = value;
            });
          },
          sourceKey: searchTarget,
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}
