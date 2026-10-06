import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/navigation_bar.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/global_state.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/routing/page_jump_target.dart';
import 'package:venera_plus/routing/settings.dart';

import 'categories_page.dart';

class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key, this.initialSection = DiscoverySection.browse});

  final DiscoverySection initialSection;

  /// Derive source order: first occurrence among enabled explore pages,
  /// append category-only sources in configured order.
  /// All sources matching a page title are included in deterministic registry order.
  static List<ComicSource> deriveOrderedSources({
    required List<ComicSource> allSources,
    required List<String> enabledExplorePages,
    required List<String> enabledCategories,
  }) {
    final ordered = <ComicSource>[];

    // 1. First occurrence among enabled explore pages
    for (final pageTitle in enabledExplorePages) {
      for (final source in allSources) {
        if (source.explorePages.any((p) => p.title == pageTitle)) {
          if (!ordered.contains(source)) {
            ordered.add(source);
          }
        }
      }
    }

    // 2. Append category-only sources in configured order
    for (final catKey in enabledCategories) {
      for (final source in allSources) {
        if (source.categoryData?.key == catKey) {
          if (!ordered.contains(source)) {
            ordered.add(source);
          }
        }
      }
    }

    return ordered;
  }

  /// Preserve user configured explore pages order from settings for this source.
  static List<ExplorePageData> getEnabledExplorePagesForSource({
    required ComicSource source,
    required List<String> enabledExplorePages,
  }) {
    final result = <ExplorePageData>[];
    final seenTitles = <String>{};
    for (final pageTitle in enabledExplorePages) {
      if (seenTitles.contains(pageTitle)) continue;
      final page = source.explorePages.firstWhereOrNull(
        (p) => p.title == pageTitle,
      );
      if (page != null) {
        seenTitles.add(pageTitle);
        result.add(page);
      }
    }
    return result;
  }

  /// Check whether category is enabled for source.
  static bool hasEnabledCategoryForSource({
    required ComicSource source,
    required Iterable<String> enabledCategories,
  }) {
    final catKey = source.categoryData?.key;
    if (catKey == null) return false;
    return enabledCategories.contains(catKey);
  }

  /// Resolve initial source and section honoring startup requestedSection.
  static ({String? sourceKey, DiscoverySection section})
  resolveInitialSelection({
    required List<ComicSource> orderedSources,
    required List<String> enabledExplorePages,
    required List<String> enabledCategories,
    required DiscoverySection requestedSection,
    String? rememberedSourceKey,
  }) {
    if (orderedSources.isEmpty) {
      return (sourceKey: null, section: requestedSection);
    }

    final remSource = rememberedSourceKey != null
        ? orderedSources.firstWhereOrNull((s) => s.key == rememberedSourceKey)
        : null;

    final categoriesSet = enabledCategories.toSet();
    final exploreSet = enabledExplorePages.toSet();

    if (requestedSection == DiscoverySection.categories) {
      if (remSource != null &&
          hasEnabledCategoryForSource(
            source: remSource,
            enabledCategories: categoriesSet,
          )) {
        return (sourceKey: remSource.key, section: DiscoverySection.categories);
      }
      final firstCatSource = orderedSources.firstWhereOrNull(
        (s) => hasEnabledCategoryForSource(
          source: s,
          enabledCategories: categoriesSet,
        ),
      );
      if (firstCatSource != null) {
        return (
          sourceKey: firstCatSource.key,
          section: DiscoverySection.categories,
        );
      }
      final target = remSource ?? orderedSources.first;
      return (sourceKey: target.key, section: DiscoverySection.browse);
    } else {
      if (remSource != null &&
          remSource.explorePages.any((p) => exploreSet.contains(p.title))) {
        return (sourceKey: remSource.key, section: DiscoverySection.browse);
      }
      final firstBrowseSource = orderedSources.firstWhereOrNull(
        (s) => s.explorePages.any((p) => exploreSet.contains(p.title)),
      );
      if (firstBrowseSource != null) {
        return (
          sourceKey: firstBrowseSource.key,
          section: DiscoverySection.browse,
        );
      }
      final target = remSource ?? orderedSources.first;
      return (sourceKey: target.key, section: DiscoverySection.categories);
    }
  }

  /// Resolve section for a selected source.
  static DiscoverySection resolveSectionForSource({
    required ComicSource source,
    required List<String> enabledExplorePages,
    required List<String> enabledCategories,
    String? rememberedSectionName,
  }) {
    final categoriesSet = enabledCategories.toSet();
    final exploreSet = enabledExplorePages.toSet();

    final hasBrowse = source.explorePages.any(
      (p) => exploreSet.contains(p.title),
    );
    final hasCategories = hasEnabledCategoryForSource(
      source: source,
      enabledCategories: categoriesSet,
    );

    if (hasBrowse && hasCategories) {
      if (rememberedSectionName == DiscoverySection.categories.name) {
        return DiscoverySection.categories;
      }
      return DiscoverySection.browse;
    } else if (hasBrowse) {
      return DiscoverySection.browse;
    } else {
      return DiscoverySection.categories;
    }
  }

  /// Reconcile active source and section on source/settings changes.
  /// Preserves active section when capability remains valid; otherwise falls back.
  static ({String? sourceKey, DiscoverySection section}) reconcileSelection({
    required List<ComicSource> orderedSources,
    required List<String> enabledExplorePages,
    required List<String> enabledCategories,
    required String? currentSourceKey,
    required DiscoverySection currentSection,
    String? rememberedSourceKey,
    String? rememberedSectionName,
  }) {
    if (orderedSources.isEmpty) {
      return (sourceKey: null, section: currentSection);
    }

    final existingSource = orderedSources.firstWhereOrNull(
      (s) => s.key == currentSourceKey,
    );
    if (existingSource != null) {
      final exploreSet = enabledExplorePages.toSet();
      final categoriesSet = enabledCategories.toSet();
      final hasBrowse = existingSource.explorePages.any(
        (p) => exploreSet.contains(p.title),
      );
      final hasCategories = hasEnabledCategoryForSource(
        source: existingSource,
        enabledCategories: categoriesSet,
      );

      if (currentSection == DiscoverySection.browse && hasBrowse) {
        return (
          sourceKey: existingSource.key,
          section: DiscoverySection.browse,
        );
      } else if (currentSection == DiscoverySection.categories &&
          hasCategories) {
        return (
          sourceKey: existingSource.key,
          section: DiscoverySection.categories,
        );
      } else if (hasBrowse) {
        return (
          sourceKey: existingSource.key,
          section: DiscoverySection.browse,
        );
      } else {
        return (
          sourceKey: existingSource.key,
          section: DiscoverySection.categories,
        );
      }
    }

    final fallbackSource =
        (rememberedSourceKey != null
            ? orderedSources.firstWhereOrNull(
                (s) => s.key == rememberedSourceKey,
              )
            : null) ??
        orderedSources.first;

    final resolvedSection = resolveSectionForSource(
      source: fallbackSource,
      enabledExplorePages: enabledExplorePages,
      enabledCategories: enabledCategories,
      rememberedSectionName: rememberedSectionName,
    );

    return (sourceKey: fallbackSource.key, section: resolvedSection);
  }

  /// Purge visited view entries whose source was removed or whose section capability was disabled.
  static Set<({String sourceKey, DiscoverySection section})> purgeInvalidViews({
    required Set<({String sourceKey, DiscoverySection section})> visitedViews,
    required List<ComicSource> orderedSources,
    required List<String> enabledExplorePages,
    required List<String> enabledCategories,
  }) {
    final validSourceKeys = orderedSources.map((s) => s.key).toSet();
    final categoriesSet = enabledCategories.toSet();
    final exploreSet = enabledExplorePages.toSet();

    return visitedViews.where((item) {
      if (!validSourceKeys.contains(item.sourceKey)) return false;
      final s = orderedSources.firstWhereOrNull(
        (src) => src.key == item.sourceKey,
      );
      if (s == null) return false;
      if (item.section == DiscoverySection.browse) {
        return s.explorePages.any((p) => exploreSet.contains(p.title));
      }
      if (item.section == DiscoverySection.categories) {
        final catKey = s.categoryData?.key;
        return catKey != null && categoriesSet.contains(catKey);
      }
      return false;
    }).toSet();
  }

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage>
    with AutomaticKeepAliveClientMixin<ExplorePage> {
  List<ComicSource> orderedSources = [];
  String? currentSourceKey;
  DiscoverySection currentSection = DiscoverySection.browse;

  List<String> _enabledExplorePages = const [];
  List<String> _enabledCategories = const [];
  Set<String> _enabledExplorePagesSet = const {};
  Set<String> _enabledCategoriesSet = const {};

  /// Set of visited view typed identities: (sourceKey, section).
  /// Stored as typed identities; widgets are reconstructed in buildContentBody
  /// from current orderedSources and settings, allowing didUpdateWidget to fire
  /// on updates while preserving element states under stable ValueKeys.
  final Set<({String sourceKey, DiscoverySection section})> _visitedViews = {};
  bool showFB = true;
  double location = 0;
  NaviPaneState? naviPane;

  ComicSource? get currentSource {
    final key = currentSourceKey;
    if (key == null) return null;
    return orderedSources.firstWhereOrNull((s) => s.key == key);
  }

  void _loadSettingsData() {
    _enabledExplorePages =
        (appdata.settings["explore_pages"] as List?)
            ?.whereType<String>()
            .toList() ??
        const [];
    _enabledCategories =
        (appdata.settings["categories"] as List?)
            ?.whereType<String>()
            .toList() ??
        const [];
    _enabledExplorePagesSet = _enabledExplorePages.toSet();
    _enabledCategoriesSet = _enabledCategories.toSet();
  }

  bool _sourceHasBrowse(ComicSource source) {
    return source.explorePages.any(
      (p) => _enabledExplorePagesSet.contains(p.title),
    );
  }

  bool _sourceHasCategories(ComicSource source) {
    final catKey = source.categoryData?.key;
    return catKey != null && _enabledCategoriesSet.contains(catKey);
  }

  void _syncSourcesAndState({bool isInitial = false}) {
    _loadSettingsData();

    final newOrdered = ExplorePage.deriveOrderedSources(
      allSources: ComicSource.all(),
      enabledExplorePages: _enabledExplorePages,
      enabledCategories: _enabledCategories,
    );

    orderedSources = newOrdered;

    if (newOrdered.isEmpty) {
      currentSourceKey = null;
      _visitedViews.clear();
      return;
    }

    if (isInitial) {
      final rememberedSourceKey =
          appdata.implicitData['discovery_source'] as String?;
      final initialSelection = ExplorePage.resolveInitialSelection(
        orderedSources: newOrdered,
        enabledExplorePages: _enabledExplorePages,
        enabledCategories: _enabledCategories,
        requestedSection: widget.initialSection,
        rememberedSourceKey: rememberedSourceKey,
      );
      currentSourceKey = initialSelection.sourceKey;
      currentSection = initialSelection.section;

      // Persist canonical initial state so subsequent unrelated settings changes
      // do not flip requested section back to browse
      if (currentSourceKey != null) {
        appdata.implicitData['discovery_source'] = currentSourceKey;
        appdata.implicitData['discovery_section_$currentSourceKey'] =
            currentSection.name;
        appdata.writeImplicitData();
      }
    } else {
      final rememberedSourceKey =
          appdata.implicitData['discovery_source'] as String?;
      final rememberedSectionName = currentSourceKey != null
          ? appdata.implicitData['discovery_section_$currentSourceKey']
                as String?
          : null;

      final reconciled = ExplorePage.reconcileSelection(
        orderedSources: newOrdered,
        enabledExplorePages: _enabledExplorePages,
        enabledCategories: _enabledCategories,
        currentSourceKey: currentSourceKey,
        currentSection: currentSection,
        rememberedSourceKey: rememberedSourceKey,
        rememberedSectionName: rememberedSectionName,
      );
      currentSourceKey = reconciled.sourceKey;
      currentSection = reconciled.section;
    }

    final purged = ExplorePage.purgeInvalidViews(
      visitedViews: _visitedViews,
      orderedSources: newOrdered,
      enabledExplorePages: _enabledExplorePages,
      enabledCategories: _enabledCategories,
    );
    _visitedViews.clear();
    _visitedViews.addAll(purged);

    _recordActiveViewVisited();
  }

  void _recordActiveViewVisited() {
    final sKey = currentSourceKey;
    if (sKey != null) {
      _visitedViews.add((sourceKey: sKey, section: currentSection));
    }
  }

  void _onSettingsOrSourcesChanged() {
    if (!mounted) return;
    setState(() {
      _syncSourcesAndState();
    });
  }

  void selectSource(String sourceKey) {
    if (currentSourceKey == sourceKey) return;
    final source = orderedSources.firstWhereOrNull((s) => s.key == sourceKey);
    if (source == null) return;

    setState(() {
      currentSourceKey = sourceKey;
      appdata.implicitData['discovery_source'] = sourceKey;

      final rememberedSectionName =
          appdata.implicitData['discovery_section_$sourceKey'] as String?;
      currentSection = ExplorePage.resolveSectionForSource(
        source: source,
        enabledExplorePages: _enabledExplorePages,
        enabledCategories: _enabledCategories,
        rememberedSectionName: rememberedSectionName,
      );

      appdata.implicitData['discovery_section_$sourceKey'] =
          currentSection.name;
      appdata.writeImplicitData();

      _recordActiveViewVisited();
    });
  }

  void setSection(DiscoverySection section) {
    if (currentSection == section) return;
    final source = currentSource;
    if (source == null) return;

    setState(() {
      currentSection = section;
      appdata.implicitData['discovery_section_${source.key}'] = section.name;
      appdata.writeImplicitData();

      _recordActiveViewVisited();
    });
  }

  void onNaviItemTapped(int index) {
    if (index == 2 && naviPane?.currentPage == 2) {
      toTop();
    }
  }

  void toTop() {
    final source = currentSource;
    if (source == null) return;

    if (currentSection == DiscoverySection.browse) {
      GlobalState.findOrNull<_SourceBrowseViewState>(
        'browse:${source.key}',
      )?.toTop();
    } else {
      GlobalState.findOrNull<SourceCategoryViewState>(
        'category:${source.key}',
      )?.toTop();
    }
  }

  void refresh() {
    final source = currentSource;
    if (source == null) return;

    if (currentSection == DiscoverySection.browse) {
      GlobalState.findOrNull<_SourceBrowseViewState>(
        'browse:${source.key}',
      )?.refresh();
    } else {
      GlobalState.findOrNull<SourceCategoryViewState>(
        'category:${source.key}',
      )?.refresh();
    }
  }

  @override
  void initState() {
    super.initState();
    _syncSourcesAndState(isInitial: true);
    appdata.settings.addListener(_onSettingsOrSourcesChanged);
    ComicSourceManager().addListener(_onSettingsOrSourcesChanged);
    NaviPane.of(context).addNaviItemTapListener(onNaviItemTapped);
  }

  @override
  void didChangeDependencies() {
    naviPane = NaviPane.of(context);
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_onSettingsOrSourcesChanged);
    ComicSourceManager().removeListener(_onSettingsOrSourcesChanged);
    naviPane?.removeNaviItemTapListener(onNaviItemTapped);
    super.dispose();
  }

  void _showSourceSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Text("Comic Source".tl, style: ts.s18.bold),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(sheetContext),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final source in orderedSources) ...[
                      ListTile(
                        leading: const Icon(Icons.source_outlined),
                        title: Text(source.name),
                        subtitle: Text(
                          _getSourceCapabilitiesDesc(source),
                          style: ts.s12,
                        ),
                        trailing: source.key == currentSourceKey
                            ? Icon(
                                Icons.check,
                                color: context.colorScheme.primary,
                              )
                            : null,
                        selected: source.key == currentSourceKey,
                        onTap: () {
                          Navigator.pop(sheetContext);
                          selectSource(source.key);
                        },
                      ),
                    ],
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.extension_outlined),
                      title: Text("Manage Comic Sources".tl),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        context.to(() => ComicSourcePage());
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _getSourceCapabilitiesDesc(ComicSource source) {
    final hasBrowse = _sourceHasBrowse(source);
    final hasCategories = _sourceHasCategories(source);
    if (hasBrowse && hasCategories) {
      return "${"Browse".tl} / ${"Categories".tl}";
    } else if (hasBrowse) {
      return "Browse".tl;
    } else {
      return "Categories".tl;
    }
  }

  void _showManageChoices(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: Text("Manage".tl),
          children: [
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialogContext);
                showPopUpWidget(App.rootContext, setExplorePagesWidget());
              },
              child: Row(
                children: [
                  const Icon(Icons.tune),
                  const SizedBox(width: 12),
                  Text("Explore Pages".tl),
                ],
              ),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialogContext);
                showPopUpWidget(App.rootContext, setCategoryPagesWidget());
              },
              child: Row(
                children: [
                  const Icon(Icons.category_outlined),
                  const SizedBox(width: 12),
                  Text("Category Pages".tl),
                ],
              ),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialogContext);
                context.to(() => ComicSourcePage());
              },
              child: Row(
                children: [
                  const Icon(Icons.extension_outlined),
                  const SizedBox(width: 12),
                  Text("Manage Comic Sources".tl),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget buildEmptyNoSources() {
    return NetworkError(
      message: "${"No Comic Sources".tl}\n${"Please add some sources".tl}",
      retry: () {
        context.to(() => ComicSourcePage());
      },
      withAppbar: false,
      buttonText: "Manage Comic Sources".tl,
    );
  }

  Widget buildEmptyAllHidden() {
    return NetworkError(
      message: "${"All Pages Hidden".tl}\n${"Please check your settings".tl}",
      retry: () => _showManageChoices(context),
      withAppbar: false,
      buttonText: "Manage".tl,
    );
  }

  Widget buildTopBar(BuildContext context) {
    final source = currentSource!;
    final hasBrowse = _sourceHasBrowse(source);
    final hasCategories = _sourceHasCategories(source);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 380;

        final sourceSelector = Material(
          borderRadius: BorderRadius.circular(8),
          color: context.colorScheme.surfaceContainerHighest.toOpacity(0.6),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _showSourceSelector(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      source.name,
                      style: ts.s16.bold,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 20,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );

        final sectionSelector = (hasBrowse && hasCategories)
            ? SegmentedButton<DiscoverySection>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  ),
                ),
                segments: [
                  ButtonSegment<DiscoverySection>(
                    value: DiscoverySection.browse,
                    label: Text("Browse".tl),
                  ),
                  ButtonSegment<DiscoverySection>(
                    value: DiscoverySection.categories,
                    label: Text("Categories".tl),
                  ),
                ],
                selected: {currentSection},
                onSelectionChanged: (selected) {
                  setSection(selected.first);
                },
              )
            : null;

        final manageMenu = PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: "Manage".tl,
          onSelected: (action) {
            if (action == 'explore') {
              showPopUpWidget(App.rootContext, setExplorePagesWidget());
            } else if (action == 'categories') {
              showPopUpWidget(App.rootContext, setCategoryPagesWidget());
            } else if (action == 'sources') {
              context.to(() => ComicSourcePage());
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'explore',
              child: Row(
                children: [
                  const Icon(Icons.tune, size: 20),
                  const SizedBox(width: 12),
                  Text("Explore Pages".tl),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'categories',
              child: Row(
                children: [
                  const Icon(Icons.category_outlined, size: 20),
                  const SizedBox(width: 12),
                  Text("Category Pages".tl),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'sources',
              child: Row(
                children: [
                  const Icon(Icons.extension_outlined, size: 20),
                  const SizedBox(width: 12),
                  Text("Manage Comic Sources".tl),
                ],
              ),
            ),
          ],
        );

        if (isNarrow && sectionSelector != null) {
          return Container(
            padding: EdgeInsets.fromLTRB(12, context.padding.top + 4, 12, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: sourceSelector),
                    const SizedBox(width: 8),
                    manageMenu,
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(width: double.infinity, child: sectionSelector),
              ],
            ),
          );
        }

        return Container(
          padding: EdgeInsets.fromLTRB(12, context.padding.top + 4, 12, 4),
          child: Row(
            children: [
              Flexible(child: sourceSelector),
              if (sectionSelector != null) ...[
                const SizedBox(width: 8),
                sectionSelector,
              ],
              const Spacer(),
              manageMenu,
            ],
          ),
        );
      },
    );
  }

  Widget buildFAB() => Material(
    color: Colors.transparent,
    child: FloatingActionButton(
      key: const Key("FAB"),
      onPressed: refresh,
      child: const Icon(Icons.refresh),
    ),
  );

  Widget buildContentBody(BuildContext context) {
    final source = currentSource;
    if (source == null) {
      return Center(child: Text("Empty Page".tl));
    }

    _recordActiveViewVisited();

    final activeKey = (sourceKey: source.key, section: currentSection);

    final children = <Widget>[];
    for (final item in _visitedViews) {
      final itemSource = orderedSources.firstWhereOrNull(
        (s) => s.key == item.sourceKey,
      );
      if (itemSource == null) continue;

      final bool isActive = item == activeKey;

      Widget contentWidget;
      if (item.section == DiscoverySection.browse) {
        contentWidget = _SourceBrowseView(
          key: ValueKey('browse_view_${item.sourceKey}'),
          source: itemSource,
          enabledExplorePages: _enabledExplorePages,
        );
      } else {
        final catData = itemSource.categoryData;
        if (catData == null) continue;
        contentWidget = SourceCategoryView(
          key: ValueKey('category_view_${item.sourceKey}'),
          sourceKey: itemSource.key,
          data: catData,
        );
      }

      children.add(
        _buildOffstageView(
          key: ValueKey('offstage_${item.section.name}_${item.sourceKey}'),
          child: contentWidget,
          isActive: isActive,
        ),
      );
    }

    return Stack(fit: StackFit.expand, children: children);
  }

  Widget _buildOffstageView({
    required Key key,
    required Widget child,
    required bool isActive,
  }) {
    return Offstage(
      key: key,
      offstage: !isActive,
      child: TickerMode(
        enabled: isActive,
        child: ExcludeFocus(
          excluding: !isActive,
          child: HeroMode(enabled: isActive, child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (ComicSource.isEmpty) {
      return Material(child: buildEmptyNoSources());
    }

    if (orderedSources.isEmpty || currentSourceKey == null) {
      return Material(child: buildEmptyAllHidden());
    }

    return Material(
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                buildTopBar(context),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notifications) {
                      if (notifications.metrics.axis == Axis.horizontal) {
                        if (!showFB) {
                          setState(() {
                            showFB = true;
                          });
                        }
                        return true;
                      }

                      var current = notifications.metrics.pixels;
                      var overflow = notifications.metrics.outOfRange;
                      if (current > location && current != 0 && showFB) {
                        setState(() {
                          showFB = false;
                        });
                      } else if ((current < location - 50 || current == 0) &&
                          !showFB) {
                        setState(() {
                          showFB = true;
                        });
                      }
                      if ((current > location || current < location - 50) &&
                          !overflow) {
                        location = current;
                      }
                      return false;
                    },
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: buildContentBody(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              reverseDuration: const Duration(milliseconds: 150),
              child: showFB ? buildFAB() : const SizedBox(),
              transitionBuilder: (widget, animation) {
                var tween = Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: const Offset(0, 0),
                );
                return SlideTransition(
                  position: tween.animate(animation),
                  child: widget,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

/// Dedicated browsing view for a single comic source with its own TabController.
class _SourceBrowseView extends StatefulWidget {
  const _SourceBrowseView({
    required this.source,
    required this.enabledExplorePages,
    super.key,
  });

  final ComicSource source;
  final List<String> enabledExplorePages;

  @override
  State<_SourceBrowseView> createState() => _SourceBrowseViewState();
}

class _SourceBrowseViewState extends AutomaticGlobalState<_SourceBrowseView>
    with
        TickerProviderStateMixin,
        AutomaticKeepAliveClientMixin<_SourceBrowseView> {
  @override
  Object? get key => 'browse:${widget.source.key}';

  TabController? _tabController;
  List<ExplorePageData> _pages = const [];

  void _syncPagesAndController() {
    String? activeTitle;
    if (_tabController != null &&
        _tabController!.index >= 0 &&
        _tabController!.index < _pages.length) {
      activeTitle = _pages[_tabController!.index].title;
    } else if (_pages.isNotEmpty) {
      activeTitle = _pages.first.title;
    }

    if (activeTitle == null) {
      final saved = appdata.implicitData['discovery_page_${widget.source.key}'];
      if (saved is String) {
        activeTitle = saved;
      }
    }

    _pages = ExplorePage.getEnabledExplorePagesForSource(
      source: widget.source,
      enabledExplorePages: widget.enabledExplorePages,
    );

    if (_pages.isEmpty) {
      _disposeTabController();
      return;
    }

    int initialIndex = 0;
    if (activeTitle != null) {
      final idx = _pages.indexWhere((p) => p.title == activeTitle);
      if (idx != -1) {
        initialIndex = idx;
      }
    }

    final chosenTitle = _pages[initialIndex].title;
    final storageKey = 'discovery_page_${widget.source.key}';
    if (appdata.implicitData[storageKey] != chosenTitle) {
      appdata.implicitData[storageKey] = chosenTitle;
      appdata.writeImplicitData();
    }

    if (_pages.length > 1) {
      if (_tabController == null || _tabController!.length != _pages.length) {
        _disposeTabController();
        _tabController = TabController(
          length: _pages.length,
          initialIndex: initialIndex,
          vsync: this,
        );
        _tabController!.addListener(_onTabChanged);
      } else if (_tabController!.index != initialIndex) {
        _tabController!.index = initialIndex;
      }
    } else {
      _disposeTabController();
    }
  }

  void _onTabChanged() {
    final controller = _tabController;
    if (controller != null && !controller.indexIsChanging) {
      if (controller.index >= 0 && controller.index < _pages.length) {
        appdata.implicitData['discovery_page_${widget.source.key}'] =
            _pages[controller.index].title;
        appdata.writeImplicitData();
      }
    }
  }

  void _disposeTabController() {
    _tabController?.removeListener(_onTabChanged);
    _tabController?.dispose();
    _tabController = null;
  }

  void toTop() {
    if (_pages.isEmpty) return;
    final int pageIdx = _tabController?.index ?? 0;
    if (pageIdx >= 0 && pageIdx < _pages.length) {
      final pageTitle = _pages[pageIdx].title;
      GlobalState.findOrNull<_SingleExplorePageState>(
        '${widget.source.key}:$pageTitle',
      )?.toTop();
    }
  }

  @override
  void refresh() {
    if (_pages.isEmpty) return;
    final int pageIdx = _tabController?.index ?? 0;
    if (pageIdx >= 0 && pageIdx < _pages.length) {
      final pageTitle = _pages[pageIdx].title;
      GlobalState.findOrNull<_SingleExplorePageState>(
        '${widget.source.key}:$pageTitle',
      )?.refresh();
    }
  }

  @override
  void initState() {
    super.initState();
    _syncPagesAndController();
  }

  @override
  void didUpdateWidget(covariant _SourceBrowseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.enabledExplorePages != widget.enabledExplorePages) {
      setState(() {
        _syncPagesAndController();
      });
    }
  }

  @override
  void dispose() {
    _disposeTabController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_pages.isEmpty) {
      return Center(child: Text("Empty Page".tl));
    }

    if (_pages.length == 1) {
      return _SingleExplorePage(
        sourceKey: widget.source.key,
        title: _pages.first.title,
        key: PageStorageKey('${widget.source.key}:${_pages.first.title}'),
      );
    }

    return Column(
      children: [
        Material(
          child: AppTabBar(
            key: ValueKey('${widget.source.key}_tabs_${_pages.length}'),
            controller: _tabController,
            tabs: _pages
                .map(
                  (p) => Tab(
                    text: p.title.ts(widget.source.key),
                    key: Key('${widget.source.key}:${p.title}'),
                  ),
                )
                .toList(),
            actionButton: TabActionButton(
              icon: const Icon(Icons.add),
              text: "Add".tl,
              onPressed: () {
                showPopUpWidget(App.rootContext, setExplorePagesWidget());
              },
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _pages
                .map(
                  (p) => _SingleExplorePage(
                    sourceKey: widget.source.key,
                    title: p.title,
                    key: PageStorageKey('${widget.source.key}:${p.title}'),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _SingleExplorePage extends StatefulWidget {
  const _SingleExplorePage({
    required this.sourceKey,
    required this.title,
    super.key,
  });

  final String sourceKey;
  final String title;

  @override
  State<_SingleExplorePage> createState() => _SingleExplorePageState();
}

class _SingleExplorePageState extends AutomaticGlobalState<_SingleExplorePage>
    with AutomaticKeepAliveClientMixin<_SingleExplorePage> {
  ExplorePageData? data;
  String? comicSourceKey;

  bool _wantKeepAlive = true;
  final ScrollController scrollController = ScrollController();
  VoidCallback? refreshHandler;
  VoidCallback? reloadHandler;

  @override
  Object? get key => '${widget.sourceKey}:${widget.title}';

  void onDataChanged() {
    reloadHandler?.call();
  }

  void onSettingsChanged() {
    final explorePages =
        (appdata.settings["explore_pages"] as List?)
            ?.whereType<String>()
            .toList() ??
        const [];
    if (!explorePages.contains(widget.title)) {
      _wantKeepAlive = false;
      updateKeepAlive();
    }
  }

  void _bindSourceData() {
    final oldData = data;
    final source =
        ComicSource.find(widget.sourceKey) ??
        ComicSource.all().firstWhereOrNull((s) => s.key == widget.sourceKey);
    ExplorePageData? newData;
    if (source != null) {
      newData = source.explorePages.firstWhereOrNull(
        (d) => d.title == widget.title,
      );
    }
    if (oldData != newData) {
      oldData?.changeListenable?.removeListener(onDataChanged);
      data = newData;
      comicSourceKey = source?.key;
      newData?.changeListenable?.addListener(onDataChanged);
      refreshHandler = null;
      reloadHandler = null;
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _onSourcesManagerChanged() {
    _bindSourceData();
  }

  @override
  void initState() {
    super.initState();
    _bindSourceData();
    appdata.settings.addListener(onSettingsChanged);
    ComicSourceManager().addListener(_onSourcesManagerChanged);
  }

  @override
  void didUpdateWidget(covariant _SingleExplorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey ||
        oldWidget.title != widget.title) {
      _bindSourceData();
    }
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    ComicSourceManager().removeListener(_onSourcesManagerChanged);
    data?.changeListenable?.removeListener(onDataChanged);
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final currentData = data;
    if (currentData == null) {
      return Center(child: Text("Empty Page".tl));
    }

    final childStorageKey = PageStorageKey(currentData);

    if (currentData.loadMultiPart != null) {
      return _MultiPartExplorePage(
        key: childStorageKey,
        data: currentData,
        controller: scrollController,
        comicSourceKey: comicSourceKey ?? widget.sourceKey,
        refreshHandlerCallback: (c) {
          refreshHandler = c;
        },
      );
    } else if (currentData.loadPage != null || currentData.loadNext != null) {
      return ComicList(
        enablePageStorage: true,
        loadPage: currentData.loadPage,
        loadNext: currentData.loadNext,
        key: childStorageKey,
        controller: scrollController,
        refreshHandlerCallback: (c) {
          refreshHandler = c;
        },
        reloadHandlerCallback: (c) {
          reloadHandler = c;
        },
      );
    } else if (currentData.loadMixed != null) {
      return _MixedExplorePage(
        currentData,
        comicSourceKey ?? widget.sourceKey,
        key: childStorageKey,
        controller: scrollController,
        refreshHandlerCallback: (c) {
          refreshHandler = c;
        },
      );
    } else {
      return Center(child: Text("Empty Page".tl));
    }
  }

  @override
  void refresh() {
    final currentData = data;
    if (currentData == null) return;
    final onRefresh = currentData.onRefresh;
    if (onRefresh == null) {
      refreshHandler?.call();
      return;
    }
    unawaited(
      onRefresh().whenComplete(() {
        if (mounted && identical(data, currentData)) {
          reloadHandler?.call();
        }
      }),
    );
  }

  @override
  bool get wantKeepAlive => _wantKeepAlive;

  void toTop() {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }
}

class _MixedExplorePage extends StatefulWidget {
  const _MixedExplorePage(
    this.data,
    this.sourceKey, {
    super.key,
    this.controller,
    required this.refreshHandlerCallback,
  });

  final ExplorePageData data;
  final String sourceKey;
  final ScrollController? controller;
  final void Function(VoidCallback c) refreshHandlerCallback;

  @override
  State<_MixedExplorePage> createState() => _MixedExplorePageState();
}

class _MixedExplorePageState
    extends MultiPageLoadingState<_MixedExplorePage, Object> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.refreshHandlerCallback(refresh);
  }

  @override
  void didUpdateWidget(covariant _MixedExplorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.refreshHandlerCallback(refresh);
    if (oldWidget.data != widget.data) {
      reset();
    }
  }

  void refresh() {
    reset();
  }

  Iterable<Widget> buildSlivers(BuildContext context, List<Object> data) sync* {
    List<Comic> cache = [];
    for (var part in data) {
      if (part is ExplorePagePart) {
        if (cache.isNotEmpty) {
          yield SliverGridComics(comics: (cache));
          yield const SliverToBoxAdapter(child: Divider());
          cache.clear();
        }
        yield* _buildExplorePagePart(part, widget.sourceKey);
        yield const SliverToBoxAdapter(child: Divider());
      } else {
        cache.addAll(part as List<Comic>);
      }
    }
    if (cache.isNotEmpty) {
      yield SliverGridComics(comics: (cache));
    }
  }

  @override
  Widget buildContent(BuildContext context, List<Object> data) {
    return SmoothCustomScrollView(
      controller: widget.controller,
      slivers: [
        ...buildSlivers(context, data),
        const SliverListLoadingIndicator(),
      ],
    );
  }

  @override
  Future<Res<List<Object>>> loadData(int page) async {
    var res = await widget.data.loadMixed!(page);
    if (res.error) {
      return res;
    }
    for (var element in res.data) {
      if (element is! ExplorePagePart && element is! List<Comic>) {
        return const Res.error("function loadMixed return invalid data");
      }
    }
    return res;
  }
}

Iterable<Widget> _buildExplorePagePart(
  ExplorePagePart part,
  String sourceKey,
) sync* {
  Widget buildTitle(ExplorePagePart part) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
          child: Row(
            children: [
              Text(
                part.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              if (part.viewMore != null)
                TextButton(
                  onPressed: () {
                    var context = App.mainNavigatorKey!.currentContext!;
                    part.viewMore!.jump(context);
                  },
                  child: Text("View more".tl),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildComics(ExplorePagePart part) {
    return SliverGridComics(comics: part.comics);
  }

  yield buildTitle(part);
  yield buildComics(part);
}

class _MultiPartExplorePage extends StatefulWidget {
  const _MultiPartExplorePage({
    super.key,
    required this.data,
    required this.controller,
    required this.comicSourceKey,
    required this.refreshHandlerCallback,
  });

  final ExplorePageData data;
  final ScrollController controller;
  final String comicSourceKey;
  final void Function(VoidCallback c) refreshHandlerCallback;

  @override
  State<_MultiPartExplorePage> createState() => _MultiPartExplorePageState();
}

class _MultiPartExplorePageState extends State<_MultiPartExplorePage> {
  List<ExplorePagePart>? parts;
  bool loading = true;
  bool _inFlight = false;
  String? message;

  Map<String, dynamic> get state => {
    "loading": loading,
    "message": message,
    "parts": parts,
  };

  void restoreState(dynamic state) {
    if (state == null) return;
    loading = state["loading"] ?? true;
    message = state["message"];
    parts = state["parts"];
  }

  void storeState() {
    PageStorage.of(context).writeState(context, state);
  }

  void refresh() {
    if (!mounted) return;
    setState(() {
      loading = true;
      message = null;
      parts = null;
    });
    storeState();
    _fetch();
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    restoreState(PageStorage.of(context).readState(context));
    widget.refreshHandlerCallback(refresh);
    if (loading && parts == null && message == null) {
      _fetch();
    }
  }

  @override
  void didUpdateWidget(covariant _MultiPartExplorePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.refreshHandlerCallback(refresh);
    if (oldWidget.data != widget.data) {
      refresh();
    }
  }

  void _fetch() async {
    if (_inFlight) return;
    _inFlight = true;
    final loadFunc = widget.data.loadMultiPart;
    if (loadFunc == null) {
      _inFlight = false;
      return;
    }
    final expectedData = widget.data;
    final res = await loadFunc();
    _inFlight = false;
    if (mounted && identical(widget.data, expectedData)) {
      setState(() {
        loading = false;
        if (res.error) {
          message = res.errorMessage;
        } else {
          parts = res.data;
        }
      });
      storeState();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    } else if (message != null) {
      return NetworkError(message: message!, retry: refresh, withAppbar: false);
    } else {
      return buildPage();
    }
  }

  Widget buildPage() {
    return SmoothCustomScrollView(
      key: const PageStorageKey('scroll'),
      controller: widget.controller,
      slivers: _buildPage().toList(),
    );
  }

  Iterable<Widget> _buildPage() sync* {
    for (var part in parts!) {
      yield* _buildExplorePagePart(part, widget.comicSourceKey);
    }
  }
}
