import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/discovery/discovery.dart';
import 'package:venera_plus/foundation/navigation_settings.dart';
import 'package:venera_plus/foundation/res.dart';

ComicSource _createTestSource({
  required String key,
  required String name,
  List<String> explorePageTitles = const [],
  String? categoryKey,
}) {
  return ComicSource(
    name,
    key,
    null,
    categoryKey != null
        ? CategoryData(
            title: '$name Categories',
            categories: const [],
            enableRankingPage: false,
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
            (page) async => const Res<List<Comic>>(<Comic>[]),
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
