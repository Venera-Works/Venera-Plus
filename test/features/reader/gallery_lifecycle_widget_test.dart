import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:photo_view/photo_view.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/comic_image.dart';
import 'package:venera_plus/features/reader/images.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/reader/scaffold.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/res.dart';

import '../../support/sqlite.dart';

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready() && clock.elapsed < const Duration(seconds: 10)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(
    ready(),
    isTrue,
    reason: 'Gallery state did not settle within 10 seconds.',
  );
  await tester.pumpAndSettle();
}

Completer<void> _watchDisposal(PhotoViewControllerBase controller) {
  final disposed = Completer<void>();
  final subscription = controller.outputStateStream.listen(
    (_) {},
    onDone: disposed.complete,
  );
  addTearDown(subscription.cancel);
  return disposed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Production reader navigation and lifecycle', () {
    late Directory directory;
    late Database database;
    late Map<String, dynamic> previousSettings;
    late HistoryManager? previousHistory;
    late LocalFavoritesManager? previousFavorites;
    late DataSync? previousSync;
    late List<String> images;

    setUp(() {
      previousSettings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
      previousHistory = HistoryManager.cache;
      previousFavorites = LocalFavoritesManager.cache;
      previousSync = DataSync.instance;
      directory = Directory.systemTemp.createTempSync('gallery-widget-');
      App.cachePath = directory.path;
      database = sqlite3.openInMemory();
      HistoryManager.cache = _History(database);
      ImageFavoriteManager().init();
      LocalFavoritesManager.cache = _Favorites();
      DataSync.instance = _Sync();
      ComicSourceManager().add(_Source());
      final settings = <String, dynamic>{
        'comicSpecificSettings': <String, dynamic>{},
        'deviceSpecificSettings': <String, dynamic>{},
        'autoReaderMode': false,
        'readerMode': 'galleryLeftToRight',
        'readerScreenPicNumberForLandscape': 1,
        'readerScreenPicNumberForPortrait': 1,
        'showSingleImageOnFirstPage': false,
        'splitDualPage': false,
        'splitDualPageInvert': false,
        'showChapterComments': false,
        'showChapterCommentsAtEnd': false,
        'enablePageAnimation': true,
        'enableTurnPageByVolumeKey': false,
        'enableClockAndBatteryInfoInReader': false,
        'showPageNumberInReader': false,
        'showSystemStatusBar': true,
        'enableCustomImageProcessing': false,
        'limitImageWidth': false,
        'eInkMode': false,
        'preloadImageCount': 1,
        'language': 'en-US',
      };
      settings.forEach((key, value) => appdata.settings[key] = value);
      images = [];
      for (var i = 1; i <= 5; i++) {
        final file = File('${directory.path}/$i.png');
        file.writeAsBytesSync(
          image.encodePng(image.Image(width: i == 5 ? 200 : 100, height: 150)),
        );
        images.add('file://${file.path}');
      }
    });

    tearDown(() async {
      await ReadingSessionTracker.finishAll();
      ComicSourceManager().remove('local');
      HistoryManager.cache = previousHistory;
      LocalFavoritesManager.cache = previousFavorites;
      DataSync.instance = previousSync;
      appdata.settings.replaceAll(previousSettings);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      ComicImage.clear();
      database.close();
      await directory.delete(recursive: true);
    });

    Future<_ReaderState> openReader(WidgetTester tester) async {
      final key = GlobalKey<_ReaderState>();
      await tester.pumpWidget(
        MaterialApp(
          home: _Reader(key: key, images: images),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      });
      final reader = key.currentState!;
      reader.onReaderContentReady();
      await _waitFor(
        tester,
        () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
      );
      return reader;
    }

    for (final keyboard in [false, true]) {
      testWidgets(
        'rapid ${keyboard ? 'keyboard' : 'volume'} input accumulates and reverses during animation',
        (tester) async {
          final reader = await openReader(tester);
          final gallery = reader.imageViewController as GalleryModeState;
          void next() {
            if (keyboard) {
              gallery.handleKeyEvent(
                const KeyDownEvent(
                  physicalKey: PhysicalKeyboardKey.arrowRight,
                  logicalKey: LogicalKeyboardKey.arrowRight,
                  timeStamp: Duration.zero,
                ),
              );
            } else {
              reader.onDown();
            }
          }

          void previous() {
            if (keyboard) {
              gallery.handleKeyEvent(
                const KeyDownEvent(
                  physicalKey: PhysicalKeyboardKey.arrowLeft,
                  logicalKey: LogicalKeyboardKey.arrowLeft,
                  timeStamp: Duration.zero,
                ),
              );
            } else {
              reader.onUp();
            }
          }

          reader.navigationEvents.clear();
          next();
          next();
          expect(reader.pendingNavigationPage, 3);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(gallery.controller.page, inExclusiveRange(2.5, 3));
          next();
          expect(reader.pendingNavigationPage, 4);
          previous();
          expect(reader.pendingNavigationPage, 3);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          expect(reader.isPageAnimating, isTrue);
          await tester.pumpAndSettle();
          await _waitFor(
            tester,
            () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
          );
          expect(gallery.controller.page, 3);
          expect(reader.page, 3);
          expect(reader.isPageAnimating, isFalse);
          expect(reader.pendingNavigationSource, isNull);
          final committed = reader.navigationEvents
              .where((event) => event.recordProgress && event.commandId != null)
              .toList();
          expect(committed, isNotEmpty);
          expect(committed.every((event) => event.page == 3), isTrue);
          expect(committed.last.source, ReadingNavigationSource.userBackward);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('reversing before the first frame completes the command', (
      tester,
    ) async {
      final reader = await openReader(tester);
      reader.onDown();
      reader.onUp();
      await tester.pumpAndSettle();
      expect(reader.page, 1);
      expect(reader.isPageAnimating, isFalse);
      expect(reader.pendingNavigationSource, isNull);
      expect(reader.navigationEvents.last.page, 1);
      expect(
        reader.navigationEvents.last.source,
        ReadingNavigationSource.userBackward,
      );
      expect(reader.navigationEvents.last.commandId, isNotNull);
    });

    testWidgets('seeks and volume input replace unfinished destinations', (
      tester,
    ) async {
      final reader = await openReader(tester);
      final gallery = reader.imageViewController as GalleryModeState;
      reader.toPage(5);
      reader.onUp();
      await tester.pumpAndSettle();
      expect(gallery.controller.page, 4);
      expect(reader.page, 4);
      expect(reader.isPageAnimating, isFalse);
      expect(reader.pendingNavigationSource, isNull);

      reader.onDown();
      reader.toPage(2, animated: false);
      await tester.pumpAndSettle();
      expect(gallery.controller.page, 2);
      expect(reader.page, 2);
      expect(reader.isPageAnimating, isFalse);
      reader.onDown();
      reader.onDown();
      await tester.pumpAndSettle();
      expect(gallery.controller.page, 4);
      expect(reader.page, 4);
      expect(reader.pendingNavigationSource, isNull);
      await _waitFor(
        tester,
        () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'rapid input preserves split halves and the comments boundary',
      (tester) async {
        appdata.settings['splitDualPage'] = true;
        appdata.settings['showChapterComments'] = true;
        appdata.settings['showChapterCommentsAtEnd'] = true;
        final reader = await openReader(tester);
        final gallery = reader.imageViewController as GalleryModeState;
        reader.toPage(5, animated: false);
        await _waitFor(tester, () => gallery.totalVisualImagePages == 6);
        expect(gallery.controller.page, 5);
        reader.onDown();
        reader.onDown();
        reader.onDown();
        await tester.pumpAndSettle();
        expect(gallery.controller.page, 7);
        expect(reader.isOnChapterCommentsPage, isTrue);
        expect(reader.chapter, 1);
        expect(reader.pendingNavigationSource, isNull);
        reader.onUp();
        reader.onUp();
        await tester.pumpAndSettle();
        expect(gallery.controller.page, 5);
        expect(reader.page, 5);
        expect(reader.isOnChapterCommentsPage, isFalse);
        reader.toPage(1, animated: false);
        expect(reader.toPrevPage(), isFalse);
        expect(reader.chapter, 1);
        await _waitFor(
          tester,
          () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('waterfall scrolling only notifies changed reader locations', (
      tester,
    ) async {
      appdata.settings['readerMode'] = 'waterfallTopToBottom';
      final reader = await openReader(tester);
      final flow = reader.imageViewController as ContinuousModeState;
      final scaffold = tester.state<_ScaffoldState>(find.byType(_Scaffold));
      expect(reader.page, 1);
      scaffold.fullUpdates = 0;
      scaffold.pageUpdates = 0;

      flow.scrollController.jumpTo(40);
      await tester.pumpAndSettle();
      expect(reader.page, 1);
      expect(scaffold.fullUpdates, 0);
      expect(scaffold.pageUpdates, 0);

      flow.itemScrollController.jumpTo(index: 2);
      await tester.pumpAndSettle();
      expect(reader.page, 2);
      expect(scaffold.fullUpdates, 0);
      expect(scaffold.pageUpdates, greaterThan(0));

      flow.scrollController.jumpTo(
        flow.scrollController.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      expect(reader.page, 5);
      scaffold.fullUpdates = 0;
      scaffold.pageUpdates = 0;
      reader.beginNavigationCommand(
        ReadingNavigationSource.userSeek,
        chapter: reader.chapter,
        page: 5,
      );
      flow.onPositionChanged();
      await tester.pump();
      expect(reader.pendingNavigationSource, isNull);
      expect(scaffold.fullUpdates, 0);
      expect(scaffold.pageUpdates, 1);
      await _waitFor(
        tester,
        () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('scroll state delays retain event order and cancel on exit', (
      tester,
    ) async {
      appdata.settings['readerMode'] = 'waterfallTopToBottom';
      final reader = await openReader(tester);
      final flow = reader.imageViewController as ContinuousModeState;
      flow.delayedSetIsScrolling(true);
      await tester.pump(const Duration(milliseconds: 200));
      flow.delayedSetIsScrolling(false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(flow.delayedIsScrolling, isTrue);
      await tester.pump(const Duration(milliseconds: 199));
      expect(flow.delayedIsScrolling, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(flow.delayedIsScrolling, isFalse);

      flow.delayedSetIsScrolling(true);
      flow.delayedSetIsScrolling(false);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(flow.mounted, isFalse);
      expect(reader.imageViewController, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'turning pages prunes controllers and reader exit disposes the retained controller',
      (tester) async {
        final reader = await openReader(tester);
        final gallery = reader.imageViewController as GalleryModeState;
        final first = tester
            .widget<PhotoView>(find.byType(PhotoView))
            .controller!;
        final firstDisposed = _watchDisposal(first);
        gallery.controller.jumpToPage(2);
        await _waitFor(
          tester,
          () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
        );
        final second = tester
            .widget<PhotoView>(find.byType(PhotoView))
            .controller!;
        final secondDisposed = _watchDisposal(second);
        expect(firstDisposed.isCompleted, isFalse);

        gallery.controller.jumpToPage(3);
        await _waitFor(tester, () => firstDisposed.isCompleted);
        await _waitFor(
          tester,
          () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
        );
        expect(secondDisposed.isCompleted, isFalse);
        gallery.controller.jumpToPage(2);
        await _waitFor(
          tester,
          () => PaintingBinding.instance.imageCache.pendingImageCount == 0,
        );
        expect(
          tester.widget<PhotoView>(find.byType(PhotoView)).controller,
          same(second),
        );
        expect(reader.page, 2);

        await tester.pumpWidget(const SizedBox.shrink());
        await _waitFor(tester, () => secondDisposed.isCompleted);
        expect(reader.imageViewController, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the actual comments page follows both halves of the final wide image',
      (tester) async {
        appdata.settings['splitDualPage'] = true;
        appdata.settings['showChapterComments'] = true;
        appdata.settings['showChapterCommentsAtEnd'] = true;
        final reader = await openReader(tester);
        final gallery = reader.imageViewController as GalleryModeState;
        gallery.controller.jumpToPage(5);
        await _waitFor(tester, () => gallery.totalVisualImagePages == 6);
        expect(gallery.totalVisualPages, 7);
        expect(gallery.isChapterCommentsPage(6), isFalse);
        expect(gallery.isChapterCommentsPage(7), isTrue);
        expect(gallery.isChapterCommentsPage(8), isFalse);
        gallery.controller.jumpToPage(7);
        await tester.pumpAndSettle();
        expect(find.byType(EmbeddedChapterCommentsPage), findsOneWidget);
        expect(reader.isOnChapterCommentsPage, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }, skip: !isSqliteAvailable());
}

class _Reader extends Reader {
  _Reader({super.key, required this.images})
    : super(
        type: ComicType.local,
        cid: 'gallery-book',
        name: 'Gallery book',
        chapters: const ComicChapters({'one': 'One'}),
        initialPage: 1,
        history: History.fromMap({
          'id': 'gallery-book',
          'type': 0,
          'time': 1000,
          'title': 'Gallery book',
          'ep': 1,
          'page': 1,
        }),
        author: '',
        tags: const [],
      );
  final List<String> images;
  @override
  ReaderState createState() => _ReaderState();
}

class _ReaderState extends ReaderState {
  final navigationEvents =
      <
        ({
          int page,
          ReadingNavigationSource source,
          String? commandId,
          bool recordProgress,
        })
      >[];

  @override
  void initState() {
    super.initState();
    images = (widget as _Reader).images;
  }

  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}
  @override
  void updateHistory({
    ReadingNavigationSource source = ReadingNavigationSource.passive,
    String? commandId,
    bool recordProgress = true,
  }) {
    navigationEvents.add((
      page: page,
      source: source,
      commandId: commandId,
      recordProgress: recordProgress,
    ));
  }

  @override
  Widget build(BuildContext context) => _Scaffold(
    child: mode.isGallery
        ? const GalleryMode()
        : const ContinuousMode(crossChapter: true),
  );
}

class _Scaffold extends ReaderScaffold {
  const _Scaffold({required super.child});

  @override
  State<ReaderScaffold> createState() => _ScaffoldState();
}

class _ScaffoldState extends ReaderScaffoldState {
  int fullUpdates = 0;
  int pageUpdates = 0;

  @override
  void update() {
    fullUpdates++;
    super.update();
  }

  @override
  void updatePage() {
    pageUpdates++;
    super.updatePage();
  }
}

class _Source extends Fake implements ComicSource {
  @override
  String get key => 'local';
  @override
  get updateReadProgressFunc => null;
  @override
  get sendChapterCommentFunc => null;
  @override
  ChapterCommentsLoader get chapterCommentsLoader =>
      (_, _, _, _) async => const Res<List<Comment>>([], subData: 1);
}

class _History extends HistoryManager {
  _History(this.database) : super.create();
  final Database database;
  @override
  Database get imageFavoritesDatabase => database;
  @override
  Future<History> resolveReadingProgressCatalog(
    History fallback,
    ReadingCatalog catalog,
  ) async => fallback;
  @override
  Future<void> addReadDuration(History history, Duration duration) async {}
  @override
  Future<void> flushReadingProgress({String? id, ComicType? type}) async {}
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  void onRead(String id, ComicType type) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync extends Fake implements DataSync {
  @override
  void onDataChanged() {}
}
