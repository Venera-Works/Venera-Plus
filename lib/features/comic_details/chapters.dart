import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class ComicChaptersView extends StatelessWidget {
  const ComicChaptersView({
    super.key,
    required this.chapters,
    this.pageCounts = const {},
    this.chapterGroups = const {},
    this.history,
    required this.readChapter,
  });

  final ComicChapters chapters;

  final Map<String, int> pageCounts;

  final Map<String, String> chapterGroups;

  final History? history;

  final void Function(int chapter, int? group)? readChapter;

  @override
  Widget build(BuildContext context) {
    if (!chapters.isGrouped && chapterGroups.isNotEmpty) {
      final groups = <String, Map<String, String>>{};
      final chapterIndices = <String, int>{};
      String? currentGroup;
      var chapterIndex = 0;
      for (final id in chapters.ids) {
        final group = chapterGroups[id] ?? 'Chapters'.tl;
        final title = chapters[id]!;
        (groups[group] ??= {})[id] = title.startsWith('$group/')
            ? title.substring(group.length + 1)
            : title;
        chapterIndices[id] = ++chapterIndex;
        if (history?.group == null && history?.ep == chapterIndex) {
          currentGroup = group;
        }
      }
      return _GroupedComicChapters(
        chapters: ComicChapters.grouped(groups),
        chapterIndices: chapterIndices,
        pageCounts: pageCounts,
        history: history,
        initialGroup: currentGroup == null
            ? 1
            : groups.keys.toList().indexOf(currentGroup) + 1,
        readChapter: readChapter == null
            ? null
            : (chapter, group) {
                final id = groups.values
                    .elementAt(group! - 1)
                    .keys
                    .elementAt(chapter - 1);
                readChapter!(chapterIndices[id]!, null);
              },
      );
    }
    return chapters.isGrouped
        ? _GroupedComicChapters(
            chapters: chapters,
            pageCounts: pageCounts,
            history: history,
            readChapter: readChapter,
          )
        : _NormalComicChapters(
            chapters: chapters,
            pageCounts: pageCounts,
            history: history,
            readChapter: readChapter,
          );
  }
}

class _NormalComicChapters extends StatefulWidget {
  const _NormalComicChapters({
    required this.chapters,
    required this.pageCounts,
    this.history,
    required this.readChapter,
  });

  final ComicChapters chapters;

  final Map<String, int> pageCounts;

  final History? history;

  final void Function(int chapter, int? group)? readChapter;

  @override
  State<_NormalComicChapters> createState() => _NormalComicChaptersState();
}

class _NormalComicChaptersState extends State<_NormalComicChapters> {
  late bool reverse;

  bool showAll = false;

  late History? history;

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    history = widget.history;
  }

  @override
  void didUpdateWidget(covariant _NormalComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    setState(() {
      history = widget.history;
    });
  }

  void setReverse(bool value) {
    if (reverse == value) return;
    setState(() {
      reverse = value;
    });
    appdata.settings["reverseChapterOrder"] = value;
    appdata.saveData();
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.chapters;
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        int length = chapters.length;
        bool canShowAll = showAll;
        if (!showAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == chapters.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: ListTile(
                title: Text("Chapters".tl),
                trailing: _ChapterOrderSegment(
                  reverse: reverse,
                  onChanged: setReverse,
                ),
              ),
            ),
            SliverGrid(
              delegate: SliverChildBuilderDelegate((context, i) {
                if (reverse) {
                  i = chapters.length - i - 1;
                }
                var key = chapters.ids.elementAt(i);
                var value = chapters[key]!;
                bool visited = (history?.readEpisode ?? {}).contains(i + 1);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: Material(
                    color: context.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    child: ClickInkWell(
                      onTap: widget.readChapter == null
                          ? null
                          : () => widget.readChapter!(i + 1, null),
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: _ChapterLabel(
                            title: value,
                            pageCount: widget.pageCounts[key],
                            visited: visited,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }, childCount: length),
              gridDelegate: SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 250,
                itemHeight: _chapterGridHeight(
                  context,
                  chapters.ids,
                  widget.pageCounts,
                ),
              ),
            ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${chapters.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverToBoxAdapter(child: Divider()),
          ],
        );
      },
    );
  }
}

class _GroupedComicChapters extends StatefulWidget {
  const _GroupedComicChapters({
    required this.chapters,
    required this.pageCounts,
    this.initialGroup,
    this.history,
    this.chapterIndices,
    required this.readChapter,
  });

  final int? initialGroup;

  final ComicChapters chapters;

  final Map<String, int> pageCounts;
  final Map<String, int>? chapterIndices;
  final History? history;

  final void Function(int chapter, int? group)? readChapter;

  @override
  State<_GroupedComicChapters> createState() => _GroupedComicChaptersState();
}

