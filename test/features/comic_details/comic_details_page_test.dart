import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:image/image.dart' as img;
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/custom_slider.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_details/chapters.dart';
import 'package:venera_plus/features/comic_details/thumbnails.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/comic_image.dart';
import 'package:venera_plus/features/reader/brightness.dart';
import 'package:venera_plus/features/reader/chapters.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/reader/reader.dart' show ReaderWithLoading;
import 'package:venera_plus/features/reader/scaffold.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sync_records.dart';

const _testRoundId = '00000000-0000-4000-8000-000000000001';

void main() {
  test(
    'read-only comic info namespaces exclude searchable author and tag fields',
    () {
      expect(isReadOnlyComicInfoNamespaceForTesting('views'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('浏览量'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('last update'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('作者'), isFalse);
      expect(isReadOnlyComicInfoNamespaceForTesting('标签'), isFalse);

      expect(isReadOnlyComicInfoNamespaceForTesting('artist'), isFalse);
      expect(isReadOnlyComicInfoNamespaceForTesting('language'), isFalse);

      expect(isAuthorNamespace('author'), isTrue);
      expect(isAuthorNamespace('artist'), isTrue);
      expect(isAuthorNamespace('language'), isFalse);
    },
  );

  for (final entry in ['details', 'reader', 'direct-reader']) {
    final fromReader = entry != 'details';
    final directReader = entry == 'direct-reader';
    testWidgets(
      'source preview and confirmation replace the active page (entry=$entry)',
      (tester) async {
        final fixture = await _createFixture(tester, grouped: false);
        final targetKey = '${fixture.sourceKey}_replacement';
        final target = ComicDetails.fromJson({
          'title': 'Alternate source',
          'cover': fixture.imageUrls.last,
          'description': 'Alternate description',
          'tags': <String, dynamic>{},
          'chapters': {'different-chapter': 'Different chapter'},
          'sourceKey': targetKey,
          'comicId': 'replacement',
        });
        final candidate = Comic(
          'Alternate source',
          target.cover,
          target.id,
          null,
          null,
          '',
          targetKey,
          null,
          null,
        );
        final searches = <String>[];
        ComicSourceManager().add(
          _comicSource(
            sourceKey: targetKey,
            details: target,
            imageUrls: fixture.imageUrls,
            requestedChapterIds: [],
            searchPageData: SearchPageData(const [], (
              keyword,
              page,
              options,
            ) async {
              searches.add(keyword);
              return Res([candidate], subData: 1);
            }, null),
          ),
        );
        addTearDown(() => ComicSourceManager().remove(targetKey));
        appdata.settings['bangumiBindings'] = <String, dynamic>{};
        appdata.settings['searchSources'] = [targetKey];
        final favorites = LocalFavoritesManager() as _TestFavorites;
        if (fromReader) {
          fixture.histories.addHistory(fixture.makeHistory(ep: 2, page: 3));
        }
        if (directReader) {
          fixture.histories.addHistory(
            History.fromModel(model: target, ep: 1, page: 2),
          );
        }
        await tester.pumpWidget(
          directReader
              ? MaterialApp(
                  navigatorKey: App.rootNavigatorKey,
                  builder: (context, child) => WindowFrame(child!),
                  home: ReaderWithLoading(
                    id: fixture.comicId,
                    sourceKey: fixture.sourceKey,
                  ),
                )
              : fixture.page,
        );
        if (!directReader)
          await _waitForText(tester, fromReader ? 'Continue' : 'Read');
        if (fromReader) {
          if (!directReader) await tester.tap(find.text('Continue'));
          final reader = await _waitForReaderRoute(tester);
          await _waitForReader(tester, reader, 3);
          tester
              .state<ReaderScaffoldState>(find.byType(ReaderScaffold))
              .openOrClose();
          await tester.pumpAndSettle();
        }
        expect(find.byIcon(Icons.share), findsNothing);
        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();
        expect(find.text('Share'), findsOneWidget);
        await tester.tap(find.text('Switch source'));
        await tester.pumpAndSettle();
        expect(searches, ['Fixture Comic']);
        await tester.tap(find.byType(SimpleComicTile));
        await tester.pumpAndSettle();
        expect(find.text('Alternate description'), findsOneWidget);
        expect(find.text('Different chapter'), findsOneWidget);
        expect(
          tester
              .widget<ComicChaptersView>(find.byType(ComicChaptersView))
              .readChapter,
          isNull,
        );
        expect(find.byKey(const Key('use-comic-source')), findsOneWidget);
        expect(favorites.replacements, isEmpty);
        expect(
          fixture.histories.find(target.id, target.comicType)?.page,
          directReader ? 2 : null,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(favorites.replacements, isEmpty);

        // Confirm from a source's full result list, not just its preview row.
        await tester.tap(find.text('Comic details test source'));
        await tester.pumpAndSettle();
        final grid = tester.widget<SliverGridComics>(
          find.byType(SliverGridComics),
        );
        grid.onTap!(grid.comics.single, 0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('use-comic-source')));
        if (directReader) {
          final reader = await _waitForReaderRoute(tester, comicId: target.id);
          await _waitForReader(tester, reader, 2);
          expect(reader.cid, target.id);
          expect(reader.page, 2);
          await _popReader(tester, fixture);
        } else {
          await _waitForText(tester, 'Read');
          await tester.pumpAndSettle();
        }
        expect(favorites.replacements, [
          (fixture.comicId, fixture.type, target.id),
        ]);
        final pages = tester.widgetList<ComicPage>(
          find.byType(ComicPage, skipOffstage: false),
        );
        expect(pages, hasLength(1));
        expect(pages.single.sourceKey, targetKey);
        expect(find.byType(Reader), findsNothing);
        if (fromReader) {
          expect(
            fixture.histories.find(fixture.comicId, fixture.type),
            isNotNull,
          );
        }
        expect(tester.takeException(), isNull);
      },
      skip: !_sqliteAvailable(),
    );
  }

  for (final disposed in [false, true]) {
    testWidgets(
      'favorite folders finish after details load (disposed=$disposed)',
      (tester) async {
        final folders = Completer<Res<Map<String, String>>>();
        final foldersRequested = Completer<void>();
        final fixture = await _createFixture(
          tester,
          grouped: false,
          chapterless: true,
          favoriteData: FavoriteData(
            key: 'test-favorites',
            title: 'Favorites',
            multiFolder: true,
            loadComic: null,
            loadNext: null,
            loadFolders: ([comicId]) {
              foldersRequested.complete();
              return folders.future;
            },
          ),
        );
        ComicSource.find(fixture.sourceKey)!.data['account'] = ['test'];

        await tester.pumpWidget(fixture.page);
        await _pumpAsyncWork(tester, foldersRequested.future);
        if (disposed) {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        folders.complete(
          const Res({'folder': 'Favorites'}, subData: ['folder']),
        );
        await tester.pump();

        if (!disposed) {
          await _waitForText(tester, 'Read');
          expect(
            find.descendant(
              of: find.byKey(const Key('comic-detail-favorite')),
              matching: find.byIcon(Icons.bookmark),
            ),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
      skip: !_sqliteAvailable(),
    );
  }

  testWidgets(
    'pull down toggles a bookmark and excludes menu, cancellation, multitouch and zoom',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      fixture.histories.addHistory(fixture.makeHistory(ep: 1, page: 1));
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await _waitForReader(tester, reader, 1);
      await tester.pumpAndSettle();
      final scaffold = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      final start = tester.getCenter(find.byType(ReaderGestureDetector));
      int count() =>
          ImageFavoriteManager()
              .find(fixture.comicId, fixture.sourceKey)
              ?.bookmarks
              .length ??
          0;
      Future<void> pull(Offset delta) async {
        await tester.dragFrom(start, delta);
        await tester.pumpAndSettle();
      }

      await pull(const Offset(0, 150));
      expect(count(), 1);
      await pull(const Offset(0, 150));
      expect(count(), 0);
      await pull(const Offset(0, -150));
      expect(count(), 0);
      final canceled = await tester.startGesture(start);
      await canceled.moveBy(const Offset(0, 150));
      await canceled.cancel();
      await tester.pumpAndSettle();
      expect(count(), 0);
      final first = await tester.startGesture(start);
      final second = await tester.startGesture(
        start + const Offset(30, 0),
        pointer: 2,
      );
      await first.moveBy(const Offset(0, 150));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(count(), 0);
      scaffold.openOrClose();
      await tester.pumpAndSettle();
      await pull(const Offset(0, 150));
      expect(count(), 0);
      scaffold.openOrClose();
      await tester.pumpAndSettle();
      reader.mode = ReaderMode.galleryTopToBottom;
      reader.update();
      await tester.pumpAndSettle();
      await pull(const Offset(0, 150));
      expect(count(), 0);
      reader.mode = ReaderMode.galleryLeftToRight;
      reader.update();
      await tester.pumpAndSettle();
      reader.imageViewController!.handleDoubleTap(start);
      await tester.pumpAndSettle();
      await pull(const Offset(0, 150));
      expect(count(), 0);
      expect(tester.takeException(), isNull);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  for (final grouped in [false, true]) {
    testWidgets(
      'reader chapters expose download selection and bookmark navigation (grouped=$grouped)',
      (tester) async {
        final fixture = await _createFixture(tester, grouped: grouped);
        fixture.histories.addHistory(
          fixture.makeHistory(ep: 1, page: 1, group: grouped ? 1 : null),
        );
        final favorite = ImageFavoritesComic(
          fixture.comicId,
          [],
          'Comic',
          fixture.sourceKey,
          [],
          [],
          DateTime(2026),
          '',
          {},
          '',
          4,
        );
        favorite.toggleImageFavorite(
          ImageFavorite(
            3,
            fixture.imageUrls[2],
            false,
            fixture.details.chapters!.ids.elementAt(1),
            fixture.comicId,
            2,
            fixture.sourceKey,
            fixture.details.chapters!.titles.elementAt(1),
          ),
          firstImageKey: fixture.imageUrls.first,
          chapterPageCount: 4,
        );
        ImageFavoriteManager().addOrUpdateOrDelete(favorite);
        await tester.runAsync(() async {
          final chapterId = fixture.details.chapters!.ids.elementAt(1);
          final directory = Directory(
            '${LocalManager().path}/bookmark-fixture/$chapterId',
          )..createSync(recursive: true);
          for (var index = 0; index < fixture.imageUrls.length; index++) {
            File(
              fixture.imageUrls[index].substring(7),
            ).copySync('${directory.path}/${index + 1}.png');
          }
          await LocalManager().add(
            LocalComic(
              id: fixture.comicId,
              title: 'Comic',
              subtitle: '',
              tags: [],
              directory: 'bookmark-fixture',
              chapters: fixture.details.chapters,
              cover: '',
              comicType: fixture.type,
              downloadedChapters: [chapterId],
              createdAt: DateTime(2026),
            ),
          );
        });
        await tester.pumpWidget(fixture.page);
        await _waitForText(tester, 'Continue');
        await tester.tap(find.text('Continue'));
        final reader = await _waitForReaderRoute(tester);
        await _waitForReader(tester, reader, 1);
        await tester.pumpAndSettle();
        tester
            .state<ReaderScaffoldState>(find.byType(ReaderScaffold))
            .openOrClose();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithIcon(IconButton, Icons.library_books));
        await tester.pumpAndSettle();
        expect(find.byType(ReaderChaptersView), findsOneWidget);
        final fab = find.byType(FloatingActionButton);
        final panel = tester.getRect(find.byType(ReaderChaptersView));
        expect(tester.getCenter(fab).dx, greaterThan(panel.center.dx));
        await tester.tap(fab);
        await _waitForText(tester, 'Download Selected');
        await tester.pumpAndSettle();
        expect(find.text('Download Selected'), findsOneWidget);
        expect(
          find.byType(CheckboxListTile),
          findsNWidgets(fixture.details.chapters!.length),
        );
        Navigator.of(tester.element(find.text('Download Selected'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bookmarks'));
        await tester.pumpAndSettle();
        final bookmarks = find.descendant(
          of: find.byType(ReaderChaptersView),
          matching: find.text('P3'),
        );
        expect(bookmarks, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(ReaderChaptersView),
            matching: find.text('P1'),
          ),
          findsNothing,
        );
        await tester.drag(find.byType(TabBarView), const Offset(350, 0));
        await tester.pumpAndSettle();
        expect(fab, findsOneWidget);
        await tester.tap(find.text('Bookmarks'));
        await tester.pumpAndSettle();
        await tester.tap(bookmarks);
        await _waitForReader(tester, reader, 3);
        expect(reader.chapter, 2);
        expect(find.byType(Reader), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _popReader(tester, fixture);
      },
      skip: !_sqliteAvailable(),
    );
  }

  testWidgets(
    'chapterless local comic exposes bookmarks on a narrow screen',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        grouped: false,
        chapterless: true,
      );
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final local = LocalComic(
        id: 'local-bookmarks',
        title: 'Imported comic',
        subtitle: '',
        tags: [],
        directory: File(fixture.imageUrls.first.substring(7)).parent.path,
        chapters: null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: [],
        createdAt: DateTime(2026),
      );
      await tester.runAsync(() => LocalManager().add(local));
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Read');
      unawaited(
        App.rootNavigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (context) => Reader(
              type: ComicType.local,
              cid: local.id,
              name: local.title,
              chapters: null,
              history: History.fromModel(model: local, ep: 1, page: 1),
              initialPage: 1,
              initialChapter: 1,
              author: '',
              tags: [],
            ),
          ),
        ),
      );
      final reader = await _waitForReaderRoute(tester);
      await _waitForReader(tester, reader, 1);
      await tester.pumpAndSettle();
      final scaffold = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      scaffold.openOrClose();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.favorite_border));
      await tester.pumpAndSettle();
      expect(
        ImageFavoriteManager().find(local.id, 'local')!.bookmarks.single.page,
        1,
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.library_books));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ReaderChaptersView),
          matching: find.text('Full comic'),
        ),
        findsOneWidget,
      );
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(
        tabs.indicatorColor,
        Theme.of(
          tester.element(find.byType(ReaderChaptersView)),
        ).colorScheme.primary,
      );
      await tester.tap(find.text('Bookmarks'));
      await tester.pumpAndSettle();
      final target = find.descendant(
        of: find.byType(ReaderChaptersView),
        matching: find.text('P1'),
      );
      expect(target, findsOneWidget);
      await tester.tap(target);
      await _waitForReader(tester, reader, 1);
      expect(reader.chapter, 1);
      await tester.pumpAndSettle();
      expect(find.byType(ReaderChaptersView), findsNothing);
      expect(tester.takeException(), isNull);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  for (final nested in [false, true]) {
    testWidgets(
      'covered details defer page refreshes until visible (nested=$nested)',
      (tester) async {
        final fixture = await _createFixture(tester, grouped: false);
        fixture.histories.addHistory(fixture.makeHistory(ep: 1, page: 1));
        final page = fixture.page as MaterialApp;
        await tester.pumpWidget(
          nested
              ? MaterialApp(
                  navigatorKey: App.rootNavigatorKey,
                  builder: page.builder,
                  home: Navigator(
                    onGenerateRoute: (_) =>
                        AppPageRoute<void>(builder: (_) => page.home!),
                  ),
                )
              : page,
        );
        await _waitForText(tester, 'P1');
        await tester.tap(find.text('Continue'));
        final reader = await _waitForReaderRoute(tester);
        await _waitForReader(tester, reader, 1);
        await tester.pumpAndSettle();
        final chapters = find.byType(ComicChaptersView, skipOffstage: false);
        final before = tester.widget<ComicChaptersView>(chapters);
        expect(chapters, findsOneWidget);

        for (final page in [2, 3, 4]) {
          reader.setPage(page, source: ReadingNavigationSource.userForward);
          await tester.pump();
          expect(tester.widget<ComicChaptersView>(chapters), same(before));
        }
        await _pumpAsyncWork(tester, fixture.histories.flushReadingProgress());
        await tester.pump();
        expect(tester.widget<ComicChaptersView>(chapters), same(before));

        final history = reader.history!;
        await _popReader(tester, fixture);
        expect(tester.widget<ComicChaptersView>(chapters), isNot(same(before)));
        expect(find.textContaining('P4'), findsOneWidget);
        fixture.histories.recordReadingProgress(
          history,
          position: const ReadingPosition(ep: 1, page: 3, chapterId: 'c1'),
          source: ReadingNavigationSource.userBackward,
          commandId: 'visible-backward',
          catalog: fixture.readingCatalog,
        );
        await tester.pump();
        expect(find.textContaining('P3'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _pumpAsyncWork(tester, fixture.histories.flushReadingProgress());
      },
      skip: !_sqliteAvailable(),
    );
  }

  testWidgets(
    'gallery midpoint updates page text without rebuilding hidden controls',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        grouped: false,
        withChapterComments: true,
      );
      appdata.settings['showPageNumberInReader'] = true;
      fixture.histories.addHistory(fixture.makeHistory(ep: 1, page: 1));
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await _waitForReader(tester, reader, 1);
      await tester.pumpAndSettle();
      final scaffold = tester.state<ReaderScaffoldState>(
        find.byType(ReaderScaffold),
      );
      final slider = find.byType(CustomSlider);
      final brightness = find.byType(ReaderBrightnessOverlay);
      final top = find.descendant(
        of: find.byType(ReaderScaffold),
        matching: find.byType(MenuButton),
      );
      final sliderBefore = tester.widget<CustomSlider>(slider);
      final brightnessBefore = tester.widget(brightness);
      final topBefore = tester.widget(top);
      final gallery = find.byType(PageView);
      final width = tester.getSize(gallery).width;
      // Start an accepted page drag, independently of PhotoView's zoom arena.
      // This still emits the real drag notifications and midpoint callback.
      final drag = tester
          .widget<PageView>(gallery)
          .controller!
          .position
          .drag(DragStartDetails(), () {});
      drag.update(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: Offset(-width * 0.35, 0),
          primaryDelta: -width * 0.35,
        ),
      );
      await tester.pump();
      expect(reader.page, 1);
      drag.update(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: Offset(-width * 0.3, 0),
          primaryDelta: -width * 0.3,
        ),
      );
      await tester.pump();
      expect(reader.page, 2);
      await tester.pump();
      expect(find.textContaining('2/4'), findsNWidgets(2));
      expect(tester.widget<CustomSlider>(slider), same(sliderBefore));
      expect(tester.widget(brightness), same(brightnessBefore));
      expect(tester.widget(top), same(topBefore));
      drag.end(DragEndDetails(primaryVelocity: 0));
      await tester.pumpAndSettle();

      scaffold.openOrClose();
      await tester.pumpAndSettle();
      expect(tester.widget<CustomSlider>(slider).value, 2);
      reader.imageViewController!.toPage(3);
      await tester.pumpAndSettle();
      expect(reader.page, 3);
      expect(find.textContaining('3/4'), findsNWidgets(2));
      expect(tester.widget<CustomSlider>(slider).value, 3);

      reader.imageViewController!.toPage(5);
      await tester.pumpAndSettle();
      expect(reader.isOnChapterCommentsPage, isTrue);
      expect(find.byType(ReaderBrightnessOverlay), findsNothing);
      expect(find.textContaining('/4'), findsNothing);
      expect(tester.widget<CustomSlider>(slider).value, 4);
      reader.imageViewController!.toPage(4);
      await tester.pumpAndSettle();
      expect(reader.isOnChapterCommentsPage, isFalse);
      expect(find.byType(ReaderBrightnessOverlay), findsOneWidget);
      expect(find.textContaining('4/4'), findsNWidgets(2));

      reader.toNextChapter();
      await _waitForReader(tester, reader, 1);
      await tester.pumpAndSettle();
      expect(reader.chapter, 2);
      expect(find.text('Chapter Two'), findsOneWidget);
      expect(tester.widget<CustomSlider>(slider).value, 1);
      expect(tester.takeException(), isNull);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  for (final grouped in [false, true]) {
    testWidgets(
      grouped
          ? 'details page continues to imported grouped history'
          : 'details page continues to imported flat history',
      (tester) async {
        final fixture = await _createFixture(tester, grouped: grouped);
        if (!grouped) {
          fixture.histories.addHistory(
            fixture.makeHistory(ep: 1, page: 1, group: null),
          );
        }
        await tester.pumpWidget(fixture.page);
        await _waitForText(tester, grouped ? 'Read' : 'P1');
        if (grouped) {
          expect(find.text('Continue'), findsNothing);
        }

        final targetEp = grouped ? 1 : 2;
        final targetPage = grouped ? 1 : 3;
        final targetGroup = grouped ? 2 : null;
        fixture.histories.applySyncRecords(
          _syncRecords(
            fixture,
            ep: targetEp,
            page: targetPage,
            group: targetGroup,
            reread: grouped,
          ),
        );
        await tester.pump();
        expect(find.textContaining('P$targetPage'), findsOneWidget);
        if (grouped) {
          expect(find.textContaining('Group Two Chapter A'), findsOneWidget);
        }
        expect(find.text('Continue'), findsOneWidget);

        await tester.tap(find.text('Continue'));
        final reader = await _waitForReaderRoute(tester);
        final expectedChapter = grouped ? 3 : 2;
        expect(reader.chapter, expectedChapter);
        expect(reader.pageValue, targetPage);
        expect(reader.history!.ep, targetEp);
        expect(reader.history!.page, targetPage);
        expect(reader.history!.group, targetGroup);
        expect(reader.history!.resumePosition?.ep, targetEp);
        expect(reader.history!.resumePosition?.page, targetPage);
        expect(reader.history!.resumePosition?.group, targetGroup);

        await _waitForReader(tester, reader, targetPage);
        expect(reader.images, fixture.imageUrls);
        expect(_visibleReaderPage(targetPage), findsWidgets);
        expect(fixture.requestedChapterIds.last, grouped ? 'g2a' : 'c2');

        await tester.pump(const Duration(seconds: 2));
        await _pumpAsyncWork(tester, fixture.histories.waitForAsyncWrites());
        final persistedRecords = await _pumpAsyncWork(
          tester,
          fixture.histories.exportSyncRecords(),
        );
        final persistedHistoryRecord =
            persistedRecords[syncRecordKey('history', [
              fixture.comicId,
              fixture.type.value,
            ])]!;
        expect(persistedHistoryRecord.containsKey('progress'), isFalse);
        final persistedProgress = ReadingProgress.fromJson(
          persistedHistoryRecord['readingProgress'],
        );
        expect(persistedProgress.resumePosition?.ep, targetEp);
        expect(persistedProgress.resumePosition?.page, targetPage);
        expect(persistedProgress.resumePosition?.group, targetGroup);
        if (grouped) {
          expect(persistedProgress.activeRoundId, _testRoundId);
          expect(persistedProgress.maximumPositions.single.page, 3);
        }
      },
      skip: !_sqliteAvailable(),
    );
  }
  testWidgets(
    'loaded reordered directory rebases saved chapter before continue',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        grouped: false,
        reordered: true,
      );
      final originalCatalog = ReadingCatalog(const [
        ReadingChapter(id: 'c1', ep: 1),
        ReadingChapter(id: 'c2', ep: 2),
      ]);
      final saved = fixture.makeHistory(ep: 2, page: 3)
        ..readingProgress = ReadingProgress.seed(
          const ReadingPosition(ep: 2, page: 3, chapterId: 'c2'),
          catalog: originalCatalog,
          time: 1700000000000,
        );
      fixture.histories.addHistory(saved);

      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      final normalized = fixture.histories.find(fixture.comicId, fixture.type)!;
      expect(normalized.resumePosition?.chapterId, 'c2');
      expect(normalized.resumePosition?.ep, 1);

      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      expect(reader.chapter, 1);
      expect(reader.pageValue, 3);
      await _waitForReader(tester, reader, 3);
      expect(fixture.requestedChapterIds.last, 'c2');
      expect(
        find.text(
          'Saved reading position is ambiguous. Select a chapter to continue.',
        ),
        findsNothing,
      );
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'loaded reordered directory joins same-round reread after mapping candidates',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        grouped: false,
        reordered: true,
        includeThirdChapter: true,
      );
      final originalCatalog = ReadingCatalog(const [
        ReadingChapter(id: 'c1', ep: 1),
        ReadingChapter(id: 'c2', ep: 2),
        ReadingChapter(id: 'c3', ep: 3),
      ]);
      final firstCandidate =
          ReadingProgress.seed(
            const ReadingPosition(ep: 3, page: 1, chapterId: 'c3'),
            catalog: originalCatalog,
          ).record(
            const ReadingPosition(ep: 1, page: 1, chapterId: 'c1'),
            source: ReadingNavigationSource.userBackward,
            newRoundId: _testRoundId,
            catalog: originalCatalog,
          );
      final secondCandidate = firstCandidate
          .record(
            const ReadingPosition(ep: 2, page: 9, chapterId: 'c2'),
            source: ReadingNavigationSource.userForward,
            sessionRoundId: _testRoundId,
            catalog: originalCatalog,
          )
          .rebaseCatalog(fixture.readingCatalog);
      final joinedCandidates = firstCandidate.merge(secondCandidate);
      expect(joinedCandidates.hasOrderConflict, isTrue);
      fixture.histories.addHistory(
        fixture.makeHistory(ep: 3, page: 1)..readingProgress = joinedCandidates,
      );

      var resolvedCandidates = false;
      configureHistoryReadingProgressCatalogResolver((
        recordKey,
        catalog,
      ) async {
        if (resolvedCandidates) return false;
        final progress = firstCandidate
            .normalizeForCatalog(catalog)!
            .merge(secondCandidate.normalizeForCatalog(catalog)!);
        fixture.histories.remove(fixture.comicId, fixture.type);
        fixture.histories.addHistory(
          fixture.makeHistory(ep: 3, page: 1)..readingProgress = progress,
        );
        resolvedCandidates = true;
        return true;
      });
      addTearDown(() => configureHistoryReadingProgressCatalogResolver(null));

      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      expect(reader.chapter, 2);
      expect(reader.pageValue, 1);
      expect(
        reader.history!.resumePosition,
        const ReadingPosition(ep: 2, page: 1, chapterId: 'c1'),
      );
      expect(reader.history!.activeRereadId, _testRoundId);
      expect(reader.history!.readingProgress!.maximumPositions, const [
        ReadingPosition(ep: 3, page: 1, chapterId: 'c3'),
      ]);
      await _waitForReader(tester, reader, 1);
      expect(fixture.requestedChapterIds.last, 'c1');
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'duplicate chapter identity still requires an explicit chapter choice',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        grouped: true,
        duplicateChapterId: true,
      );
      final saved = fixture.makeHistory(ep: 1, page: 2)
        ..readingProgress = ReadingProgress.seed(
          const ReadingPosition(ep: 1, page: 2, chapterId: 'duplicate-chapter'),
        );
      fixture.histories.addHistory(saved);

      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await _waitForText(
        tester,
        'Saved reading position is ambiguous. Select a chapter to continue.',
      );
      expect(fixture.requestedChapterIds, isEmpty);
      expect(reader.images, isNull);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'duplicate chapter IDs resume when the saved group uniquely identifies one',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        grouped: true,
        duplicateChapterId: true,
      );
      final saved = fixture.makeHistory(ep: 1, page: 2, group: 2)
        ..readingProgress = ReadingProgress.seed(
          const ReadingPosition(
            ep: 1,
            page: 2,
            group: 2,
            chapterId: 'duplicate-chapter',
          ),
        );
      fixture.histories.addHistory(saved);

      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      expect(reader.chapter, 3);
      expect(reader.pageValue, 2);
      await _waitForReader(tester, reader, 2);
      expect(fixture.requestedChapterIds.last, 'duplicate-chapter');
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'explicit chapter and thumbnail selections do not inherit synced group progress',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: true);
      fixture.histories.addHistory(
        fixture.makeHistory(ep: 1, page: 1, group: 1),
      );
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'P1');

      void importCurrentPosition() {
        fixture.histories.applySyncRecords(
          _syncRecords(fixture, ep: 1, page: 4, group: 2),
        );
      }

      importCurrentPosition();
      await tester.pump();
      expect(find.textContaining('P4'), findsOneWidget);

      final chapter = find.text('Group One Chapter B');
      await _scrollUntilVisible(tester, chapter);
      await tester.tap(chapter);
      final selectedChapterReader = await _waitForReaderRoute(tester);
      expect(selectedChapterReader.chapter, 2);
      expect(selectedChapterReader.pageValue, 1);
      await _waitForReader(tester, selectedChapterReader, 1);
      expect(fixture.requestedChapterIds.last, 'g1b');
      expect(_visibleReaderPage(1), findsWidgets);

      await _popReader(tester, fixture);
      final groupTwoTab = find.text('Group Two').first;
      await _scrollUntilVisible(tester, groupTwoTab);
      await tester.tap(groupTwoTab);
      await tester.pumpAndSettle();
      final groupTwoChapter = find.text('Group Two Chapter B');
      await _scrollUntilVisible(tester, groupTwoChapter);
      await tester.tap(groupTwoChapter);
      final selectedGroupTwoReader = await _waitForReaderRoute(tester);
      expect(selectedGroupTwoReader.chapter, 4);
      expect(selectedGroupTwoReader.pageValue, 1);
      await _waitForReader(tester, selectedGroupTwoReader, 1);
      expect(fixture.requestedChapterIds.last, 'g2b');
      expect(_visibleReaderPage(1), findsWidgets);

      await _popReader(tester, fixture);
      importCurrentPosition();
      await tester.pump();

      final preview = find.byType(ComicThumbnails);
      await _scrollUntilVisible(tester, preview);
      final secondThumbnail = find
          .descendant(of: preview, matching: find.byType(ClickInkWell))
          .at(1);
      await tester.ensureVisible(secondThumbnail);
      await tester.tap(secondThumbnail);
      final selectedPageReader = await _waitForReaderRoute(tester);
      expect(selectedPageReader.chapter, 1);
      expect(selectedPageReader.pageValue, 2);
      await _waitForReader(tester, selectedPageReader, 2);
      expect(fixture.requestedChapterIds.last, 'g1a');
      expect(_visibleReaderPage(2), findsWidgets);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'explicit target stays open while catalog resolution waits and fails',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      final saved = fixture.makeHistory(ep: 1, page: 1);
      fixture.histories.addHistory(saved);
      final resolverStarted = Completer<void>();
      final finishResolver = Completer<void>();
      configureHistoryReadingProgressCatalogResolver((
        recordKey,
        catalog,
      ) async {
        resolverStarted.complete();
        await finishResolver.future;
        throw StateError('catalog commit failed');
      });
      addTearDown(() => configureHistoryReadingProgressCatalogResolver(null));

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => WindowFrame(child!),
          home: Reader(
            type: fixture.type,
            cid: fixture.comicId,
            name: fixture.details.title,
            chapters: fixture.details.chapters,
            history: saved,
            initialChapter: 2,
            initialPage: 3,
            initialNavigationSource: ReadingNavigationSource.userSeek,
            author: fixture.details.subTitle ?? '',
            tags: fixture.details.plainTags,
          ),
        ),
      );
      await resolverStarted.future;
      final reader = tester.state<ReaderState>(find.byType(Reader));
      expect(reader.chapter, 2);
      expect(reader.pageValue, 3);
      await _waitForReader(tester, reader, 3);
      expect(fixture.requestedChapterIds.last, 'c2');

      reader.toChapter(1, source: ReadingNavigationSource.userSeek);
      await _waitForReader(tester, reader, 1);
      expect(reader.chapter, 1);
      finishResolver.complete();
      await tester.pump();
      expect(reader.chapter, 1);
      expect(fixture.requestedChapterIds.last, 'c1');
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpAsyncWork(tester, fixture.histories.flushReadingProgress());
      await tester.pump();
    },
    skip: !_sqliteAvailable(),
  );
  testWidgets(
    'Read starts at the beginning when the comic has no saved history',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Read');
      expect(find.text('Continue'), findsNothing);

      await tester.tap(find.text('Read'));
      final reader = await _waitForReaderRoute(tester);
      expect(reader.chapter, 1);
      expect(reader.pageValue, 1);
      await _waitForReader(tester, reader, 1);
      expect(fixture.requestedChapterIds.last, 'c1');
      expect(_visibleReaderPage(1), findsWidgets);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'layout changes retain the visible source image without rereading',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      fixture.histories.applySyncRecords(
        _syncRecords(fixture, ep: 2, page: 2, group: null),
      );
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await _waitForReader(tester, reader, 2);
      expect(_visibleReaderPage(2), findsWidgets);

      appdata.settings['showSingleImageOnFirstPage'] = false;
      appdata.settings['readerScreenPicNumberForPortrait'] = 2;
      appdata.settings['readerScreenPicNumberForLandscape'] = 2;
      reader.update();
      await tester.pumpAndSettle();
      appdata.settings['showSingleImageOnFirstPage'] = true;
      reader.update();
      await tester.pumpAndSettle();
      appdata.settings['readerScreenPicNumberForPortrait'] = 1;
      appdata.settings['readerScreenPicNumberForLandscape'] = 1;
      reader.update();
      await tester.pumpAndSettle();
      await _waitForReader(tester, reader, 2);
      expect(_visibleReaderPage(2), findsWidgets);
      final records = await _pumpAsyncWork(
        tester,
        fixture.histories.exportSyncRecords(),
      );
      final state = ReadingProgress.fromJson(
        records[syncRecordKey('history', [
          fixture.comicId,
          fixture.type.value,
        ])]!['readingProgress'],
      );
      expect(state.maximumPositions.single.page, 2);
      expect(state.resumePosition?.page, 2);
      expect(state.activeRoundId, isNull);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'unmapped progress prompts for a real chapter selection before reading',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      final records = _syncRecords(fixture, ep: 2, page: 2, group: null);
      final key = syncRecordKey('history', [
        fixture.comicId,
        fixture.type.value,
      ]);
      final known = ReadingProgress.fromJson(records[key]!['readingProgress']);
      final unresolved = known.merge(
        ReadingProgress.seed(
          const ReadingPosition(ep: 2, page: 4, chapterId: 'removed-chapter'),
        ),
      );
      expect(unresolved.hasOrderConflict, isTrue);
      records[key]!['readingProgress'] = unresolved.toJson();
      fixture.histories.applySyncRecords(records);
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await _waitForText(
        tester,
        'Saved reading position is ambiguous. Select a chapter to continue.',
      );
      expect(fixture.requestedChapterIds, isEmpty);
      await tester.tap(find.text(fixture.details.chapters!.allChapters['c2']!));
      await _waitForReader(tester, reader, 1);
      expect(fixture.requestedChapterIds.last, 'c2');
      expect(_visibleReaderPage(1), findsWidgets);
      expect(
        fixture.histories
            .find(fixture.comicId, fixture.type)!
            .readingProgress!
            .maximumPositions
            .any((position) => position.chapterId == 'removed-chapter'),
        isTrue,
      );
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'chapterless comic requires an explicit choice for unmappable history',
    (tester) async {
      final fixture = await _createFixture(
        tester,
        grouped: false,
        chapterless: true,
      );
      final unmappableProgress = ReadingProgress.seed(
        const ReadingPosition(ep: 2, page: 2),
      );
      fixture.histories.addHistory(
        fixture.makeHistory(ep: 1, page: 4)
          ..readingProgress = unmappableProgress,
      );

      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(reader.images, isNull);
      expect(fixture.requestedChapterIds, isEmpty);
      await tester.tap(find.widgetWithText(ListTile, fixture.details.title));
      await _waitForReader(tester, reader, 1);
      expect(fixture.requestedChapterIds, ['single']);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.close();
    return true;
  } catch (_) {
    return false;
  }
}

