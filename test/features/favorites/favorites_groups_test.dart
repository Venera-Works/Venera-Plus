import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/opencc.dart';

import '../../widget_test_io.dart';

bool _sqliteAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

FavoriteItem _favorite(String id, String title, {List<String> tags = const []}) =>
    FavoriteItem(
      id: id,
      name: title,
      coverPath: '',
      author: '',
      type: ComicType.local,
      tags: tags,
    );

BangumiBinding _binding(String id) => BangumiBinding(
  sourceKey: 'local',
  comicId: id,
  subjectId: 42,
  subjectTitle: 'Shared Work',
  subjectOriginalTitle: 'Original Work',
  coverUrl: '',
  progressMode: BangumiProgressMode.auto,
  totalEpisodes: 10,
  totalVolumes: 1,
  lastRemoteEpisode: 0,
  lastRemoteVolume: 0,
  rating: 0,
);

void _setBindings(Iterable<String> ids) {
  appdata.settings['bangumiBindings'] = {
    for (final id in ids) bangumiBindingKey('local', id): _binding(id).toJson(),
  };
}

class _FavoritesFixture {
  _FavoritesFixture(this.manager, this.history);

  final LocalFavoritesManager manager;
  final HistoryManager history;

  static Future<_FavoritesFixture> create(WidgetTester tester) async {
    final directory = Directory.systemTemp.createTempSync('venera-groups-');
    final previousSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
    final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    final previousFavorites = LocalFavoritesManager.cache;
    final previousHistory = HistoryManager.cache;
    String? previousDataPath;
    String? previousCachePath;
    try {
      previousDataPath = App.dataPath;
    } on Error {
      // Paths are unset before the first fixture.
    }
    try {
      previousCachePath = App.cachePath;
    } on Error {
      // Paths are unset before the first fixture.
    }
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    LocalFavoritesManager.cache = null;
    HistoryManager.cache = null;
    final manager = LocalFavoritesManager();
    final history = HistoryManager();
    appdata.settings['language'] = 'en-US';
    appdata.settings['bangumiAccessToken'] = '';
    appdata.settings['bangumiUsername'] = '';
    appdata.settings.remove('readingFolder');
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['comicDisplayMode'] = 'brief';
    appdata.settings[favoriteDisplayModeKey] = favoriteDisplayList;
    appdata.settings[favoriteGalleryColumnsKey] = 0;
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['showUpdateStatusOnTile'] = false;
    appdata.implicitData['favoriteFolder'] = {'name': 'Main', 'isNetwork': false};
    appdata.implicitData['local_favorites_read_filter'] = 'All';
    _setBindings(['primary', 'alternate', 'outside']);
    configureComicWidgets(
      favoriteDisplayStateResolver: () => ComicFavoriteDisplayState(
        isGallery: isFavoriteGalleryMode(),
        galleryColumns: favoriteGalleryColumns(),
      ),
    );
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await runWidgetIo(tester, () async {
        await manager.waitForPendingReads();
        await appdata.saveData(false);
        manager.close();
        history.close();
      });
      configureComicWidgets();
      LocalFavoritesManager.cache = previousFavorites;
      HistoryManager.cache = previousHistory;
      (appdata.toJson()['settings'] as Map)
        ..clear()
        ..addAll(previousSettings);
      appdata.implicitData = previousImplicit;
      App.dataPath = previousDataPath ?? Directory.systemTemp.path;
      App.cachePath = previousCachePath ?? Directory.systemTemp.path;
      directory.deleteSync(recursive: true);
    });
    await tester.pump();
    await runWidgetIo(tester, () async {
      await manager.init();
      await history.init();
      for (final folder in ['Main', 'Outside', 'Target A', 'Target B']) {
        manager.createFolder(folder);
      }
      final favorites = [
        _favorite('primary', 'Primary title'),
        _favorite('middle', 'Shared Work'),
        _favorite('alternate', 'Hidden alias', tags: ['kind:adventure']),
        _favorite('tail', 'Tail'),
      ];
      for (final (index, favorite) in favorites.indexed) {
        manager.addComic('Main', favorite, index);
      }
      manager.addComic('Outside', _favorite('outside', 'Outside source'));
      await manager.waitForPendingReads();
    });
    return _FavoritesFixture(manager, history);
  }

  Future<void> openLocal(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: const Scaffold(body: FavoritesPage()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openHome(WidgetTester tester) async {
    await runWidgetIo(tester, () => manager.setReadingFolder('Main'));
    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: Scaffold(
        appBar: AppBar(actions: const [ReadingFavoritesMenuButton()]),
        body: const ReadingFavoritesView(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  List<String> ids(String folder) =>
      manager.getFolderComics(folder).map((comic) => comic.id).toList();
}

SliverGridComics _grid(WidgetTester tester) =>
    tester.widget<SliverGridComics>(find.byType(SliverGridComics));

BangumiComicGroup<FavoriteItem> _work(WidgetTester tester) =>
    _grid(tester).comics.cast<BangumiComicGroup<FavoriteItem>>()
        .singleWhere((group) => group.subjectId == 42);

void _toolbarAction(WidgetTester tester, String title) {
  tester.widgetList<MenuButton>(find.byType(MenuButton))
      .expand((menu) => menu.entries)
      .singleWhere((entry) => entry.text == title)
      .onClick();
}

Future<void> _selectWork(WidgetTester tester) async {
  _grid(tester).onLongPressed!(_work(tester), 0);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(OpenCC.init);
  final skip = !_sqliteAvailable();

  testWidgets('home and local favorites group only current folder members', (tester) async {
    final fixture = await _FavoritesFixture.create(tester);
    await fixture.openHome(tester);
    expect(_grid(tester).comics.length, 3);
    expect(_work(tester).members.map((item) => item.id), ['primary', 'alternate']);
    expect(fixture.ids('Main'), ['primary', 'middle', 'alternate', 'tail']);
    expect(fixture.ids('Outside'), ['outside']);

    await fixture.openLocal(tester);
    expect(_grid(tester).comics.length, 3);
    expect(find.text('4 source entries'), findsOneWidget);
    expect(_work(tester).members.map((item) => item.id), ['primary', 'alternate']);
    await _selectWork(tester);
    expect(_grid(tester).selections!.length, 1);
    _setBindings(['primary', 'outside']);
    await tester.pumpAndSettle();
    expect(_grid(tester).comics.length, 4);
    expect(_grid(tester).selections, isEmpty);
    expect(find.text('Selected 1 comics'), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: skip);

  testWidgets('searching any member or Bangumi title preserves all current members', (tester) async {
    final fixture = await _FavoritesFixture.create(tester);
    await fixture.openLocal(tester);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    for (final query in ['Hidden alias', 'Primary title', 'Original Work', 'adventure']) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pumpAndSettle();
      expect(_grid(tester).comics.length, 1, reason: query);
      expect(_work(tester).members.map((item) => item.id), ['primary', 'alternate']);
    }
    await _selectWork(tester);
    _toolbarAction(tester, 'Select All');
    await tester.pumpAndSettle();
    expect(_grid(tester).selections!.length, 1);
    _toolbarAction(tester, 'Deselect');
    await tester.pumpAndSettle();
    final group = _work(tester);
    _grid(tester).menuBuilder!(group).singleWhere((entry) => entry.text == 'Delete').onClick();
    await tester.pumpAndSettle();
    expect(fixture.ids('Main'), ['middle', 'tail']);
    expect(fixture.ids('Outside'), ['outside']);
    expect(tester.takeException(), isNull);
  }, skip: skip);

  for (final move in [false, true]) {
    testWidgets('${move ? 'move' : 'copy'} expands a selected work to every target folder', (tester) async {
      final fixture = await _FavoritesFixture.create(tester);
      await fixture.openLocal(tester);
      await _selectWork(tester);
      _toolbarAction(tester, move ? 'Move to folder' : 'Copy to folder');
      await tester.pumpAndSettle();
      for (final target in ['Target A', 'Target B']) {
        await tester.tap(find.widgetWithText(CheckboxListTile, target));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.widgetWithText(FilledButton, move ? 'Move' : 'Add'));
      await tester.pumpAndSettle();
      for (final target in ['Target A', 'Target B']) {
        expect(fixture.ids(target), ['primary', 'alternate']);
      }
      expect(fixture.ids('Main'), move ? ['middle', 'tail'] : ['primary', 'middle', 'alternate', 'tail']);
      expect(fixture.ids('Outside'), ['outside']);
      expect(tester.takeException(), isNull);
    }, skip: skip);
  }

  testWidgets('selection follows reading and keyword filters and latest member history', (tester) async {
    final fixture = await _FavoritesFixture.create(tester);
    appdata.implicitData['local_favorites_read_filter'] = 'UnCompleted';
    appdata.settings['blockedWords'] = ['blocked-tag'];
    await runWidgetIo(tester, () async {
      fixture.manager.addComic('Main', _favorite('blocked', 'Blocked', tags: ['blocked-tag']), 4);
      for (final (id, page, time) in [
        ('primary', 2, 3000),
        ('alternate', 10, 1000),
        ('middle', 10, 2000),
      ]) {
        fixture.history.addHistory(History.fromMap({
          'id': id,
          'type': 0,
          'time': time,
          'title': id,
          'ep': 1,
          'page': page,
          'max_page': 10,
        }));
      }
      await fixture.manager.waitForPendingReads();
    });
    await fixture.openLocal(tester);
    expect(_grid(tester).comics.map((comic) => comic.id), ['primary', 'tail']);
    expect(_work(tester).representative.id, 'primary');
    await _selectWork(tester);
    _toolbarAction(tester, 'Select All');
    await tester.pumpAndSettle();
    expect(_grid(tester).selections!.keys.map((comic) => comic.id), ['primary', 'tail']);
    _toolbarAction(tester, 'Deselect');
    await tester.pumpAndSettle();
    await _selectWork(tester);
    final tail = _grid(tester).comics.singleWhere((comic) => comic.id == 'tail');
    _grid(tester).onLongPressed!(tail, 1);
    await tester.pumpAndSettle();
    expect(_grid(tester).selections!.length, 2);
    _toolbarAction(tester, 'Invert Selection');
    await tester.pumpAndSettle();
    expect(_grid(tester).selections, isEmpty);
    expect(tester.takeException(), isNull);
  }, skip: skip);

  testWidgets('group downloads ask for a source even with recent reading history', (tester) async {
    final fixture = await _FavoritesFixture.create(tester);
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    addTearDown(LocalManager.resetForTesting);
    final local = LocalManager();
    await runWidgetIo(tester, () async {
      await local.init();
      await local.add(LocalComic(
        id: 'primary',
        title: 'Primary title',
        subtitle: '',
        tags: const [],
        directory: 'primary',
        chapters: null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime(2026),
      ));
      fixture.history.addHistory(History.fromMap({
        'id': 'primary',
        'type': 0,
        'time': 3000,
        'title': 'Primary title',
        'ep': 1,
        'page': 2,
        'max_page': 10,
      }));
    });
    await fixture.openLocal(tester);
    _grid(tester).menuBuilder!(_work(tester))
        .singleWhere((entry) => entry.text == 'Download').onClick();
    await tester.pumpAndSettle();
    expect(find.text('Choose comic source'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-source:local:primary')), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-source:local:alternate')), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-source:local:outside')), findsNothing);
    expect(local.downloadingTasks, isEmpty);
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(local.downloadingTasks, isEmpty);
    expect(tester.takeException(), isNull);
  }, skip: skip);

  testWidgets('reversing work order persists member blocks only in the current folder', (tester) async {
    final fixture = await _FavoritesFixture.create(tester);
    await fixture.openHome(tester);
    _toolbarAction(tester, 'Reorder');
    await tester.pumpAndSettle();
    expect(tester.widgetList<ComicTile>(find.byType(ComicTile)).length, 3);
    await tester.tap(find.byIcon(Icons.swap_vert));
    await tester.pumpAndSettle();
    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    expect(fixture.ids('Main'), ['tail', 'middle', 'primary', 'alternate']);
    expect(fixture.ids('Outside'), ['outside']);
    expect(_grid(tester).comics.map((comic) => comic.id), ['tail', 'middle', 'primary']);
    expect(tester.takeException(), isNull);
  }, skip: skip);
}
