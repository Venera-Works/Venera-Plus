import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/reader/reader_page.dart' show ReaderState;
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/routing/app_links.dart';

import '../support/sqlite.dart';
import '../widget_test_io.dart';

const _eventChannel = MethodChannel('com.llfbandit.app_links/events');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var subscriptions = 0;

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_eventChannel, (call) async {
          if (call.method == 'listen') subscriptions++;
          return null;
        });
    // 单例订阅不能绑定到某一项 Widget 测试的 FakeAsync Zone。
    handleLinks();
    await Future<void>.delayed(Duration.zero);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_eventChannel, null);
  });

  setUp(() {
    final previousKey = App.mainNavigatorKey;
    final previousMuted = Log.isMuted;
    Log.isMuted = true;
    setAppLinkNavigationReady(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => false,
        );
    addTearDown(() {
      setAppLinkNavigationReady(false);
      App.mainNavigatorKey = previousKey;
      Log.isMuted = previousMuted;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            null,
          );
    });
  });

  testWidgets('系统链接在可见根路由上打开详情并忽略域名大小写', (tester) async {
    final source = _source(
      'root_link_fixture',
      LinkHandler(['NHENTAI.NET'], (_) => '123'),
    );
    _registerSource(source);
    final root = _Routes();
    final nested = _Routes();
    await _mountNavigation(tester, root: root, nested: nested);
    unawaited(
      App.rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('根阅读器')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      await handleAppLink(
        Uri.parse('https://nhentai.net/g/123/7/'),
        rootNavigator: true,
      ),
      isTrue,
    );
    final route = root.routes.last as AppPageRoute;
    final page = route.builder(App.rootContext) as ComicPage;
    expect(route.navigator, App.rootNavigatorKey.currentState);
    expect(route.isCurrent, isTrue);
    expect(nested.routes, hasLength(1));
    expect(page.id, '123');
    expect(page.sourceKey, source.key);
    expect(page.initialReaderPage, 7);
    App.rootNavigatorKey.currentState!.removeRoute(route);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('页内链接仍由主导航打开，评论调用方可以收起根弹层', (tester) async {
    _registerSource(
      _source(
        'inline_link_fixture',
        LinkHandler(['example.test'], (_) => 'book'),
      ),
    );
    final root = _Routes();
    final nested = _Routes();
    await _mountNavigation(tester, root: root, nested: nested);
    expect(await handleAppLink(Uri.parse('https://example.test/book')), isTrue);
    final route = nested.routes.last as AppPageRoute;
    expect(route.navigator, App.mainNavigatorKey!.currentState);
    expect(root.routes, hasLength(1));
    App.mainNavigatorKey!.currentState!.removeRoute(route);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同域源解析失败后继续查找，未知路径不剥离数字 ID', (tester) async {
    final inputs = <String>[];
    _registerSource(
      _source(
        'declined_link_fixture',
        LinkHandler(['example.test'], (_) => null),
      ),
    );
    _registerSource(
      _source(
        'throwing_link_fixture',
        LinkHandler([
          'example.test',
        ], (_) => throw const FormatException('伪源拒绝链接')),
      ),
    );
    _registerSource(
      _source(
        'accepted_link_fixture',
        LinkHandler(['EXAMPLE.TEST'], (url) {
          inputs.add(url);
          return '456';
        }),
      ),
    );
    final root = _Routes();
    await _mountNavigation(tester, root: root);
    final uri = Uri.parse('https://example.test/g/123/456/');
    expect(await handleAppLink(uri, rootNavigator: true), isTrue);
    final route = root.routes.last as AppPageRoute;
    final page = route.builder(App.rootContext) as ComicPage;
    expect(inputs, [uri.toString()]);
    expect(page.id, '456');
    expect(page.initialReaderPage, isNull);
    App.rootNavigatorKey.currentState!.removeRoute(route);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('订阅收到链接但导航未挂载时保留，挂载后处理一次', (tester) async {
    _registerSource(
      _source(
        'queued_link_fixture',
        LinkHandler([
          'example.test',
        ], (url) => Uri.parse(url).pathSegments.last),
      ),
    );
    handleLinks();
    handleLinks();
    await tester.pump();
    expect(subscriptions, 1);

    // 未识别链接不阻塞，已识别但暂时无导航的链接不能提前消费。
    setAppLinkNavigationReady(true);
    await _sendLink(tester, 'https://unsupported.test/book');
    await _sendLink(tester, 'https://example.test/first');
    await _sendLink(tester, 'https://example.test/second');
    expect(App.rootNavigatorKey.currentContext, isNull);
    final root = _Routes();
    await _mountNavigation(tester, root: root);
    setAppLinkNavigationReady(true);
    // 队列仅等待导航入栈，不等待用户退出页面。
    await tester.idle();
    final routes = root.routes.whereType<AppPageRoute>().toList();
    expect(
      routes.map((route) => (route.builder(App.rootContext) as ComicPage).id),
      ['first', 'second'],
    );
    for (final route in routes.reversed) {
      App.rootNavigatorKey.currentState!.removeRoute(route);
    }
    setAppLinkNavigationReady(true);
    await tester.idle();
    expect(root.routes.whereType<AppPageRoute>(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final target in [(2, true), (99, true), (99, false)]) {
    final (targetPage, hasMaxPage) = target;
    testWidgets(
      '详情加载后打开指定页且不预写历史：$targetPage（maxPage=$hasMaxPage）',
      (tester) async {
        final detailsLoaded = Completer<Res<ComicDetails>>();
        final fixture = await _createFixture(
          tester,
          loadDetails: (_) => detailsLoaded.future,
          maxPage: hasMaxPage ? 4 : null,
        );
        fixture.histories.addHistory(
          History.fromModel(
            model: fixture.details,
            ep: 1,
            page: 4,
            readingProgress: ReadingProgress.seed(
              const ReadingPosition(ep: 1, page: 4),
              time: 1000,
            ),
          ),
        );
        final root = _Routes();
        await _mountNavigation(tester, root: root);
        expect(
          await handleAppLink(
            Uri.parse('https://nhentai.net/g/123/$targetPage/'),
            rootNavigator: true,
          ),
          isTrue,
        );
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.byType(Reader), findsNothing);
        expect(fixture.histories.find('123', fixture.type)!.page, 4);

        detailsLoaded.complete(Res(fixture.details));
        final expectedPage = targetPage.clamp(1, 4);
        await _waitFor(tester, () {
          if (find.byType(Reader).evaluate().isEmpty) return false;
          final reader = tester.state<ReaderState>(find.byType(Reader));
          return reader.images?.length == 4 && reader.page == expectedPage;
        });
        final reader = tester.widget<Reader>(find.byType(Reader));
        expect(reader.cid, '123');
        expect(reader.initialPage, hasMaxPage ? expectedPage : targetPage);
        expect(reader.initialChapter, 1);
        expect(
          reader.initialNavigationSource,
          ReadingNavigationSource.userSeek,
        );
        await runWidgetIo(
          tester,
          () => fixture.histories.flushReadingProgress(),
        );
        final progress = fixture.histories
            .find('123', fixture.type)!
            .readingProgress!;
        expect(progress.maximumPositions.single.page, 4);
        expect(progress.resumePosition!.page, expectedPage);
        expect(fixture.histories.find('123', fixture.type)!.page, expectedPage);

        // 刷新详情及从阅读器返回均不重复执行初始链接。
        tester
            .state<LoadingState<ComicPage, ComicDetails>>(
              find.byType(ComicPage, skipOffstage: false),
            )
            .retry();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(Reader, skipOffstage: false), findsOneWidget);
        App.rootNavigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(Reader, skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);
      },
      skip: !isSqliteAvailable(),
    );
  }

  testWidgets('排队的多个页码链接不会被较早详情的延迟加载抢占', (tester) async {
    final firstLoaded = Completer<Res<ComicDetails>>();
    final secondLoaded = Completer<Res<ComicDetails>>();
    final fixture = await _createFixture(
      tester,
      loadDetails: (id) =>
          id == '123' ? firstLoaded.future : secondLoaded.future,
    );
    final root = _Routes();
    await _mountNavigation(tester, root: root);
    handleLinks();
    await tester.pump();
    await _sendLink(tester, 'https://nhentai.net/g/123/2/');
    await _sendLink(tester, 'https://nhentai.net/g/456/3/');
    setAppLinkNavigationReady(true);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      root.routes.whereType<AppPageRoute>().map(
        (route) => (route.builder(App.rootContext) as ComicPage).id,
      ),
      ['123', '456'],
    );

    secondLoaded.complete(Res(_details(fixture.sourceKey, '456')));
    await _waitFor(tester, () {
      if (find.byType(Reader).evaluate().isEmpty) return false;
      return tester.widget<Reader>(find.byType(Reader)).cid == '456';
    });
    firstLoaded.complete(Res(fixture.details));
    await tester.pump(const Duration(milliseconds: 500));
    final readers = tester.widgetList<Reader>(
      find.byType(Reader, skipOffstage: false),
    );
    expect(readers.map((reader) => reader.cid), ['456']);
    expect(readers.single.initialPage, 3);
    expect(fixture.histories.find('123', fixture.type), isNull);
    await runWidgetIo(tester, () => fixture.histories.flushReadingProgress());
    expect(tester.takeException(), isNull);
  }, skip: !isSqliteAvailable());
}

void _registerSource(ComicSource source) {
  ComicSourceManager().add(source);
  addTearDown(() => ComicSourceManager().remove(source.key));
}

Future<void> _sendLink(WidgetTester tester, String url) async {
  await tester.runAsync(() async {
    final delivered = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _eventChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope(url),
      (_) => delivered.complete(),
    );
    await delivered.future;
    await Future<void>.delayed(Duration.zero);
  });
  await tester.pump();
}

Future<void> _mountNavigation(
  WidgetTester tester, {
  required _Routes root,
  _Routes? nested,
}) async {
  App.mainNavigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      navigatorObservers: [root],
      builder: (_, child) => WindowFrame(child!),
      home: Navigator(
        key: App.mainNavigatorKey,
        observers: [?nested],
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('主页')),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _Routes extends NavigatorObserver {
  final routes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.add(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      routes.remove(route);
}

ComicSource _source(
  String key,
  LinkHandler handler, {
  LoadComicFunc? loadDetails,
  LoadComicPagesFunc? loadPages,
}) => ComicSource(
  '链接测试伪源',
  key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  loadDetails ?? ((_) async => const Res.error('不加载详情')),
  null,
  loadPages ?? ((_, _) async => const Res(<String>[])),
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  handler,
  false,
  false,
  null,
  null,
);

ComicDetails _details(String sourceKey, String id, {int? maxPage = 4}) =>
    ComicDetails.fromJson({
      'title': '链接测试漫画 $id',
      'cover': '',
      'description': '',
      'tags': <String, dynamic>{},
      'sourceKey': sourceKey,
      'comicId': id,
      'maxPage': ?maxPage,
    });

Future<_Fixture> _createFixture(
  WidgetTester tester, {
  required LoadComicFunc loadDetails,
  int? maxPage = 4,
}) async {
  final previousSettings =
      jsonDecode(jsonEncode(appdata.toJson()['settings']))
          as Map<String, dynamic>;
  final previousHistory = HistoryManager.cache;
  final previousFavorites = LocalFavoritesManager.cache;
  final previousDataPath = _appPath(cache: false);
  final previousCachePath = _appPath(cache: true);
  final temporary = Directory.systemTemp.createTempSync('app-links-');
  App.dataPath = temporary.path;
  App.cachePath = temporary.path;
  final settings = appdata.settings;
  settings['language'] = 'en-US';
  settings['readerMode'] = 'galleryLeftToRight';
  settings['autoReaderMode'] = false;
  settings['readerScreenPicNumberForPortrait'] = 1;
  settings['readerScreenPicNumberForLandscape'] = 1;
  settings['comicSpecificSettings'] = <String, dynamic>{};
  settings['deviceSpecificSettings'] = <String, dynamic>{};
  settings['enableCustomImageProcessing'] = false;
  settings['enableClockAndBatteryInfoInReader'] = false;
  settings['enableTurnPageByVolumeKey'] = false;
  settings['showPageNumberInReader'] = false;
  settings['showChapterComments'] = false;
  settings['showChapterCommentsAtEnd'] = false;
  settings['showSystemStatusBar'] = false;
  settings['historyRetentionDays'] = 0;
  HistoryManager.cache = null;
  LocalFavoritesManager.cache = _Favorites();
  LocalManager.resetForTesting();
  LocalManager.debugSkipComicSourceInit = true;
  final histories = HistoryManager();
  final comics = Directory('${temporary.path}/comics')..createSync();
  File('${temporary.path}/local_path').writeAsStringSync(comics.path);
  await tester.runAsync(() async {
    await histories.init();
    await LocalManager().init();
  });
  final bytes = img.encodePng(img.Image(width: 100, height: 160));
  final images = [
    for (var i = 1; i <= 4; i++)
      File('${temporary.path}/$i.png')..writeAsBytesSync(bytes),
  ];
  final key = 'app_link_${temporary.path.hashCode}';
  _registerSource(
    _source(
      key,
      LinkHandler(['NHENTAI.NET'], (url) => Uri.parse(url).pathSegments[1]),
      loadDetails: loadDetails,
      loadPages: (_, _) async =>
          Res([for (final file in images) 'file://${file.path}']),
    ),
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter_memory_info'),
    (call) async => 1 << 30,
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async => false,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await runWidgetIo(tester, () async {
      await histories.flushReadingProgress();
      await histories.waitForAsyncWrites();
      await appdata.saveData(false);
    });
    histories.close();
    LocalManager.resetForTesting();
    HistoryManager.cache = previousHistory;
    LocalFavoritesManager.cache = previousFavorites;
    (appdata.toJson()['settings'] as Map)
      ..clear()
      ..addAll(previousSettings);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    for (final channel in ['flutter_memory_info', 'window_manager']) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(channel),
        null,
      );
    }
    await tester.runAsync(() => temporary.delete(recursive: true));
  });
  return _Fixture(key, histories, _details(key, '123', maxPage: maxPage));
}

String _appPath({required bool cache}) {
  try {
    return cache ? App.cachePath : App.dataPath;
  } catch (_) {
    return Directory.systemTemp.path;
  }
}

class _Fixture {
  const _Fixture(this.sourceKey, this.histories, this.details);
  final String sourceKey;
  final HistoryManager histories;
  final ComicDetails details;
  ComicType get type => ComicType.fromKey(sourceKey);
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  bool hasNewUpdate(String id, ComicType type, [String? folder]) => false;
  @override
  bool isExist(String id, ComicType type) => false;
  @override
  ComicUpdateState getUpdateState(String id, ComicType type) =>
      const ComicUpdateState.empty();
  @override
  void onRead(String id, ComicType type) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (ready()) return;
  }
  fail('链接导航或阅读页未在限定时间内就绪');
}