Future<_ComicDetailsFixture> _createFixture(
  WidgetTester tester, {
  required bool grouped,
  bool reordered = false,
  bool duplicateChapterId = false,
  bool chapterless = false,
  bool includeThirdChapter = false,
  bool withChapterComments = false,
  FavoriteData? favoriteData,
}) async {
  final previousSettings =
      jsonDecode(jsonEncode(appdata.toJson()['settings']))
          as Map<String, dynamic>;
  final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
  final previousHistory = HistoryManager.cache;
  final previousFavorites = LocalFavoritesManager.cache;
  final previousDataPath = _currentAppPath(cache: false);
  final previousCachePath = _currentAppPath(cache: true);
  final previousLogMuted = Log.isMuted;
  final previousDisableWindowCloseHandler =
      DataSync.debugDisableWindowCloseHandler;
  final temporary = Directory.systemTemp.createTempSync(
    'comic-details-history-',
  );
  final sourceKey =
      'comic_details_history_${DateTime.now().microsecondsSinceEpoch}';
  final comicId = grouped ? 'grouped-comic' : 'flat-comic';
  final imageBytes = img.encodePng(img.Image(width: 100, height: 160));
  final imageUrls = <String>[];
  for (var page = 1; page <= 4; page++) {
    final imageFile = File('${temporary.path}/page-$page.png')
      ..writeAsBytesSync(imageBytes);
    imageUrls.add('file://${imageFile.path}');
  }
  final chapterData = chapterless
      ? null
      : duplicateChapterId
      ? <String, dynamic>{
          'Group One': {
            'duplicate-chapter': 'Duplicate Chapter One',
            'g1b': 'Group One Chapter B',
          },
          'Group Two': {
            'duplicate-chapter': 'Duplicate Chapter Two',
            'g2b': 'Group Two Chapter B',
          },
        }
      : grouped
      ? <String, dynamic>{
          'Group One': {
            'g1a': 'Group One Chapter A',
            'g1b': 'Group One Chapter B',
          },
          'Group Two': {
            'g2a': 'Group Two Chapter A',
            'g2b': 'Group Two Chapter B',
          },
        }
      : includeThirdChapter
      ? reordered
            ? <String, dynamic>{
                'c2': 'Chapter Two',
                'c1': 'Chapter One',
                'c3': 'Chapter Three',
              }
            : <String, dynamic>{
                'c1': 'Chapter One',
                'c2': 'Chapter Two',
                'c3': 'Chapter Three',
              }
      : reordered
      ? <String, dynamic>{'c2': 'Chapter Two', 'c1': 'Chapter One'}
      : <String, dynamic>{'c1': 'Chapter One', 'c2': 'Chapter Two'};
  final details = ComicDetails.fromJson({
    'title': 'Fixture Comic',
    'subtitle': 'Fixture Author',
    'cover': imageUrls.first,
    'description': '',
    'tags': <String, dynamic>{},
    'chapters': chapterData,
    'thumbnails': imageUrls,
    'sourceKey': sourceKey,
    'comicId': comicId,
    'maxPage': 4,
  });
  final requestedChapterIds = <String>[];
  final source = _comicSource(
    sourceKey: sourceKey,
    details: details,
    imageUrls: imageUrls,
    requestedChapterIds: requestedChapterIds,
    favoriteData: favoriteData,
    chapterCommentsLoader: withChapterComments
        ? (comicId, epId, page, replyTo) async =>
              const Res(<Comment>[], subData: 1)
        : null,
  );
  ComicSourceManager().add(source);

  App.dataPath = temporary.path;
  App.cachePath = temporary.path;
  final settings = appdata.settings;
  settings['webdav'] = <String>[];
  appdata.implicitData
    ..clear()
    ..addAll({'webdavSyncMode': 'manual', 'webdavAutoSync': false});
  settings['language'] = 'en-US';
  settings['readerMode'] = 'galleryLeftToRight';
  settings['autoReaderMode'] = false;
  settings['readerScreenPicNumberForPortrait'] = 1;
  settings['readerScreenPicNumberForLandscape'] = 1;
  settings['comicSpecificSettings'] = <String, Map<String, dynamic>>{};
  settings['deviceSpecificSettings'] = <String, dynamic>{};
  settings['enableCustomImageProcessing'] = false;
  settings['enableClockAndBatteryInfoInReader'] = false;
  settings['showPageNumberInReader'] = false;
  settings['showChapterComments'] = withChapterComments;
  settings['showChapterCommentsAtEnd'] = withChapterComments;
  settings['showSystemStatusBar'] = false;
  settings['historyRetentionDays'] = 0;
  settings['reverseChapterOrder'] = false;
  Log.isMuted = true;
  DataSync.resetForTesting();
  DataSync.debugDisableWindowCloseHandler = true;
  LocalFavoritesManager.cache = _TestFavorites();
  HistoryManager.cache = null;
  LocalManager.resetForTesting();
  LocalManager.debugSkipComicSourceInit = true;

  final histories = HistoryManager();
  await tester.runAsync(() async {
    final comicsDirectory = Directory('${temporary.path}/comics')
      ..createSync(recursive: true);
    File(
      '${temporary.path}/local_path',
    ).writeAsStringSync(comicsDirectory.path);
    await histories.init();
    await LocalManager().init();
  });
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter_memory_info'),
    (call) async => 1 << 30,
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async {
      if (call.method == 'isMaximized') return false;
      throw MissingPluginException('Unexpected window call: ${call.method}');
    },
  );

  final fixture = _ComicDetailsFixture(
    sourceKey: sourceKey,
    comicId: comicId,
    details: details,
    histories: histories,
    imageUrls: imageUrls,
    requestedChapterIds: requestedChapterIds,
  );
  addTearDown(() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpAsyncWork(tester, histories.flushReadingProgress());
      // Reader disposal can enqueue read-duration/progress work; drain the
      // history queue after that producer has settled.
      await _pumpAsyncWork(tester, histories.flushReadingProgress());
      await _pumpAsyncWork(tester, histories.waitForAsyncWrites());
    } finally {
      ComicSourceManager().remove(sourceKey);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_memory_info'),
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
      LocalManager.resetForTesting();
      try {
        histories.close();
      } finally {
        DataSync.resetForTesting();
        HistoryManager.cache = previousHistory;
        LocalFavoritesManager.cache = previousFavorites;
        DataSync.debugDisableWindowCloseHandler =
            previousDisableWindowCloseHandler;
        Log.isMuted = previousLogMuted;
        (appdata.toJson()['settings'] as Map)
          ..clear()
          ..addAll(previousSettings);
        App.dataPath = previousDataPath ?? Directory.systemTemp.path;
        App.cachePath = previousCachePath ?? Directory.systemTemp.path;
        appdata.implicitData
          ..clear()
          ..addAll(previousImplicit);
        if (temporary.existsSync()) {
          await tester.runAsync(() => temporary.delete(recursive: true));
        }
      }
    }
  });
  return fixture;
}

