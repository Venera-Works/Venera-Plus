import 'package:flutter/material.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';
import 'package:venera_plus/features/settings/about.dart';
import 'package:venera_plus/features/settings/appearance.dart';
import 'package:venera_plus/features/settings/app.dart';
import 'package:venera_plus/features/settings/debug.dart';
import 'package:venera_plus/features/settings/explore_settings.dart';
import 'package:venera_plus/features/settings/network.dart';
import 'package:venera_plus/features/settings/reader.dart';

enum SettingsDestination {
  reading,
  appearance,
  browsing,
  sources,
  storage,
  network,
  privacy,
  advanced,
  about,
}

Widget _buildSettingsContent(SettingsDestination destination) {
  return switch (destination) {
    SettingsDestination.reading => const ReaderSettings(),
    SettingsDestination.appearance => const AppearanceSettings(),
    SettingsDestination.browsing => const BrowsingAndFavoritesSettings(),
    SettingsDestination.sources => const SourcesAndServicesSettings(),
    SettingsDestination.storage => const StorageAndSyncSettings(),
    SettingsDestination.network => const NetworkSettings(),
    SettingsDestination.privacy => const PrivacyAndSecuritySettings(),
    SettingsDestination.advanced => const AdvancedSettings(),
    SettingsDestination.about => const AboutSettings(),
  };
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
  bool _innerCanPop = false;

  ColorScheme get colors => Theme.of(context).colorScheme;

  bool get enableTwoViews => context.width > 720;

  @override
  void initState() {
    super.initState();
    currentPage = widget.initialDestination;
    if (widget.initialDestination != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !enableTwoViews && widget.initialDestination != null) {
          context.to(
            () => _SettingsDetailPage(destination: widget.initialDestination!),
          );
        }
      });
    }
  }

  void _selectDestination(SettingsDestination destination) {
    if (currentPage == destination) return;
    setState(() {
      _detailNavKey = GlobalKey<NavigatorState>();
      currentPage = destination;
      _innerCanPop = false;
    });
  }

  Future<void> _handleBack() async {
    if (enableTwoViews) {
      final innerNav = _detailNavKey.currentState;
      if (innerNav != null && (_innerCanPop || innerNav.canPop())) {
        final didPop = await innerNav.maybePop();
        if (didPop) return;
      }
      if (currentPage != null && widget.initialDestination == null) {
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
          !enableTwoViews ||
          (!_innerCanPop &&
              (_detailNavKey.currentState?.canPop() != true) &&
              (currentPage == null || widget.initialDestination != null)),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !widget.isActive) return;
        _handleBack();
      },
      child: Material(child: buildBody()),
    );
  }

  Widget buildBody() {
    if (enableTwoViews) {
      return Row(
        children: [
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
          Expanded(child: buildRight()),
        ],
      );
    } else {
      return buildLeft();
    }
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
        title: "Reading & Browsing".tl,
        destinations: [
          _SettingsItem(
            destination: SettingsDestination.reading,
            title: "Reading".tl,
            icon: Icons.menu_book,
          ),
          _SettingsItem(
            destination: SettingsDestination.appearance,
            title: "Appearance and Interface".tl,
            icon: Icons.palette_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.browsing,
            title: "Browsing and Favorites".tl,
            icon: Icons.explore_outlined,
          ),
        ],
      ),
      _SettingsGroup(
        title: "Sources & Data".tl,
        destinations: [
          _SettingsItem(
            destination: SettingsDestination.sources,
            title: "Sources and Services".tl,
            icon: Icons.extension_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.storage,
            title: "Storage and Sync".tl,
            icon: Icons.storage_outlined,
          ),
          _SettingsItem(
            destination: SettingsDestination.network,
            title: "Network".tl,
            icon: Icons.public,
          ),
        ],
      ),
      _SettingsGroup(
        title: "System".tl,
        destinations: [
          _SettingsItem(
            destination: SettingsDestination.privacy,
            title: "Privacy and Security".tl,
            icon: Icons.lock_outline,
          ),
          _SettingsItem(
            destination: SettingsDestination.advanced,
            title: "Advanced and Diagnostics".tl,
            icon: Icons.tune,
          ),
          _SettingsItem(
            destination: SettingsDestination.about,
            title: "About".tl,
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
          borderRadius: BorderRadius.circular(8),
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
          onTap: () {
            if (enableTwoViews) {
              _selectDestination(item.destination);
            } else {
              context.to(
                () => _SettingsDetailPage(destination: item.destination),
              );
            }
          },
          child: content,
        ).paddingVertical(2),
      );
    }

    return ListView(
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
  }

  Widget buildRight() {
    final destination = currentPage;
    if (destination == null) {
      return const SizedBox();
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
        onGenerateRoute: (settings) {
          return PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) {
              return _buildSettingsContent(destination);
            },
            transitionDuration: Duration.zero,
          );
        },
      ),
    );
  }
}

class _SettingsDetailPage extends StatelessWidget {
  const _SettingsDetailPage({required this.destination});

  final SettingsDestination destination;

  @override
  Widget build(BuildContext context) {
    return Material(child: _buildSettingsContent(destination));
  }
}
