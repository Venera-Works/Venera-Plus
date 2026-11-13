import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
  group('Production gallery widget', () {
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
        'readerMode': 'galleryLeftToRight',
        'readerScreenPicNumberForLandscape': 1,
        'readerScreenPicNumberForPortrait': 1,
        'showSingleImageOnFirstPage': false,
        'splitDualPage': false,
        'splitDualPageInvert': false,
        'showChapterComments': false,
        'showChapterCommentsAtEnd': false,
        'enableTurnPageByVolumeKey': false,
        'enableClockAndBatteryInfoInReader': false,
        'showPageNumberInReader': false,
        'showSystemStatusBar': true,
        'enableCustomImageProcessing': false,
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
  }) {}
  @override
  Widget build(BuildContext context) =>
      const ReaderScaffold(child: GalleryMode());
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
