import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
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

FavoriteItem _favorite(
  String id,
  String title, {
  List<String> tags = const [],
}) => FavoriteItem(
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
    final previousSettings = Map<String, dynamic>.from(
      appdata.toJson()['settings'],
    );
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
    appdata.implicitData['favoriteFolder'] = {
      'name': 'Main',
      'isNetwork': false,
    };
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
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(body: FavoritesPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openHome(WidgetTester tester) async {
    await runWidgetIo(tester, () => manager.setReadingFolder('Main'));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          appBar: AppBar(actions: const [ReadingFavoritesMenuButton()]),
          body: const ReadingFavoritesView(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> ids(String folder) =>
      manager.getFolderComics(folder).map((comic) => comic.id).toList();
}

SliverGridComics _grid(WidgetTester tester) =>
    tester.widget<SliverGridComics>(find.byType(SliverGridComics));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(OpenCC.init);
  final skip = !_sqliteAvailable();

  testWidgets(
    'home and favorites display original sources despite shared bindings',
    (tester) async {
      final fixture = await _FavoritesFixture.create(tester);
      await fixture.openHome(tester);
      expect(_grid(tester).comics.map((comic) => comic.id), [
        'primary',
        'middle',
        'alternate',
        'tail',
      ]);
      expect(_grid(tester).comics.map((comic) => comic.title), [
        'Primary title',
        'Shared Work',
        'Hidden alias',
        'Tail',
      ]);
      await fixture.openLocal(tester);
      expect(_grid(tester).comics.map((comic) => comic.id), [
        'primary',
        'middle',
        'alternate',
        'tail',
      ]);
      final primary = _grid(tester).comics.first;
      _grid(tester).menuBuilder!(primary)
          .singleWhere((entry) => entry.text == 'Delete')
          .onClick();
      await tester.pumpAndSettle();
      expect(fixture.ids('Main'), ['middle', 'alternate', 'tail']);
      expect(fixture.ids('Outside'), ['outside']);
    },
    skip: skip,
  );

  testWidgets('tag search and selection affect only the visible source', (
    tester,
  ) async {
    final fixture = await _FavoritesFixture.create(tester);
    await fixture.openLocal(tester);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'adventure');
    await tester.pumpAndSettle();
    expect(_grid(tester).comics.single.id, 'alternate');
    final comic = _grid(tester).comics.single;
    _grid(tester).onLongPressed!(comic, 0);
    await tester.pumpAndSettle();
    expect(_grid(tester).selections!.keys.single.id, 'alternate');
    expect(fixture.ids('Main'), hasLength(4));
  }, skip: skip);

  testWidgets(
    'replacement preserves folder membership, order and persisted metadata',
    (tester) async {
      final fixture = await _FavoritesFixture.create(tester);
      final original = fixture.manager.getComic(
        'Main',
        'primary',
        ComicType.local,
      );
      fixture.manager.addComic('Outside', original, 5);
      final replacement = _favorite('replacement', 'New source')
        ..coverPath = 'https://example.invalid/new-cover.jpg';
      await runWidgetIo(tester, () async {
        fixture.manager.replaceComic(
          'primary',
          ComicType.local,
          replacement,
          updateTime: '2026-10-29',
        );
        expect(fixture.manager.isExist('primary', ComicType.local), isFalse);
        expect(fixture.manager.isExist('replacement', ComicType.local), isTrue);
        await fixture.manager.waitForPendingReads();
      });
      expect(fixture.ids('Main'), [
        'replacement',
        'middle',
        'alternate',
        'tail',
      ]);
      expect(fixture.ids('Outside'), ['outside', 'replacement']);
      expect(
        fixture.manager.getComic('Main', replacement.id, replacement.type).time,
        original.time,
      );
      await fixture.openHome(tester);
      expect(_grid(tester).comics.first.title, 'New source');
      expect(_grid(tester).comics.first.cover, replacement.cover);
      await runWidgetIo(tester, () async {
        await fixture.manager.waitForPendingReads();
        fixture.manager.close();
        await fixture.manager.init();
      });
      await tester.pumpAndSettle();
      expect(fixture.ids('Main'), [
        'replacement',
        'middle',
        'alternate',
        'tail',
      ]);
      expect(
        fixture.manager
            .getComic('Main', replacement.id, replacement.type)
            .cover,
        replacement.cover,
      );
      expect(fixture.manager.isExist('primary', ComicType.local), isFalse);
      expect(fixture.manager.isExist('replacement', ComicType.local), isTrue);
    },
    skip: skip,
  );

  testWidgets(
    'replacement deduplicates its target without changing other bound entries',
    (tester) async {
      final fixture = await _FavoritesFixture.create(tester);
      fixture.manager.replaceComic(
        'primary',
        ComicType.local,
        _favorite('alternate', 'Selected source'),
      );
      await runWidgetIo(tester, fixture.manager.waitForPendingReads);
      expect(fixture.ids('Main'), ['alternate', 'middle', 'tail']);
      expect(fixture.ids('Outside'), ['outside']);
      expect(fixture.manager.folderComics('Main'), 3);
      expect(
        fixture.manager.getComic('Main', 'alternate', ComicType.local).title,
        'Selected source',
      );
      expect(fixture.history.find('primary', ComicType.local), isNull);
    },
    skip: skip,
  );

  testWidgets('a failed replacement rolls back every folder', (tester) async {
    final fixture = await _FavoritesFixture.create(tester);
    fixture.manager.addComic('Outside', _favorite('primary', 'Primary title'));
    final database = sqlite3.open('${App.dataPath}/local_favorite.db');
    database.execute(
      '''CREATE TRIGGER reject_replacement BEFORE UPDATE ON "Outside"
      WHEN NEW.id = 'replacement' BEGIN SELECT RAISE(ABORT, 'test failure'); END;''',
    );
    database.dispose();
    expect(
      () => fixture.manager.replaceComic(
        'primary',
        ComicType.local,
        _favorite('replacement', 'Replacement'),
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(fixture.ids('Main'), ['primary', 'middle', 'alternate', 'tail']);
    expect(fixture.ids('Outside'), contains('primary'));
    expect(fixture.manager.isExist('replacement', ComicType.local), isFalse);
  }, skip: skip);
}
