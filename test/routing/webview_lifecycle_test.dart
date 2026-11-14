import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// Exercise the locked Windows factory so an Android feature call still fails.
// ignore: depend_on_referenced_packages
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/cloudflare.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:venera_plus/routing/cloudflare.dart';
import 'package:venera_plus/routing/webview.dart';
import 'package:venera_plus/routing/windows_webview_environment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  App.dataPath = 'webview-lifecycle-test';
  late _WindowsPlatform platform;
  late _CookieJar jar;

  setUp(() {
    final previousPlatform = InAppWebViewPlatform.instance;
    final previousProxy = appdata.settings['proxy'];
    final previousLanguage = appdata.settings['language'];
    final previousJar = SingleInstanceCookieJar.instance;
    final previousMuted = Log.isMuted;
    platform = _WindowsPlatform();
    InAppWebViewPlatform.instance = platform;
    appdata.settings['proxy'] = 'system';
    appdata.settings['language'] = 'en-US';
    jar = _CookieJar();
    SingleInstanceCookieJar.instance = jar;
    Log.isMuted = true;
    addTearDown(() {
      if (previousPlatform != null) {
        InAppWebViewPlatform.instance = previousPlatform;
      }
      appdata.settings['proxy'] = previousProxy;
      appdata.settings['language'] = previousLanguage;
      SingleInstanceCookieJar.instance = previousJar;
      Log.isMuted = previousMuted;
    });
  });

  Future<void> pumpInitialization(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  void cleanUpWidget(WidgetTester tester) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  InAppWebViewController attach(_Controller native) {
    final controller = InAppWebViewController.fromPlatform(platform: native);
    final view = platform.views.last;
    view.params.onWebViewCreated!(controller);
    view.params.onProgressChanged!(controller, 100);
    return controller;
  }

  Future<void> showWebview(WidgetTester tester, AppWebview webview) async {
    await tester.pumpWidget(MaterialApp(home: webview));
    await pumpInitialization(tester);
  }

  Future<void> showRequest(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(body: Text('home')),
      ),
    );
    unawaited(
      App.rootNavigatorKey.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('request')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Windows webview lifecycle', () {
    for (final proxy in {
      'system': null,
      'direct': '--no-proxy-server',
      '127.0.0.1:7890': '--proxy-server=http://127.0.0.1:7890',
      'socks5://localhost:1080': '--proxy-server=socks5://localhost:1080',
    }.entries) {
      testWidgets('initializes ${proxy.key} without Android APIs', (
        tester,
      ) async {
        cleanUpWidget(tester);
        appdata.settings['proxy'] = proxy.key;
        await showWebview(tester, const AppWebview(initialUrl: 'about:blank'));
        attach(_Controller());
        await tester.pumpAndSettle();
        expect(platform.featureQueries, 0);
        expect(
          platform.environments.single.settings!.additionalBrowserArguments,
          proxy.value,
        );
        expect(
          platform.environments.single.settings!.userDataFolder,
          'webview-lifecycle-test\\webview',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'cookies stay with their controller and closed callbacks stop',
      (tester) async {
        cleanUpWidget(tester);
        final events = <String>[];
        await showWebview(
          tester,
          AppWebview(
            initialUrl: 'about:blank',
            onStarted: (_) => events.add('started'),
            onTitleChange: (_, _) => events.add('title'),
            onLoadStop: (_) => events.add('loaded'),
          ),
        );
        final controller = attach(_Controller());
        final firstView = platform.views.last;
        final firstEnvironment = platform.environments.single;
        final wrapper = InAppWebViewController.fromPlatform(
          platform: controller.platform,
        );
        await wrapper.getCookies('https://example.test/');
        expect(platform.cookieEnvironments.single, same(firstEnvironment));
        firstView.params.onTitleChanged!(wrapper, 'Active');
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        firstView.params.onTitleChanged!(wrapper, 'Late');
        firstView.params.onLoadStop!(wrapper, WebUri('about:blank'));
        firstView.params.onWebViewCreated!(wrapper);
        expect(events, ['started', 'title']);

        appdata.settings['proxy'] = 'direct';
        await showWebview(tester, const AppWebview(initialUrl: 'about:blank'));
        final next = attach(_Controller());
        await tester.pumpAndSettle();
        await next.getCookies('https://example.test/');
        expect(
          platform.cookieEnvironments.last,
          same(platform.environments.last),
        );
        expect(firstEnvironment.disposals, 1);
        await expectLater(
          wrapper.getCookies('https://example.test/'),
          throwsA(isA<WebviewEnvironmentException>()),
        );
        expect(platform.cookieEnvironments, hasLength(2));
      },
    );

    testWidgets('closing pending initialization releases the environment', (
      tester,
    ) async {
      cleanUpWidget(tester);
      final pending = Completer<void>();
      platform.beforeCreate = () => pending.future;
      await showWebview(tester, const AppWebview(initialUrl: 'about:blank'));
      expect(platform.views, isEmpty);
      await tester.pumpWidget(const SizedBox());
      pending.complete();
      await pumpInitialization(tester);
      expect(platform.views, isEmpty);
      platform.beforeCreate = null;
      appdata.settings['proxy'] = 'direct';
      await showWebview(tester, const AppWebview(initialUrl: 'about:blank'));
      attach(_Controller());
      await tester.pumpAndSettle();
      expect(platform.environments.first.disposals, 1);
      expect(platform.environments, hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('invalid proxy stops loading and can retry', (tester) async {
      cleanUpWidget(tester);
      appdata.settings['proxy'] = 'localhost:7890 --no-proxy-server';
      await showWebview(tester, const AppWebview(initialUrl: 'about:blank'));
      expect(
        find.textContaining('Invalid Windows webview proxy.'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(platform.environments, isEmpty);
      appdata.settings['proxy'] = 'direct';
      await tester.tap(find.text('Retry'));
      await pumpInitialization(tester);
      attach(_Controller());
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cloudflare waits for valid DOM and a clearance cookie', (
      tester,
    ) async {
      cleanUpWidget(tester);
      await showRequest(tester);
      var finished = 0;
      final verification = passCloudflare(
        CloudflareException('https://example.test/'),
        () => finished++,
      );
      await pumpInitialization(tester);
      final native = _Controller();
      final controller = attach(native);
      final view = platform.views.last;
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      await tester.pumpAndSettle();
      expect(platform.cookieEnvironments, isEmpty);

      native.head = '<title>Ready</title>';
      native.body = null;
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      await tester.pump();
      expect(platform.cookieEnvironments, isEmpty);

      native.body = '<main>Ready</main>';
      view.params.onTitleChanged!(controller, 'Ready');
      await tester.pump();
      expect(finished, 0);
      expect(jar.saved, isEmpty);

      platform.cookies = [Cookie(name: 'cf_clearance', value: 'test')];
      native.body = 'challenge-platform';
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      await tester.pump();
      expect(finished, 0);

      native.body = '<main>Ready</main>';
      view.params.onTitleChanged!(controller, 'Ready');
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      await tester.pumpAndSettle();
      await verification;
      expect(finished, 1);
      expect(jar.saved, hasLength(1));
      expect(find.text('request'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cloudflare catches JS and cookie errors and permits retry', (
      tester,
    ) async {
      cleanUpWidget(tester);
      await showRequest(tester);
      var finished = 0;
      final verification = passCloudflare(
        CloudflareException('https://example.test/'),
        () => finished++,
      );
      await pumpInitialization(tester);
      final native = _Controller()..failEvaluation = true;
      final controller = attach(native);
      final view = platform.views.last;
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      await tester.pumpAndSettle();
      expect(finished, 0);
      expect(tester.takeException(), isNull);

      native.failEvaluation = false;
      native.head = '';
      native.body = '';
      platform.failCookies = true;
      view.params.onTitleChanged!(controller, 'Ready');
      await tester.pump();
      expect(finished, 0);
      expect(tester.takeException(), isNull);

      platform.failCookies = false;
      platform.cookies = [Cookie(name: 'cf_clearance', value: 'test')];
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      await tester.pumpAndSettle();
      await verification;
      expect(finished, 1);
      expect(jar.saved, hasLength(1));
    });

    testWidgets('Cloudflare coalesces concurrent callbacks and retries once', (
      tester,
    ) async {
      cleanUpWidget(tester);
      await showRequest(tester);
      var finished = 0;
      final verification = passCloudflare(
        CloudflareException('https://example.test/'),
        () => finished++,
      );
      await pumpInitialization(tester);
      final pending = Completer<dynamic>();
      final native = _Controller()..pendingHead = pending.future;
      final controller = attach(native);
      final view = platform.views.last;
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      view.params.onTitleChanged!(controller, 'Ready');
      view.params.onLoadStart!(controller, WebUri('https://example.test/'));
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      expect(native.headReads, 1);
      pending.complete(null);
      await tester.pumpAndSettle();
      expect(native.headReads, 2);
      expect(finished, 0);
      expect(jar.saved, isEmpty);
      native.pendingHead = null;
      native.head = '';
      native.body = '';
      platform.cookies = [Cookie(name: 'cf_clearance', value: 'test')];
      view.params.onLoadStop!(controller, WebUri('https://example.test/'));
      await tester.pumpAndSettle();
      await verification;
      expect(finished, 1);
      expect(jar.saved, hasLength(1));
    });

    testWidgets('a closed Cloudflare check cannot pop the replacement page', (
      tester,
    ) async {
      cleanUpWidget(tester);
      await showRequest(tester);
      final pendingCookies = Completer<List<Cookie>>();
      platform.pendingCookies = pendingCookies.future;
      var finished = 0;
      final verification = passCloudflare(
        CloudflareException('https://example.test/'),
        () => finished++,
      );
      await pumpInitialization(tester);
      final native = _Controller()
        ..head = ''
        ..body = '';
      final controller = attach(native);
      platform.views.last.params.onLoadStop!(
        controller,
        WebUri('https://example.test/'),
      );
      await tester.pumpAndSettle();
      expect(platform.cookieEnvironments, hasLength(1));
      final navigator = App.rootNavigatorKey.currentState!;
      navigator.pop();
      await tester.pumpAndSettle();
      await verification;
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('replacement')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      pendingCookies.complete([Cookie(name: 'cf_clearance', value: 'test')]);
      await tester.pumpAndSettle();
      expect(find.text('replacement'), findsOneWidget);
      expect(finished, 1);
      expect(jar.saved, isEmpty);
      expect(native.uaReads, 0);
      expect(tester.takeException(), isNull);
    });
  }, skip: !io.Platform.isWindows);
}

class _WindowsPlatform extends WindowsInAppWebViewPlatform {
  final environments = <_Environment>[];
  final views = <_View>[];
  final cookieEnvironments = <PlatformWebViewEnvironment?>[];
  Future<void> Function()? beforeCreate;
  Future<List<Cookie>>? pendingCookies;
  List<Cookie> cookies = [];
  bool failCookies = false;
  int featureQueries = 0;

  @override
  PlatformWebViewFeature createPlatformWebViewFeatureStatic() {
    featureQueries++;
    return super.createPlatformWebViewFeatureStatic();
  }

  @override
  WindowsWebViewEnvironment createPlatformWebViewEnvironmentStatic() =>
      _EnvironmentFactory(this);

  @override
  WindowsInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _View(params);
    views.add(view);
    return view;
  }

  @override
  WindowsCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => _Cookies(params, this);
}

class _EnvironmentFactory extends WindowsWebViewEnvironment {
  _EnvironmentFactory(this.owner)
    : super(const PlatformWebViewEnvironmentCreationParams());

  final _WindowsPlatform owner;

  @override
  Future<WindowsWebViewEnvironment> create({
    WebViewEnvironmentSettings? settings,
  }) async {
    await owner.beforeCreate?.call();
    final environment = _Environment(settings!);
    owner.environments.add(environment);
    return environment;
  }
}

class _Environment extends WindowsWebViewEnvironment {
  _Environment(WebViewEnvironmentSettings settings)
    : super(PlatformWebViewEnvironmentCreationParams(settings: settings));

  int disposals = 0;

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class _View extends WindowsInAppWebViewWidget {
  _View(super.params);

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  void dispose() {
    params.webViewEnvironment?.onBrowserProcessExited?.call(_BrowserExit());
  }
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );

  dynamic head;
  dynamic body;
  Future<dynamic>? pendingHead;
  bool failEvaluation = false;
  int headReads = 0;
  int uaReads = 0;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (failEvaluation) throw StateError('JS evaluation failed');
    if (source.contains('document.head')) {
      headReads++;
      return pendingHead == null ? head : await pendingHead;
    }
    if (source.contains('document.body')) return body;
    if (source == 'navigator.userAgent') uaReads++;
    return null;
  }
}

class _Cookies extends WindowsCookieManager {
  _Cookies(super.params, this.owner);

  final _WindowsPlatform owner;

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    owner.cookieEnvironments.add(params.webViewEnvironment);
    if (owner.failCookies) throw StateError('Cookie read failed');
    return owner.pendingCookies == null
        ? owner.cookies
        : await owner.pendingCookies!;
  }
}

class _CookieJar extends Fake implements SingleInstanceCookieJar {
  final saved = <List<io.Cookie>>[];

  @override
  void saveFromResponse(Uri uri, List<io.Cookie> cookies) => saved.add(cookies);
}

class _BrowserExit extends Fake implements BrowserProcessExitedDetail {}
