import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  late Map<String, dynamic> previousSettings;
  late Set<VoidCallback> listeners;
  late ComicTileState tileState;
  var presentationReads = 0;
  const settingKeys = [
    'blockedWords',
    'comicDisplayMode',
    'comicTileScale',
    'favoritesDisplayMode',
    'favoritesGalleryColumns',
    'language',
  ];

  setUp(() {
    previousSettings = {
      for (final key in settingKeys) key: appdata.settings[key],
    };
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['comicTileScale'] = 1.0;
    appdata.settings['favoritesDisplayMode'] = 'list';
    appdata.settings['favoritesGalleryColumns'] = 4;
    appdata.settings['language'] = 'en-US';
    listeners = {};
    tileState = const ComicTileState();
    presentationReads = 0;
    configureComicWidgets(
      addStateListener: listeners.add,
      removeStateListener: listeners.remove,
      tileStateResolver: (_) {
        presentationReads++;
        return tileState;
      },
      favoriteDisplayStateResolver: () => ComicFavoriteDisplayState(
        isGallery: appdata.settings['favoritesDisplayMode'] == 'gallery',
        galleryColumns: appdata.settings['favoritesGalleryColumns'],
      ),
    );
  });

  tearDown(() {
    configureComicWidgets();
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
  });

  void notifyPresentation() {
    for (final listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }

  testWidgets(
    'keyword-hidden count explains missing books and updates when cleared',
    (tester) async {
      final comics = [
        _comic('first', 'Keep'),
        _comic('second', 'Blocked title'),
      ];
      appdata.settings['blockedWords'] = ['Blocked'];
      await tester.pumpWidget(
        _host(
          CustomScrollView(
            slivers: [SliverGridComics(comics: comics, showHiddenCount: true)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hidden by keyword filters: 1 comics'), findsOneWidget);
      expect(find.text('Blocked title'), findsNothing);
      appdata.settings['blockedWords'] = <String>[];
      await tester.pumpAndSettle();
      expect(find.text('Hidden by keyword filters: 1 comics'), findsNothing);
      expect(find.text('Blocked title'), findsOneWidget);
    },
  );

  testWidgets(
    'visible badge updates do not revisit or filter the source list',
    (tester) async {
      final comics = _CountingComics([
        for (var i = 0; i < 200; i++) _comic('$i', 'Comic $i'),
      ]);
      await tester.pumpWidget(_host(_grid(comics)));
      final heroIDs = _heroIDs(tester);
      final filterPasses = comics.filterPasses;
      final previousReads = presentationReads;
      comics.reads = 0;
      tileState = const ComicTileState(isFavorite: true, historyPage: 7);

      for (var i = 0; i < 100; i++) {
        notifyPresentation();
      }
      await tester.pump();

      expect(comics.reads, 0);
      expect(comics.filterPasses, filterPasses);
      expect(presentationReads, greaterThan(previousReads));
      expect(find.byIcon(Icons.bookmark_rounded), findsWidgets);
      expect(_heroIDs(tester), heroIDs);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(listeners, isEmpty);
    },
  );

  testWidgets(
    'hidden updates merge once and detect words mutated without notification',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('comic-grid-');
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      final comics = _CountingComics([
        _comic('one', 'One'),
        _comic('two', 'Two'),
        _comic('three', 'Three'),
      ]);
      var visible = true;
      late StateSetter rebuild;
      try {
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return TickerMode(enabled: visible, child: _grid(comics));
              },
            ),
          ),
        );
        rebuild(() => visible = false);
        await tester.pump();
        final previousReads = presentationReads;
        final filterPasses = comics.filterPasses;
        comics.reads = 0;

        for (var i = 0; i < 100; i++) {
          notifyPresentation();
        }
        appdata.settings['comicDisplayMode'] = 'brief';
        rebuild(() => comics[0] = _comic('one', 'Renamed'));
        await tester.pump();
        final words = appdata.settings['blockedWords'] as List;
        words.add('Two');
        await tester.runAsync(() => appdata.saveData(false));
        await tester.pump();
        expect(comics.reads, 0);
        expect(comics.filterPasses, filterPasses);
        expect(presentationReads, previousReads);

        rebuild(() => visible = true);
        await tester.pump();
        expect(comics.filterPasses, filterPasses + 1);
        expect(_tiles(tester).map((tile) => tile.comic.title), [
          'Renamed',
          'Three',
        ]);
        final restoredReads = presentationReads;
        final restoredFilters = comics.filterPasses;
        comics.reads = 0;
        await tester.pump();
        expect(presentationReads, restoredReads);
        expect(comics.filterPasses, restoredFilters);
        expect(comics.reads, 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );

  testWidgets('a covering route defers presentation updates until pop', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final comics = _CountingComics([_comic('one', 'One')]);
    await tester.pumpWidget(_host(_grid(comics), navigator: navigator));
    navigator.currentState!.push<void>(
      DialogRoute(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Cover')),
      ),
    );
    await tester.pumpAndSettle();
    comics.reads = 0;
    final previousReads = presentationReads;
    final filterPasses = comics.filterPasses;
    tileState = const ComicTileState(isFavorite: true);
    for (var i = 0; i < 20; i++) {
      notifyPresentation();
    }
    await tester.pump();
    expect(comics.reads, 0);
    expect(comics.filterPasses, filterPasses);
    expect(presentationReads, previousReads);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
    expect(comics.filterPasses, filterPasses);
  });

  testWidgets('root reader route also suspends a grid in a nested navigator', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final comics = _CountingComics([_comic('one', 'One')]);
    await tester.pumpWidget(
      _host(
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Scaffold(body: _grid(comics)),
          ),
        ),
        navigator: navigator,
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Reader'))),
    );
    await tester.pumpAndSettle();
    final previousReads = presentationReads;
    final filterPasses = comics.filterPasses;
    comics.reads = 0;
    tileState = const ComicTileState(isFavorite: true);
    for (var i = 0; i < 20; i++) {
      notifyPresentation();
    }
    await tester.pump();
    expect(comics.reads, 0);
    expect(comics.filterPasses, filterPasses);
    expect(presentationReads, previousReads);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
    expect(comics.filterPasses, filterPasses);
  });

  testWidgets('same identity accepts fresh metadata and keeps Hero IDs', (
    tester,
  ) async {
    final comics = _CountingComics([
      _comic('one', 'Old'),
      _comic('two', 'Two'),
    ]);
    late StateSetter rebuild;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return _grid(comics);
          },
        ),
      ),
    );
    final originalHeroes = _heroIDs(tester);
    final replacement = Comic.fromJson({
      'id': 'one',
      'title': 'Updated',
      'cover': 'fresh-cover',
      'subtitle': 'Fresh subtitle',
      'description': 'Fresh description',
      'tags': ['Fresh tag'],
      'stars': 4.5,
    }, 'grid-test');
    rebuild(() => comics[0] = replacement);
    await tester.pump();
    expect(_tiles(tester).first.comic, same(replacement));
    expect(_tiles(tester).first.comic.cover, 'fresh-cover');
    expect(_tiles(tester).first.comic.stars, 4.5);
    expect(find.text('Updated'), findsOneWidget);
    expect(_heroIDs(tester), originalHeroes);

    final filterPasses = comics.filterPasses;
    rebuild(() {});
    await tester.pump();
    expect(comics.filterPasses, filterPasses);
    expect(_heroIDs(tester), originalHeroes);

    rebuild(() => comics.items = comics.items.reversed.toList());
    await tester.pump();
    expect(_tiles(tester).map((tile) => tile.comic.id), ['two', 'one']);
    expect(_heroIDs(tester), isNot(originalHeroes));
  });

  for (final favoriteDisplay in [false, true]) {
    testWidgets(
      'settings refresh layout without refiltering ($favoriteDisplay)',
      (tester) async {
        final comics = _CountingComics([_comic('one', 'One')]);
        await tester.pumpWidget(
          _host(_grid(comics, favoriteDisplay: favoriteDisplay)),
        );
        final filterPasses = comics.filterPasses;
        final heroIDs = _heroIDs(tester);
        appdata.settings['comicTileScale'] = 1.2;
        appdata.settings['comicDisplayMode'] = 'brief';
        if (favoriteDisplay) {
          appdata.settings['favoritesDisplayMode'] = 'gallery';
        }
        await tester.pump();
        final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
        final delegate = grid.gridDelegate as SliverGridDelegateWithComics;
        expect(delegate.scale, 1.2);
        expect(delegate.useBriefMode, isTrue);
        expect(delegate.galleryColumns, favoriteDisplay ? 4 : null);
        expect(comics.filterPasses, filterPasses);
        expect(_heroIDs(tester), heroIDs);

        appdata.settings['blockedWords'] = ['One'];
        await tester.pump();
        expect(find.byType(ComicTile), findsNothing);
        expect(comics.filterPasses, filterPasses + 1);
        appdata.settings['blockedWords'] = <String>[];
        await tester.pump();
        expect(find.byType(ComicTile), findsOneWidget);
        expect(_heroIDs(tester), isNot(heroIDs));
      },
    );
  }
}