String? _currentAppPath({required bool cache}) {
  try {
    return cache ? App.cachePath : App.dataPath;
  } catch (_) {
    return null;
  }
}

ComicSource _comicSource({
  required String sourceKey,
  required ComicDetails details,
  required List<String> imageUrls,
  required List<String> requestedChapterIds,
  ChapterCommentsLoader? chapterCommentsLoader,
  FavoriteData? favoriteData,
  SearchPageData? searchPageData,
}) => ComicSource(
  'Comic details test source',
  sourceKey,
  null,
  null,
  null,
  favoriteData,
  const [],
  searchPageData,
  null,
  (id) async => Res(details),
  (id, next) async => const Res(<String>[]),
  (id, ep) async {
    requestedChapterIds.add(ep ?? 'single');
    return Res(imageUrls);
  },
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  chapterCommentsLoader,
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

class _ComicDetailsFixture {
  const _ComicDetailsFixture({
    required this.sourceKey,
    required this.comicId,
    required this.details,
    required this.histories,
    required this.imageUrls,
    required this.requestedChapterIds,
  });

  final String sourceKey;
  final String comicId;
  final ComicDetails details;
  final HistoryManager histories;
  final List<String> imageUrls;
  final List<String> requestedChapterIds;
  ComicType get type => ComicType.fromKey(sourceKey);

  History makeHistory({required int ep, required int page, int? group}) =>
      History.fromModel(
        model: details,
        ep: ep,
        page: page,
        group: group,
        readChapters: <String>{},
      );

  ReadingCatalog get readingCatalog =>
      readingCatalogFromComicChapters(details.chapters)!;

  Widget get page => MaterialApp(
    navigatorKey: App.rootNavigatorKey,
    builder: (context, child) => WindowFrame(child!),
    home: ComicPage(id: comicId, sourceKey: sourceKey),
  );
}

SyncRecords _syncRecords(
  _ComicDetailsFixture fixture, {
  required int ep,
  required int page,
  required int? group,
  bool reread = false,
}) {
  final typeValue = fixture.type.value;
  final chapterKey = group == null ? '$ep' : '$group-$ep';
  final catalog = fixture.readingCatalog;
  var readingProgress = ReadingProgress.seed(
    ReadingPosition(ep: ep, page: reread ? 3 : page, group: group),
    time: 1700000000000,
    catalog: catalog,
  );
  if (reread) {
    readingProgress = readingProgress.record(
      ReadingPosition(ep: ep, page: page, group: group),
      source: ReadingNavigationSource.userBackward,
      newRoundId: _testRoundId,
      catalog: catalog,
    );
  }
  final metadata = <String, Object?>{
    'title': fixture.details.title,
    'subtitle': fixture.details.subTitle ?? '',
    'cover': fixture.details.cover,
    'maxPage': 4,
    'readDurationMs': 0,
  };
  final records = <String, Map<String, Object?>>{
    syncRecordKey('history', [fixture.comicId, typeValue]): {
      ...metadata,
      'readingProgress': readingProgress.toJson(),
    },
    syncRecordKey('historyChapter', [fixture.comicId, typeValue, chapterKey]): {
      'comicId': fixture.comicId,
      'typeValue': typeValue,
      'chapter': chapterKey,
      'title': fixture.details.title,
      'subtitle': fixture.details.subTitle ?? '',
      'cover': fixture.details.cover,
      'maxPage': 4,
    },
  };
  return records;
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  final target = find.textContaining(text);
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (target.evaluate().isNotEmpty) return;
  }
  expect(target, findsOneWidget);
}

