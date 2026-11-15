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
import 'package:venera_plus/routing/cloudflare_verification.dart';
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
    Timer? retryTimer;
    var retryCount = 0;
    var navigationGeneration = 0;
    var checkAgain = false;
    late final Future<void> Function(DesktopWebview controller) check;

    void cancelRetry() {
      retryTimer?.cancel();
      retryTimer = null;
    }

    bool isCurrent(int generation) =>
        !closed && !success && generation == navigationGeneration;

    void retry(DesktopWebview controller, int generation) {
      if (!isCurrent(generation) ||
          retryTimer != null ||
          retryCount >= cloudflareVerificationMaxRetries) {
        return;
      }
      retryCount++;
      retryTimer = Timer(cloudflareVerificationRetryDelay, () {
        retryTimer = null;
        if (isCurrent(generation)) {
          unawaited(check(controller));
        }
      });
    }

    check = (DesktopWebview controller) async {
      if (closed || success) return;
      if (checking) {
        checkAgain = true;
        return;
      }
      checking = true;
      checkAgain = false;
      final generation = navigationGeneration;
      try {
        final readyState = jsonDecode(
          await controller.evaluateJavascript('document.readyState') ?? 'null',
        );
        final head = jsonDecode(
          await controller.evaluateJavascript('document.head?.innerHTML') ??
              'null',
        );
        final body = jsonDecode(
          await controller.evaluateJavascript('document.body?.innerHTML') ??
              'null',
        );
        if (!isCurrent(generation)) return;
        if (!isCloudflareDocumentReady(readyState, head, body)) {
          retry(controller, generation);
          return;
        }
        if (_hasCloudflareChallenge(head, body)) {
          cancelRetry();
          return;
        }
        final cookies = await controller.getCookies(url);
        if (!isCurrent(generation)) return;
        if (!cookies.containsKey('cf_clearance')) {
          retry(controller, generation);
          return;
        }
        final ua = controller.userAgent;
        if (ua != null) {
          appdata.implicitData['ua'] = ua;
          await appdata.writeImplicitData();
        }
        if (!isCurrent(generation)) return;
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
        cancelRetry();
        controller.close();
        finish();
      } catch (error, stack) {
        if (!closed) Log.error('Cloudflare', error, stack);
      } finally {
        checking = false;
        if (checkAgain && !closed && !success) unawaited(check(controller));
      }
    };

    final webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (_, controller) => unawaited(check(controller)),
      onNavigation: (_, _) {
        navigationGeneration++;
        retryCount = 0;
        cancelRetry();
      },
      onClose: () {
        closed = true;
        cancelRetry();
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
  var retryCount = 0;
  Timer? retryTimer;
  late final Future<void> Function(InAppWebViewController controller) check;

  bool isActive() => !closed && !success && route.isActive && route.isCurrent;

  void cancelRetry() {
    retryTimer?.cancel();
    retryTimer = null;
  }

  void retry(InAppWebViewController controller, int generation) {
    if (!isActive() ||
        generation != navigationGeneration ||
        retryTimer != null ||
        retryCount >= cloudflareVerificationMaxRetries) {
      return;
    }
    retryCount++;
    retryTimer = Timer(cloudflareVerificationRetryDelay, () {
      retryTimer = null;
      if (isActive() && generation == navigationGeneration) {
        unawaited(check(controller));
      }
    });
  }

  void checkFromEvent(InAppWebViewController controller) {
    retryCount = 0;
    cancelRetry();
    unawaited(check(controller));
  }

  check = (InAppWebViewController controller) async {
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
      final readyState = await controller.evaluateJavascript(
        source: 'document.readyState',
      );
      if (!isCurrent()) return;
      final head = await controller.evaluateJavascript(
        source: 'document.head?.innerHTML',
      );
      if (!isCurrent()) return;
      final body = await controller.evaluateJavascript(
        source: 'document.body?.innerHTML',
      );
      if (!isCurrent()) return;
      if (!isCloudflareDocumentReady(readyState, head, body)) {
        retry(controller, generation);
        return;
      }
      if (_hasCloudflareChallenge(head, body)) {
        cancelRetry();
        return;
      }
      final cookies = await controller.getCookies(url) ?? [];
      if (!isCurrent()) return;
      if (!cookies.any((cookie) => cookie.name == 'cf_clearance')) {
        retry(controller, generation);
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
      cancelRetry();
      route.navigator?.pop();
    } catch (error, stack) {
      if (isActive()) Log.error('Cloudflare', error, stack);
    } finally {
      checking = false;
      if (checkAgain && isActive()) unawaited(check(controller));
    }
  };

  route = AppPageRoute<void>(
    builder: (_) => AppWebview(
      initialUrl: url,
      singlePage: true,
      onTitleChange: (_, controller) => checkFromEvent(controller),
      onLoadStart: (_, _) {
        navigationGeneration++;
        retryCount = 0;
        cancelRetry();
      },
      onLoadStop: checkFromEvent,
    ),
  );
  try {
    await Navigator.of(App.rootContext).push(route);
  } finally {
    closed = true;
    cancelRetry();
    finish();
  }
}
