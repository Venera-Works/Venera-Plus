import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_plus/components/custom_slider.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/features/comic_source/models.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/images.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/reader/scaffold.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';

import '../../widget_test_io.dart';

void main() {
  for (final rapid in [false, true]) {
    testWidgets('300-page slider jump preserves touch scrolling (rapid=$rapid)', (
      tester,
    ) async {
      final previous =
          jsonDecode(jsonEncode(appdata.toJson()['settings']))
              as Map<String, dynamic>;
      final previousFavorites = LocalFavoritesManager.cache;
      final previousHistory = HistoryManager.cache;
      final directory = Directory.systemTemp.createTempSync(
        'slider-navigation-',
      );
      final key = GlobalKey<_ReaderState>();
      Log.isMuted = true;
      try {
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        LocalFavoritesManager.cache = _Favorites();
        DataSync.debugDisableWindowCloseHandler = true;
        final settings = appdata.settings;
        settings['comicSpecificSettings'] = <String, dynamic>{};
        settings['deviceSpecificSettings'] = <String, dynamic>{};
        settings['autoReaderMode'] = false;
        settings['readerMode'] = 'continuousTopToBottom';
        settings['enablePageAnimation'] = true;
        settings['enableClockAndBatteryInfoInReader'] = false;
        settings['showPageNumberInReader'] = false;
        settings['eInkMode'] = false;
        settings['limitImageWidth'] = false;
        settings['preloadImageCount'] = 1;
        settings['language'] = 'en-US';
        LocalManager.resetForTesting();
        LocalManager.debugSkipComicSourceInit = true;
        await tester.runAsync(() async {
          Directory('${directory.path}/comics').createSync();
          File(
            '${directory.path}/local_path',
          ).writeAsStringSync('${directory.path}/comics');
          HistoryManager.cache = _TestHistory();
          await HistoryManager().init();
          await LocalManager().init();
          final png = img.encodePng(img.Image(width: 100, height: 200));
          final folder = Directory('${LocalManager().path}/book/one')
            ..createSync(recursive: true);
          for (var i = 1; i <= 300; i++) {
            File('${folder.path}/$i.png').writeAsBytesSync(png);
          }
          await LocalManager().add(
            LocalComic(
              id: 'book',
              title: 'Book',
              subtitle: '',
              tags: const [],
              directory: 'book',
              chapters: _chapters,
              cover: '',
              comicType: ComicType.local,
              downloadedChapters: const ['one'],
              createdAt: DateTime(2026),
            ),
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: App.rootNavigatorKey,
            home: Scaffold(body: OverlayWidget(_Reader(key: key))),
          ),
        );
        Future<void> frames(int count) async {
          for (var i = 0; i < count; i++) {
            await runWidgetIo(
              tester,
              () => HistoryManager().flushReadingProgress(
                id: 'book',
                type: ComicType.local,
              ),
            );
            await tester.pump(const Duration(milliseconds: 20));
            if (i % 10 == 0) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
            }
          }
        }

        final reader = key.currentState!;
        for (var i = 0; i < 30 && reader.imageViewController == null; i++) {
          await frames(5);
        }
        expect(reader.maxPage, 300);
        expect(reader.imageViewController, isA<ContinuousModeState>());
        expect(reader.page, 250);
        final scaffold = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        scaffold.openOrClose();
        await frames(15);
        final slider = tester.widget<CustomSlider>(find.byType(CustomSlider));
        // A slider can emit multiple destination changes before the next frame,
        // while the positioned list has not mounted its transition list yet.
        if (rapid) slider.onChanged(150);
        slider.onChanged(200);
        await frames(50);
        expect(reader.isPageAnimating, isFalse);
        expect(reader.page, 200);

        final manager = HistoryManager();
        var history = manager.find('book', ComicType.local)!;
        final firstRoundId = history.activeRereadId;
        expect(firstRoundId, isNotNull);
        expect(reader.sessionRoundId, firstRoundId);
        slider.onChanged(250);
        await frames(50);
        expect(reader.page, 250);
        expect(manager.find('book', ComicType.local)!.activeRereadId, isNull);

        final catalog = ReadingCatalog(const [
          ReadingChapter(id: 'one', ep: 1),
        ]);
        const lateRootId = '00000000-0000-4000-8000-000000000001';
        reader.toPage(
          200,
          animated: false,
          source: ReadingNavigationSource.automatic,
        );
        await frames(50);
        expect(reader.page, 200);
        reader.toPage(250, source: ReadingNavigationSource.userSeek);
        final imported = manager.recordReadingProgress(
          reader.history!,
          position: const ReadingPosition(ep: 1, page: 200, chapterId: 'one'),
          source: ReadingNavigationSource.userBackward,
          commandId: lateRootId,
          catalog: catalog,
        );
        expect(imported.isActiveRound(lateRootId), isTrue);
        await frames(50);
        expect(reader.page, 250);
        history = manager.find('book', ComicType.local)!;
        expect(history.readingProgress!.isActiveRound(lateRootId), isTrue);
        expect(reader.sessionRoundId, firstRoundId);
        reader.toPage(
          299,
          animated: false,
          source: ReadingNavigationSource.automatic,
        );
        await frames(50);
        // The flow is at its tail: the last original image is visible.
        expect(reader.page, 300);
        history = manager.find('book', ComicType.local)!;
        expect(history.readingProgress!.isActiveRound(lateRootId), isTrue);
        expect(history.readingProgress!.maximumPositions.single.page, 300);
        expect(reader.sessionRoundId, firstRoundId);
        slider.onChanged(250);
        await frames(10);
        final rereadRoundId = manager
            .find('book', ComicType.local)!
            .activeRereadId;
        expect(rereadRoundId, isNotNull);
        expect(rereadRoundId, isNot(firstRoundId));
        expect(reader.sessionRoundId, rereadRoundId);
        reader.toPage(
          260,
          animated: false,
          source: ReadingNavigationSource.userForward,
        );
        await frames(5);
        await runWidgetIo(
          tester,
          () => manager.flushReadingProgress(id: 'book', type: ComicType.local),
        );
        final flushedRound = manager.find('book', ComicType.local)!;
        expect(flushedRound.activeRereadId, rereadRoundId);
        expect(flushedRound.resumePosition?.page, 260);

        scaffold.openOrClose();
        await frames(15);
        reader.toPage(
          200,
          animated: false,
          source: ReadingNavigationSource.automatic,
        );
        await frames(15);
        expect(reader.page, 200);
        expect(reader.isPageAnimating, isFalse);
        final flow = reader.imageViewController as ContinuousModeState;
        final before = flow.scrollController.offset;
        await tester.dragFrom(const Offset(400, 400), const Offset(0, -220));
        await frames(15);
        expect(flow.scrollController.offset, greaterThan(before + 50));
        final after = flow.scrollController.offset;
        final pageBeforeBackwardDrag = reader.page;
        expect(pageBeforeBackwardDrag, greaterThan(2));
        final backwardDrag = await tester.startGesture(const Offset(400, 150));
        const concurrentDragRoundId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
        for (var i = 0; i < 12; i++) {
          await backwardDrag.moveBy(const Offset(0, 300));
          await frames(2);
          if (i == 2) {
            manager.recordReadingProgress(
              reader.history!,
              position: const ReadingPosition(
                ep: 1,
                page: 100,
                chapterId: 'one',
              ),
              source: ReadingNavigationSource.userBackward,
              commandId: concurrentDragRoundId,
              catalog: catalog,
              observedProgress: ReadingProgress.seed(
                const ReadingPosition(ep: 1, page: 300, chapterId: 'one'),
                catalog: catalog,
              ),
            );
          }
        }
        await backwardDrag.up();
        await tester.pumpAndSettle();
        expect(flow.scrollController.offset, lessThan(after - 50));
        expect(reader.page, lessThan(pageBeforeBackwardDrag - 1));
        expect(
          manager
              .find('book', ComicType.local)!
              .readingProgress!
              .isActiveRound(concurrentDragRoundId),
          isTrue,
        );
        final sourceBeforeLayout = reader.page;
        expect(
          manager.find('book', ComicType.local)!.resumePosition?.page,
          sourceBeforeLayout,
        );
        final sessionBeforeDoublePageSeek = reader.sessionRoundId;

        settings['readerScreenPicNumberForPortrait'] = 2;
        settings['readerScreenPicNumberForLandscape'] = 2;
        settings['showSingleImageOnFirstPage'] = false;
        reader.mode = ReaderMode.galleryLeftToRight;
        reader.update();
        await frames(50);
        expect(reader.imagesPerPage, 2);
        expect(reader.page, (sourceBeforeLayout + 1) ~/ 2);
        expect(reader.sessionRoundId, sessionBeforeDoublePageSeek);
        reader.toPage(
          reader.page,
          animated: false,
          source: ReadingNavigationSource.userSeek,
        );
        await frames(15);
        expect(reader.sessionRoundId, sessionBeforeDoublePageSeek);

        settings['readerScreenPicNumberForPortrait'] = 1;
        tester.view.physicalSize = const Size(400, 800);
        await frames(20);
        reader.update();
        await frames(20);
        expect(reader.imagesPerPage, 1);
        expect(reader.page, sourceBeforeLayout);
        expect(reader.sessionRoundId, sessionBeforeDoublePageSeek);
        await runWidgetIo(
          tester,
          () => manager.flushReadingProgress(id: 'book', type: ComicType.local),
        );
        final flushed = manager.find('book', ComicType.local)!;
        expect(
          flushed.readingProgress!.maximumPositions.any(
            (position) => position.page == 300,
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        await runWidgetIo(
          tester,
          () => HistoryManager().flushReadingProgress(
            id: 'book',
            type: ComicType.local,
          ),
        );
        LocalManager.resetForTesting();
        if (HistoryManager.cache?.isInitialized == true) {
          HistoryManager().close();
        }
        HistoryManager.cache = previousHistory;
        DataSync.resetForTesting();
        LocalFavoritesManager.cache = previousFavorites;
        Log.isMuted = false;
        previous.forEach((key, value) => appdata.settings[key] = value);
        await tester.runAsync(() async {
          await appdata.saveData(false);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await directory.delete(recursive: true);
        });
      }
    });
  }
}

const _chapters = ComicChapters({'one': 'One'});

class _Reader extends Reader {
  _Reader({required super.key})
    : super(
        type: ComicType.local,
        cid: 'book',
        name: 'Book',
        author: '',
        tags: const [],
        chapters: _chapters,
        history: History.fromMap({
          'id': 'book',
          'type': 0,
          'time': 1000,
          'title': 'Book',
          'subtitle': '',
          'cover': '',
          'ep': 1,
          'page': 250,
          'max_page': 300,
        }),
      );
  @override
  ReaderState createState() => _ReaderState();
}

class _ReaderState extends ReaderState {
  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  void onRead(String id, ComicType type) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHistory extends HistoryManager {
  _TestHistory() : super.create();
  @override
  Future<void> addReadDuration(History history, Duration duration) async {}
}
