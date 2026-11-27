import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/components/select.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/image_favorites/image_favorites_item.dart';
import 'package:venera_plus/features/image_favorites/image_favorites_photo_view.dart';
import 'package:venera_plus/features/image_favorites/type.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/consts.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class ImageFavoritesPage extends StatefulWidget {
  const ImageFavoritesPage({
    super.key,
    this.initialKeyword,
    this.isRoot = false,
    this.isActive = true,
  });

  final String? initialKeyword;
  final bool isRoot;
  final bool isActive;

  @override
  State<ImageFavoritesPage> createState() => _ImageFavoritesPageState();
}

class _ImageFavoritesPageState extends State<ImageFavoritesPage> {
  late ImageFavoriteSortType sortType;
  late TimeRange timeFilterSelect;
  late int numFilterSelect;

  // 所有的图片收藏
  List<ImageFavoritesComic> comics = [];

  late var controller = TextEditingController(
    text: widget.initialKeyword ?? "",
  );

  String get keyword => controller.text;

  // 进入关键词搜索模式
  bool searchMode = false;

  bool multiSelectMode = false;

  // 多选的时候选中的图片
  Map<ImageFavorite, bool> selectedImageFavorites = {};

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  void updateImageFavorites() async {
    comics = searchMode
        ? ImageFavoriteManager().search(keyword)
        : ImageFavoriteManager().getAll();
    sortImageFavorites();
    update();
  }

  void sortImageFavorites() {
    comics = searchMode
        ? ImageFavoriteManager().search(keyword)
        : ImageFavoriteManager().getAll();
    // 筛选到最终列表
    comics = comics.where((ele) {
      final matchesTime = timeFilterSelect.contains(ele.time);
      final matchesCount =
          numFilterSelect == numFilterList[0] ||
          ele.images.length > numFilterSelect;
      return matchesTime && matchesCount;
    }).toList();
    // 给列表排序
    switch (sortType) {
      case ImageFavoriteSortType.title:
        comics.sort((a, b) => a.title.compareTo(b.title));
      case ImageFavoriteSortType.timeAsc:
        comics.sort((a, b) => a.time.compareTo(b.time));
      case ImageFavoriteSortType.timeDesc:
        comics.sort((a, b) => b.time.compareTo(a.time));
      case ImageFavoriteSortType.maxFavorites:
        comics.sort((a, b) => b.images.length.compareTo(a.images.length));
      case ImageFavoriteSortType.favoritesCompareComicPages:
        comics.sort((a, b) {
          double tempA = a.images.length / a.maxPageFromEp;
          double tempB = b.images.length / b.maxPageFromEp;
          return tempB.compareTo(tempA);
        });
    }
  }

  @override
  void initState() {
    if (widget.initialKeyword != null) {
      searchMode = true;
    }
    sortType =
        ImageFavoriteSortType.values.firstWhereOrNull(
          (e) => e.value == appdata.implicitData["image_favorites_sort"],
        ) ??
        ImageFavoriteSortType.title;
    timeFilterSelect = TimeRange.fromString(
      appdata.implicitData["image_favorites_time_filter"],
    );
    numFilterSelect =
        appdata.implicitData["image_favorites_number_filter"] ??
        numFilterList[0];
    updateImageFavorites();
    ImageFavoriteManager().addListener(updateImageFavorites);
    super.initState();
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(updateImageFavorites);
    scrollController.dispose();
    super.dispose();
  }

  void deleteSelected() {
    final selected = selectedImageFavorites.keys.toList();
    if (selected.isEmpty) return;
    confirmImageFavoriteDeletion(context, selected.length, () {
      if (!mounted) return;
      ImageFavoriteManager().deleteImageFavorite(selected);
      setState(() {
        multiSelectMode = false;
        selectedImageFavorites.clear();
      });
    });
  }

  var scrollController = ScrollController();

  void selectAll() => selectImages(comics.expand((comic) => comic.images));

  void selectImages(Iterable<ImageFavorite> images) {
    setState(() {
      for (final image in images) {
        selectedImageFavorites[image] = true;
      }
      if (selectedImageFavorites.isNotEmpty) multiSelectMode = true;
    });
  }

  void deSelect() {
    setState(() {
      selectedImageFavorites.clear();
    });
  }

