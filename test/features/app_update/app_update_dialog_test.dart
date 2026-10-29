import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/app_update/app_update.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/app_dio.dart';

import 'fixtures.dart';

class _Updater extends AppUpdateService {
  final downloads = <AppReleaseAsset>[];
  final installs = <File>[];
  bool permission = true;
  Completer<File>? transfer;
  Completer<bool>? permissionResult;
  Completer<AppRelease?>? checkResult;
  Object? checkError;
  int checks = 0;

  @override
  Future<AppRelease?> check(String currentVersion) async {
    checks++;
    if (checkError != null) throw checkError!;
    return checkResult?.future;
  }

  @override
  Future<List<String>> supportedAbis() async => ['arm64-v8a', 'armeabi-v7a'];

  @override
  Future<File> downloadApk(
    AppReleaseAsset asset, {
    required CancelToken cancelToken,
    required ProgressCallback onProgress,
  }) async {
    downloads.add(asset);
    onProgress(50, 100);
    final pending = transfer;
    return pending == null
        ? File('app_updates/${asset.name}')
        : await Future.any([
            pending.future,
            cancelToken.whenCancel.then<File>((error) => throw error),
          ]);
  }

  @override
  Future<bool> requestInstallPermission() async =>
      permissionResult == null ? permission : await permissionResult!.future;

  @override
  Future<void> installApk(File file) async => installs.add(file);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const urlChannel = MethodChannel('plugins.flutter.io/url_launcher');
  late _Updater updater;
  late List<String> urls;
  late List<String> messages;
  late Object? language;
  late String version;
  late bool muted;

  AppRelease release({bool packages = true, String? notes}) =>
      AppRelease.fromJson({
        ...releaseJson(
          'v3.3.0',
          assets: packages
              ? [
                  assetJson('android-armeabi-v7a.apk'),
                  assetJson('android-arm64-v8a.apk'),
                  assetJson('windows-installer.exe'),
                  assetJson('windows-portable.zip'),
                ]
              : [],
        ),
        'body': ?notes,
      });

  Widget harness({AppRelease? update, double scale = 1}) => MaterialApp(
    navigatorKey: App.rootNavigatorKey,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => AppUpdateDialog(
              release: update ?? release(),
              currentVersion: '3.2.0',
              service: updater,
            ),
          ),
          child: const Text('Show update'),
        ),
      ),
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    AppRelease? update,
    double scale = 1,
  }) async {
    await tester.pumpWidget(harness(update: update, scale: scale));
    await tester.tap(find.text('Show update'));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    updater = _Updater();
    urls = [];
    messages = [];
    registerShowMessageHandler((_, message) => messages.add(message));
    language = appdata.settings['language'];
    appdata.settings['language'] = 'en-US';
    version = App.version;
    App.version = '3.2.0';
    muted = Log.isMuted;
    Log.isMuted = true;
    await AppTranslation.init();
    messenger.setMockMethodCallHandler(urlChannel, (call) async {
      if (call.method == 'launch') {
        urls.add((call.arguments as Map)['url'] as String);
        return true;
      }
      return null;
    });
  });
  tearDown(() {
    registerShowMessageHandler((_, _) {});
    appdata.settings['language'] = language;
    App.version = version;
    Log.isMuted = muted;
    messenger.setMockMethodCallHandler(urlChannel, null);
  });

  testWidgets(
    'Windows keeps all actions visible while long release notes scroll at a narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notes = List.generate(
        60,
        (i) => '- **Feature $i**: release notes',
      ).join('\n');
      await open(tester, update: release(notes: notes), scale: 1.5);
      expect(find.text('Current version: 3.2.0'), findsOneWidget);
      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        notes,
      );
      for (final label in [
        'Download installer',
        'Download ZIP',
        'View release',
      ]) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      final actionPosition = tester.getTopLeft(find.text('View release'));
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('View release')), actionPosition);
      for (final label in [
        'Download installer',
        'Download ZIP',
        'View release',
      ]) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(urls, [
        'https://example.com/windows-installer.exe',
        'https://example.com/windows-portable.zip',
        release().pageUrl,
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Android downloads the preferred ABI and starts the system installer',
    (tester) async {
      await open(tester);
      expect(find.text('Download installer'), findsNothing);
      expect(find.text('Download and install'), findsOneWidget);
      await tester.tap(find.text('Download and install'));
      await tester.pumpAndSettle();
      expect(updater.downloads.single.name, endsWith('-arm64-v8a.apk'));
      expect(updater.installs.single.path, endsWith('-arm64-v8a.apk'));
      expect(find.text('Install update'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'missing release packages disable download while keeping the release page usable',
    (tester) async {
      await open(tester, update: release(packages: false, notes: ''));
      expect(find.text('No release notes provided.'), findsOneWidget);
      expect(
        find.text('The installation package is not available yet.'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('View release'));
      await tester.pumpAndSettle();
      expect(urls.last, release().pageUrl);
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'permission denial leaves the update ready for another installation attempt',
    (tester) async {
      updater.permission = false;
      await open(tester);
      await tester.tap(find.text('Download and install'));
      await tester.pumpAndSettle();
      expect(updater.installs, isEmpty);
      expect(
        find.text('Allow installing apps from VeneraPlus to continue'),
        findsOneWidget,
      );
      updater.permission = true;
      await tester.tap(find.text('Install update'));
      await tester.pumpAndSettle();
      expect(updater.installs, hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'canceling a download prevents installation and allows retry',
    (tester) async {
      updater.transfer = Completer<File>();
      await open(tester);
      await tester.tap(find.text('Download and install'));
      await tester.pump();
      expect(find.text('50 B / 100 B'), findsOneWidget);
      await tester.tap(find.text('Cancel download'));
      await tester.pumpAndSettle();
      expect(updater.installs, isEmpty);
      updater.transfer = null;
      await tester.tap(find.text('Download and install'));
      await tester.pumpAndSettle();
      expect(updater.installs, hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'closing the update dialog during authorization prevents a late installation',
    (tester) async {
      updater.permissionResult = Completer<bool>();
      await open(tester);
      await tester.tap(find.text('Download and install'));
      await tester.pump();
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      updater.permissionResult!.complete(true);
      await tester.pump();
      expect(updater.installs, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'automatic and manual checks share the request and display one update dialog',
    (tester) async {
      updater.checkResult = Completer<AppRelease?>();
      final prompt = AppUpdatePrompt(service: updater);
      await tester.pumpWidget(harness());
      final automatic = prompt.check(manual: false, delay: true);
      final manual = prompt.check();
      expect(updater.checks, 1);
      updater.checkResult!.complete(release());
      await tester.pump();
      expect(find.byType(AppUpdateDialog), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdateDialog), findsOneWidget);
      await tester.tap(find.byType(CloseButton));
      await tester.pumpAndSettle();
      await Future.wait([automatic, manual]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'check failures stay quiet automatically and show an error for a manual check',
    (tester) async {
      updater.checkError = StateError('Network unavailable');
      final prompt = AppUpdatePrompt(service: updater);
      await tester.pumpWidget(harness());
      await prompt.check(manual: false);
      await tester.pump();
      expect(messages, isEmpty);
      await prompt.check();
      await tester.pump();
      expect(messages, ['Failed to check for updates']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