Widget _host(Widget child, {GlobalKey<NavigatorState>? navigator}) =>
    MaterialApp(
      navigatorKey: navigator,
      home: Scaffold(body: child),
    );

Widget _grid(List<Comic> comics, {bool favoriteDisplay = false}) =>
    CustomScrollView(
      slivers: [
        SliverGridComics(
          comics: comics,
          useFavoriteDisplaySettings: favoriteDisplay,
        ),
      ],
    );

Comic _comic(String id, String title) =>
    Comic(title, '', id, null, null, '', 'grid-test', null, null);

List<ComicTile> _tiles(WidgetTester tester) =>
    tester.widgetList<ComicTile>(find.byType(ComicTile)).toList();

List<int?> _heroIDs(WidgetTester tester) =>
    _tiles(tester).map((tile) => tile.heroID).toList();

class _CountingComics extends ListBase<Comic> {
  _CountingComics(this.items);

  List<Comic> items;
  int reads = 0;
  int filterPasses = 0;

  @override
  int get length {
    reads++;
    return items.length;
  }

  @override
  set length(int value) => items.length = value;

  @override
  Comic operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, Comic value) => items[index] = value;

  @override
  Iterable<Comic> where(bool Function(Comic) test) {
    reads++;
    filterPasses++;
    return items.where(test);
  }
}
