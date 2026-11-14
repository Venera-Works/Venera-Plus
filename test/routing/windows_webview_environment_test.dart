import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/routing/windows_webview_environment.dart';

void main() {
  test('Windows proxy modes produce WebView2 arguments', () {
    const arguments = {
      'system': null,
      'direct': '--no-proxy-server',
      '127.0.0.1:7890': '--proxy-server=http://127.0.0.1:7890',
      'HTTP://LOCALHOST:00080': '--proxy-server=http://localhost:80',
      'https://proxy.example:443': '--proxy-server=https://proxy.example:443',
      'socks4://localhost:1080': '--proxy-server=socks4://localhost:1080',
      'socks5://localhost:1080': '--proxy-server=socks5://localhost:1080',
      '[::1]:7890': '--proxy-server=http://[::1]:7890',
    };
    for (final entry in arguments.entries) {
      expect(windowsWebviewProxyArguments(entry.key), entry.value);
    }
  });

  test('manual proxies require one valid endpoint', () {
    for (final proxy in [
      '',
      'localhost',
      'localhost:0',
      'localhost:65536',
      'localhost:1 --no-proxy-server',
      'localhost:1\r\n--no-proxy-server',
      'localhost:1;direct://',
      'http://localhost:80/path',
      'http://localhost:80?option=1',
      'ftp://localhost:80',
      'proxy..example:80',
      '[1:2:3]:80',
    ]) {
      expect(
        () => windowsWebviewProxyArguments(proxy),
        throwsA(isA<WebviewEnvironmentException>()),
        reason: proxy,
      );
    }
    expect(
      () => windowsWebviewProxyArguments(
        'http://user:${'credential'}@localhost:80',
      ),
      throwsA(
        isA<WebviewEnvironmentException>()
            .having((error) => '$error', 'message', contains('system proxy'))
            .having(
              (error) => '$error',
              'credentials',
              isNot(contains('credential')),
            ),
      ),
    );
  });

  late WindowsWebviewEnvironmentPool pool;
  late List<_Environment> created;
  setUp(() {
    created = [];
    pool = WindowsWebviewEnvironmentPool(
      create: (settings) async {
        final environment = _Environment(settings);
        created.add(environment);
        return WebViewEnvironment.fromPlatform(platform: environment);
      },
    );
  });

  Future<WindowsWebviewEnvironmentLease> acquire(String proxy) =>
      pool.acquire(userDataFolder: r'profile\webview', proxy: proxy);

  test('concurrent equivalent proxies share one environment', () async {
    final leases = await Future.wait([
      acquire('127.0.0.1:7890'),
      acquire('http://127.0.0.1:7890'),
    ]);
    expect(created, hasLength(1));
    expect(leases.first.environment, same(leases.last.environment));
    leases.first.release();
    leases.first.release();
    await expectLater(
      acquire('direct'),
      throwsA(isA<WebviewEnvironmentException>()),
    );
    expect(created.single.disposals, 0);
    leases.last.release();
  });

  test(
    'proxy changes wait for browser exit and preserve the profile',
    () async {
      final first = await acquire('system');
      first.viewRequested();
      first.release();
      var ready = false;
      final second = acquire('localhost:7890').then((value) {
        ready = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      expect(created.single.disposals, 0);
      created.single.exit();
      final lease = await second;
      expect(created, hasLength(2));
      expect(created.first.disposals, 1);
      expect(created.last.settings!.userDataFolder, r'profile\webview');
      expect(
        created.last.settings!.additionalBrowserArguments,
        '--proxy-server=http://localhost:7890',
      );
      lease.release();
      final direct = await acquire('direct');
      expect(
        created.last.settings!.additionalBrowserArguments,
        '--no-proxy-server',
      );
      direct.release();
      final system = await acquire('system');
      expect(created.last.settings!.additionalBrowserArguments, isNull);
      system.release();
    },
  );

  test('cancelled initialization can release without a browser exit', () async {
    final first = await acquire('system');
    first.release();
    final second = await acquire('direct');
    expect(created.first.disposals, 1);
    second.release();
  });

  test('reopening the same proxy reuses the environment before exit', () async {
    final first = await acquire('system');
    first.viewRequested();
    first.release();
    final reopened = await acquire('system');
    expect(reopened.environment, same(first.environment));
    expect(created, hasLength(1));
    expect(created.single.disposals, 0);
    reopened.release();
    created.single.exit();
    final afterExit = await acquire('system');
    expect(created, hasLength(2));
    expect(created.first.disposals, 1);
    afterExit.release();
  });

  test(
    'an exit timeout keeps the old environment available for retry',
    () async {
      pool = WindowsWebviewEnvironmentPool(
        browserExitTimeout: Duration.zero,
        create: (settings) async {
          final environment = _Environment(settings);
          created.add(environment);
          return WebViewEnvironment.fromPlatform(platform: environment);
        },
      );
      final first = await acquire('system');
      first.viewRequested();
      first.release();
      await expectLater(
        acquire('direct'),
        throwsA(isA<WebviewEnvironmentException>()),
      );
      expect(created.single.disposals, 0);
      created.single.exit();
      final retry = await acquire('direct');
      expect(created.first.disposals, 1);
      retry.release();
    },
  );

  test(
    'in-flight cookies retain their environment and late reads fail',
    () async {
      final first = await acquire('system');
      final result = Completer<String>();
      final read = first.use((environment) {
        expect(environment, same(first.environment));
        return result.future;
      });
      first.release();
      await expectLater(
        acquire('direct'),
        throwsA(isA<WebviewEnvironmentException>()),
      );
      result.complete('cookie');
      expect(await read, 'cookie');
      var called = false;
      await expectLater(
        first.use((_) async => called = true),
        throwsA(isA<WebviewEnvironmentException>()),
      );
      expect(called, isFalse);
      final next = await acquire('direct');
      expect(created.first.disposals, 1);
      next.release();
    },
  );

  test('failed creation permits a later attempt', () async {
    var attempts = 0;
    pool = WindowsWebviewEnvironmentPool(
      create: (settings) async {
        if (attempts++ == 0) throw StateError('creation failed');
        return WebViewEnvironment.fromPlatform(
          platform: _Environment(settings),
        );
      },
    );
    await expectLater(acquire('system'), throwsStateError);
    final retry = await acquire('direct');
    expect(attempts, 2);
    retry.release();
  });
}

class _Environment extends PlatformWebViewEnvironment {
  _Environment(WebViewEnvironmentSettings settings)
    : super.implementation(
        PlatformWebViewEnvironmentCreationParams(settings: settings),
      );

  int disposals = 0;

  void exit() => onBrowserProcessExited?.call(_BrowserExit());

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class _BrowserExit extends Fake implements BrowserProcessExitedDetail {}
