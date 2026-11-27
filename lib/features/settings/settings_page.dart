import 'package:flutter/material.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/settings/about.dart';
import 'package:venera_plus/features/settings/app.dart';
import 'package:venera_plus/features/settings/appearance.dart';
import 'package:venera_plus/features/settings/content_sources_page.dart';
import 'package:venera_plus/features/settings/debug.dart';
import 'package:venera_plus/features/settings/explore_settings.dart';
import 'package:venera_plus/features/settings/general.dart';
import 'package:venera_plus/features/settings/library.dart';
import 'package:venera_plus/features/settings/network.dart';
import 'package:venera_plus/features/settings/reader.dart';
import 'package:venera_plus/features/settings/storage.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

enum SettingsDestination {
  general,
  appearance,
  reader,
  library,
  explore,
  sources,
  storage,
  sync,
  network,
  advanced,
  about,
}

Widget _buildSettingsContent(SettingsDestination destination) {
  final key = ValueKey(destination);
  final content = switch (destination) {
    SettingsDestination.general => GeneralSettings(key: key),
    SettingsDestination.appearance => AppearanceSettings(key: key),
    SettingsDestination.reader => ReaderSettings(key: key),
    SettingsDestination.library => LibrarySettings(key: key),
    SettingsDestination.explore => ExploreSettings(key: key),
    SettingsDestination.sources => ContentSourcesPage(key: key),
    SettingsDestination.storage => StorageSettings(key: key),
    SettingsDestination.sync => SyncSettings(key: key),
    SettingsDestination.network => NetworkSettings(key: key),
    SettingsDestination.advanced => AdvancedSettings(key: key),
    SettingsDestination.about => AboutSettings(key: key),
  };
  return MouseDragScrollRegion(child: content);
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    this.initialDestination,
    this.isRoot = false,
    this.isActive = true,
    super.key,
  });

  final SettingsDestination? initialDestination;
  final bool isRoot;
  final bool isActive;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsGroup {
  const _SettingsGroup({required this.title, required this.destinations});

  final String title;
  final List<_SettingsItem> destinations;
}

class _SettingsItem {
  const _SettingsItem({
    required this.destination,
    required this.title,
    required this.icon,
  });

  final SettingsDestination destination;
  final String title;
  final IconData icon;
}

class _SettingsPageState extends State<SettingsPage> {
  SettingsDestination? currentPage;
  GlobalKey<NavigatorState> _detailNavKey = GlobalKey<NavigatorState>();
  List<Page<void>> _detailPages = const [];
  bool _innerCanPop = false;
  bool _confirmingDestination = false;

  ColorScheme get colors => Theme.of(context).colorScheme;

  bool get enableTwoViews => context.width > 720;

  @override
  void initState() {
    super.initState();
    currentPage = widget.initialDestination;
  }

  Future<void> _selectDestination(SettingsDestination destination) async {
    if (currentPage == destination || _confirmingDestination) return;
    if (!App.isDesktop && !enableTwoViews && currentPage == null) {
      await context.to(
        () => Material(child: _buildSettingsContent(destination)),
      );
      return;
    }
    if (_innerCanPop || _detailNavKey.currentState?.canPop() == true) {
      var confirmed = false;
      _confirmingDestination = true;
      try {
        await showConfirmDialog(
          context: context,
          title: 'Discard unsaved changes?'.tl,
          content:
              'Changing settings categories will close the current page.'.tl,
          confirmText: 'Discard changes',
          onConfirm: () => confirmed = true,
        );
      } finally {
        _confirmingDestination = false;
      }
      if (!mounted || !confirmed) return;
    }
    setState(() {
      _detailNavKey = GlobalKey<NavigatorState>();
      currentPage = destination;
      _innerCanPop = false;
    });
  }

