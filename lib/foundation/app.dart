import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';

import 'appdata.dart';

Locale resolveAppLocale(String? preference, List<Locale> systemLocales) {
  final selected = switch (preference) {
    'zh-CN' => const Locale('zh', 'CN'),
    'zh-TW' => const Locale('zh', 'TW'),
    'en-US' => const Locale('en', 'US'),
    _ => null,
  };
  if (selected != null) return selected;

  for (final locale in systemLocales) {
    if (locale.languageCode == 'zh') {
      // Script takes priority over region: zh-Hans-US is simplified Chinese.
      // Older locale identifiers may only provide a region, such as zh-HK.
      final traditional = switch (locale.scriptCode) {
        'Hant' => true,
        'Hans' => false,
        _ => const ['TW', 'HK', 'MO'].contains(locale.countryCode),
      };
      return Locale('zh', traditional ? 'TW' : 'CN');
    }
    if (locale.languageCode == 'en') return const Locale('en', 'US');
  }
  return const Locale('en', 'US');
}

class _App {
  String version = "0.0.0";

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  Locale get locale => resolveAppLocale(
    appdata.settings['language'],
    PlatformDispatcher.instance.locales,
  );

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  Future<void> init() async {
    await _initVersion();
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    isInitialized = true;
  }

  Future<void> _initVersion() async {
    final pubspec = await rootBundle.loadString("pubspec.yaml");
    final data = loadYaml(pubspec);
    version = data["version"].toString().split('+').first;
  }

  Future<void> initComponents([
    Iterable<Future<void> Function()> featureInitializers = const [],
  ]) async {
    await Future.wait([
      data.init(),
      for (final initializer in featureInitializers) initializer(),
    ]);
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}

// ignore: non_constant_identifier_names
final App = _App();
