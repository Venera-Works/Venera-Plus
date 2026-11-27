import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebViewController;
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/routing/webview.dart';

const _loginUrl = 'https://pan.quark.cn/';
const _apiUrl = 'https://drive.quark.cn/1/clouddrive';
const _desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/133.0.0.0 Safari/537.36';

// Keep the probe in the browser session. Reading this flag synchronously also
// works on desktop WebViews that cannot return a JavaScript Promise result.
const _checkLoginScript =
    '''
(() => {
  if (location.origin !== 'https://pan.quark.cn') return false;
  if (window.__veneraQuarkLoggedIn) return true;
  if (!window.__veneraQuarkChecking) {
    window.__veneraQuarkChecking = true;
    fetch('$_apiUrl/file/sort?pr=ucpro&fr=pc&pdir_fid=0&_page=1&_size=1',
      {credentials: 'include'})
      .then(response => response.json())
      .then(data => {
        window.__veneraQuarkLoggedIn = data.status === 200 && data.code === 0;
      })
      .catch(() => {})
      .finally(() => { window.__veneraQuarkChecking = false; });
  }
  return false;
})()
''';

Future<void> _clearWindowsQuarkCookies(
  InAppWebViewController controller,
) async {
  final response =
      await controller.callDevToolsProtocolMethod(
            methodName: 'Network.getCookies',
            parameters: {
              'urls': [
                _loginUrl,
                _apiUrl,
                'https://quark.cn/',
                'https://u.quark.cn/',
              ],
            },
          )
          as Map;
  for (final cookie in (response['cookies'] as List).cast<Map>()) {
    await controller.callDevToolsProtocolMethod(
      methodName: 'Network.deleteCookies',
      parameters: {
        'name': cookie['name'],
        'domain': cookie['domain'],
        'path': cookie['path'],
      },
    );
  }
  final remaining = await controller.getCookies(_apiUrl);
  if (remaining?.any(
        (cookie) => cookie.name == '__pus' && cookie.value.isNotEmpty,
      ) ==
      true) {
    throw const FormatException('Unable to clear the Quark session.');
  }
  await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_loginUrl)));
}

Future<Map<String, dynamic>?> showQuarkLogin(BuildContext context) async {
  Map<String, dynamic>? authorization;
  Timer? timer;
  var finished = false;
  var checking = false;
  String? failure;

  Future<void> checkLogin(
    Future<Map<String, String>> Function() getCookies,
    Future<dynamic> Function(String script) evaluate,
    VoidCallback close, {
    Future<bool> Function(String session)? confirmSession,
  }) async {
    if (finished || checking) return;
    checking = true;
    try {
      final cookies = await getCookies();
      if (finished || (cookies['__pus'] ?? '').isEmpty) return;
      dynamic loggedIn;
      try {
        loggedIn = await evaluate(_checkLoginScript);
      } catch (_) {
        // Navigation may invalidate the JavaScript context; retry after load.
        return;
      }
      if (finished || (loggedIn != true && loggedIn != 'true')) return;
      // The probe can renew __puus. Read the native cookie store again so the
      // saved Cookie includes the renewed value and HttpOnly cookies.
      final current = await getCookies();
      final session = current['__pus'];
      if (finished || session == null || session.isEmpty) return;
      if (confirmSession != null && !await confirmSession(session)) return;
      if (finished) return;
      authorization = {
        'cookie': current.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; '),
      };
      finished = true;
      close();
    } catch (error) {
      if (!finished) {
        failure = error is FormatException
            ? error.message
            : 'Unable to read login cookies';
        finished = true;
        close();
      }
    } finally {
      checking = false;
    }
  }

  try {
    if (App.isLinux) {
      if (!await DesktopWebview.isAvailable()) {
        throw const FormatException('Webview is not available');
      }
      if (!context.mounted) return null;
      final closed = Completer<void>();
      final webview = DesktopWebview(
        initialUrl: _loginUrl,
        onTitleChange: (_, webview) => checkLogin(
          () => webview.getCookies(_apiUrl),
          webview.evaluateJavascript,
          webview.close,
        ),
        onClose: () => closed.complete(),
      );
      await webview.open();
      await closed.future;
    } else {
      Future<String?>? initialSession;
      await context.to<void>(
        () => Builder(
          builder: (loginContext) {
            bool isCurrent() =>
                loginContext.mounted &&
                ModalRoute.of(loginContext)?.isCurrent == true;
            void close() {
              if (isCurrent()) loginContext.pop();
            }

            Future<bool> confirmSession(
              InAppWebViewController controller,
              String session,
            ) async {
              final existing = await initialSession;
              if (finished || !isCurrent()) return false;
              if (existing != session) return true;
              final useCurrent = await showDialog<bool>(
                context: loginContext,
                builder: (context) => ContentDialog(
                  title: 'A Quark account is already signed in.'.tl,
                  content: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Switching accounts clears the Quark sign-in session in this browser.'
                          .tl,
                    ),
                  ),
                  actions: [
                    TextButton(
                      style: actionButtonStyle,
                      onPressed: () => context.pop(false),
                      child: Text('Switch account'.tl),
                    ),
                    FilledButton(
                      style: actionButtonStyle,
                      onPressed: () => context.pop(true),
                      child: Text('Use current session'.tl),
                    ),
                  ],
                ),
              );
              if (finished || !isCurrent()) return false;
              if (useCurrent == null) {
                finished = true;
                close();
              } else if (!useCurrent) {
                try {
                  await _clearWindowsQuarkCookies(controller);
                } catch (_) {
                  throw const FormatException(
                    'Unable to clear the Quark session.',
                  );
                }
              }
              return useCurrent == true;
            }

            void check(InAppWebViewController controller) => checkLogin(
              () async => {
                for (final cookie in await controller.getCookies(_apiUrl) ?? [])
                  cookie.name: cookie.value,
              },
              (script) => controller.evaluateJavascript(source: script),
              close,
              confirmSession: (session) => confirmSession(controller, session),
            );

            return AppWebview(
              initialUrl: _loginUrl,
              userAgent: _desktopUserAgent,
              onStarted: (controller) {
                timer?.cancel();
                timer = Timer.periodic(
                  const Duration(seconds: 2),
                  (_) => check(controller),
                );
              },
              onLoadStart: (_, controller) {
                if (App.isWindows) {
                  initialSession ??= controller
                      .getCookies(_apiUrl)
                      .then(
                        (cookies) => cookies
                            ?.where((cookie) => cookie.name == '__pus')
                            .firstOrNull
                            ?.value,
                        onError: (Object _, StackTrace _) => null,
                      );
                }
              },
              onLoadStop: check,
            );
          },
        ),
      );
    }
  } finally {
    finished = true;
    timer?.cancel();
  }
  if (failure != null) throw FormatException(failure!);
  return authorization;
}
