import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/comic_image.dart';
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

import '../../support/sqlite.dart';

const _sourceKey = 'waterfall_loading_fixture';
const _pageCount = 8;
const _viewportSize = Size(400, 600);
const _chapters = ComicChapters({'one': 'One', 'two': 'Two', 'three': 'Three'});
final _type = ComicType.fromKey(_sourceKey);

List<String> _images(int chapter) =>
    List.generate(_pageCount, (i) => 'file://waterfall-$chapter-${i + 1}');

Finder _image(int chapter, int page) => find.byWidgetPredicate(
  (widget) =>
      widget is ComicImage &&
      widget.image is ReaderImageProvider &&
      (widget.image as ReaderImageProvider).chapter == chapter &&
      (widget.image as ReaderImageProvider).page == page,
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _ImageStream extends ImageStreamCompleter {
  _ImageStream() {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.grey, ui.BlendMode.src);
    final picture = recorder.endRecording();
    setImage(ImageInfo(image: picture.toImageSync(40, 60)));
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('瀑布流异步前章插入', () {
    late Directory directory;
    late Database database;
    late Map<String, dynamic> previousSettings;
    late HistoryManager? previousHistory;
    late LocalFavoritesManager? previousFavorites;
    late DataSync? previousSync;
    late _Source source;

    setUp(() async {
      previousSettings = jsonDecode(jsonEncode(appdata.toJson()['settings']));
      previousHistory = HistoryManager.cache;
      previousFavorites = LocalFavoritesManager.cache;
      previousSync = DataSync.instance;
      directory = Directory.systemTemp.createTempSync('waterfall-loading-');
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      database = sqlite3.openInMemory();
      HistoryManager.cache = _History(database);
      ImageFavoriteManager().init();
      LocalFavoritesManager.cache = _Favorites();
      DataSync.instance = _Sync();
      source = _Source();
      ComicSourceManager().add(source);
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      await LocalManager().init();
      final settings = <String, dynamic>{
        'comicSpecificSettings': <String, dynamic>{},
        'deviceSpecificSettings': <String, dynamic>{},
        'autoReaderMode': false,
        'readerMode': 'waterfallTopToBottom',
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
        'readerSideMargin': 0,
        'eInkMode': false,
        'preloadImageCount': 1,
        'language': 'en-US',
      };
      settings.forEach((key, value) => appdata.settings[key] = value);
      // 只控制图片与章节返回时机，布局、滚动和进度均执行生产路径。
      for (var chapter = 1; chapter <= 3; chapter++) {
        for (var page = 1; page <= _pageCount; page++) {
          final provider = ReaderImageProvider(
            _images(chapter)[page - 1],
            _sourceKey,
            'waterfall-book',
            _chapters.ids.elementAt(chapter - 1),
            page,
            chapter: chapter,
            enableResize: true,
            target: calculateReaderImageTarget(
              mode: ReaderMode.waterfallTopToBottom,
              viewportSize: _viewportSize,
              devicePixelRatio: 1,
              page: page,
              totalImages: _pageCount,
            ),
          );
          PaintingBinding.instance.imageCache.putIfAbsent(
            provider,
            _ImageStream.new,
          );
        }
      }
    });

    tearDown(() async {
      await ReadingSessionTracker.finishAll();
      ComicSourceManager().remove(_sourceKey);
      LocalManager.resetForTesting();
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
      tester.view.physicalSize = _viewportSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey<_ReaderState>();
      await tester.pumpWidget(MaterialApp(home: _Reader(key: key)));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        source.completeAll();
        await tester.pump(const Duration(seconds: 1));
      });
      final reader = key.currentState!;
      reader.onReaderContentReady();
      await _frames(tester);
      expect(source.requests['one'], hasLength(1));
      expect(tester.takeException(), isNull);
      return reader;
    }

    int itemCount(WidgetTester tester) => tester
        .widget<ScrollablePositionedList>(find.byType(ScrollablePositionedList))
        .itemCount;

    testWidgets('保留请求期间滚到的最新图片及部分偏移', (tester) async {
      final reader = await openReader(tester);
      final flow = reader.imageViewController as ContinuousModeState;
      flow.itemScrollController.jumpTo(index: 3, alignment: -0.35);
      await _frames(tester);
      final before = tester.getRect(_image(2, 3));
      expect(before.top, lessThan(0));
      final page = reader.page;
      final scaffold = tester.state<_ScaffoldState>(find.byType(_Scaffold));
      scaffold.fullUpdates = 0;
      scaffold.pageUpdates = 0;
      reader.navigationEvents.clear();

      source.complete('one');
      await _frames(tester);

      expect(itemCount(tester), _pageCount * 2 + 2);
      expect(tester.getRect(_image(2, 3)).top, closeTo(before.top, 0.01));
      expect(reader.chapter, 2);
      expect(reader.page, page);
      expect(reader.navigationEvents, isEmpty);
      expect(scaffold.fullUpdates, 0);
      expect(scaffold.pageUpdates, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('前章返回时保持拖动响应，空闲后恢复最终锚点', (tester) async {
      final reader = await openReader(tester);
      final flow = reader.imageViewController as ContinuousModeState;
      flow.itemScrollController.jumpTo(index: 3, alignment: -0.2);
      await _frames(tester);
      final gesture = await tester.startGesture(const Offset(200, 350));
      var gestureActive = true;
      addTearDown(() async {
        if (gestureActive) await gesture.cancel();
      });
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      final before = tester.getRect(_image(2, 3));

      source.complete('one');
      await _frames(tester);
      expect(itemCount(tester), _pageCount + 2);
      expect(flow.scrollController.position.isScrollingNotifier.value, isTrue);
      expect(tester.getRect(_image(2, 3)).top, closeTo(before.top, 0.01));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      final finalTop = tester.getRect(_image(2, 3)).top;
      expect(finalTop, closeTo(before.top - 40, 0.01));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      gestureActive = false;
      await tester.pumpAndSettle();

      expect(itemCount(tester), _pageCount * 2 + 2);
      expect(tester.getRect(_image(2, 3)).top, closeTo(finalTop, 0.01));
      expect(reader.chapter, 2);
      expect(tester.takeException(), isNull);
    });

    for (final animated in [false, true]) {
      testWidgets('主动翻页后丢弃迟到前章，animated=$animated', (tester) async {
        final reader = await openReader(tester);
        expect(reader.toPage(5, animated: animated), isTrue);
        await tester.pumpAndSettle();
        final before = tester.getRect(_image(2, 5));
        source.complete('one');
        await _frames(tester);

        expect(itemCount(tester), _pageCount + 2);
        expect(tester.getRect(_image(2, 5)).top, closeTo(before.top, 0.01));
        expect(reader.chapter, 2);
        expect(reader.page, 5);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('旧请求完成不清除新的前章加载状态', (tester) async {
      final reader = await openReader(tester);
      final flow = reader.imageViewController as ContinuousModeState;
      expect(reader.toPage(3, animated: false), isTrue);
      await _frames(tester);
      flow.itemScrollController.jumpTo(index: 1);
      await _frames(tester);
      expect(source.requests['one'], hasLength(2));

      source.complete('one');
      await _frames(tester);
      flow.onPositionChanged();
      await _frames(tester);
      expect(source.requests['one'], hasLength(2));
      expect(itemCount(tester), _pageCount + 2);
      source.complete('one', request: 1);
      await _frames(tester);
      expect(itemCount(tester), _pageCount * 2 + 2);
      expect(reader.chapter, 2);
      expect(tester.takeException(), isNull);
    });

    for (final empty in [false, true]) {
      testWidgets('导航${empty ? '空章节' : '失败'}后仍可继续滚动阅读', (tester) async {
        final reader = await openReader(tester);
        final flow = reader.imageViewController as ContinuousModeState;
        expect(reader.toChapter(3), isTrue);
        await tester.pump();
        source.complete(
          'three',
          result: empty ? const Res([]) : const Res.error('offline'),
        );
        await _frames(tester);

        expect(reader.imageViewController, same(flow));
        expect(reader.isLoading, isFalse);
        expect(reader.chapter, 2);
        expect(itemCount(tester), _pageCount + 2);
        flow.itemScrollController.jumpTo(index: 3);
        await _frames(tester);
        expect(reader.page, 3);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('主动跳章重置后丢弃旧前章及后章结果', (tester) async {
      final reader = await openReader(tester);
      final flow = reader.imageViewController as ContinuousModeState;
      flow.itemScrollController.jumpTo(index: _pageCount);
      await _frames(tester);
      expect(source.requests['three'], hasLength(1));

      expect(reader.toChapter(1), isTrue);
      await tester.pump();
      expect(source.requests['one'], hasLength(2));
      source.complete('one', request: 1);
      await _frames(tester);
      expect(reader.chapter, 1);
      expect(reader.page, 1);
      final before = tester.getRect(_image(1, 1));
      reader.navigationEvents.clear();

      source.complete('one');
      source.complete('three');
      await _frames(tester);

      expect(itemCount(tester), _pageCount + 2);
      expect(tester.getRect(_image(1, 1)).top, closeTo(before.top, 0.01));
      expect(reader.chapter, 1);
      expect(reader.page, 1);
      expect(reader.navigationEvents, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('重载时丢弃已返回且正在等待空闲的前章', (tester) async {
      final reader = await openReader(tester);
      final oldFlow = reader.imageViewController as ContinuousModeState;
      final gesture = await tester.startGesture(const Offset(200, 350));
      var gestureActive = true;
      addTearDown(() async {
        if (gestureActive) await gesture.cancel();
      });
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      source.complete('one');
      await _frames(tester);
      expect(
        oldFlow.scrollController.position.isScrollingNotifier.value,
        isTrue,
      );

      reader.reloadAt(chapter: 3, page: 3);
      await tester.pump();
      await gesture.cancel();
      gestureActive = false;
      await _frames(tester);

      expect(oldFlow.mounted, isFalse);
      expect(reader.imageViewController, isNot(same(oldFlow)));
      expect(itemCount(tester), _pageCount + 2);
      expect(reader.chapter, 3);
      expect(reader.page, 3);
      expect(tester.takeException(), isNull);
    });

    for (final waitingForIdle in [false, true]) {
      testWidgets('退出取消迟到加载或空闲等待，waitingForIdle=$waitingForIdle', (
        tester,
      ) async {
        final reader = await openReader(tester);
        final flow = reader.imageViewController as ContinuousModeState;
        TestGesture? gesture;
        if (waitingForIdle) {
          gesture = await tester.startGesture(const Offset(200, 350));
          await gesture.moveBy(const Offset(0, -40));
          await tester.pump();
          source.complete('one');
          await _frames(tester);
          expect(
            flow.scrollController.position.isScrollingNotifier.value,
            isTrue,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await gesture?.cancel();
        if (!waitingForIdle) source.complete('one');
        await tester.pump(const Duration(seconds: 1));

        expect(flow.mounted, isFalse);
        expect(reader.imageViewController, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }, skip: !isSqliteAvailable());
}

class _Reader extends Reader {
  _Reader({super.key})
    : super(
        type: _type,
        cid: 'waterfall-book',
        name: 'Waterfall book',
        chapters: _chapters,
        initialChapter: 2,
        initialPage: 1,
        history: History.fromMap({
          'id': 'waterfall-book',
          'type': _type.value,
          'time': 1000,
          'title': 'Waterfall book',
          'ep': 2,
          'page': 1,
        }),
        author: '',
        tags: const [],
      );

  @override
  ReaderState createState() => _ReaderState();
}

class _ReaderState extends ReaderState {
  final navigationEvents =
      <({int chapter, int page, ReadingNavigationSource source})>[];
  int _reload = 0;

  @override
  void initState() {
    super.initState();
    images = _images(2);
  }

  void reloadAt({required int chapter, required int page}) {
    onReaderContentLoading();
    setState(() {
      this.chapter = chapter;
      pageValue = page;
      images = _images(chapter);
      _reload++;
    });
    onReaderContentReady();
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
    navigationEvents.add((chapter: chapter, page: page, source: source));
  }

  @override
  Widget build(BuildContext context) => _Scaffold(
    child: ContinuousMode(key: ValueKey(_reload), crossChapter: true),
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
  final requests = <String, List<Completer<Res<List<String>>>>>{};

  @override
  String get key => _sourceKey;
  @override
  String get filePath => '';
  @override
  String get name => 'Waterfall';
  @override
  get updateReadProgressFunc => null;
  @override
  get sendChapterCommentFunc => null;
  @override
  get chapterCommentsLoader => null;
  @override
  LoadComicPagesFunc get loadComicPages => (_, chapter) {
    final pending = Completer<Res<List<String>>>();
    requests.putIfAbsent(chapter!, () => []).add(pending);
    return pending.future;
  };

  void complete(String chapter, {int request = 0, Res<List<String>>? result}) {
    final index = _chapters.ids.toList().indexOf(chapter) + 1;
    requests[chapter]![request].complete(result ?? Res(_images(index)));
  }

  void completeAll() {
    for (final chapter in requests.keys) {
      for (final pending in requests[chapter]!) {
        if (!pending.isCompleted) {
          final index = _chapters.ids.toList().indexOf(chapter) + 1;
          pending.complete(Res(_images(index)));
        }
      }
    }
  }
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
