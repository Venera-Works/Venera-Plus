import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

import '../../widget_test_io.dart';

List<String> _comicOrder(WidgetTester tester, {Finder? within}) {
  final scope = within ?? find.byType(ReorderableBuilder<FavoriteItem>);
  final tiles = tester.widgetList<ComicTile>(
    find.descendant(of: scope, matching: find.byType(ComicTile)),
  );
  final seen = <String>{};
  final items = <({String id, Offset center})>[];
  for (final tile in tiles) {
    if (!seen.add(tile.comic.id)) continue;
    final finder = find.descendant(
      of: scope,
      matching: find.byWidgetPredicate(
        (widget) => widget is ComicTile && widget.comic.id == tile.comic.id,
      ),
    );
    items.add((id: tile.comic.id, center: tester.getCenter(finder)));
  }
  items.sort((a, b) => a.center.dy.compareTo(b.center.dy));
  const rowTolerance = 12.0;
  final rows = <List<({String id, Offset center})>>[];
  for (final item in items) {
    if (rows.isEmpty ||
        (item.center.dy - rows.last.first.center.dy).abs() > rowTolerance) {
      rows.add([item]);
    } else {
      rows.last.add(item);
    }
  }
  for (final row in rows) {
    row.sort((a, b) => a.center.dx.compareTo(b.center.dx));
  }
  return rows.expand((row) => row).map((item) => item.id).toList();
}

Future<void> _openReorder(WidgetTester tester) async {
  final menu = find.byWidgetPredicate(
    (widget) =>
        widget is MenuButton &&
        widget.entries.any((entry) => entry.text == 'Reorder'),
  );
  tester
      .widget<MenuButton>(menu)
      .entries
      .singleWhere((entry) => entry.text == 'Reorder')
      .onClick();
  await tester.pumpAndSettle();
  expect(find.byType(ReorderableBuilder<FavoriteItem>), findsOneWidget);
}