  void addSelected(ImageFavorite i) {
    if (selectedImageFavorites[i] == null) {
      selectedImageFavorites[i] = true;
    } else {
      selectedImageFavorites.remove(i);
    }
    if (selectedImageFavorites.isEmpty) {
      multiSelectMode = false;
    } else {
      multiSelectMode = true;
    }
    update();
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
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete'.tl,
        onPressed: selectedImageFavorites.isEmpty ? null : deleteSelected,
      ),
    ];

    var scrollWidget = SmoothCustomScrollView(
      controller: scrollController,
      slivers: [
        if (!searchMode && !multiSelectMode)
          SliverAppbar(
            leading: widget.isRoot
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
                      : const SizedBox.shrink()),
            title: Text("Image Favorites".tl),
            actions: [
              Tooltip(
                message: "Search".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      searchMode = true;
                    });
                  },
                ),
              ),
              Tooltip(
                message: "Sort".tl,
                child: IconButton(
                  isSelected:
                      timeFilterSelect != TimeRange.all ||
                      numFilterSelect != numFilterList[0],
                  icon: const Icon(Icons.sort_rounded),
                  onPressed: sort,
                ),
              ),
              Tooltip(
                message: multiSelectMode
                    ? "Exit Multi-Select".tl
                    : "Multi-Select".tl,
                child: IconButton(
                  icon: const Icon(Icons.checklist),
                  onPressed: () {
                    setState(() {
                      multiSelectMode = !multiSelectMode;
                    });
                  },
                ),
              ),
            ],
          )
        else if (multiSelectMode)
          SliverAppbar(
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    multiSelectMode = false;
                    selectedImageFavorites.clear();
                  });
                },
              ),
            ),
            title: Text(selectedImageFavorites.length.toString()),
            actions: selectActions,
          )
        else if (searchMode)
          SliverAppbar(
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  controller.clear();
                  setState(() {
                    searchMode = false;
                    controller.clear();
                    updateImageFavorites();
                  });
                },
              ),
            ),
            title: TextField(
              autofocus: true,
              controller: controller,
              decoration: InputDecoration(
                hintText: "Search".tl,
                border: InputBorder.none,
              ),
              onChanged: (v) {
                updateImageFavorites();
              },
            ),
            actions: [
              if (controller.text.isNotEmpty)
                IconButton(
                  tooltip: 'Clear'.tl,
                  iconSize: 20,
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    controller.clear();
                    updateImageFavorites();
                  },
                ),
            ],
          ),
        SliverList(
          delegate: SliverChildBuilderDelegate((context, index) {
            final comic = comics[index];
            return ImageFavoritesItem(
              key: ValueKey((comic.sourceKey, comic.id)),
              imageFavoritesComic: comic,
              selectedImageFavorites: selectedImageFavorites,
              addSelected: addSelected,
              selectImages: selectImages,
              multiSelectMode: multiSelectMode,
            );
          }, childCount: comics.length),
        ),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    Widget body = Scrollbar(
      controller: scrollController,
      thickness: App.isDesktop ? 8 : 12,
      radius: const Radius.circular(8),
      interactive: true,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: context.width > changePoint
            ? scrollWidget.paddingHorizontal(8)
            : scrollWidget,
      ),
    );
    final canPopScope = widget.isActive
        ? (!multiSelectMode && !searchMode)
        : true;
    return PopScope(
      canPop: canPopScope,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !widget.isActive) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedImageFavorites.clear();
          });
        } else if (searchMode) {
          controller.clear();
          setState(() {
            searchMode = false;
            updateImageFavorites();
          });
        }
      },
      child: body,
    );
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return _ImageFavoritesDialog(
          initSortType: sortType,
          initTimeFilterSelect: timeFilterSelect,
          initNumFilterSelect: numFilterSelect,
          updateConfig: (sortType, timeFilter, numFilter) {
            setState(() {
              this.sortType = sortType;
              timeFilterSelect = timeFilter;
              numFilterSelect = numFilter;
            });
            sortImageFavorites();
          },
        );
      },
    );
  }
}

class _ImageFavoritesDialog extends StatefulWidget {
  const _ImageFavoritesDialog({
    required this.initSortType,
    required this.initTimeFilterSelect,
    required this.initNumFilterSelect,
    required this.updateConfig,
  });

  final ImageFavoriteSortType initSortType;
  final TimeRange initTimeFilterSelect;
  final int initNumFilterSelect;
  final Function updateConfig;

  @override
  State<_ImageFavoritesDialog> createState() => _ImageFavoritesDialogState();
}

class _ImageFavoritesDialogState extends State<_ImageFavoritesDialog> {
  List<String> optionTypes = ['Sort', 'Filter'];
  late var sortType = widget.initSortType;
  late var numFilter = widget.initNumFilterSelect;
  late TimeRangeType timeRangeType;
  DateTime? start;
  DateTime? end;

