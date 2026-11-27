import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/search/search.dart';
import 'package:venera_plus/features/settings/setting_components.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'keyword_blocking.dart';

class ExploreSettings extends StatelessWidget {
  const ExploreSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text('Explore'.tl)),
        SettingPartTitle(title: "Pages".tl, icon: Icons.view_carousel_outlined),
        PopupWindowSetting(
          title: "Explore Pages".tl,
          builder: setExplorePagesWidget,
        ).toSliver(),
        PopupWindowSetting(
          title: "Category Pages".tl,
          builder: setCategoryPagesWidget,
        ).toSliver(),
        PopupWindowSetting(
          title: "Network Favorite Pages".tl,
          builder: setFavoritesPagesWidget,
        ).toSliver(),
        SettingPartTitle(title: 'Search'.tl, icon: Icons.search),
        PopupWindowSetting(
          title: "Search Sources".tl,
          builder: setSearchSourcesWidget,
        ).toSliver(),
        ListenableBuilder(
          listenable: Listenable.merge([
            appdata.settings,
            ComicSourceManager(),
          ]),
          builder: (context, _) => SelectSetting(
            title: "Default Search Target".tl,
            settingKey: "defaultSearchTarget",
            optionTranslation: {
              '_aggregated_': "Aggregated".tl,
              for (final target in enabledSearchTargets())
                target.key: target.name,
            },
          ),
        ).toSliver(),
        SelectSetting(
          title: "Auto Language Filters".tl,
          settingKey: "autoAddLanguageFilter",
          optionTranslation: {
            'none': "None".tl,
            'chinese': 'Chinese'.tl,
            'english': 'English'.tl,
            'japanese': 'Japanese'.tl,
          },
        ).toSliver(),
        SettingPartTitle(title: "Blocking".tl, icon: Icons.block),
        PopupWindowSetting(
          title: 'Comic keyword blocking'.tl,
          builder: () => const KeywordBlockingSettings(),
        ).toSliver(),
        PopupWindowSetting(
          title: "Comment keyword blocking".tl,
          builder: () => const KeywordBlockingSettings(comments: true),
        ).toSliver(),
      ],
    );
  }
}

Widget setExplorePagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    for (var page in c.explorePages) {
      pages[page.title] = page.title.ts(c.key);
    }
  }
  return MultiPagesFilter(
    title: "Explore Pages".tl,
    settingsIndex: "explore_pages",
    pages: pages,
  );
}

Widget setCategoryPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.categoryData != null) {
      pages[c.categoryData!.key] = c.categoryData!.title;
    }
  }
  return MultiPagesFilter(
    title: "Category Pages".tl,
    settingsIndex: "categories",
    pages: pages,
  );
}

Widget setFavoritesPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.favoriteData != null) {
      pages[c.favoriteData!.key] = c.favoriteData!.title;
    }
  }
  return MultiPagesFilter(
    title: "Network Favorite Pages".tl,
    settingsIndex: "favorites",
    pages: pages,
  );
}

Widget setSearchSourcesWidget() {
  final targets = allSearchTargets();
  return MultiPagesFilter(
    title: "Search Sources".tl,
    settingsIndex: "searchSources",
    pages: {for (final target in targets) target.key: target.name},
    initialKeys: searchSourceOrder(targets),
    onSelectionChanged: (keys) => saveLibrarySearchSelection(targets, keys),
  );
}