// Isolate writes complete through fake-zone callbacks. Drive those callbacks
// with frames; use runAsync only to let the real I/O make progress.
Future<T> _pumpAsyncWork<T>(WidgetTester tester, Future<T> work) async {
  late T result;
  var completed = false;
  Object? error;
  StackTrace? errorStack;
  work.then<void>(
    (value) {
      result = value;
      completed = true;
    },
    onError: (Object failure, StackTrace stack) {
      error = failure;
      errorStack = stack;
      completed = true;
    },
  );
  final clock = Stopwatch()..start();
  while (!completed && clock.elapsed < const Duration(seconds: 10)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  clock.stop();
  expect(completed, isTrue, reason: 'Timed out waiting for async history work');
  if (error != null) {
    Error.throwWithStackTrace(error!, errorStack!);
  }
  return result;
}

Future<ReaderState> _waitForReaderRoute(
  WidgetTester tester, {
  String? comicId,
}) async {
  final reader = find.byWidgetPredicate(
    (widget) => widget is Reader && (comicId == null || widget.cid == comicId),
  );
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (reader.evaluate().isNotEmpty &&
        ModalRoute.of(tester.element(reader))?.animation?.isCompleted == true) {
      return tester.state<ReaderState>(reader);
    }
  }
  expect(reader, findsOneWidget);
  fail('Reader navigation did not finish');
}

