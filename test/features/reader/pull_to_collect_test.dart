import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/reader/scaffold.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

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
  @override
  ReaderImageReference getImageReferenceByOffset(Offset offset) =>
      ReaderImageReference(
        imageKey: offset.dx > 400 ? 'page-2' : 'page-1',
        cid: 'pull-book',
        eid: '0',
        chapter: 1,
        page: offset.dx > 400 ? 2 : 1,
      );

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
