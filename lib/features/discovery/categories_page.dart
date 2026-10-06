import 'package:flutter/material.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/global_state.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/routing/page_jump_target.dart';

import 'ranking_page.dart';

class SourceCategoryView extends StatefulWidget {
  const SourceCategoryView({
    required this.sourceKey,
    required this.data,
    super.key,
  });

  final String sourceKey;
  final CategoryData data;

  @override
  State<SourceCategoryView> createState() => SourceCategoryViewState();
}

class SourceCategoryViewState extends AutomaticGlobalState<SourceCategoryView>
    with AutomaticKeepAliveClientMixin<SourceCategoryView> {
  @override
  Object? get key => 'category:${widget.sourceKey}';

  final ScrollController _scrollController = ScrollController();
  void toTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  void refresh() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant SourceCategoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.sourceKey != widget.sourceKey) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final categoryData = widget.data;

    var children = <Widget>[];
    if (categoryData.enableRankingPage || categoryData.buttons.isNotEmpty) {
      children.add(buildTitle(categoryData.title));
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
          child: Wrap(
            children: [
              if (categoryData.enableRankingPage)
                buildTag("Ranking".tl, () {
                  context.to(() => RankingPage(categoryKey: categoryData.key));
                }),
              for (var buttonData in categoryData.buttons)
                buildTag(buttonData.label.tl, buttonData.onTap),
            ],
          ),
        ),
      );
    }

    for (var part in categoryData.categories) {
      if (part.enableRandom) {
        children.add(
          StatefulBuilder(
            builder: (context, updater) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  buildTitleWithRefresh(part.title, () => updater(() {})),
                  buildTags(part.categories),
                ],
              );
            },
          ),
        );
      } else {
        children.add(buildTitle(part.title));
        children.add(buildTags(part.categories));
      }
    }

    return SmoothCustomScrollView(
      key: PageStorageKey('category_${widget.sourceKey}'),
      controller: _scrollController,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget buildTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
      child: Text(
        title.tl,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget buildTitleWithRefresh(String title, void Function() onRefresh) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
      child: Row(
        children: [
          Text(
            title.tl,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          ),
          const Spacer(),
          IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ],
      ),
    );
  }

  Widget buildTags(List<CategoryItem> categories) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
      child: Wrap(
        children: List<Widget>.generate(
          categories.length,
          (index) => buildCategory(categories[index]),
        ),
      ),
    );
  }

  Widget buildCategory(CategoryItem c) {
    return buildTag(c.label, () {
      var context = App.mainNavigatorKey!.currentContext!;
      c.target.jump(context);
    });
  }

  Widget buildTag(String label, VoidCallback onClick) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Builder(
        builder: (context) {
          return Material(
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            color: context.colorScheme.primaryContainer.toOpacity(0.72),
            child: ClickInkWell(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              onTap: onClick,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(label),
              ),
            ),
          );
        },
      ),
    );
  }
}
