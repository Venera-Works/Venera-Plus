import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/navigation_bar.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/discovery/discovery.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/foundation/res.dart';

import '../../widget_test_io.dart';

ComicSource _createTestSource({
  required String key,
  required String name,
  List<String> explorePageTitles = const [],
  String? categoryKey,
  bool emptyBrowsePages = false,
  bool showCategoryTitle = false,
}) {
  return ComicSource(
    name,
    key,
    null,
    categoryKey != null
        ? CategoryData(
            title: '$name Categories',
            categories: const [],
            enableRankingPage: showCategoryTitle,
            key: categoryKey,
          )
        : null,
    null,
    null,
    explorePageTitles
        .map(
          (title) => ExplorePageData(
            title,
            ExplorePageType.multiPageComicList,
            emptyBrowsePages
                ? null
                : (_) async => const Res<List<Comic>>(<Comic>[]),
            null,
            null,
            null,
          ),
        )
        .toList(),
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    'test/$key.js',
    'https://example.com/$key',
    '1.0.0',
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
}

void main() {
  group('Discovery section swipe navigation', () {
    testWidgets(
      'swipes switch the active view and remembered section without stealing '
      'vertical or single-capability gestures',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync(
          'venera-discovery-swipe-',
        );
        final previousSettings = Map<String, dynamic>.from(
          appdata.toJson()['settings'] as Map,
        );
        final previousImplicit = Map<String, dynamic>.from(
          appdata.implicitData,
        );
        String? previousDataPath;
        try {
          previousDataPath = App.dataPath;
        } on Error {
          /* Unset late path. */
        }

        final manager = ComicSourceManager();
        const dualKey = 'discovery_swipe_dual';
        const singleKey = 'discovery_swipe_single';
        manager.remove(dualKey);
        manager.remove(singleKey);
        manager.add(
          _createTestSource(
            key: dualKey,
            name: 'A Long Comic Source Name That Needs Room',
            explorePageTitles: const ['Dual Browse', 'Dual Browse 2'],
            categoryKey: 'discovery_swipe_category',
            emptyBrowsePages: true,
            showCategoryTitle: true,
          ),
        );
        manager.add(
          _createTestSource(
            key: singleKey,
            name: 'Single Source',
            explorePageTitles: const ['Single Browse', 'Single Browse 2'],
            emptyBrowsePages: true,
          ),
        );

        App.dataPath = directory.path;
        appdata.settings['language'] = 'en-US';
        appdata.settings['explore_pages'] = const [
          'Dual Browse',
          'Dual Browse 2',
          'Single Browse',
          'Single Browse 2',
        ];
        appdata.settings['categories'] = const ['discovery_swipe_category'];
        appdata.implicitData['discovery_source'] = dualKey;
        appdata.implicitData.remove('discovery_section_$dualKey');
        appdata.implicitData.remove('discovery_section_$singleKey');
        appdata.implicitData.remove('discovery_page_$dualKey');
        appdata.implicitData.remove('discovery_page_$singleKey');

        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await runWidgetIo(tester, () => appdata.writeImplicitData());
          manager.remove(dualKey);
          manager.remove(singleKey);
          (appdata.toJson()['settings'] as Map)
            ..clear()
            ..addAll(previousSettings);
          appdata.implicitData = previousImplicit;
          App.dataPath = previousDataPath ?? Directory.systemTemp.path;
          directory.deleteSync(recursive: true);
        });

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: NaviPane(
              paneItems: [
                PaneItemEntry(
                  label: 'Explore',
                  icon: Icons.explore_outlined,
                  activeIcon: Icons.explore,
                ),
              ],
              paneActions: const [],
              pageBuilder: (_) => const ExplorePage(),
              observer: NaviObserver(),
              navigatorKey: GlobalKey<NavigatorState>(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Empty Page'), findsWidgets);
        expect(appdata.implicitData['discovery_section_$dualKey'], 'browse');
        expect(find.text('Dual Browse'), findsOneWidget);
        expect(find.text('Dual Browse 2'), findsOneWidget);
        expect(appdata.implicitData['discovery_page_$dualKey'], 'Dual Browse');
        await tester.ensureVisible(find.text('Dual Browse 2'));
        await tester.tap(find.text('Dual Browse 2'));
        await tester.pumpAndSettle();
        expect(
          appdata.implicitData['discovery_page_$dualKey'],
          'Dual Browse 2',
        );

        final sourceSelector = find.byKey(
          const ValueKey('discovery_source_selector'),
        );
        final sourceRect = tester.getRect(sourceSelector);
        final sectionSelector = find.byType(SegmentedButton<DiscoverySection>);
        final sectionRect = tester.getRect(sectionSelector);
        final manageRect = tester.getRect(find.byTooltip('Manage'));
        expect(sourceRect.center.dy, closeTo(sectionRect.center.dy, 1));
        expect(sectionRect.center.dy, closeTo(manageRect.center.dy, 1));
        expect(manageRect.left, greaterThanOrEqualTo(sectionRect.right));
        expect(manageRect.left, greaterThan(sourceRect.right));
        if (App.isDesktop) {
          for (final width in [390.0, 1280.0]) {
            tester.view.physicalSize = Size(width, 844);
            await tester.pumpAndSettle();
            final menuRect = tester.getRect(
              find.byType(PopupMenuButton<String>),
            );
            final contentRect = tester.getRect(find.byType(ExplorePage));
            expect(
              contentRect.right - menuRect.right,
              lessThan(menuRect.width),
            );
          }
          tester.view.physicalSize = const Size(390, 844);
          await tester.pumpAndSettle();
        }

        final browseContentBefore = tester.getRect(
          find.text('Empty Page').first,
        );
        await tester.drag(find.text('Empty Page').first, const Offset(-200, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final categoryTitle = find.text(
          'A Long Comic Source Name That Needs Room Categories',
        );
        final categoryTitleDuringTransition = tester.getRect(categoryTitle);
        expect(
          tester.getRect(find.text('Empty Page').first).center.dx,
          lessThan(browseContentBefore.center.dx),
        );
        await tester.pumpAndSettle();
        final categoryTitleAfterTransition = tester.getRect(categoryTitle);
        expect(
          categoryTitleDuringTransition.left,
          greaterThan(categoryTitleAfterTransition.left),
        );
        expect(categoryTitle, findsOneWidget);
        expect(find.text('Empty Page'), findsNothing);
        expect(
          appdata.implicitData['discovery_section_$dualKey'],
          'categories',
        );
        final categoryTitleBeforeReturn = tester.getRect(categoryTitle);
        await tester.drag(categoryTitle, const Offset(200, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.getRect(categoryTitle).center.dx,
          greaterThan(categoryTitleBeforeReturn.center.dx),
        );
        await tester.pumpAndSettle();
        expect(find.text('Empty Page'), findsWidgets);
        expect(appdata.implicitData['discovery_section_$dualKey'], 'browse');
        expect(
          appdata.implicitData['discovery_page_$dualKey'],
          'Dual Browse 2',
        );
        expect(categoryTitle, findsNothing);

        await tester.drag(find.text('Empty Page').first, const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(find.text('Empty Page'), findsWidgets);
        expect(appdata.implicitData['discovery_section_$dualKey'], 'browse');

        await tester.tap(sourceSelector);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Single Source'));
        await tester.pumpAndSettle();
        expect(find.text('Single Browse'), findsOneWidget);
        expect(find.text('Single Browse 2'), findsOneWidget);
        await tester.drag(find.text('Empty Page').first, const Offset(-320, 0));
        await tester.pumpAndSettle();
        expect(
          appdata.implicitData['discovery_page_$singleKey'],
          'Single Browse 2',
        );
        expect(appdata.implicitData['discovery_section_$singleKey'], 'browse');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Discovery Source Derivation & Order', () {
    test(
      'derives source order by first occurrence among enabled explore pages',
      () {
        final sourceA = _createTestSource(
          key: 'source_a',
          name: 'Source A',
          explorePageTitles: ['A_Daily', 'A_Weekly'],
        );
        final sourceB = _createTestSource(
          key: 'source_b',
          name: 'Source B',
          explorePageTitles: ['B_Top', 'B_New'],
        );
        final sourceC = _createTestSource(
          key: 'source_c',
          name: 'Source C',
          explorePageTitles: ['C_All'],
        );

        // Settings ordering has B_Top first, then A_Weekly, then B_New, then A_Daily
        final enabledPages = ['B_Top', 'A_Weekly', 'B_New', 'A_Daily'];
        final ordered = ExplorePage.deriveOrderedSources(
          allSources: [sourceA, sourceB, sourceC],
          enabledExplorePages: enabledPages,
          enabledCategories: const [],
        );

        // B first because B_Top occurred first, then A because A_Weekly occurred next, C excluded
        expect(ordered.map((s) => s.key).toList(), ['source_b', 'source_a']);
      },
    );

    test('appends category-only sources in configured category order', () {
      final sourceBrowseOnly = _createTestSource(
        key: 'browse_only',
        name: 'Browse Only',
        explorePageTitles: ['BO_Page1'],
      );
      final sourceBoth = _createTestSource(
        key: 'both',
        name: 'Both',
        explorePageTitles: ['Both_Page1'],
        categoryKey: 'cat_both',
      );
      final sourceCat1 = _createTestSource(
        key: 'cat_1',
        name: 'Category 1',
        categoryKey: 'cat_key_1',
      );
      final sourceCat2 = _createTestSource(
        key: 'cat_2',
        name: 'Category 2',
        categoryKey: 'cat_key_2',
      );

      final enabledPages = ['Both_Page1', 'BO_Page1'];
      // cat_key_2 comes before cat_key_1, and cat_both is already present via explore
      final enabledCategories = ['cat_key_2', 'cat_both', 'cat_key_1'];

      final ordered = ExplorePage.deriveOrderedSources(
        allSources: [sourceBrowseOnly, sourceBoth, sourceCat1, sourceCat2],
        enabledExplorePages: enabledPages,
        enabledCategories: enabledCategories,
      );

      // 'both' first, then 'browse_only', then appended category-only: 'cat_2', then 'cat_1'
      expect(ordered.map((s) => s.key).toList(), [
        'both',
        'browse_only',
        'cat_2',
        'cat_1',
      ]);
    });

    test(
      'preserves user configured explore page order from settings within source',
      () {
        final source = _createTestSource(
          key: 'multi_page',
          name: 'Multi Page',
          explorePageTitles: ['Page_1', 'Page_2', 'Page_3'],
        );

        // User configured order in explore_pages setting has Page_3, then Page_1
        final enabledPages = ['Page_3', 'Page_1'];
        final pages = ExplorePage.getEnabledExplorePagesForSource(
          source: source,
          enabledExplorePages: enabledPages,
        );

        // Preserves existing user configured order: Page_3 before Page_1
        expect(pages.map((p) => p.title).toList(), ['Page_3', 'Page_1']);
      },
    );

    test(
      'derives both sources sharing the same explore page title in registry order',
      () {
        final sourceA = _createTestSource(
          key: 'source_a',
          name: 'Source A',
          explorePageTitles: ['Shared_Title'],
        );
        final sourceB = _createTestSource(
          key: 'source_b',
          name: 'Source B',
          explorePageTitles: ['Shared_Title'],
        );

        final ordered = ExplorePage.deriveOrderedSources(
          allSources: [sourceA, sourceB],
          enabledExplorePages: ['Shared_Title'],
          enabledCategories: const [],
        );

        // Both sources are included in deterministic registry order
        expect(ordered.map((s) => s.key).toList(), ['source_a', 'source_b']);
      },
    );

    test(
      'excludes sources with neither explore pages nor categories enabled',
      () {
        final sourceHidden = _createTestSource(
          key: 'hidden',
          name: 'Hidden',
          explorePageTitles: ['H_Page'],
          categoryKey: 'cat_hidden',
        );

        final ordered = ExplorePage.deriveOrderedSources(
          allSources: [sourceHidden],
          enabledExplorePages: ['Other_Page'],
          enabledCategories: ['other_cat'],
        );

        expect(ordered, isEmpty);
      },
    );
  });

  group('Discovery Initial Selection & Capability Fallbacks', () {
    test('initialSection categories chooses category-capable source', () {
      final sourceBrowse = _createTestSource(
        key: 'browse_only',
        name: 'Browse Only',
        explorePageTitles: ['BO_Page'],
      );
      final sourceCat = _createTestSource(
        key: 'cat_only',
        name: 'Category Only',
        categoryKey: 'cat_1',
      );

      final ordered = [sourceBrowse, sourceCat];
      final enabledPages = ['BO_Page'];
      final enabledCats = ['cat_1'];

      // Even if remembered source is browse_only, startup on categories picks cat_only
      final result = ExplorePage.resolveInitialSelection(
        orderedSources: ordered,
        enabledExplorePages: enabledPages,
        enabledCategories: enabledCats,
        requestedSection: DiscoverySection.categories,
        rememberedSourceKey: 'browse_only',
      );

      expect(result.sourceKey, 'cat_only');
      expect(result.section, DiscoverySection.categories);
    });

    test(
      'initialSection categories retains remembered source if it supports categories',
      () {
        final source1 = _createTestSource(
          key: 'src_1',
          name: 'Source 1',
          explorePageTitles: ['P1'],
          categoryKey: 'cat_1',
        );
        final source2 = _createTestSource(
          key: 'src_2',
          name: 'Source 2',
          categoryKey: 'cat_2',
        );

        final ordered = [source1, source2];
        final enabledPages = ['P1'];
        final enabledCats = ['cat_1', 'cat_2'];

        final result = ExplorePage.resolveInitialSelection(
          orderedSources: ordered,
          enabledExplorePages: enabledPages,
          enabledCategories: enabledCats,
          requestedSection: DiscoverySection.categories,
          rememberedSourceKey: 'src_2',
        );

        expect(result.sourceKey, 'src_2');
        expect(result.section, DiscoverySection.categories);
      },
    );

    test(
      'initialSection categories falls back to browse if no category source exists',
      () {
        final sourceBrowse = _createTestSource(
          key: 'browse_only',
          name: 'Browse Only',
          explorePageTitles: ['BO_Page'],
        );

        final ordered = [sourceBrowse];
        final enabledPages = ['BO_Page'];

        final result = ExplorePage.resolveInitialSelection(
          orderedSources: ordered,
          enabledExplorePages: enabledPages,
          enabledCategories: const [],
          requestedSection: DiscoverySection.categories,
        );

        expect(result.sourceKey, 'browse_only');
        expect(result.section, DiscoverySection.browse);
      },
    );

    test(
      'initialSection browse chooses browse-capable source over category-only remembered',
      () {
        final sourceCat = _createTestSource(
          key: 'cat_only',
          name: 'Cat Only',
          categoryKey: 'cat_1',
        );
        final sourceBrowse = _createTestSource(
          key: 'browse_only',
          name: 'Browse Only',
          explorePageTitles: ['BO_Page'],
        );

        final ordered = [sourceCat, sourceBrowse];
        final enabledPages = ['BO_Page'];
        final enabledCats = ['cat_1'];

        final result = ExplorePage.resolveInitialSelection(
          orderedSources: ordered,
          enabledExplorePages: enabledPages,
          enabledCategories: enabledCats,
          requestedSection: DiscoverySection.browse,
          rememberedSourceKey: 'cat_only',
        );

        expect(result.sourceKey, 'browse_only');
        expect(result.section, DiscoverySection.browse);
      },
    );

    test('empty ordered sources returns null sourceKey without throwing', () {
      final result = ExplorePage.resolveInitialSelection(
        orderedSources: const [],
        enabledExplorePages: const [],
        enabledCategories: const [],
        requestedSection: DiscoverySection.browse,
      );

      expect(result.sourceKey, isNull);
      expect(result.section, DiscoverySection.browse);
    });
  });

  group('Per-Source Section Resolution', () {
    test('dual-capability source honors remembered section', () {
      final sourceDual = _createTestSource(
        key: 'dual',
        name: 'Dual',
        explorePageTitles: ['Page'],
        categoryKey: 'cat',
      );

      final sectionCat = ExplorePage.resolveSectionForSource(
        source: sourceDual,
        enabledExplorePages: ['Page'],
        enabledCategories: ['cat'],
        rememberedSectionName: DiscoverySection.categories.name,
      );
      expect(sectionCat, DiscoverySection.categories);

      final sectionBrowse = ExplorePage.resolveSectionForSource(
        source: sourceDual,
        enabledExplorePages: ['Page'],
        enabledCategories: ['cat'],
        rememberedSectionName: DiscoverySection.browse.name,
      );
      expect(sectionBrowse, DiscoverySection.browse);
    });

    test('browse-only source forces browse section', () {
      final sourceBrowse = _createTestSource(
        key: 'browse',
        name: 'Browse',
        explorePageTitles: ['Page'],
      );

      final section = ExplorePage.resolveSectionForSource(
        source: sourceBrowse,
        enabledExplorePages: ['Page'],
        enabledCategories: const [],
        rememberedSectionName: DiscoverySection.categories.name,
      );
      expect(section, DiscoverySection.browse);
    });

    test('category-only source forces categories section', () {
      final sourceCat = _createTestSource(
        key: 'cat',
        name: 'Category',
        categoryKey: 'cat_key',
      );

      final section = ExplorePage.resolveSectionForSource(
        source: sourceCat,
        enabledExplorePages: const [],
        enabledCategories: ['cat_key'],
        rememberedSectionName: DiscoverySection.browse.name,
      );
      expect(section, DiscoverySection.categories);
    });
  });

  group('Section Retention and Capability Boundaries', () {
    test(
      'deduplicates explore page titles within source while preserving order',
      () {
        final source = _createTestSource(
          key: 'multi',
          name: 'Multi',
          explorePageTitles: ['Page_A', 'Page_B'],
        );

        // Settings has duplicates
        final enabledPages = ['Page_B', 'Page_A', 'Page_B'];
        final pages = ExplorePage.getEnabledExplorePagesForSource(
          source: source,
          enabledExplorePages: enabledPages,
        );

        expect(pages.map((p) => p.title).toList(), ['Page_B', 'Page_A']);
      },
    );

    test(
      'reconcileSelection preserves active categories section on dual-capable source when valid',
      () {
        final source = _createTestSource(
          key: 'dual',
          name: 'Dual Source',
          explorePageTitles: ['Daily'],
          categoryKey: 'cat_dual',
        );

        // Dual source has both browse and categories enabled
        final result = ExplorePage.reconcileSelection(
          orderedSources: [source],
          enabledExplorePages: ['Daily', 'Weekly'],
          enabledCategories: ['cat_dual'],
          currentSourceKey: 'dual',
          currentSection: DiscoverySection.categories,
        );

        // Stays on categories
        expect(result.sourceKey, 'dual');
        expect(result.section, DiscoverySection.categories);
      },
    );

    test(
      'reconcileSelection falls back cleanly to categories when browse capability is disabled',
      () {
        final source = _createTestSource(
          key: 'dual',
          name: 'Dual Source',
          explorePageTitles: ['Daily'],
          categoryKey: 'cat_dual',
        );

        // Explore pages disabled for this source
        final result = ExplorePage.reconcileSelection(
          orderedSources: [source],
          enabledExplorePages: const [],
          enabledCategories: ['cat_dual'],
          currentSourceKey: 'dual',
          currentSection: DiscoverySection.browse,
        );

        expect(result.sourceKey, 'dual');
        expect(result.section, DiscoverySection.categories);
      },
    );

    test(
      'reconcileSelection falls back cleanly to browse when category capability is disabled',
      () {
        final source = _createTestSource(
          key: 'dual',
          name: 'Dual Source',
          explorePageTitles: ['Daily'],
          categoryKey: 'cat_dual',
        );

        // Category disabled for this source
        final result = ExplorePage.reconcileSelection(
          orderedSources: [source],
          enabledExplorePages: ['Daily'],
          enabledCategories: const [],
          currentSourceKey: 'dual',
          currentSection: DiscoverySection.categories,
        );

        expect(result.sourceKey, 'dual');
        expect(result.section, DiscoverySection.browse);
      },
    );

    test(
      'reconcileSelection on source removal falls back to remembered source or first available',
      () {
        final sourceRemaining = _createTestSource(
          key: 'remaining',
          name: 'Remaining Source',
          explorePageTitles: ['Daily'],
        );

        // Current source was removed from orderedSources
        final result = ExplorePage.reconcileSelection(
          orderedSources: [sourceRemaining],
          enabledExplorePages: ['Daily'],
          enabledCategories: const [],
          currentSourceKey: 'removed_source',
          currentSection: DiscoverySection.categories,
          rememberedSourceKey: 'remaining',
        );

        expect(result.sourceKey, 'remaining');
        expect(result.section, DiscoverySection.browse);
      },
    );

    test(
      'purgeInvalidViews removes views for uninstalled sources or disabled capabilities',
      () {
        final sourceActive = _createTestSource(
          key: 'active',
          name: 'Active Source',
          explorePageTitles: ['Daily'],
          categoryKey: 'cat_active',
        );

        final visited = <({String sourceKey, DiscoverySection section})>{
          (sourceKey: 'active', section: DiscoverySection.browse),
          (sourceKey: 'active', section: DiscoverySection.categories),
          (sourceKey: 'deleted_source', section: DiscoverySection.browse),
        };

        // 'cat_active' is disabled, only explore page 'Daily' is enabled
        final purged = ExplorePage.purgeInvalidViews(
          visitedViews: visited,
          orderedSources: [sourceActive],
          enabledExplorePages: ['Daily'],
          enabledCategories: const [],
        );

        // Deleted source purged, active:categories purged (capability disabled), active:browse retained
        expect(purged, {
          (sourceKey: 'active', section: DiscoverySection.browse),
        });
      },
    );
  });
}
