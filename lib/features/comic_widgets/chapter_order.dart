import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/features/comic_storage/chapter_title_sort.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

enum ChapterListOrder {
  source('Source order'),
  reversedSource('Reversed source order'),
  numberAscending('Volume and chapter ascending'),
  numberDescending('Volume and chapter descending');

  const ChapterListOrder(this.label);
  final String label;

  static ChapterListOrder get current {
    final reverse = appdata.settings['reverseChapterOrder'] == true;
    if (appdata.settings['sortChaptersByNumber'] == true) {
      return reverse ? numberDescending : numberAscending;
    }
    return reverse ? reversedSource : source;
  }

  void save() {
    if (this == current) return;
    appdata.settings['sortChaptersByNumber'] =
        this == numberAscending || this == numberDescending;
    appdata.settings['reverseChapterOrder'] =
        this == reversedSource || this == numberDescending;
    appdata.saveData();
  }

  /// 显示顺序可变，左侧下标始终对应源目录，供点击跳章和已读标记使用。
  List<(int, MapEntry<String, String>)> entries(Map<String, String> chapters) {
    final indexed = chapters.entries.indexed;
    return switch (this) {
      source => indexed.toList(),
      reversedSource => indexed.toList().reversed.toList(),
      numberAscending || numberDescending => sortedChapterEntries(
        indexed,
        titleOf: (entry) => entry.$2.value,
        descending: this == numberDescending,
      ),
    };
  }
}

class ChapterOrderButton extends StatelessWidget {
  const ChapterOrderButton({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    void showOrderMenu() {
      final box = context.findRenderObject() as RenderBox;
      final current = ChapterListOrder.current;
      showMenuX(context, box.localToGlobal(Offset(0, box.size.height)), [
        for (final order in ChapterListOrder.values)
          MenuEntry(
            text: order.label.tl,
            icon: order == current ? Icons.check : null,
            onClick: order.save,
          ),
      ]);
    }

    if (compact) {
      return Button.icon(
        icon: const Icon(Icons.sort),
        tooltip: 'Chapter order'.tl,
        onPressed: showOrderMenu,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
        child: TextButton.icon(
          onPressed: showOrderMenu,
          iconAlignment: IconAlignment.end,
          icon: const Icon(Icons.arrow_drop_down),
          label: Text(
            ChapterListOrder.current.label.tl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
