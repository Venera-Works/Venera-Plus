import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  testWidgets('comic library settings expose credential sync opt-in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appdata.settings['webdavComicLibrarySyncEnabled'] = false;
    addTearDown(
      () => appdata.settings['webdavComicLibrarySyncEnabled'] = false,
    );
    LocalManager().path = 'test-library';
    final root = Directory.systemTemp.createTempSync('venera-settings-page-');
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    App.dataPath = (Directory('${root.path}/data')..createSync()).path;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      WebDavLibrarySource.resetCacheForTesting();
      CacheManager.resetForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.8)),
          child: child!,
        ),
        home: const SettingsPage(),
      ),
    );
    await tester.tap(find.text('APP'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('WebDAV Comic Library'));
    await tester.tap(find.text('WebDAV Comic Library'));
    await tester.pumpAndSettle();

    final switchFinder = find.byKey(
      const Key('webdav-comic-library-config-sync-switch'),
    );
    expect(switchFinder, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
  });
}
