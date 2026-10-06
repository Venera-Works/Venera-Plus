import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/image_favorites/image_favorites.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/foundation/translations.dart';

/// Wraps an offstage / keepalive view with complete isolation:
/// - HeroMode disabled when inactive to prevent duplicate Hero tags across sections
/// - Focus disabled when inactive to prevent focus trapping
/// - TickerMode disabled when inactive to avoid unnecessary animations
/// - Offstage to hide and prevent painting / hit-testing
class KeepAliveView extends StatefulWidget {
  const KeepAliveView({super.key, required this.isActive, required this.child});

  final bool isActive;
  final Widget child;

  @override
  State<KeepAliveView> createState() => _KeepAliveViewState();
}

class _KeepAliveViewState extends State<KeepAliveView> {
  final FocusScopeNode _focusScopeNode = FocusScopeNode();

  @override
  void didUpdateWidget(covariant KeepAliveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      if (_focusScopeNode.hasFocus) {
        _focusScopeNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _focusScopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      node: _focusScopeNode,
      canRequestFocus: widget.isActive,
      child: ExcludeFocus(
        excluding: !widget.isActive,
        child: HeroMode(
          enabled: widget.isActive,
          child: TickerMode(
            enabled: widget.isActive,
            child: Offstage(offstage: !widget.isActive, child: widget.child),
          ),
        ),
      ),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.initialSection, this.isActive = true});

  final LibrarySection? initialSection;
  final bool isActive;

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late LibrarySection _currentSection;
  late Set<LibrarySection> _visitedSections;

  static const _sections = [
    LibrarySection.favorites,
    LibrarySection.local,
    LibrarySection.images,
    LibrarySection.history,
  ];

  LibrarySection get currentSection => _currentSection;

  LibrarySection _resolveInitialSection() {
    if (widget.initialSection != null) {
      return widget.initialSection!;
    }
    final savedName = appdata.implicitData['librarySection'];
    if (savedName is String) {
      for (final s in LibrarySection.values) {
        if (s.name == savedName) {
          return s;
        }
      }
    }
    return LibrarySection.favorites;
  }

  @override
  void initState() {
    super.initState();
    _currentSection = _resolveInitialSection();
    _visitedSections = {_currentSection};
    _tabController = TabController(
      length: _sections.length,
      initialIndex: _sections.indexOf(_currentSection),
      vsync: this,
    );
    _tabController.addListener(_onTabChanged);

    appdata.implicitData['librarySection'] = _currentSection.name;
    appdata.writeImplicitData();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final newSection = _sections[_tabController.index];
    if (newSection != _currentSection) {
      setState(() {
        _currentSection = newSection;
        _visitedSections.add(newSection);
      });
      appdata.implicitData['librarySection'] = newSection.name;
      appdata.writeImplicitData();
    }
  }

  void selectSection(LibrarySection section) {
    final targetIndex = _sections.indexOf(section);
    if (targetIndex < 0) return;
    if (_tabController.index != targetIndex) {
      _tabController.animateTo(targetIndex);
    }
    if (_currentSection != section) {
      setState(() {
        _currentSection = section;
        _visitedSections.add(section);
      });
      appdata.implicitData['librarySection'] = section.name;
      appdata.writeImplicitData();
    }
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection != null &&
        widget.initialSection != oldWidget.initialSection &&
        widget.initialSection != _currentSection) {
      selectSection(widget.initialSection!);
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  String _sectionTitle(LibrarySection section) {
    switch (section) {
      case LibrarySection.favorites:
        return 'Comic Favorites'.tl;
      case LibrarySection.local:
        return 'Local Comics'.tl;
      case LibrarySection.images:
        return 'Image Favorites'.tl;
      case LibrarySection.history:
        return 'Reading Records'.tl;
    }
  }

  Widget _buildSectionWidget(LibrarySection section) {
    final isSectionActive = widget.isActive && (_currentSection == section);
    switch (section) {
      case LibrarySection.favorites:
        return FavoritesPage(
          key: const PageStorageKey('library_favorites'),
          isRoot: true,
          isActive: isSectionActive,
        );
      case LibrarySection.local:
        return LocalComicsPage(
          key: const PageStorageKey('library_local'),
          isRoot: true,
          isActive: isSectionActive,
        );
      case LibrarySection.images:
        return ImageFavoritesPage(
          key: const PageStorageKey('library_images'),
          isRoot: true,
          isActive: isSectionActive,
        );
      case LibrarySection.history:
        return HistoryPage(
          key: const PageStorageKey('library_history'),
          isRoot: true,
          isActive: isSectionActive,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          child: AppTabBar(
            controller: _tabController,
            tabs: _sections
                .map((section) => Tab(text: _sectionTitle(section)))
                .toList(),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              for (final section in _sections)
                if (_visitedSections.contains(section))
                  Positioned.fill(
                    key: ValueKey('library_section_${section.name}'),
                    child: KeepAliveView(
                      isActive: widget.isActive && (_currentSection == section),
                      child: _buildSectionWidget(section),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}
