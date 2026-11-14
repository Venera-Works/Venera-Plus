import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/network/proxy.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/routing/windows_webview_environment.dart';
import 'dart:io' as io;

export 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show WebUri, URLRequest;

final _windowsEnvironments = WindowsWebviewEnvironmentPool();
final _controllerEnvironments = Expando<WindowsWebviewEnvironmentLease>();

extension WebviewExtension on InAppWebViewController {
  Future<List<io.Cookie>?> getCookies(String url) async {
    Future<List<Cookie>> read(WebViewEnvironment? environment) =>
        CookieManager.instance(
          webViewEnvironment: environment,
        ).getCookies(url: WebUri(url), webViewController: this);
    final lease = _controllerEnvironments[platform];
    if (App.isWindows && lease == null) {
      throw const WebviewEnvironmentException('This webview is closed.');
    }
    final cookies = await (lease == null ? read(null) : lease.use(read));
    var res = <io.Cookie>[];
    for (var cookie in cookies) {
      var c = io.Cookie(cookie.name, cookie.value);
      c.domain = cookie.domain;
      res.add(c);
    }
    return res;
  }

  Future<String?> getUA() async {
    var res = await evaluateJavascript(source: "navigator.userAgent");
    if (res is String && res.isNotEmpty) {
      if (res[0] == "'" || res[0] == "\"") {
        res = res.substring(1, res.length - 1);
      }
    }
    return res is String ? res : null;
  }
}

class AppWebview extends StatefulWidget {
  const AppWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.singlePage = false,
    this.onStarted,
    this.onLoadStart,
    this.onLoadStop,
    this.initialScripts = const [],
    this.userAgent,
    super.key,
  });

  final String initialUrl;

  final String? userAgent;

  final void Function(String title, InAppWebViewController controller)?
  onTitleChange;

  final bool Function(String url, InAppWebViewController controller)?
  onNavigation;

  final void Function(InAppWebViewController controller)? onStarted;

  final void Function(String url, InAppWebViewController controller)?
  onLoadStart;

  final void Function(InAppWebViewController controller)? onLoadStop;

  final List<String> initialScripts;

  final bool singlePage;

  @override
  State<AppWebview> createState() => _AppWebviewState();
}

class _AppWebviewState extends State<AppWebview> {
  InAppWebViewController? controller;

  WindowsWebviewEnvironmentLease? _environment;

  bool _retryAllowed = false;

  String title = "Webview";

  double _progress = 0;

  late var future = _startInitialization();

  Future<void> _startInitialization() {
    _retryAllowed = false;
    final operation = _createWebviewEnvironment();
    unawaited(
      operation.catchError((Object _, StackTrace _) {
        _retryAllowed = mounted;
      }),
    );
    return operation;
  }

  Future<void> _createWebviewEnvironment() async {
    var proxy = appdata.settings['proxy'].toString();
    if (App.isWindows) {
      final environment = await _windowsEnvironments.acquire(
        userDataFolder: "${App.dataPath}\\webview",
        proxy: proxy,
      );
      if (!mounted) {
        environment.release();
        return;
      }
      _environment = environment;
      return;
    }
    if (App.isAndroid && proxy != "system" && proxy != "direct") {
      var proxyAvailable = await WebViewFeature.isFeatureSupported(
        WebViewFeature.PROXY_OVERRIDE,
      );
      if (proxyAvailable) {
        ProxyController proxyController = ProxyController.instance();
        await proxyController.clearProxyOverride();
        if (!proxy.contains("://")) {
          proxy = "http://$proxy";
        }
        await proxyController.setProxyOverride(
          settings: ProxySettings(proxyRules: [ProxyRule(url: proxy)]),
        );
      }
    }
  }

