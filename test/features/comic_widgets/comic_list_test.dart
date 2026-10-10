import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/res.dart';

void main() {
  testWidgets('ComicList stores mutable page data from unmodifiable results', (
    tester,
  ) async {
    final key = GlobalKey<ComicListState>();
    const comic = Comic(
      'Cat Eye',
      '',
      'cat-eye',
      null,
      null,
      '',
      'webdav_library',
      null,
      null,
    );
    final oldListMode = appdata.settings['comicListDisplayMode'];
    final oldDisplayMode = appdata.settings['comicDisplayMode'];
    final oldBlockedWords = appdata.settings['blockedWords'];
    final oldFavoriteStatus = appdata.settings['showFavoriteStatusOnTile'];
    final oldHistoryStatus = appdata.settings['showHistoryStatusOnTile'];
    final oldUpdateStatus = appdata.settings['showUpdateStatusOnTile'];

    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['showUpdateStatusOnTile'] = false;
    addTearDown(() {
      appdata.settings['comicListDisplayMode'] = oldListMode;
      appdata.settings['comicDisplayMode'] = oldDisplayMode;
      appdata.settings['blockedWords'] = oldBlockedWords;
      appdata.settings['showFavoriteStatusOnTile'] = oldFavoriteStatus;
      appdata.settings['showHistoryStatusOnTile'] = oldHistoryStatus;
      appdata.settings['showUpdateStatusOnTile'] = oldUpdateStatus;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageStorage(
            bucket: PageStorageBucket(),
            child: ComicList(
              key: key,
              enablePageStorage: true,
              loadPage: (_) async =>
                  Res(List<Comic>.unmodifiable([comic]), subData: 1),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Cat Eye'), findsOneWidget);
    expect(() => key.currentState!.remove(comic), returnsNormally);
    await tester.pump();
    expect(find.text('Cat Eye'), findsNothing);
  });

  for (final mode in ['paging', 'Continuous']) {
    testWidgets('favorite badge suppression preserves other badges in $mode', (
      tester,
    ) async {
      final previousSettings = Map<String, dynamic>.from(
        appdata.toJson()['settings'] as Map,
      );
      var gallery = false;
      configureComicWidgets(
        tileStateResolver: (_) => const ComicTileState(
          isFavorite: true,
          historyPage: 2,
          historyMaxPage: 10,
          hasNewUpdate: true,
        ),
        favoriteDisplayStateResolver: () =>
            ComicFavoriteDisplayState(isGallery: gallery),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        configureComicWidgets();
        appdata.settings.replaceAll(previousSettings);
      });
      appdata.settings['comicListDisplayMode'] = mode;
      appdata.settings['blockedWords'] = <String>[];
      appdata.settings['showFavoriteStatusOnTile'] = true;
      appdata.settings['showHistoryStatusOnTile'] = true;
      appdata.settings['showUpdateStatusOnTile'] = true;
      const comic = Comic(
        'Favorite status comic',
        '',
        'badge-comic',
        null,
        null,
        '',
        'test-source',
        null,
        null,
      );
      Future<Res<List<Comic>>> loadPage(int _) async =>
          Res<List<Comic>>(const [comic], subData: 1);
      Widget page({bool hideFavoriteBadge = false}) => MaterialApp(
        home: Scaffold(
          body: ComicList(
            loadPage: loadPage,
            useFavoriteDisplaySettings: true,
            hideFavoriteBadge: hideFavoriteBadge,
          ),
        ),
      );

      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
      for (final isGallery in [false, true]) {
        gallery = isGallery;
        await tester.pumpWidget(page(hideFavoriteBadge: true));
        await tester.pumpAndSettle();
        final tile = find.byType(ComicTile);
        expect(find.text('Favorite status comic'), findsOneWidget);
        expect(find.byIcon(Icons.bookmark_rounded), findsNothing);
        expect(
          find.descendant(of: tile, matching: find.byType(CustomPaint)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: tile, matching: find.byIcon(Icons.update)),
          findsOneWidget,
        );
      }
    });
  }
}
