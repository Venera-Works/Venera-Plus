import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/storage/quark_login.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/routing/webview.dart';

void main() {
  final session = _Session();
  setUp(() {
    session.cookies.clear();
    session.urls.clear();
    session.loggedIn = false;
    InAppWebViewPlatform.instance = _CookiePlatform(session);
  });

  for (final cancel in [false, true]) {
    testWidgets(
      cancel
          ? 'canceling Quark login returns no authorization'
          : 'Quark login waits for a valid session and captures native cookies',
      (tester) async {
        String? desktopUrl;
        var desktopClosed = false;
        if (io.Platform.isLinux) {
          App.dataPath = io.Directory.systemTemp.path;
          const channel = MethodChannel('webview_window');
          const codec = StandardMethodCodec();
          final messenger = tester.binding.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'create':
                return 1;
              case 'launch':
                desktopUrl = call.arguments['url'] as String;
                return null;
              case 'evaluateJavaScript':
                final script = call.arguments['javaScriptString'] as String;
                if (script.contains('function collect()')) {
                  return jsonEncode({
                    'id': 'document_created',
                    'data': {'title': 'Quark', 'ua': 'test'},
                  });
                }
                return jsonEncode(session.loggedIn);
              case 'getAllCookies':
                return [
                  for (final cookie in session.cookies.entries)
                    {
                      'name': cookie.key,
                      'value': cookie.value,
                      'domain': '.quark.cn',
                      'path': '/',
                      'httpOnly': true,
                    },
                  {
                    'name': 'unrelated',
                    'value': 'other-session',
                    'domain': '.example.com',
                    'path': '/',
                  },
                ];
              case 'close':
                desktopClosed = true;
                tester.binding.channelBuffers.push(
                  channel.name,
                  codec.encodeMethodCall(
                    const MethodCall('onWindowClose', {'id': 1}),
                  ),
                  (_) {},
                );
                return null;
              default:
                return null;
            }
          });
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        }
        Map<String, dynamic>? authorization;
        var returned = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  authorization = await showQuarkLogin(context);
                  returned = true;
                },
                child: const Text('Login'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Login'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final login = io.Platform.isLinux
            ? null
            : tester.widget<AppWebview>(find.byType(AppWebview));
        expect(
          io.Platform.isLinux ? desktopUrl : login!.initialUrl,
          'https://pan.quark.cn/',
        );
        if (login != null) {
          expect(login.userAgent, contains('Chrome/'));
          login.onStarted!(_Controller(session));
        }
        await tester.pump(const Duration(seconds: 2));
        expect(returned, isFalse);

        session.cookies.addAll({'__pus': 'session', '__puus': 'http-only'});
        await tester.pump(const Duration(seconds: 2));
        expect(returned, isFalse);
        if (cancel) {
          if (io.Platform.isLinux) {
            tester.binding.channelBuffers.push(
              'webview_window',
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('onWindowClose', {'id': 1}),
              ),
              (_) {},
            );
          } else {
            Navigator.of(tester.element(find.byType(AppWebview))).pop();
          }
        } else {
          session.loggedIn = true;
          session.cookies['__puus'] = 'renewed-http-only';
          await tester.pump(const Duration(seconds: 2));
        }
        await tester.pumpAndSettle();
        expect(returned, isTrue);
        if (cancel) {
          expect(authorization, isNull);
        } else {
          expect(authorization, {
            'cookie': '__pus=session; __puus=renewed-http-only',
          });
          if (io.Platform.isLinux) expect(desktopClosed, isTrue);
        }
        if (!io.Platform.isLinux) {
          expect(session.urls, isNotEmpty);
          expect(
            session.urls,
            everyElement('https://drive.quark.cn/1/clouddrive'),
          );
        }
        expect(find.byType(AppWebview), findsNothing);
      },
    );
  }
}

class _Session {
  final cookies = <String, String>{};
  final urls = <String>[];
  bool loggedIn = false;
}

class _Controller extends Fake implements InAppWebViewController {
  _Controller(this.session);
  final _Session session;

  @override
  final PlatformInAppWebViewController platform = _PlatformController();

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async => session.loggedIn;
}

class _PlatformController extends Fake
    implements PlatformInAppWebViewController {}

class _CookiePlatform extends InAppWebViewPlatform {
  _CookiePlatform(this.session);
  final _Session session;

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => _Cookies(params, session);
}

class _Cookies extends PlatformCookieManager {
  _Cookies(super.params, this.session) : super.implementation();
  final _Session session;

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    session.urls.add(url.toString());
    return [
      for (final cookie in session.cookies.entries)
        Cookie(name: cookie.key, value: cookie.value, isHttpOnly: true),
    ];
  }
}
