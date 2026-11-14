import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/cloudflare.dart';
import 'package:venera_plus/network/cookie_jar.dart';
import 'package:venera_plus/routing/webview.dart';

bool _hasCloudflareChallenge(String head, String body) =>
    head.contains('#challenge-success-text') ||
    head.contains('#challenge-error-text') ||
    head.contains('#challenge-form') ||
    body.contains('challenge-platform') ||
    body.contains('window._cf_chl_opt');

Future<void> passCloudflare(
  CloudflareException e,
  void Function() onFinished,
) async {
  final url = e.url;
  final uri = Uri.parse(url);
  var closed = false;
  var checking = false;
  var success = false;
  var finished = false;

  void finish() {
    if (finished) return;
    finished = true;
    onFinished();
  }

  if (App.isLinux) {
    final webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) async {
        if (closed || success || checking) return;
        checking = true;
        try {
          final head = jsonDecode(
            await controller.evaluateJavascript('document.head?.innerHTML') ??
                'null',
          );
          final body = jsonDecode(
            await controller.evaluateJavascript('document.body?.innerHTML') ??
                'null',
          );
          if (closed ||
              head is! String ||
              body is! String ||
              _hasCloudflareChallenge(head, body)) {
            return;
          }
          final cookies = await controller.getCookies(url);
          if (closed || !cookies.containsKey('cf_clearance')) return;
          final ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            await appdata.writeImplicitData();
          }
          if (closed) return;
          var domain = uri.host;
          final splits = domain.split('.');
          if (splits.length > 1) {
            domain = '.${splits[splits.length - 2]}.${splits.last}';
          }
          SingleInstanceCookieJar.instance?.saveFromResponse(uri, [
            for (final cookie in cookies.entries)
              io.Cookie(cookie.key, cookie.value)..domain = domain,
          ]);
          success = true;
          controller.close();
          finish();
        } catch (error, stack) {
          if (!closed) Log.error('Cloudflare', error, stack);
        } finally {
          checking = false;
        }
      },
      onClose: () {
        closed = true;
        finish();
      },
    );
    try {
      await webview.open();
    } catch (error, stack) {
      closed = true;
      Log.error('Cloudflare', error, stack);
      finish();
    }
    return;
  }

  late final AppPageRoute<void> route;
  var checkAgain = false;
  var navigationGeneration = 0;

  bool isActive() => !closed && !success && route.isActive && route.isCurrent;

  Future<void> check(InAppWebViewController controller) async {
    if (!isActive()) return;
    if (checking) {
      checkAgain = true;
      return;
    }
    checking = true;
    checkAgain = false;
    final generation = navigationGeneration;
    bool isCurrent() => isActive() && generation == navigationGeneration;
    try {
      final head = await controller.evaluateJavascript(
        source: 'document.head?.innerHTML',
      );
      if (!isCurrent() || head is! String) return;
      final body = await controller.evaluateJavascript(
        source: 'document.body?.innerHTML',
      );
      if (!isCurrent() ||
          body is! String ||
          _hasCloudflareChallenge(head, body)) {
        return;
      }
      final cookies = await controller.getCookies(url) ?? [];
      if (!isCurrent() ||
          !cookies.any((cookie) => cookie.name == 'cf_clearance')) {
        return;
      }
      final ua = await controller.getUA();
      if (!isCurrent()) return;
      if (ua != null) {
        appdata.implicitData['ua'] = ua;
        await appdata.writeImplicitData();
      }
      if (!isCurrent()) return;
      SingleInstanceCookieJar.instance?.saveFromResponse(uri, cookies);
      success = true;
      route.navigator?.pop();
    } catch (error, stack) {
      if (isActive()) Log.error('Cloudflare', error, stack);
    } finally {
      checking = false;
      if (checkAgain && isActive()) unawaited(check(controller));
    }
  }

  route = AppPageRoute<void>(
    builder: (_) => AppWebview(
      initialUrl: url,
      singlePage: true,
      onTitleChange: (_, controller) => unawaited(check(controller)),
      onLoadStart: (_, _) => navigationGeneration++,
      onLoadStop: (controller) => unawaited(check(controller)),
    ),
  );
  try {
    await Navigator.of(App.rootContext).push(route);
  } finally {
    closed = true;
    finish();
  }
}
