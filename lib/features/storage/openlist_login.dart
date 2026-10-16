import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/routing/webview.dart';

import 'token_import.dart';

// The official page clears its fragment when React mounts. Keep the callback
// before that happens, including on Linux where navigation events are delayed.
const _captureCallbackScript = '''
if (window.top === window &&
    location.origin === 'https://api.oplist.org' &&
    location.pathname === '/' && location.hash.length > 1) {
  window.__veneraOpenListCallback = location.href;
}
''';

Future<Map<String, dynamic>?> showOpenListLogin(
  BuildContext context, {
  required String driver,
}) async {
  final requestUri = openListLoginUri(driver);
  final requestUrl = requestUri.toString();
  Map<String, dynamic>? authorization;
  String? failure;
  var finished = false;
  var reading = false;
  var redirected = false;

  bool receiveCallback(String url, VoidCallback close) {
    if (finished) return true;
    try {
      final value = parseOpenListLoginCallback(url, driver: driver);
      if (value == null) return false;
      authorization = value;
    } on FormatException catch (error) {
      failure = error.message;
    }
    finished = true;
    close();
    return true;
  }

  Future<void> readPage(
    Future<dynamic> Function(String script) evaluate,
    VoidCallback close,
  ) async {
    if (finished || reading) return;
    reading = true;
    try {
      var page = await evaluate('''
(() => {
  if (location.origin !== 'https://api.oplist.org') return null;
  return {
    url: window.__veneraOpenListCallback || location.href,
    body: location.href === ${jsonEncode(requestUrl)}
      ? document.body.textContent : null
  };
})()
''');
      if (finished) return;
      if (page is String) page = jsonDecode(page);
      if (page is! Map) return;
      final url = page['url'] as String? ?? '';
      if (receiveCallback(url, close) || redirected || url != requestUrl) {
        return;
      }
      // Load /requests in the WebView itself so its Set-Cookie headers and the
      // subsequent provider login share the same browser session.
      final response = jsonDecode(page['body'] as String);
      final target = response is Map ? response['text'] : null;
      final loginUri = target is String ? Uri.tryParse(target) : null;
      if (loginUri == null ||
          loginUri.scheme != 'https' ||
          loginUri.host.isEmpty) {
        throw FormatException(
          target is String ? target : 'Unable to start authorization',
        );
      }
      redirected = true;
      await evaluate('location.replace(${jsonEncode(loginUri.toString())})');
    } catch (error) {
      if (!finished) {
        failure = error is FormatException
            ? error.message
            : 'Unable to start authorization';
        finished = true;
        close();
      }
    } finally {
      reading = false;
    }
  }

  if (App.isLinux) {
    if (!await DesktopWebview.isAvailable()) {
      throw const FormatException('Webview is not available');
    }
    if (!context.mounted) return null;
    final closed = Completer<void>();
    final webview = DesktopWebview(
      initialUrl: requestUrl,
      initialScripts: const [_captureCallbackScript],
      onNavigation: (url, webview) => receiveCallback(url, webview.close),
      onTitleChange: (_, webview) =>
          readPage(webview.evaluateJavascript, webview.close),
      onClose: () => closed.complete(),
    );
    await webview.open();
    await closed.future;
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (loginContext) {
          void close() => Navigator.of(loginContext).pop();
          return AppWebview(
            initialUrl: requestUrl,
            initialScripts: const [_captureCallbackScript],
            onLoadStart: (url, _) => receiveCallback(url, close),
            onLoadStop: (controller) => readPage(
              (script) => controller.evaluateJavascript(source: script),
              close,
            ),
          );
        },
      ),
    );
  }
  finished = true;
  if (failure != null) throw FormatException(failure!);
  return authorization;
}
