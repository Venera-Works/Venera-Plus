import 'package:venera_plus/foundation/appdata.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/flyout.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/routing/bangumi_comic_navigation.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.isRoot = false, this.isActive = true});

  final bool isRoot;
  final bool isActive;
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  ModalRoute<dynamic>? _route;
  bool _tickerModeEnabled = true;
  bool _needsRefresh = true;
  Object? _bindings;
  List<String> _blockedWords = [];

  bool get _isVisible =>
      widget.isActive && _tickerModeEnabled && (_route?.isCurrent ?? true);

  @override
  void initState() {
    HistoryManager().addListener(onUpdate);
    _bindings = appdata.settings['bangumiBindings'];
    appdata.settings.addListener(_onSettingsChanged);
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    // A reader on the root navigator also covers the library's nested route.
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _refreshIfVisible();
  }

  @override
  void didUpdateWidget(covariant HistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshIfVisible();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    appdata.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    final bindings = appdata.settings['bangumiBindings'];
    if (!identical(bindings, _bindings)) {
      _bindings = bindings;
      selectedComics.clear();
      multiSelectMode = false;
      _needsRefresh = true;
    } else if (listEquals(
      _blockedWords,
      appdata.settings['blockedWords'] as List,
    )) {
      return;
    }
    if (_isVisible) setState(_refreshIfVisible);
  }

  void onUpdate() {
    _needsRefresh = true;
    // Reading progress changes during a swipe. Query only when this tab and
    // its route are visible again, coalescing all intervening notifications.
    if (_isVisible) setState(_refreshIfVisible);
  }

  void _refreshIfVisible() {
    if (!_isVisible) return;
    final words = appdata.settings['blockedWords'] as List;
    if (!_needsRefresh && listEquals(_blockedWords, words)) return;
    if (_needsRefresh) {
      comics = groupBangumiComics(
        HistoryManager().getAll(),
        lastRead: (history) => history.time,
      );
      _needsRefresh = false;
    }
    _blockedWords = List<String>.from(words);
    visibleComics = comics.where((comic) => isBlocked(comic) == null).toList();
    if (multiSelectMode) {
      final previousSelections = {
        for (final group in selectedComics.keys) group.groupKey: group,
      };
      selectedComics = {
        for (final group in visibleComics)
          if (previousSelections[group.groupKey] case final previous?)
            if (previous.members.length == group.members.length &&
                previous.members.toSet().containsAll(group.members))
              group: true,
      };
      if (selectedComics.isEmpty) {
        multiSelectMode = false;
      }
    }
  }

  List<BangumiComicGroup<History>> comics = [];
  List<BangumiComicGroup<History>> visibleComics = [];
  var controller = FlyoutController();

  bool multiSelectMode = false;
  Map<BangumiComicGroup<History>, bool> selectedComics = {};

  void selectAll() {
    setState(() {
      selectedComics = {for (final comic in visibleComics) comic: true};
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      selectedComics = {
        for (final comic in visibleComics)
          if (!selectedComics.containsKey(comic)) comic: true,
      };
    });
  }

  void _removeHistories(Iterable<History> histories) {
    HistoryManager().batchDeleteHistories([
      for (final history in histories) ComicID(history.type, history.id),
    ]);
  }

  void _removeSourceHistory(BangumiComicGroup<History> group) async {
    final source = await selectBangumiComicSource(
      context,
      group,
      alwaysChoose: true,
      allowUnavailable: true,
    );
    if (source is History && mounted) {
      HistoryManager().remove(source.id, source.type);
    }
  }

  void _refreshHistory(BangumiComicGroup<History> group) async {
    final source = await selectBangumiComicSource(
      context,
      group,
      alwaysChoose: true,
    );
    if (source is! History || !mounted) return;
    var result = await HistoryManager().refreshHistoryInfo(source);
    if (result) {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Success".tl);
      }
    } else {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Failed".tl);
      }
    }
  }

  void _refreshAllHistories() async {
    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Refreshing Histories".tl,
    );

    int success = 0;
    int failed = 0;
    int skipped = 0;

    await for (var progress in HistoryManager().refreshAllHistoriesStream()) {
      if (isCanceled) {
        return;
      }
      if (progress.total > 0) {
        loadingController.setProgress(progress.current / progress.total);
      }
      success = progress.success;
      failed = progress.failed;
      skipped = progress.skipped;
    }

    loadingController.close();

    if (mounted) {
      App.rootContext.showMessage(
        message:
            "Refresh Completed: Success @success, Failed @failed, Skipped @skipped"
                .tlParams({
                  'success': success,
                  'failed': failed,
                  'skipped': skipped,
                }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () {
                final comicsToDelete = selectedComics.keys
                    .expand((group) => group.members)
                    .toList();
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });

                _removeHistories(comicsToDelete);
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.query_stats),
        tooltip: 'Reading statistics'.tl,
        onPressed: () => context.to(() => const ReadingStatsPage()),
      ),
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              content: Text('Are you sure you want to clear your history?'.tl),
              actions: [
                Button.outlined(
                  onPressed: () {
                    HistoryManager().clearUnfavoritedHistory();
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    HistoryManager().clearHistory();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    final canPopScope = widget.isActive ? !multiSelectMode : true;
    return PopScope(
      canPop: canPopScope,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !widget.isActive) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              leading: multiSelectMode
                  ? Tooltip(
                      message: "Cancel".tl,
                      child: IconButton(
                        onPressed: () {
                          setState(() {
                            multiSelectMode = false;
                            selectedComics.clear();
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
                    )
                  : (widget.isRoot
                        ? const SizedBox.shrink()
                        : (context.canPop()
                              ? Tooltip(
                                  message: "Back".tl,
                                  child: IconButton(
                                    onPressed: () {
                                      context.pop();
                                    },
                                    icon: const Icon(Icons.arrow_back),
                                  ),
                                )
                              : const SizedBox.shrink())),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text('Reading Records'.tl),
              actions: multiSelectMode ? selectActions : normalActions,
            ),
            SliverGridComics(
              comics: visibleComics,
              selections: selectedComics,
              onLongPressed: null,
              onTap: (c, heroID) {
                final group = c as BangumiComicGroup<History>;
                if (!multiSelectMode) {
                  openBangumiComic(context, group, read: false, heroID: heroID);
                  return;
                }
                setState(() {
                  if (selectedComics.containsKey(group)) {
                    selectedComics.remove(group);
                  } else {
                    selectedComics[group] = true;
                  }
                  if (selectedComics.isEmpty) {
                    multiSelectMode = false;
                  }
                });
              },
              badgeBuilder: (c) {
                final group = c as BangumiComicGroup<History>;
                if (group.members.length > 1) {
                  return '@count sources'.tlParams({
                    'count': group.members.length,
                  });
                }
                return c.sourceKey == 'local'
                    ? 'Local'.tl
                    : ComicSource.find(c.sourceKey)?.name ?? c.sourceKey;
              },
              menuBuilder: (c) {
                final group = c as BangumiComicGroup<History>;
                return [
                  MenuEntry(
                    icon: Icons.play_arrow,
                    text: 'Continue'.tl,
                    onClick: () => openBangumiComic(context, group, read: true),
                  ),
                  if (group.members.length > 1)
                    MenuEntry(
                      icon: Icons.swap_horiz,
                      text: 'Choose comic source'.tl,
                      onClick: () => openBangumiComic(
                        context,
                        group,
                        read: true,
                        chooseSource: true,
                      ),
                    ),
                  MenuEntry(
                    icon: Icons.refresh,
                    text: 'Refresh Info'.tl,
                    onClick: () => _refreshHistory(group),
                  ),
                  MenuEntry(
                    icon: Icons.remove,
                    text: 'Remove work history'.tl,
                    color: context.colorScheme.error,
                    onClick: () => _removeHistories(group.members),
                  ),
                  if (group.members.length > 1)
                    MenuEntry(
                      icon: Icons.remove_circle_outline,
                      text: 'Remove source history'.tl,
                      color: context.colorScheme.error,
                      onClick: () => _removeSourceHistory(group),
                    ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }

  String getDescription(History h) => h.progressDescription(
    showTotals: appdata.settings['showDetailedReadingProgress'] == true,
  );
}