  @override
  void initState() {
    super.initState();
    final range = widget.initTimeFilterSelect;
    timeRangeType = switch (range) {
      TimeRange.all => TimeRangeType.all,
      TimeRange.lastWeek => TimeRangeType.lastWeek,
      TimeRange.lastMonth => TimeRangeType.lastMonth,
      TimeRange.lastHalfYear => TimeRangeType.lastHalfYear,
      TimeRange.lastYear => TimeRangeType.lastYear,
      _ => range.end == null ? TimeRangeType.all : TimeRangeType.custom,
    };
    final rangeEnd = range.end;
    if (rangeEnd != null) {
      start = rangeEnd.subtract(range.duration);
      end = DateTime(rangeEnd.year, rangeEnd.month, rangeEnd.day - 1);
    }
  }

  Future<void> _selectDate({required bool isStart}) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final earliest = DateTime(2000);
    final firstDate = isStart ? earliest : (start ?? earliest);
    final lastDate = isStart ? (end ?? today) : today;
    var initialDate = (isStart ? start : end) ?? today;
    if (initialDate.isBefore(firstDate)) {
      initialDate = firstDate;
    } else if (initialDate.isAfter(lastDate)) {
      initialDate = lastDate;
    }
    final date = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (date == null || !mounted) return;
    setState(() {
      if (isStart) {
        start = date;
      } else {
        end = date;
      }
    });
  }

  TimeRange? get _selectedTimeRange {
    switch (timeRangeType) {
      case TimeRangeType.all:
        return TimeRange.all;
      case TimeRangeType.lastWeek:
        return TimeRange.lastWeek;
      case TimeRangeType.lastMonth:
        return TimeRange.lastMonth;
      case TimeRangeType.lastHalfYear:
        return TimeRange.lastHalfYear;
      case TimeRangeType.lastYear:
        return TimeRange.lastYear;
      case TimeRangeType.custom:
        final start = this.start;
        final end = this.end;
        if (start == null || end == null || start.isAfter(end)) return null;
        final rangeStart = DateUtils.dateOnly(start);
        final rangeEnd = DateTime(end.year, end.month, end.day + 1);
        return TimeRange(
          end: rangeEnd,
          duration: rangeEnd.difference(rangeStart),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeRange = _selectedTimeRange;
    Widget tabBar = Material(
      borderRadius: BorderRadius.circular(8),
      child: AppTabBar(
        key: PageStorageKey(optionTypes),
        tabs: optionTypes.map((e) => Tab(text: e.tl, key: Key(e))).toList(),
      ),
    );
    return ContentDialog(
      content: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tabBar,
            TabViewBody(
              children: [
                RadioGroup<ImageFavoriteSortType>(
                  groupValue: sortType,
                  onChanged: (v) {
                    setState(() {
                      sortType = v ?? sortType;
                    });
                  },
                  child: Column(
                    children: ImageFavoriteSortType.values
                        .map(
                          (e) => RadioListTile<ImageFavoriteSortType>(
                            title: Text(e.value.tl),
                            value: e,
                          ),
                        )
                        .toList(),
                  ),
                ),
                Column(
                  children: [
                    ListTile(
                      title: Text("Time Filter".tl),
                      trailing: Select(
                        current: timeRangeType.value.tl,
                        values: TimeRangeType.values
                            .map((e) => e.value.tl)
                            .toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() {
                            timeRangeType = TimeRangeType.values[index];
                          });
                        },
                      ),
                    ),
                    if (timeRangeType == TimeRangeType.custom)
                      Column(
                        children: [
                          ListTile(
                            title: Text("Start Time".tl),
                            trailing: TextButton(
                              onPressed: () => _selectDate(isStart: true),
                              child: Text(
                                start == null
                                    ? "Select Date".tl
                                    : DateFormat("yyyy-MM-dd").format(start!),
                              ),
                            ),
                          ),
                          ListTile(
                            title: Text("End Time".tl),
                            trailing: TextButton(
                              onPressed: () => _selectDate(isStart: false),
                              child: Text(
                                end == null
                                    ? "Select Date".tl
                                    : DateFormat("yyyy-MM-dd").format(end!),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ListTile(
                      title: Text("Image Favorites Greater Than".tl),
                      trailing: Select(
                        current: numFilter.toString(),
                        values: numFilterList.map((e) => e.toString()).toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() {
                            numFilter = numFilterList[index];
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: timeRange == null
              ? null
              : () {
                  appdata.implicitData["image_favorites_sort"] = sortType.value;
                  appdata.implicitData["image_favorites_time_filter"] =
                      timeRange.toString();
                  appdata.implicitData["image_favorites_number_filter"] =
                      numFilter;
                  appdata.writeImplicitData();
                  if (mounted) {
                    Navigator.pop(context);
                    widget.updateConfig(sortType, timeRange, numFilter);
                  }
                },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
