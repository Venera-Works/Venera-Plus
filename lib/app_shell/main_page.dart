import 'package:flutter/material.dart';
import 'package:venera_plus/app_shell/home_page.dart';
import 'package:venera_plus/app_shell/library_page.dart';
import 'package:venera_plus/features/discovery/discovery.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/search/search.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/foundation/translations.dart';

import '../components/navigation_bar.dart';
import '../foundation/app.dart';
import '../foundation/context.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;
  GlobalKey<NavigatorState>? _navigatorKey;
  final _naviPaneKey = GlobalKey<NaviPaneState>();
  final _libraryKey = GlobalKey<LibraryPageState>();

  late int index;
  LibrarySection? _initialLibrarySection;
  late DiscoverySection _initialDiscoverySection;

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

  void _openLibraryHistory() {
    if (_libraryKey.currentState == null) {
      _initialLibrarySection = LibrarySection.history;
    } else {
      _libraryKey.currentState?.selectSection(LibrarySection.history);
    }
    if (index != 1) {
      _naviPaneKey.currentState?.updatePage(1);
    }
  }

  @override
  void initState() {
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    App.mainNavigatorKey = _navigatorKey;

    final startup = StartupPage.fromId(appdata.settings['initialPage']);

    switch (startup) {
      case StartupPage.home:
        index = 0;
        _initialLibrarySection = null;
        _initialDiscoverySection = DiscoverySection.browse;
      case StartupPage.library:
        index = 1;
        _initialLibrarySection = null;
        _initialDiscoverySection = DiscoverySection.browse;
      case StartupPage.favorites:
        index = 1;
        _initialLibrarySection = LibrarySection.favorites;
        _initialDiscoverySection = DiscoverySection.browse;
      case StartupPage.browse:
        index = 2;
        _initialLibrarySection = null;
        _initialDiscoverySection = DiscoverySection.browse;
      case StartupPage.categories:
        index = 2;
        _initialLibrarySection = null;
        _initialDiscoverySection = DiscoverySection.categories;
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      key: _naviPaneKey,
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
          label: 'Library'.tl,
          icon: Icons.local_library_outlined,
          activeIcon: Icons.local_library,
        ),
        PaneItemEntry(
          label: 'Explore'.tl,
          icon: Icons.explore_outlined,
          activeIcon: Icons.explore,
        ),
        PaneItemEntry(
          label: 'Settings'.tl,
          icon: Icons.settings_outlined,
          activeIcon: Icons.settings,
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
        if (index == 0) const ReadingFavoritesMenuButton(),
      ],
      pageBuilder: (pageIndex) {
        return _MainShellPages(
          key: const ValueKey('main_shell_pages_container'),
          currentIndex: pageIndex,
          libraryKey: _libraryKey,
          onOpenHistory: _openLibraryHistory,
          initialLibrarySection: _initialLibrarySection,
          initialDiscoverySection: _initialDiscoverySection,
        );
      },
    );
  }
}

class _MainShellPages extends StatefulWidget {
  const _MainShellPages({
    super.key,
    required this.currentIndex,
    required this.libraryKey,
    required this.onOpenHistory,
    required this.initialLibrarySection,
    required this.initialDiscoverySection,
  });

  final int currentIndex;
  final GlobalKey<LibraryPageState> libraryKey;
  final VoidCallback onOpenHistory;
  final LibrarySection? initialLibrarySection;
  final DiscoverySection initialDiscoverySection;

  @override
  State<_MainShellPages> createState() => _MainShellPagesState();
}

class _MainShellPagesState extends State<_MainShellPages> {
  late final Set<int> _visitedIndices;

  @override
  void initState() {
    super.initState();
    _visitedIndices = {widget.currentIndex};
  }

  @override
  void didUpdateWidget(covariant _MainShellPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visitedIndices.add(widget.currentIndex);
  }

  Widget _buildPage(int pageIndex) {
    switch (pageIndex) {
      case 0:
        return HomePage(
          key: const PageStorageKey('main_home'),
          onOpenHistory: widget.onOpenHistory,
        );
      case 1:
        return LibraryPage(
          key: widget.libraryKey,
          initialSection: widget.initialLibrarySection,
          isActive: widget.currentIndex == 1,
        );
      case 2:
        return ExplorePage(
          key: const PageStorageKey('main_explore'),
          initialSection: widget.initialDiscoverySection,
        );
      case 3:
        return SettingsPage(isRoot: true, isActive: widget.currentIndex == 3);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (var i = 0; i < 4; i++)
          if (_visitedIndices.contains(i))
            Positioned.fill(
              key: ValueKey('main_dest_$i'),
              child: KeepAliveView(
                isActive: widget.currentIndex == i,
                child: _buildPage(i),
              ),
            ),
      ],
    );
  }
}
