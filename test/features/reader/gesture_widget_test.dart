import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/comic_image.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/features/reader/images.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/reader/scaffold.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/foundation/res.dart';

const _comicKey = ValueKey('comic-content');

void main() {
  late Map<String, dynamic> previousSettings;
  late HistoryManager? previousHistory;
  late LocalFavoritesManager? previousFavorites;
  late DataSync? previousSync;
  late Database database;
  late Directory directory;
  const settings = {
    'comicSpecificSettings': <String, dynamic>{},
    'deviceSpecificSettings': <String, dynamic>{},
    'readerMode': 'galleryLeftToRight',
    'enableTurnPageByVolumeKey': false,
    'enableClockAndBatteryInfoInReader': false,
    'showPageNumberInReader': false,
    'showSystemStatusBar': true,
    'readerScreenPicNumberForLandscape': 2,
    'readerScreenPicNumberForPortrait': 2,
    'showSingleImageOnFirstPage': false,
    'language': 'en-US',
    'oneHandedMode': false,
    'enableTapToTurnPages': true,
    'enableDoubleTapToZoom': false,
    'reverseTapToTurnPages': false,
  };

  setUp(() {
    previousSettings = {
      for (final key in settings.keys) key: appdata.settings[key],
    };
    previousHistory = HistoryManager.cache;
    previousFavorites = LocalFavoritesManager.cache;
    previousSync = DataSync.instance;
    directory = Directory.systemTemp.createTempSync('pull-to-collect-');
    App.cachePath = directory.path;
    database = sqlite3.openInMemory();
    HistoryManager.cache = _History(database);
    ImageFavoriteManager().init();
    LocalFavoritesManager.cache = _Favorites();
    DataSync.instance = _Sync();
    settings.forEach((key, value) => appdata.settings[key] = value);
  });

  tearDown(() {
    HistoryManager.cache = previousHistory;
    LocalFavoritesManager.cache = previousFavorites;
    DataSync.instance = previousSync;
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    database.close();
    directory.deleteSync(recursive: true);
  });

  Future<_ReaderState> openReader(WidgetTester tester, ReaderMode mode) async {
    appdata.settings['readerMode'] = mode.key;
    final key = GlobalKey<_ReaderState>();
    await tester.pumpWidget(MaterialApp(home: _Reader(key: key)));
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    return key.currentState!;
  }

  Finder indicator(IconData icon) => find.descendant(
    of: find.byType(ReaderGestureDetector),
    matching: find.byIcon(icon),
  );

  List<int> bookmarks() =>
      ImageFavoriteManager()
          .find('pull-book', 'local')
          ?.bookmarks
          .map((image) => image.page)
          .toList() ??
      [];

  for (final mode in [
    ReaderMode.galleryLeftToRight,
    ReaderMode.galleryRightToLeft,
    ReaderMode.galleryTopToBottom,
  ]) {
    testWidgets('one-handed mode advances from every edge ($mode)', (
      tester,
    ) async {
      appdata.settings['oneHandedMode'] = true;
      appdata.settings['reverseTapToTurnPages'] = true;
      final reader = await openReader(tester, mode);
      final bounds = tester.getRect(find.byKey(_comicKey));
      for (final position in [
        bounds.centerLeft + const Offset(10, 0),
        bounds.centerRight - const Offset(10, 0),
        bounds.topCenter + const Offset(0, 10),
        bounds.bottomCenter - const Offset(0, 10),
      ]) {
        final previousCount = reader.nextSources.length;
        await tester.tapAt(position);
        await tester.pump();
        expect(reader.nextSources, hasLength(previousCount + 1));
        expect(reader.nextSources.last, ReadingNavigationSource.userForward);
        expect(reader.previousSources, isEmpty);
      }
      await tester.tapAt(bounds.center);
      await tester.pumpAndSettle();
      expect(reader.nextSources, hasLength(4));
      expect(
        tester.state<ReaderScaffoldState>(find.byType(ReaderScaffold)).isOpen,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disabling one-handed mode restores directional taps', (
    tester,
  ) async {
    final reader = await openReader(tester, ReaderMode.galleryLeftToRight);
    final bounds = tester.getRect(find.byKey(_comicKey));
    await tester.tapAt(bounds.centerLeft + const Offset(10, 0));
    await tester.pump();
    await tester.tapAt(bounds.centerRight - const Offset(10, 0));
    await tester.pump(const Duration(milliseconds: 250));
    expect(reader.previousSources, [ReadingNavigationSource.userBackward]);
    expect(reader.nextSources, [ReadingNavigationSource.userForward]);
    expect(tester.takeException(), isNull);
  });

  for (final mode in [
    ReaderMode.galleryLeftToRight,
    ReaderMode.galleryRightToLeft,
    ReaderMode.continuousLeftToRight,
    ReaderMode.continuousRightToLeft,
  ]) {
    testWidgets(
      'pull follows the finger and toggles the touched image ($mode)',
      (tester) async {
        await openReader(tester, mode);
        final content = find.byKey(_comicKey);
        final origin = tester.getTopLeft(content);
        final start =
            tester.getRect(content).centerRight - const Offset(100, 0);
        final gesture = await tester.startGesture(start);
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        expect(tester.getTopLeft(content).dy - origin.dy, closeTo(40, 0.1));
        expect(indicator(Icons.favorite_border), findsOneWidget);
        expect(bookmarks(), isEmpty);
        final iconPosition = tester.getCenter(indicator(Icons.favorite_border));

        await gesture.moveBy(const Offset(0, 80));
        await tester.pump();
        expect(tester.getTopLeft(content).dy - origin.dy, greaterThan(40));
        expect(tester.getTopLeft(content).dy - origin.dy, lessThan(120));
        expect(indicator(Icons.favorite), findsOneWidget);
        expect(tester.getCenter(indicator(Icons.favorite)), iconPosition);
        expect(bookmarks(), isEmpty);

        await gesture.up();
        await tester.pump();
        expect(bookmarks(), [2]);
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getTopLeft(content).dy, greaterThan(origin.dy));
        await tester.pump(const Duration(milliseconds: 110));
        expect(tester.getTopLeft(content).dy, closeTo(origin.dy, 0.1));
        expect(indicator(Icons.favorite), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 150));
        expect(indicator(Icons.favorite), findsNothing);

        final remove = await tester.startGesture(start);
        await remove.moveBy(const Offset(0, 40));
        await tester.pump();
        expect(indicator(Icons.favorite), findsOneWidget);
        await remove.moveBy(const Offset(0, 80));
        await tester.pump();
        expect(indicator(Icons.favorite_border), findsOneWidget);
        await remove.up();
        await tester.pumpAndSettle();
        expect(bookmarks(), isEmpty);
        expect(tester.getTopLeft(content), origin);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('pulling back, pointer cancellation and a second finger cancel', (
    tester,
  ) async {
    await openReader(tester, ReaderMode.galleryLeftToRight);
    final content = find.byKey(_comicKey);
    final origin = tester.getTopLeft(content);
    final start = tester.getCenter(content);
    final pullBack = await tester.startGesture(start);
    await pullBack.moveBy(const Offset(0, 120));
    await tester.pump();
    expect(indicator(Icons.favorite), findsOneWidget);
    await pullBack.moveBy(const Offset(0, -70));
    await tester.pump();
    expect(indicator(Icons.favorite_border), findsOneWidget);
    await pullBack.up();
    await tester.pumpAndSettle();
    expect(bookmarks(), isEmpty);
    expect(tester.getTopLeft(content), origin);

    final cancelled = await tester.startGesture(start);
    await cancelled.moveBy(const Offset(0, 120));
    await tester.pump();
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(bookmarks(), isEmpty);
    expect(tester.getTopLeft(content), origin);

    final first = await tester.startGesture(start, pointer: 10);
    await first.moveBy(const Offset(0, 120));
    await tester.pump();
    final second = await tester.startGesture(
      start + const Offset(50, 0),
      pointer: 11,
    );
    await tester.pump(const Duration(milliseconds: 100));
    final returning = tester.getTopLeft(content).dy;
    await second.up();
    await tester.pump(const Duration(milliseconds: 20));
    expect(tester.getTopLeft(content).dy, lessThan(returning));
    await first.up();
    await tester.pumpAndSettle();
    expect(bookmarks(), isEmpty);
    expect(tester.getTopLeft(content), origin);
  });

  testWidgets(
    'horizontal drags, vertical reading and menu drags do not collect',
    (tester) async {
      final reader = await openReader(tester, ReaderMode.galleryLeftToRight);
      final content = find.byKey(_comicKey);
      final origin = tester.getTopLeft(content);
      final start = tester.getCenter(content);
      final horizontal = await tester.startGesture(start);
      await horizontal.moveBy(const Offset(80, 10));
      await horizontal.moveBy(const Offset(0, 150));
      await tester.pump();
      expect(tester.getTopLeft(content), origin);
      expect(indicator(Icons.favorite), findsNothing);
      await horizontal.up();

      reader.mode = ReaderMode.continuousTopToBottom;
      reader.update();
      await tester.pump();
      await tester.dragFrom(start, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(content), origin);
      expect(bookmarks(), isEmpty);

      reader.mode = ReaderMode.galleryLeftToRight;
      reader.update();
      tester
          .state<ReaderScaffoldState>(find.byType(ReaderScaffold))
          .openOrClose();
      await tester.pumpAndSettle();
      await tester.dragFrom(start, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(content), origin);
      expect(bookmarks(), isEmpty);
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
    },
  );

  group('context menu pinning and continuous hit testing', () {
    Uint8List encodeSolidPng(int r, int g, int b) {
      final image = img.Image(width: 4, height: 4);
      img.fill(image, color: img.ColorRgb8(r, g, b));
      return Uint8List.fromList(img.encodePng(image));
    }

    Future<Uint8List> openOriginalAndReadBytes(WidgetTester tester) async {
      await tester.tap(find.text('View Original Image'));
      final stopwatch = Stopwatch()..start();
      while (find.byType(PhotoView).evaluate().isEmpty &&
          stopwatch.elapsed < const Duration(seconds: 10)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.byType(PhotoView), findsOneWidget);
      final photoView = tester.widget<PhotoView>(find.byType(PhotoView));
      return (photoView.imageProvider as MemoryImage).bytes;
    }

    testWidgets(
      'secondary tap and touch long press pin original image reference across page turns',
      (tester) async {
        final page1Bytes = encodeSolidPng(220, 40, 40);
        final page2Bytes = encodeSolidPng(40, 80, 220);
        final page1File = File('${directory.path}/page1.png')
          ..writeAsBytesSync(page1Bytes);
        final page2File = File('${directory.path}/page2.png')
          ..writeAsBytesSync(page2Bytes);

        final reader = await openReader(tester, ReaderMode.galleryLeftToRight);
        final controller = reader.imageViewController as _ImageController;
        final ref1 = ReaderImageReference(
          imageKey: 'file://${page1File.path}',
          cid: 'pull-book',
          eid: 'ep-1',
          chapter: 1,
          page: 1,
          file: page1File,
        );
        final ref2 = ReaderImageReference(
          imageKey: 'file://${page2File.path}',
          cid: 'pull-book',
          eid: 'ep-2',
          file: page2File,
        );

        reader.chapter = 2;
        reader.pageValue = 3;
        ReaderImageReference? activeRef = ref2;
        controller.onGetByOffset = (_) => activeRef;

        final center = tester.getCenter(find.byKey(_comicKey));
        final rightClick = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await tester.pump();
        await rightClick.up();
        await tester.pumpAndSettle();
        expect(find.text('View Original Image'), findsOneWidget);

        // 模拟打开菜单后自动或按键翻页切章并更换命中目标。
        reader.chapter = 3;
        reader.pageValue = 5;
        activeRef = ref1;

        expect(await openOriginalAndReadBytes(tester), page2Bytes);
        Navigator.of(tester.element(find.byType(PhotoView))).pop();
        await tester.pumpAndSettle();

        reader.chapter = 2;
        reader.pageValue = 3;
        activeRef = ref2;
        final touch = await tester.startGesture(
          center,
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await touch.up();
        await tester.pumpAndSettle();
        expect(find.text('View Original Image'), findsOneWidget);

        reader.chapter = 4;
        reader.pageValue = 6;
        activeRef = ref1;

        expect(await openOriginalAndReadBytes(tester), page2Bytes);
        Navigator.of(tester.element(find.byType(PhotoView))).pop();
        await tester.pumpAndSettle();

        activeRef = null;
        final emptyRightClick = await tester.startGesture(
          center,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await tester.pump();
        await emptyRightClick.up();
        await tester.pumpAndSettle();
        expect(find.text('View Original Image'), findsNothing);
        expect(find.text('Copy Image'), findsNothing);
        expect(find.text('Save Image'), findsNothing);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'waterfall mode hits whitespace per image row, rejects dividers and supports zoom/pan',
      (tester) async {
        const sourceKey = 'waterfall_hit_fixture';
        const chapters = ComicChapters({'c1': 'Ch 1', 'c2': 'Ch 2'});
        final comicType = ComicType.fromKey(sourceKey);
        const viewportSize = Size(1000, 600);
        final previousAllSettings = jsonDecode(
          jsonEncode(appdata.toJson()['settings']),
        );
        late String previousDataPath;
        try {
          previousDataPath = App.dataPath;
        } on Error {
          previousDataPath = directory.path;
        }

        final source = _WaterfallHitSource(sourceKey, chapters);
        ComicSourceManager().add(source);
        App.dataPath = directory.path;
        LocalManager.resetForTesting();
        LocalManager.debugSkipComicSourceInit = true;
        await tester.runAsync(() => LocalManager().init());

        tester.view.physicalSize = viewportSize;
        tester.view.devicePixelRatio = 1.0;

        addTearDown(() async {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          await tester.runAsync(() async {
            await ReadingSessionTracker.finishAll();
            await LocalManager().pendingDownloadTaskWrites;
            LocalManager.resetForTesting();
          });
          ComicSourceManager().remove(sourceKey);
          App.dataPath = previousDataPath;
          appdata.settings.replaceAll(previousAllSettings);
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          ComicImage.clear();
        });

        final waterfallSettings = <String, dynamic>{
          'autoReaderMode': false,
          'readerMode': 'waterfallTopToBottom',
          'readerScreenPicNumberForLandscape': 1,
          'readerScreenPicNumberForPortrait': 1,
          'showSingleImageOnFirstPage': false,
          'splitDualPage': false,
          'splitDualPageInvert': false,
          'showChapterComments': false,
          'showChapterCommentsAtEnd': false,
          'enablePageAnimation': false,
          'enableCustomImageProcessing': false,
          'limitImageWidth': true,
          'readerSideMargin': 0,
          'eInkMode': false,
          'preloadImageCount': 2,
          'moveFavoriteAfterRead': 'none',
        };
        waterfallSettings.forEach(
          (key, value) => appdata.settings[key] = value,
        );

        for (var chapter = 1; chapter <= 2; chapter++) {
          for (var page = 1; page <= 2; page++) {
            final provider = ReaderImageProvider(
              _waterfallImageKey(chapter, page),
              sourceKey,
              'waterfall-hit-book',
              chapters.ids.elementAt(chapter - 1),
              page,
              chapter: chapter,
              enableResize: true,
              target: calculateReaderImageTarget(
                mode: ReaderMode.waterfallTopToBottom,
                viewportSize: viewportSize,
                devicePixelRatio: 1.0,
                page: page,
                totalImages: 2,
                limitImageWidth: true,
              ),
            );
            PaintingBinding.instance.imageCache.putIfAbsent(
              provider,
              () => _TestImageStream(400, 140),
            );
          }
        }

        final key = GlobalKey<_WaterfallReaderState>();
        await tester.pumpWidget(
          MaterialApp(
            home: _WaterfallReader(
              key: key,
              comicType: comicType,
              chapters: chapters,
            ),
          ),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
        });

        final reader = key.currentState!;
        reader.onReaderContentReady();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final flow = reader.imageViewController as ContinuousModeState;
        final rect1 = tester.getRect(_findWaterfallImage(1, 2));
        final rect2 = tester.getRect(_findWaterfallImage(2, 1));

        expect(rect1.left, greaterThan(200));
        expect(rect2.top, greaterThan(rect1.bottom));
        expect(rect2.bottom, lessThan(viewportSize.height));

        final leftBlank1 = flow.getImageReferenceByOffset(
          Offset(40, rect1.center.dy),
        );
        final rightBlank1 = flow.getImageReferenceByOffset(
          Offset(960, rect1.center.dy),
        );
        expect(leftBlank1?.chapter, 1);
        expect(leftBlank1?.page, 2);
        expect(rightBlank1?.chapter, 1);
        expect(rightBlank1?.page, 2);

        final leftBlank2 = flow.getImageReferenceByOffset(
          Offset(40, rect2.center.dy),
        );
        final rightBlank2 = flow.getImageReferenceByOffset(
          Offset(960, rect2.center.dy),
        );
        expect(leftBlank2?.chapter, 2);
        expect(leftBlank2?.page, 1);
        expect(rightBlank2?.chapter, 2);
        expect(rightBlank2?.page, 1);

        final dividerY = (rect1.bottom + rect2.top) / 2;
        expect(flow.getImageReferenceByOffset(Offset(500, dividerY)), isNull);
        expect(flow.getImageReferenceByOffset(Offset(40, dividerY)), isNull);
        expect(
          flow.getImageReferenceByOffset(Offset(-10, rect1.center.dy)),
          isNull,
        );
        expect(flow.getImageReferenceByOffset(const Offset(500, 620)), isNull);

        flow.photoViewController.updateMultiple(
          scale: 1.5,
          position: const Offset(-40, 20),
        );
        await tester.pump();

        final scaledRect1 = tester.getRect(_findWaterfallImage(1, 2));
        final scaledRect2 = tester.getRect(_findWaterfallImage(2, 1));
        expect(scaledRect2.left, greaterThan(20));
        final visibleTop = scaledRect2.top < 0 ? 0.0 : scaledRect2.top;
        final visibleBottom = scaledRect2.bottom > viewportSize.height
            ? viewportSize.height
            : scaledRect2.bottom;
        final scaledTargetY = (visibleTop + visibleBottom) / 2;
        final scaledHit = flow.getImageReferenceByOffset(
          Offset(20, scaledTargetY),
        );
        expect(scaledHit?.chapter, 2);
        expect(scaledHit?.page, 1);
        final scaledDividerY = (scaledRect1.bottom + scaledRect2.top) / 2;
        expect(
          flow.getImageReferenceByOffset(Offset(500, scaledDividerY)),
          isNull,
        );

        final barRef = flow.getImageReferenceByIndex(reader.page - 1);
        expect(barRef, isNotNull);
        expect(barRef!.page, reader.page);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
    );
  });
}

String _waterfallImageKey(int chapter, int page) =>
    'file://waterfall-hit-$chapter-$page';

Finder _findWaterfallImage(int chapter, int page) => find.byWidgetPredicate(
  (widget) =>
      widget is ComicImage &&
      widget.image is ReaderImageProvider &&
      (widget.image as ReaderImageProvider).chapter == chapter &&
      (widget.image as ReaderImageProvider).page == page,
);

class _TestImageStream extends ImageStreamCompleter {
  _TestImageStream(int width, int height) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.grey, ui.BlendMode.src);
    final picture = recorder.endRecording();
    setImage(ImageInfo(image: picture.toImageSync(width, height)));
    picture.dispose();
  }
}

class _WaterfallReader extends Reader {
  _WaterfallReader({
    required super.key,
    required ComicType comicType,
    required ComicChapters chapters,
  }) : super(
         type: comicType,
         cid: 'waterfall-hit-book',
         name: 'Waterfall hit book',
         chapters: chapters,
         initialChapter: 1,
         initialPage: 2,
         history: History.fromMap({
           'id': 'waterfall-hit-book',
           'type': comicType.value,
           'time': 1000,
           'title': 'Waterfall hit book',
           'ep': 1,
           'page': 2,
         }),
         author: '',
         tags: const [],
       );

  @override
  ReaderState createState() => _WaterfallReaderState();
}

class _WaterfallReaderState extends ReaderState {
  @override
  void initState() {
    super.initState();
    images = [_waterfallImageKey(1, 1), _waterfallImageKey(1, 2)];
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
  }) {}

  @override
  Widget build(BuildContext context) =>
      ReaderScaffold(child: ContinuousMode(crossChapter: true));
}

class _WaterfallHitSource extends Fake implements ComicSource {
  _WaterfallHitSource(this.key, this.chapters);

  @override
  final String key;
  final ComicChapters chapters;

  @override
  String get filePath => '';
  @override
  String get name => 'WaterfallHit';
  @override
  get updateReadProgressFunc => null;
  @override
  get sendChapterCommentFunc => null;
  @override
  get chapterCommentsLoader => null;
  @override
  LoadComicPagesFunc get loadComicPages => (_, chapter) async {
    final index = chapters.ids.toList().indexOf(chapter!) + 1;
    return Res([_waterfallImageKey(index, 1), _waterfallImageKey(index, 2)]);
  };
}

class _Reader extends Reader {
  _Reader({required super.key})
    : super(
        type: ComicType.local,
        cid: 'pull-book',
        name: 'Pull book',
        chapters: null,
        history: History.fromMap({
          'id': 'pull-book',
          'type': 0,
          'time': 1000,
          'title': 'Pull book',
          'ep': 1,
          'page': 1,
        }),
        author: '',
        tags: const [],
      );

  @override
  ReaderState createState() => _ReaderState();
}

class _ReaderState extends ReaderState {
  final nextSources = <ReadingNavigationSource>[];
  final previousSources = <ReadingNavigationSource>[];

  @override
  bool toNextPage({
    ReadingNavigationSource source = ReadingNavigationSource.userForward,
  }) {
    nextSources.add(source);
    return true;
  }

  @override
  bool toPrevPage({
    ReadingNavigationSource source = ReadingNavigationSource.userBackward,
  }) {
    previousSources.add(source);
    return true;
  }

  @override
  void initState() {
    super.initState();
    images = ['page-1', 'page-2'];
    imageViewController = _ImageController();
  }

  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}

  @override
  Widget build(BuildContext context) => ReaderScaffold(
    child: ReaderGestureDetector(
      child: SizedBox.expand(
        key: ValueKey(mode),
        child: const ColoredBox(key: _comicKey, color: Colors.blue),
      ),
    ),
  );
}

class _ImageController implements ReaderImageViewController {
  ReaderImageReference? Function(Offset offset)? onGetByOffset;

  @override
  ReaderImageReference? getImageReferenceByOffset(Offset offset) {
    if (onGetByOffset != null) {
      return onGetByOffset!(offset);
    }
    return ReaderImageReference(
      imageKey: offset.dx > 400 ? 'page-2' : 'page-1',
      cid: 'pull-book',
      eid: '0',
      chapter: 1,
      page: offset.dx > 400 ? 2 : 1,
    );
  }

  @override
  bool handleOnTap(Offset location) => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

class _Sync implements DataSync {
  @override
  void onDataChanged() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
