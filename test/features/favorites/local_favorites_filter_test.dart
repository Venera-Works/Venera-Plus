import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/select.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/favorites/local_favorites_page.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/opencc.dart';

import '../../widget_test_io.dart';

FavoriteItem _favorite(String id, {String? title}) => FavoriteItem(
  id: id,
  name: title ?? 'Comic $id',
  coverPath: '',
  author: 'Author',
  type: ComicType.local,
  tags: <String>[],
);

History _history(FavoriteItem comic, int page) => History.fromMap({
  'id': comic.id,
  'type': comic.type.value,
  'time': 0,
  'ep': 1,
  'page': page,
  'max_page': 10,
});

SliverGridComics _grid(WidgetTester tester) =>
    tester.widget<SliverGridComics>(find.byType(SliverGridComics));

void _selectionAction(WidgetTester tester, String text) {
  tester
      .widgetList<MenuButton>(find.byType(MenuButton))
      .expand((menu) => menu.entries)
      .firstWhere((entry) => entry.text == text)
      .onClick();
}

void _select(WidgetTester tester, FavoriteItem comic) {
  _grid(
    tester,
  ).menuBuilder!(comic).firstWhere((entry) => entry.text == 'Select').onClick();
}

Future<void> _setReadFilter(WidgetTester tester, String filter) async {
  await tester.tap(find.byTooltip('Filter'));
  await tester.pumpAndSettle();
  final select = tester.widget<Select>(find.byType(Select));
  select.onTap!(readFilterList.indexOf(filter));
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
  await tester.pumpAndSettle();
  await runWidgetIo(tester, appdata.writeImplicitData);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, dynamic> previousSettings;
  late Map<String, dynamic> previousImplicitData;
  late LocalFavoritesManager? previousFavorites;
  late HistoryManager? previousHistory;
  late _Favorites favorites;
  late _History history;
  late Directory directory;
  late String previousDataPath;

  setUpAll(OpenCC.init);

  setUp(() {
    previousSettings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
    previousImplicitData = Map.of(appdata.implicitData);
    previousFavorites = LocalFavoritesManager.cache;
    previousHistory = HistoryManager.cache;
    try {
      previousDataPath = App.dataPath;
    } on Error {
      previousDataPath = Directory.systemTemp.path;
    }
    directory = Directory.systemTemp.createTempSync('favorites-filter-');
    App.dataPath = directory.path;
    favorites = _Favorites();
    history = _History();
    LocalFavoritesManager.cache = favorites;
    HistoryManager.cache = history;
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    appdata.settings['language'] = 'en-US';
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['blockedWordRules'] = <String, dynamic>{};
    appdata.settings['comicDisplayMode'] = 'brief';
    configureComicWidgets();
  });

  tearDown(() async {
    LocalFavoritesManager.cache = previousFavorites;
    HistoryManager.cache = previousHistory;
    favorites.dispose();
    history.dispose();
    configureComicWidgets();
    appdata.implicitData = previousImplicitData;
    appdata.settings.replaceAll(previousSettings);
    App.dataPath = previousDataPath;
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: LocalFavoritesPage(
            folder: localAllFolderLabel,
            showFolders: () {},
            onFolderSelected: (_, _) {},
            updateFolderList: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('large All lists reuse filtering during rebuild and selection', (
    tester,
  ) async {
    final probe = _ObservedFavorite('probe');
    favorites.items = [
      for (var index = 0; index < 600; index++) _favorite('$index'),
      probe,
    ];
    appdata.settings['blockedWords'] = ['unmatched keyword'];
    await mount(tester);

    final displayed = _grid(tester).comics;
    final reads = probe.descriptionReads;
    expect(displayed, orderedEquals(favorites.items));
    expect(reads, greaterThan(0));
    expect(history.lookups, 0);
    expect(favorites.loads, 1);

    _select(tester, favorites.items.first);
    await tester.pump();
    _selectionAction(tester, 'Select All');
    await tester.pump();
    expect(_grid(tester).selections!.keys, orderedEquals(favorites.items));
    _selectionAction(tester, 'Invert Selection');
    await tester.pump();
    expect(_grid(tester).selections, isEmpty);

    appdata.settings['showFavoriteStatusOnTile'] = true;
    history.changed();
    await tester.pump();
    expect(_grid(tester).comics, same(displayed));
    expect(probe.descriptionReads, reads);
    expect(history.lookups, 0);
    expect(favorites.loads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('history and keyword changes retain only visible selections', (
    tester,
  ) async {
    final reading = _favorite('reading');
    final completed = _favorite('completed');
    final unread = _favorite('unread');
    final blocked = _favorite('blocked');
    favorites.items = [reading, completed, unread, blocked];
    history.records = {
      reading.id: _history(reading, 2),
      completed.id: _history(completed, 10),
    };
    appdata.implicitData['local_favorites_read_filter'] = 'UnCompleted';
    appdata.settings['blockedWords'] = ['blocked'];
    await mount(tester);

    expect(_grid(tester).comics, [reading, unread]);
    expect(history.lookups, 4);
    final notice = tester.widget<KeywordHiddenNotice>(
      find.byType(KeywordHiddenNotice),
    );
    expect(notice.count, 1);
    expect(notice.comics(), [reading, unread, blocked]);
    expect(history.lookups, 4);

    _grid(tester).onLongPressed!(reading, 0);
    await tester.pump();
    _grid(tester).onLongPressed!(unread, 0);
    await tester.pump();
    expect(_grid(tester).selections!.keys, [reading, unread]);
    expect(history.lookups, 4);

    history.records[reading.id] = _history(reading, 10);
    history.changed();
    await tester.pump();
    expect(_grid(tester).comics, [unread]);
    expect(_grid(tester).selections!.keys, [unread]);
    expect(history.lookups, 8);
    expect(favorites.loads, 1);

    appdata.settings['blockedWords'] = <String>[];
    await tester.pump();
    expect(_grid(tester).comics, [unread, blocked]);
    expect(_grid(tester).selections!.keys, [unread]);
    expect(find.byType(KeywordHiddenNotice), findsNothing);
    expect(history.lookups, 8);
    expect(tester.takeException(), isNull);
  });

  for (final coverRoute in [false, true]) {
    testWidgets(
      'hidden history updates refresh once on return (route=$coverRoute)',
      (tester) async {
        final comic = _favorite('reading');
        favorites.items = [comic];
        appdata.implicitData['local_favorites_read_filter'] = 'UnCompleted';
        var active = true;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return LocalFavoritesPage(
                    folder: localAllFolderLabel,
                    isActive: active,
                    showFolders: () {},
                    onFolderSelected: (_, _) {},
                    updateFolderList: () {},
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
        _select(tester, comic);
        await tester.pump();
        expect(history.lookups, 1);

        if (coverRoute) {
          App.rootNavigatorKey.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => const Scaffold(body: Text('Reader')),
            ),
          );
        } else {
          update(() => active = false);
        }
        await tester.pumpAndSettle();
        history.records[comic.id] = _history(comic, 10);
        for (var index = 0; index < 5; index++) {
          history.changed();
        }
        await tester.pump();
        expect(history.lookups, 1);

        if (coverRoute) {
          App.rootNavigatorKey.currentState!.pop();
        } else {
          update(() => active = true);
        }
        await tester.pumpAndSettle();
        expect(history.lookups, 2);
        expect(find.byType(ComicTile), findsNothing);
        expect(
          find.text('Hidden by reading-status filter: 1 comics'),
          findsOneWidget,
        );
        expect(find.text('Selected 1 comics'), findsNothing);
        expect(find.byTooltip('Filter'), findsOneWidget);
        expect(favorites.loads, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('search, replacement data and rule options refresh the list', (
    tester,
  ) async {
    final cat = _favorite('cat', title: 'Cat story');
    final lowerCat = _favorite('lower-cat', title: 'cat story');
    final dog = _favorite('dog', title: 'Dog story');
    favorites.items = [cat, lowerCat, dog];
    appdata.settings['blockedWords'] = ['cat'];
    await mount(tester);
    expect(_grid(tester).comics, [cat, dog]);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Cat');
    await tester.pumpAndSettle();
    expect(_grid(tester).comics, [cat]);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(_grid(tester).comics, [cat, dog]);

    _select(tester, cat);
    await tester.pump();
    final replacement = _favorite('cat', title: 'Cat revised');
    favorites.items = [dog, replacement, lowerCat];
    favorites.changed();
    await tester.pumpAndSettle();
    expect(_grid(tester).comics, [dog, replacement]);
    expect(_grid(tester).selections!.keys.single, same(replacement));

    appdata.settings['blockedWordRules'] = {
      'cat': {'mode': 'contains', 'caseSensitive': false},
    };
    await tester.pump();
    expect(_grid(tester).comics, [dog]);
    expect(_grid(tester).selections, isEmpty);
    expect(
      tester
          .widget<KeywordHiddenNotice>(find.byType(KeywordHiddenNotice))
          .count,
      2,
    );
    expect(history.lookups, 0);
    expect(favorites.loads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reading filter changes reuse loaded data and All skips history',
    (tester) async {
      final completed = _favorite('completed');
      final unread = _favorite('unread');
      favorites.items = [completed, unread];
      history.records[completed.id] = _history(completed, 10);
      await mount(tester);
      expect(history.lookups, 0);

      await _setReadFilter(tester, 'Completed');
      expect(_grid(tester).comics, [completed]);
      expect(history.lookups, 2);
      await _setReadFilter(tester, 'UnCompleted');
      expect(_grid(tester).comics, [unread]);
      expect(history.lookups, 4);
      await _setReadFilter(tester, 'All');
      expect(_grid(tester).comics, [completed, unread]);
      expect(history.lookups, 4);
      expect(favorites.loads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('display metadata changes still apply keyword rules', (
    tester,
  ) async {
    final comic = _favorite('metadata');
    favorites.items = [comic];
    appdata.settings['blockedWords'] = ['local'];
    await mount(tester);
    expect(_grid(tester).comics, [comic]);
    _select(tester, comic);
    await tester.pump();

    appdata.settings['comicDisplayMode'] = 'detailed';
    await tester.pump();
    expect(find.byType(ComicTile), findsNothing);
    final notice = tester.widget<KeywordHiddenNotice>(
      find.byType(KeywordHiddenNotice),
    );
    expect(notice.count, 1);
    expect(notice.comics(), [comic]);
    expect(find.text('Selected 1 comics'), findsNothing);
    expect(find.byTooltip('Filter'), findsOneWidget);
    expect(history.lookups, 0);
    expect(tester.takeException(), isNull);
  });
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  List<FavoriteItem> items = [];
  int loads = 0;

  @override
  int get generation => 0;

  @override
  bool isCurrentGeneration(int generation) => generation == 0;

  @override
  int get totalComics => items.length;

  @override
  List<FavoriteItem> getAllComics() {
    loads++;
    return List.of(items);
  }

  @override
  Future<List<FavoriteItem>> getAllComicsAsync() async => getAllComics();

  @override
  bool hasNewUpdate(String id, ComicType type, [String? folder]) => false;

  void changed() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History extends HistoryManager {
  _History() : super.create();

  Map<String, History> records = {};
  int lookups = 0;

  @override
  History? find(String id, ComicType type) {
    lookups++;
    return records[id];
  }

  void changed() => notifyListeners();
}

class _ObservedFavorite extends FavoriteItem {
  _ObservedFavorite(String id)
    : super(
        id: id,
        name: 'Offscreen probe',
        coverPath: '',
        author: 'Author',
        type: ComicType.local,
        tags: <String>[],
      );

  int descriptionReads = 0;

  @override
  String get description {
    descriptionReads++;
    return super.description;
  }
}