  @override
  void dispose() {
    _environment?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actions = [
      Tooltip(
        message: "more".tl,
        child: IconButton(
          icon: const Icon(Icons.more_horiz),
          onPressed: () {
            showMenuX(context, Offset(context.width, context.padding.top), [
              MenuEntry(
                icon: Icons.open_in_browser,
                text: "Open in Browser".tl,
                onClick: () async =>
                    launchUrlString((await controller?.getUrl())!.toString()),
              ),
              MenuEntry(
                icon: Icons.copy,
                text: "Copy link".tl,
                onClick: () async => Clipboard.setData(
                  ClipboardData(text: (await controller?.getUrl())!.toString()),
                ),
              ),
              MenuEntry(
                icon: Icons.refresh,
                text: "Reload".tl,
                onClick: () => controller?.reload(),
              ),
            ]);
          },
        ),
      ),
    ];

    final body = FutureBuilder<void>(
      future: future,
      builder: (context, e) {
        if (e.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (e.hasError) {
          final error = e.error;
          final message = error is WebviewEnvironmentException
              ? error.message.tl
              : App.isWindows
              ? 'Unable to initialize the webview. Check that WebView2 Runtime is installed and that the proxy settings are valid, then retry.'
                    .tl
              : '$error';
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${"Error".tl}: $message', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      if (!mounted || !_retryAllowed) return;
                      setState(() {
                        future = _startInitialization();
                      });
                    },
                    child: Text('Retry'.tl),
                  ),
                ],
              ),
            ),
          );
        }
        return Stack(
          children: [
            Positioned.fill(child: createWebviewWithEnvironment(_environment)),
            if (_progress < 1.0)
              const Positioned.fill(
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        );
      },
    );

    return Scaffold(
      appBar: Appbar(
        title: Text(
          title == "Webview" ? title.tl : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: actions,
      ),
      body: body,
    );
  }

  Widget createWebviewWithEnvironment(WindowsWebviewEnvironmentLease? lease) {
    lease?.viewRequested();
    bool owns(InAppWebViewController c) =>
        mounted &&
        identical(_environment, lease) &&
        identical(controller?.platform, c.platform);
    return InAppWebView(
      webViewEnvironment: lease?.environment,
      initialSettings: InAppWebViewSettings(
        isInspectable: true,
        userAgent: widget.userAgent,
      ),
      initialUrlRequest: URLRequest(url: WebUri(widget.initialUrl)),
      initialUserScripts: UnmodifiableListView([
        for (final script in widget.initialScripts)
          UserScript(
            source: script,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
      ]),
      onTitleChanged: (c, t) {
        if (!owns(c)) return;
        setState(() => title = t ?? "Webview");
        widget.onTitleChange?.call(title, c);
      },
      shouldOverrideUrlLoading: (c, r) async {
        if (!owns(c)) return NavigationActionPolicy.CANCEL;
        var res =
            widget.onNavigation?.call(r.request.url?.toString() ?? "", c) ??
            false;
        if (res) {
          return NavigationActionPolicy.CANCEL;
        } else {
          return NavigationActionPolicy.ALLOW;
        }
      },
      onWebViewCreated: (c) {
        if (!mounted || !identical(_environment, lease)) return;
        controller = c;
        if (lease != null) _controllerEnvironments[c.platform] = lease;
        widget.onStarted?.call(c);
      },
      onLoadStart: (c, url) {
        if (!owns(c)) return;
        widget.onLoadStart?.call(url?.toString() ?? '', c);
      },
      onLoadStop: (c, r) {
        if (!owns(c)) return;
        widget.onLoadStop?.call(c);
      },
      onProgressChanged: (c, p) {
        if (owns(c)) {
          setState(() {
            _progress = p / 100;
          });
        }
      },
    );
  }
}

class DesktopWebview {
  static Future<bool> isAvailable() => WebviewWindow.isWebviewAvailable();

  final String initialUrl;

  final void Function(String title, DesktopWebview controller)? onTitleChange;

  final void Function(String url, DesktopWebview webview)? onNavigation;

  final void Function(DesktopWebview controller)? onStarted;

  final void Function()? onClose;

  final List<String> initialScripts;

  DesktopWebview({
    required this.initialUrl,
    this.onTitleChange,
    this.onNavigation,
    this.onStarted,
    this.onClose,
    this.initialScripts = const [],
  });

  Webview? _webview;

  String? _ua;

  String? title;

  void onMessage(String message) {
    var json = jsonDecode(message);
    if (json is Map) {
      if (json["id"] == "document_created") {
        title = json["data"]["title"];
        _ua = json["data"]["ua"];
        onTitleChange?.call(title!, this);
      }
    }
  }

  String? get userAgent => _ua;

  Timer? timer;

  void _runTimer() {
    timer ??= Timer.periodic(const Duration(seconds: 2), (t) async {
      const js = '''
        function collect() {
          if(document.readyState === 'loading') {
            return '';
          }
          let data = {
            id: "document_created",
            data: {
              title: document.title,
              url: location.href,
              ua: navigator.userAgent
            }
          };
          return data;
        }
        collect();
      ''';
      if (_webview != null) {
        onMessage(await evaluateJavascript(js) ?? '');
      }
    });
  }

  Future<void> open() async {
    _webview = await WebviewWindow.create(
      configuration: CreateConfiguration(
        useWindowPositionAndSize: true,
        userDataFolderWindows: "${App.dataPath}\\webview",
        title: "Webview".tl,
        proxy: await getProxy(),
      ),
    );
    _webview!.addOnWebMessageReceivedCallback(onMessage);
    _webview!.setOnNavigation((s) {
      s = s.substring(1, s.length - 1);
      return onNavigation?.call(s, this);
    });
    for (final script in initialScripts) {
      _webview!.addScriptToExecuteOnDocumentCreated(script);
    }
    _webview!.launch(initialUrl, triggerOnUrlRequestEvent: false);
    _runTimer();
    _webview!.onClose.then((value) {
      _webview = null;
      timer?.cancel();
      timer = null;
      onClose?.call();
    });
    Future.delayed(const Duration(milliseconds: 200), () {
      onStarted?.call(this);
    });
  }

  Future<String?> evaluateJavascript(String source) {
    return _webview!.evaluateJavaScript(source);
  }

  Future<Map<String, String>> getCookies(String url) async {
    var allCookies = await _webview!.getAllCookies();
    var res = <String, String>{};
    for (var c in allCookies) {
      if (_cookieMatch(url, c.domain)) {
        res[_removeCode0(c.name)] = _removeCode0(c.value);
      }
    }
    return res;
  }

  String _removeCode0(String s) {
    var codeUints = List<int>.from(s.codeUnits);
    codeUints.removeWhere((e) => e == 0);
    return String.fromCharCodes(codeUints);
  }

  bool _cookieMatch(String url, String domain) {
    domain = _removeCode0(domain);
    var host = Uri.parse(url).host;
    var acceptedHost = _getAcceptedDomains(host);
    return acceptedHost.contains(domain.removeAllBlank);
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  void close() {
    _webview?.close();
    _webview = null;
  }
}
