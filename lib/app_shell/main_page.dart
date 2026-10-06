import 'package:flutter/material.dart';
import 'package:venera_plus/features/discovery/discovery.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/search/search.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

import '../components/navigation_bar.dart';
import '../foundation/app.dart';
import '../foundation/context.dart';
import 'home_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;

  GlobalKey<NavigatorState>? _navigatorKey;

  void to(Widget Function() widget, {bool preventDuplicate = false}) async {
    if (preventDuplicate) {
      var page = widget();
      if ("/${page.runtimeType}" == _observer.routes.last.toString()) return;
    }
    _navigatorKey!.currentContext!.to(widget);
  }

  void back() {
    _navigatorKey!.currentContext!.pop();
  }

  @override
  void initState() {
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    App.mainNavigatorKey = _navigatorKey;
    final initialPageSetting =
        int.tryParse(appdata.settings['initialPage'].toString()) ?? 0;
    index = (initialPageSetting >= 0 && initialPageSetting < _pages.length)
        ? initialPageSetting
        : 0;
    super.initState();
  }

  final _pages = [
    const HomePage(),
    const FavoritesPage(key: PageStorageKey('favorites')),
    const ExplorePage(key: PageStorageKey('explore')),
    const CategoriesPage(key: PageStorageKey('categories')),
  ];

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: index,
      observer: _observer,
      navigatorKey: _navigatorKey!,
      paneItems: [
        PaneItemEntry(
          label: 'Home'.tl,
          icon: Icons.home_outlined,
          activeIcon: Icons.home,
        ),
        PaneItemEntry(
          label: 'Favorites'.tl,
          icon: Icons.local_activity_outlined,
          activeIcon: Icons.local_activity,
        ),
        PaneItemEntry(
          label: 'Explore'.tl,
          icon: Icons.explore_outlined,
          activeIcon: Icons.explore,
        ),
        PaneItemEntry(
          label: 'Categories'.tl,
          icon: Icons.category_outlined,
          activeIcon: Icons.category,
        ),
      ],
      onPageChanged: (i) {
        setState(() {
          index = i;
        });
      },
      paneActions: [
        SyncActionButton(onConfigure: () => showDataSyncSettings(context)),
        Tooltip(
          message: "Search".tl,
          child: IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              to(() => const SearchPage(), preventDuplicate: true);
            },
          ),
        ),
        Tooltip(
          message: "Settings".tl,
          child: IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              to(() => const SettingsPage(), preventDuplicate: true);
            },
          ),
        ),
      ],
      pageBuilder: (index) {
        return _pages[index];
      },
    );
  }
}