bool _sqliteAvailable() {
  try {
    final database = sqlite3.openInMemory();
    database.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  testWidgets(
    'home folder reorder updates and persists without affecting other folders',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'venera-home-favorite-order-',
      );
      final previousSettings = Map<String, dynamic>.from(
        appdata.toJson()['settings'],
      );
      final previousFavorites = LocalFavoritesManager.cache;
      final previousHistory = HistoryManager.cache;
      String? previousDataPath;
      String? previousCachePath;
      try {
        previousDataPath = App.dataPath;
      } on Error {
        /* Unset late path. */
      }
      try {
        previousCachePath = App.cachePath;
      } on Error {
        /* Unset late path. */
      }
      final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      appdata.settings.remove('readingFolder');
      HistoryManager.cache = null;
      LocalFavoritesManager.cache = null;
      var manager = LocalFavoritesManager();
      var history = HistoryManager();
      appdata.settings['language'] = 'en-US';
      appdata.settings['comicDisplayMode'] = 'brief';
      appdata.settings[favoriteDisplayModeKey] = favoriteDisplayList;
      appdata.settings[favoriteGalleryColumnsKey] = 0;
      configureComicWidgets(
        favoriteDisplayStateResolver: () => ComicFavoriteDisplayState(
          isGallery: isFavoriteGalleryMode(),
          galleryColumns: favoriteGalleryColumns(),
        ),
      );
      addTearDown(configureComicWidgets);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await runWidgetIo(tester, () async {
          await manager.waitForPendingReads();
          await appdata.saveData(false);
          manager.close();
          history.close();
        });
        LocalFavoritesManager.cache = previousFavorites;
        HistoryManager.cache = previousHistory;
        (appdata.toJson()['settings'] as Map)
          ..clear()
          ..addAll(previousSettings);
        App.dataPath = previousDataPath ?? Directory.systemTemp.path;
        App.cachePath = previousCachePath ?? Directory.systemTemp.path;
        appdata.implicitData = previousImplicit;
        directory.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pump();
      await runWidgetIo(tester, () async {
        await manager.init();
        await history.init();
        for (final folder in ['Home reorder', 'Other folder']) {
          manager.createFolder(folder);
          final prefix = folder == 'Home reorder' ? 'home' : 'other';
          for (var i = 0; i < 6; i++) {
            manager.addComic(
              folder,
              FavoriteItem(
                id: '$prefix-$i',
                name: '$prefix Comic $i',
                coverPath: '',
                author: '',
                type: ComicType.local,
                tags: const [],
              ),
              i,
            );
          }
        }
        await manager.waitForPendingReads();
      });

      Widget homePage() => MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          appBar: AppBar(actions: [const ReadingFavoritesMenuButton()]),
          body: const ReadingFavoritesView(),
        ),
      );

      await tester.pumpWidget(homePage());
      await tester.pumpAndSettle();
      final unboundMenu = tester
          .widgetList<MenuButton>(find.byType(MenuButton))
          .single;
      expect(
        unboundMenu.entries.any((entry) => entry.text == 'Reorder'),
        isFalse,
      );

      await runWidgetIo(tester, () => manager.setReadingFolder('Home reorder'));
      await tester.pumpAndSettle();
      final initialOrder = [for (var i = 0; i < 6; i++) 'home-$i'];
      final otherOrder = [for (var i = 0; i < 6; i++) 'other-$i'];
      expect(
        _comicOrder(tester, within: find.byType(SliverGridComics)),
        initialOrder,
      );
      await _openReorder(tester);
      expect(_comicOrder(tester), initialOrder);

      Finder tile(String id) => find.byWidgetPredicate(
        (widget) => widget is ComicTile && widget.comic.id == id,
      );
      final builder = tester.widget<ReorderableBuilder<FavoriteItem>>(
        find.byType(ReorderableBuilder<FavoriteItem>),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(tile('home-0')),
      );
      await tester.pump(
        builder.longPressDelay + const Duration(milliseconds: 50),
      );
      await gesture.moveTo(tester.getCenter(tile('home-2')));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      const expectedOrder = [
        'home-1',
        'home-2',
        'home-0',
        'home-3',
        'home-4',
        'home-5',
      ];
      expect(_comicOrder(tester), expectedOrder);
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        _comicOrder(tester, within: find.byType(SliverGridComics)),
        expectedOrder,
      );
      expect(
        manager.getFolderComics('Home reorder').map((comic) => comic.id),
        expectedOrder,
      );
      expect(
        manager.getFolderComics('Other folder').map((comic) => comic.id),
        otherOrder,
      );

      await _openReorder(tester);
      expect(_comicOrder(tester), expectedOrder);
      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();
      final reversedOrder = expectedOrder.reversed.toList();
      expect(_comicOrder(tester), reversedOrder);
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        _comicOrder(tester, within: find.byType(SliverGridComics)),
        reversedOrder,
      );
      expect(
        manager.getFolderComics('Home reorder').map((comic) => comic.id),
        reversedOrder,
      );
      expect(
        manager.getFolderComics('Other folder').map((comic) => comic.id),
        otherOrder,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await runWidgetIo(tester, () async {
        await manager.waitForPendingReads();
        manager.close();
        LocalFavoritesManager.cache = null;
        manager = LocalFavoritesManager();
        await manager.init();
        await manager.waitForPendingReads();
      });
      await tester.pumpWidget(homePage());
      await tester.pumpAndSettle();
      expect(
        _comicOrder(tester, within: find.byType(SliverGridComics)),
        reversedOrder,
      );
      expect(
        manager.getFolderComics('Other folder').map((comic) => comic.id),
        otherOrder,
      );
      expect(tester.takeException(), isNull);
    },
    skip: !_sqliteAvailable(),
  );

  for (final columns in <int?>[null, 4, 0]) {
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      testWidgets(
        'favorite ${kind.name} columns $columns keeps layout and drag order',
        (tester) async {
          final directory = Directory.systemTemp.createTempSync(
            'venera-favorite-order-',
          );
          final previousSettings = Map<String, dynamic>.from(
            appdata.toJson()['settings'],
          );
          final previousFavorites = LocalFavoritesManager.cache;
          final previousHistory = HistoryManager.cache;
          String? previousDataPath;
          String? previousCachePath;
          try {
            previousDataPath = App.dataPath;
          } on Error {
            /* Unset late path. */
          }
          try {
            previousCachePath = App.cachePath;
          } on Error {
            /* Unset late path. */
          }
          final previousImplicit = Map<String, dynamic>.from(
            appdata.implicitData,
          );
          App.dataPath = directory.path;
          App.cachePath = directory.path;
          appdata.settings.remove('readingFolder');
          LocalFavoritesManager.cache = null;
          HistoryManager.cache = null;
          var manager = LocalFavoritesManager();
          final history = HistoryManager();
          appdata.settings['comicDisplayMode'] = 'brief';
          appdata.settings[favoriteDisplayModeKey] = columns == null
              ? favoriteDisplayList
              : favoriteDisplayGallery;
          appdata.settings[favoriteGalleryColumnsKey] = columns ?? 0;
          configureComicWidgets(
            favoriteDisplayStateResolver: () => ComicFavoriteDisplayState(
              isGallery: isFavoriteGalleryMode(),
              galleryColumns: favoriteGalleryColumns(),
            ),
          );
          addTearDown(configureComicWidgets);
          appdata.settings['language'] = 'en-US';
          appdata.implicitData['favoriteFolder'] = {
            'name': 'Reorder test',
            'isNetwork': false,
          };
          appdata.implicitData['local_favorites_read_filter'] = 'All';
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(const Duration(milliseconds: 300));
            await runWidgetIo(tester, () async {
              await manager.waitForPendingReads();
              await appdata.saveData(false);
              manager.close();
              history.close();
            });
            LocalFavoritesManager.cache = previousFavorites;
            HistoryManager.cache = previousHistory;
            (appdata.toJson()['settings'] as Map)
              ..clear()
              ..addAll(previousSettings);
            App.dataPath = previousDataPath ?? Directory.systemTemp.path;
            App.cachePath = previousCachePath ?? Directory.systemTemp.path;
            appdata.implicitData = previousImplicit;
            directory.deleteSync(recursive: true);
          });
          tester.view.physicalSize = const Size(900, 1600);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pump();
          await runWidgetIo(tester, () async {
            await manager.init();
            await history.init();
            manager.createFolder('Reorder test');
            for (var i = 0; i < 6; i++) {
              manager.addComic(
                'Reorder test',
                FavoriteItem(
                  id: 'comic-$i',
                  name: 'Comic $i',
                  coverPath: '',
                  author: '',
                  type: ComicType.local,
                  tags: const [],
                ),
                i,
              );
            }
            await manager.waitForPendingReads();
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: kind == PointerDeviceKind.mouse
                    ? Brightness.dark
                    : Brightness.light,
              ),
              navigatorKey: App.rootNavigatorKey,
              home: const Scaffold(body: FavoritesPage()),
            ),
          );
          await tester.pumpAndSettle();
          Finder tile(String id) => find.byWidgetPredicate(
            (widget) => widget is ComicTile && widget.comic.id == id,
          );
          final sizes = <double, Size>{};
          for (final width in [375.0, 900.0]) {
            tester.view.physicalSize = Size(width, 1600);
            await tester.pumpAndSettle();
            final grid = tester.renderObject<RenderSliver>(
              find.byType(SliverGridComics),
            );
            sizes[grid.constraints.crossAxisExtent] = tester.getSize(
              tile('comic-0'),
            );
          }
          await _openReorder(tester);
          expect(_comicOrder(tester), [for (var i = 0; i < 6; i++) 'comic-$i']);
          for (final width in sizes.keys) {
            tester.view.physicalSize = Size(width, 1600);
            await tester.pumpAndSettle();
            expect(tester.getSize(tile('comic-0')), sizes[width]);
            expect(
              tester.widget<ComicTile>(tile('comic-0')).displayMode,
              columns == null
                  ? ComicTileDisplayMode.detailed
                  : ComicTileDisplayMode.gallery,
            );
            expect(tester.takeException(), isNull);
          }
          tester.view.physicalSize = const Size(900, 1600);
          await tester.pumpAndSettle();

          // Dynamic settings update listener check
          appdata.settings[favoriteDisplayModeKey] = columns == null
              ? favoriteDisplayGallery
              : favoriteDisplayList;
          await tester.pump();
          expect(
            tester.widget<ComicTile>(tile('comic-0')).displayMode,
            columns == null
                ? ComicTileDisplayMode.gallery
                : ComicTileDisplayMode.detailed,
          );
          appdata.settings[favoriteDisplayModeKey] = columns == null
              ? favoriteDisplayList
              : favoriteDisplayGallery;
          await tester.pump();

          final target = tester.getCenter(tile('comic-2'));
          final builder = tester.widget<ReorderableBuilder<FavoriteItem>>(
            find.byType(ReorderableBuilder<FavoriteItem>),
          );
          final gesture = await tester.startGesture(
            tester.getCenter(tile('comic-0')),
            kind: kind,
          );
          await tester.pump(
            builder.longPressDelay + const Duration(milliseconds: 50),
          );
          await gesture.moveTo(target);
          await tester.pump(const Duration(milliseconds: 300));
          await gesture.up();
          await tester.pumpAndSettle();
          const expected = [
            'comic-1',
            'comic-2',
            'comic-0',
            'comic-3',
            'comic-4',
            'comic-5',
          ];
          expect(_comicOrder(tester), expected);

          App.rootNavigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 250));
          expect(
            manager.getFolderComics('Reorder test').map((comic) => comic.id),
            expected,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await runWidgetIo(tester, () async {
            await manager.waitForPendingReads();
            manager.close();
            LocalFavoritesManager.cache = null;
            manager = LocalFavoritesManager();
            await manager.init();
            await manager.waitForPendingReads();
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: kind == PointerDeviceKind.mouse
                    ? Brightness.dark
                    : Brightness.light,
              ),
              navigatorKey: App.rootNavigatorKey,
              home: const Scaffold(body: FavoritesPage()),
            ),
          );
          tester.view.physicalSize = const Size(900, 1600);
          await tester.pumpAndSettle();
          await _openReorder(tester);
          expect(_comicOrder(tester), expected);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 300));
        },
        skip: !_sqliteAvailable(),
      );
    }
  }
}