Future<void> _waitForReader(
  WidgetTester tester,
  ReaderState reader,
  int page,
) async {
  final visiblePage = _visibleReaderPage(page);
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (reader.images != null && visiblePage.evaluate().isNotEmpty) return;
  }
  expect(reader.images, isNotNull);
  expect(visiblePage, findsWidgets);
}

Finder _visibleReaderPage(int page) {
  final comicImage = find.byWidgetPredicate((widget) {
    if (widget is! ComicImage) return false;
    final provider = widget.image;
    return provider is ReaderImageProvider && provider.page == page;
  });
  return find.descendant(
    of: comicImage,
    matching: find.byWidgetPredicate(
      (widget) => widget is RawImage && widget.image != null,
    ),
  );
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder target) async {
  final scrollable = find
      .descendant(
        of: find.byType(CustomScrollView).first,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(target, 300, scrollable: scrollable);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _popReader(
  WidgetTester tester,
  _ComicDetailsFixture fixture,
) async {
  App.rootNavigatorKey.currentState!.pop();
  await tester.pumpAndSettle();
  await _pumpAsyncWork(tester, fixture.histories.flushReadingProgress());
  await tester.pump();
}

class _TestFavorites extends ChangeNotifier implements LocalFavoritesManager {
  final replacements = <(String, ComicType, String)>[];

  @override
  void replaceComic(
    String id,
    ComicType type,
    FavoriteItem replacement, {
    String? updateTime,
  }) {
    replacements.add((id, type, replacement.id));
  }

  @override
  bool hasNewUpdate(String id, ComicType type, [String? folder]) => false;

  @override
  bool isExist(String id, ComicType type) => false;

  @override
  void onRead(String id, ComicType type) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
