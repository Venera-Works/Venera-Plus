import "package:flutter/material.dart";
import "package:venera_plus/components/appbar.dart";
import "package:venera_plus/components/select.dart";
import "package:venera_plus/features/comic_widgets/comic_widgets.dart";
import "package:venera_plus/features/comic_source/comic_source.dart";
import "package:venera_plus/foundation/context.dart";
import "package:venera_plus/foundation/translations.dart";
import "package:venera_plus/foundation/widget_utils.dart";

class RankingPage extends StatefulWidget {
  const RankingPage({required this.categoryKey, super.key});

  final String categoryKey;

  @override
  State<RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<RankingPage> {
  late final CategoryComicsData data;
  late final Map<String, String> options;
  late String optionValue;

  void findData() {
    for (final source in ComicSource.all()) {
      if (source.categoryData?.key == widget.categoryKey) {
        data = source.categoryComicsData!;
        options = data.rankingData!.options;
        optionValue = options.keys.first;
        return;
      }
    }
    throw "${widget.categoryKey} Not found";
  }

  @override
  void initState() {
    findData();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = context.padding.top + 56;
    final header = buildOptions().paddingTop(topPadding);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: Appbar(title: Text("Ranking".tl)),
      body: ComicList(
        key: Key(optionValue),
        errorLeading: header,
        leadingSliver: header.toSliver(),
        loadPage: data.rankingData!.load == null
            ? null
            : (i) => data.rankingData!.load!(optionValue, i),
        loadNext: data.rankingData!.loadWithNext == null
            ? null
            : (i) => data.rankingData!.loadWithNext!(optionValue, i),
      ),
    );
  }

  Widget buildOptionItem(String text, String value) {
    return OptionChip(
      text: text,
      isSelected: value == optionValue,
      onTap: () {
        if (value == optionValue) return;
        setState(() {
          optionValue = value;
        });
      },
    );
  }

  Widget buildOptions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in options.entries)
              buildOptionItem(option.value.tl, option.key),
          ],
        ),
        const Divider(),
      ],
    ).paddingHorizontal(8);
  }
}
