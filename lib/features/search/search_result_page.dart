import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/select.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/global_state.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/foundation/search_history.dart';

import 'search_filter.dart';
import 'search_page.dart';
import 'search_options.dart';

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
  late _SuggestionsController suggestionsController;
  int _initialPage = 1;
  int _revision = 0;
  Timer? _historyTimer;
  SearchHistoryEntry? _pendingHistory;
  GlobalKey<ComicListState> _listKey = GlobalKey<ComicListState>();

  OverlayEntry? get suggestionOverlay => suggestionsController.entry;

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
    final source = ComicSource.find(sourceKey);
    if (source?.searchPageData == null) return null;
    return SearchHistoryEntry(
      keyword: text,
      sourceKey: sourceKey,
      sourceName: source!.name,
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
      text = _applyConfiguredLanguageFilter(value);
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
          top: context.padding.top + 56,
          left: 0,
          right: 0,
          bottom: 0,
          child: Material(
            child: _Suggestions(controller: suggestionsController),
          ),
        ),
      );
      Overlay.of(context).insert(suggestionOverlay!);
    }
  }

  @override
  void dispose() {
    _revision++;
    _flushHistory();
    ComicSourceManager().removeListener(_sourcesChanged);
    Future.microtask(suggestionsController.remove);
    super.dispose();
  }

  void _sourcesChanged() {
    if (ComicSource.find(sourceKey)?.searchPageData == null) {
      _listKey.currentState?.cancelPendingLoads();
    }
    if (mounted) setState(() {});
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
    text = widget.historyEntry == null
        ? _applyConfiguredLanguageFilter(widget.text)
        : widget.historyEntry!.keyword;
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
    ComicSourceManager().addListener(_sourcesChanged);
    _remember();
  }

  bool validateOptions() {
    final data = ComicSource.find(sourceKey)?.searchPageData;
    if (data == null) return false;
    final definitions = data.searchOptions ?? [];
    final valid = validatedSearchOptions(definitions, options);
    options = valid ?? defaultSearchOptions(definitions);
    return valid == null;
  }

  @override
  Widget build(BuildContext context) {
    final source = ComicSource.find(sourceKey);
    if (source?.searchPageData == null) {
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
    final keyword = text;
    final selectedOptions = List<String>.unmodifiable(options);
    final entry = _entry();
    final revision = _revision;
    final data = source!.searchPageData!;
    return Scaffold(
      body: ComicList(
        onTap: widget.onComicTap == null
            ? null
            : (comic, _) => widget.onComicTap!(comic),
        key: _listKey,
        initialPage: _initialPage,
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
      final previousOptions = List<String>.of(options);
      final previousSourceKey = sourceKey;
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (context) => _SearchSettingsDialog(state: this),
      );
      if (!mounted) return;
      if (!previousOptions.isEqualTo(options) ||
          previousSourceKey != sourceKey) {
        _listKey.currentState?.cancelPendingLoads();
        _listKey = GlobalKey<ComicListState>();
        _flushHistory();
        text = _applyConfiguredLanguageFilter(
          ComicSource.find(previousSourceKey)?.searchPageData == null
              ? text
              : controller.text,
        );
        controller.currentText = text;
        suggestionsController = _SuggestionsController(controller, sourceKey);
        validateOptions();
        _initialPage = 1;
        _revision++;
        _remember();
        setState(() {});
      }
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
    entry?.remove();
    entry = null;
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

  void onChanged() {
    widget.state.sourceKey = searchTarget;
    widget.state.options = options;
  }

  @override
  Widget build(BuildContext context) {
    var sources = ComicSource.all();
    final enabled =
        (appdata.settings['searchSources'] as List?) ??
        sources
            .where((source) => source.searchPageData != null)
            .map((source) => source.key)
            .toList();
    sources.removeWhere(
      (e) => e.searchPageData == null || !enabled.contains(e.key),
    );
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
                  setState(() {
                    searchTarget = e.key;
                    options = [];
                    final searchOptions =
                        ComicSource.find(
                          searchTarget,
                        )!.searchPageData!.searchOptions ??
                        <SearchOptions>[];
                    options = defaultSearchOptions(searchOptions);
                  });
                },
              );
            }).toList(),
          ).fixWidth(double.infinity).paddingHorizontal(16),
          buildSearchOptions(),
          const SizedBox(height: 24),
          FilledButton(
            child: Text("Confirm".tl),
            onPressed: () {
              onChanged();
              context.pop();
            },
          ),
        ],
      ).fixWidth(double.infinity),
    );
  }

  Widget buildSearchOptions() {
    var children = <Widget>[];

    final searchOptions =
        ComicSource.find(searchTarget)?.searchPageData?.searchOptions ??
        <SearchOptions>[];
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