class _GroupedComicChaptersState extends State<_GroupedComicChapters>
    with TickerProviderStateMixin {
  late bool reverse;

  bool showAll = false;

  late History? history;

  late TabController tabController;

  late int index;

  @override
  void initState() {
    super.initState();
    reverse = appdata.settings["reverseChapterOrder"] ?? false;
    history = widget.history;
    index = ((widget.initialGroup ?? history?.group ?? 1) - 1).clamp(
      0,
      math.max(0, widget.chapters.groupCount - 1),
    );
    _createTabController();
  }

  void _createTabController() {
    tabController = TabController(
      initialIndex: index,
      length: widget.chapters.groupCount,
      vsync: this,
    );
    tabController.addListener(onTabChange);
  }

  void onTabChange() {
    if (index != tabController.index) {
      setState(() {
        index = tabController.index;
      });
    }
  }

  @override
  void didUpdateWidget(covariant _GroupedComicChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    history = widget.history;
    if (tabController.length != widget.chapters.groupCount) {
      tabController.removeListener(onTabChange);
      tabController.dispose();
      index = index.clamp(0, math.max(0, widget.chapters.groupCount - 1));
      _createTabController();
    }
  }

  void setReverse(bool value) {
    if (reverse == value) return;
    setState(() {
      reverse = value;
    });
    appdata.settings["reverseChapterOrder"] = value;
    appdata.saveData();
  }

  @override
  void dispose() {
    tabController.removeListener(onTabChange);
    tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.chapters;
    if (chapters.groupCount == 0) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverLayoutBuilder(
      builder: (context, constrains) {
        var group = chapters.getGroupByIndex(index);
        int length = group.length;
        bool canShowAll = showAll;
        if (!showAll) {
          var width = constrains.crossAxisExtent - 16;
          var crossItems = width ~/ 200;
          if (width % 200 != 0) {
            crossItems += 1;
          }
          length = math.min(length, crossItems * 8);
          if (length == group.length) {
            canShowAll = true;
          }
        }

        return SliverMainAxisGroup(
          slivers: [
            SliverToBoxAdapter(
              child: ListTile(
                title: Text("Chapters".tl),
                trailing: _ChapterOrderSegment(
                  reverse: reverse,
                  onChanged: setReverse,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: AppTabBar(
                key: ValueKey(chapters.groupCount),
                withUnderLine: false,
                controller: tabController,
                tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
              ),
            ),
            SliverPadding(padding: const EdgeInsets.only(top: 8)),
            SliverGrid(
              delegate: SliverChildBuilderDelegate((context, i) {
                if (reverse) {
                  i = group.length - i - 1;
                }
                var key = group.keys.elementAt(i);
                var value = group[key]!;
                bool visited = false;
                if (history != null) {
                  if (widget.chapterIndices != null) {
                    final rawIndex = widget.chapterIndices![key]?.toString();
                    visited =
                        rawIndex != null &&
                        history!.readEpisode.contains(rawIndex);
                  } else {
                    var chapterIndex = 0;
                    for (var j = 0; j < chapters.groupCount; j++) {
                      if (j == index) {
                        chapterIndex += i;
                        break;
                      }
                      chapterIndex += chapters.getGroupByIndex(j).length;
                    }
                    String rawIndex = (chapterIndex + 1).toString();
                    String groupedIndex = "${index + 1}-${i + 1}";
                    visited =
                        history!.readEpisode.contains(groupedIndex) ||
                        history!.readEpisode.contains(rawIndex);
                  }
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: Material(
                    color: context.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    child: ClickInkWell(
                      onTap: widget.readChapter == null
                          ? null
                          : () => widget.readChapter!(i + 1, index + 1),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: _ChapterLabel(
                            title: value,
                            pageCount: widget.pageCounts[key],
                            visited: visited,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }, childCount: length),
              gridDelegate: SliverGridDelegateWithFixedHeight(
                maxCrossAxisExtent: 250,
                itemHeight: _chapterGridHeight(
                  context,
                  chapters.ids,
                  widget.pageCounts,
                ),
              ),
            ).sliverPadding(const EdgeInsets.symmetric(horizontal: 8)),
            if (!canShowAll)
              SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    icon: const Icon(Icons.arrow_drop_down),
                    onPressed: () {
                      setState(() {
                        showAll = true;
                      });
                    },
                    label: Text("${"Show all".tl} (${group.length})"),
                  ).paddingTop(12),
                ),
              ),
            const SliverToBoxAdapter(child: Divider()),
          ],
        );
      },
    );
  }
}

double _chapterGridHeight(
  BuildContext context,
  Iterable<String> ids,
  Map<String, int> pageCounts,
) {
  if (!ids.any((id) => (pageCounts[id] ?? 0) > 0)) return 48;
  final scaler = MediaQuery.textScalerOf(context);
  return math.max(56, 16 + scaler.scale(14) * 1.3 + scaler.scale(11) * 1.3);
}

class _ChapterLabel extends StatelessWidget {
  const _ChapterLabel({
    required this.title,
    this.pageCount,
    required this.visited,
  });

  final String title;
  final int? pageCount;
  final bool visited;

  @override
  Widget build(BuildContext context) {
    final count = pageCount;
    final hasCount = count != null && count > 0;
    final titleText = Text(
      title,
      maxLines: 1,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: visited ? context.colorScheme.outline : null,
        fontSize: hasCount ? 14 : null,
        height: hasCount ? 1.3 : null,
      ),
    );
    if (!hasCount) return titleText;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        titleText,
        const SizedBox(height: 2),
        Text(
          '${"Pages".tl}: $count',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            color: visited
                ? context.colorScheme.outline
                : context.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ChapterOrderSegment extends StatelessWidget {
  const _ChapterOrderSegment({required this.reverse, required this.onChanged});

  final bool reverse;

  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: "Order".tl,
      child: SegmentedButton<bool>(
        selected: {reverse},
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
        ),
        segments: [
          ButtonSegment<bool>(value: false, label: Text("Ascending".tl)),
          ButtonSegment<bool>(value: true, label: Text("Descending".tl)),
        ],
        onSelectionChanged: (selected) {
          onChanged(selected.first);
        },
      ),
    );
  }
}