  Future<void> _handleBack() async {
    if (currentPage != null) {
      final innerNav = _detailNavKey.currentState;
      if (innerNav != null && (_innerCanPop || innerNav.canPop())) {
        final didPop = await innerNav.maybePop();
        if (didPop || !mounted) return;
      }
      if (!enableTwoViews || widget.initialDestination == null) {
        setState(() {
          currentPage = null;
          _innerCanPop = false;
        });
        return;
      }
    }
    if (widget.isRoot) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop:
          !widget.isActive ||
          currentPage == null ||
          (enableTwoViews &&
              widget.initialDestination != null &&
              !_innerCanPop &&
              (_detailNavKey.currentState?.canPop() != true) &&
              !_confirmingDestination),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !widget.isActive) return;
        _handleBack();
      },
      child: Material(child: buildBody()),
    );
  }

  Widget buildBody() {
    if (!enableTwoViews && currentPage == null) return buildLeft();
    return Row(
      children: [
        if (enableTwoViews) ...[
          SizedBox(width: 280, height: double.infinity, child: buildLeft()),
          Container(
            height: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ],
        Expanded(key: const ValueKey('settings-detail'), child: buildRight()),
      ],
    );
  }

  Widget buildLeft() {
    final showHeader =
        !widget.isRoot || (enableTwoViews && currentPage != null);
    return Material(
      child: Column(
        children: [
          if (showHeader) ...[
            SizedBox(height: MediaQuery.of(context).padding.top),
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Tooltip(
                    message: "Back".tl,
                    child: IconButton(
                      key: const Key('settings-back-button'),
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _handleBack,
                    ),
                  ),
                  const SizedBox(width: 24),
                  if (!widget.isRoot) Text("Settings".tl, style: ts.s20),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
          Expanded(child: buildCategories()),
        ],
      ),
    );
  }

  Widget buildCategories() {
    final groups = [
      _SettingsGroup(
        title: 'Preferences'.tl,
        destinations: [
          _SettingsItem(
            destination: SettingsDestination.general,
            title: 'General'.tl,
            icon: Icons.settings_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.appearance,
            title: 'Appearance'.tl,
            icon: Icons.palette_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.reader,
            title: 'Reader'.tl,
            icon: Icons.menu_book_outlined,
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Content'.tl,
        destinations: [
          _SettingsItem(
            destination: SettingsDestination.library,
            title: 'Library'.tl,
            icon: Icons.collections_bookmark_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.explore,
            title: 'Explore'.tl,
            icon: Icons.explore_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.sources,
            title: 'Sources'.tl,
            icon: Icons.extension_outlined,
          ),
        ],
      ),
      _SettingsGroup(
        title: 'Data'.tl,
        destinations: [
          _SettingsItem(
            destination: SettingsDestination.storage,
            title: 'Storage'.tl,
            icon: Icons.storage_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.sync,
            title: 'Sync'.tl,
            icon: Icons.cloud_sync_outlined,
          ),
        ],
      ),
      _SettingsGroup(
        title: 'System'.tl,
        destinations: [
          _SettingsItem(
            destination: SettingsDestination.network,
            title: 'Network'.tl,
            icon: Icons.public,
          ),
          _SettingsItem(
            destination: SettingsDestination.advanced,
            title: 'Advanced'.tl,
            icon: Icons.tune,
          ),
          _SettingsItem(
            destination: SettingsDestination.about,
            title: 'About'.tl,
            icon: Icons.info_outline,
          ),
        ],
      ),
    ];

    Widget buildItem(_SettingsItem item) {
      final bool selected = item.destination == currentPage;

      Widget content = AnimatedContainer(
        key: ValueKey(item.destination),
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? colors.primaryContainer.toOpacity(0.36) : null,
          border: Border(
            left: BorderSide(
              color: selected ? colors.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(item.icon, size: 20, color: selected ? colors.primary : null),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                item.title,
                style: ts.s16.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? colors.primary : null,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected) Icon(Icons.arrow_right, color: colors.primary),
          ],
        ),
      );

      return Padding(
        padding: enableTwoViews
            ? const EdgeInsets.fromLTRB(8, 0, 8, 0)
            : const EdgeInsets.symmetric(horizontal: 8),
        child: ClickInkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _selectDestination(item.destination),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: content,
          ),
        ).paddingVertical(2),
      );
    }

    final categoryList = ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final group in groups) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              group.title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.primary,
                letterSpacing: 0.5,
              ),
            ),
          ),
          for (final item in group.destinations) buildItem(item),
        ],
        const SizedBox(height: 16),
      ],
    );
    return MouseDragScrollRegion(child: categoryList);
  }

  Widget buildRight() {
    final destination = currentPage;
    if (destination == null) {
      return const SizedBox();
    }
    final compact = !enableTwoViews;
    final pageKey = ValueKey(destination);
    // 只在布局或分类实际变化时更新页面列表，避免返回状态通知反复重建路由。
    if (_detailPages.length != (compact ? 2 : 1) ||
        _detailPages.last.key != pageKey) {
      _detailPages = [
        if (compact)
          const MaterialPage<void>(
            key: ValueKey('settings-list'),
            child: SizedBox.shrink(),
          ),
        MaterialPage<void>(
          key: pageKey,
          child: _buildSettingsContent(destination),
        ),
      ];
    }
    return NotificationListener<NavigationNotification>(
      onNotification: (notification) {
        if (_innerCanPop != notification.canHandlePop) {
          setState(() {
            _innerCanPop = notification.canHandlePop;
          });
        }
        return false;
      },
      child: Navigator(
        key: _detailNavKey,
        pages: _detailPages,
        onDidRemovePage: (page) {
          if (page.key == pageKey && currentPage == destination) {
            setState(() {
              currentPage = null;
              _innerCanPop = false;
            });
          }
        },
      ),
    );
  }
}
