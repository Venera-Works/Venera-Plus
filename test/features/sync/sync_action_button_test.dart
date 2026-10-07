import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

void main() {
  late Directory safeTemp;
  var previousDataPath = Directory.systemTemp.path;
  var previousCachePath = Directory.systemTemp.path;
  Object? previousConfig;

  setUpAll(() async {
    safeTemp = Directory.systemTemp.createTempSync('sync-action-widget-');
    try {
      previousDataPath = App.dataPath;
    } on Error {
      // A widget-only process has not initialized the application profile.
    }
    try {
      previousCachePath = App.cachePath;
    } on Error {
      // Keep the restoration path isolated even without an application profile.
    }
    App.dataPath = safeTemp.path;
    App.cachePath = safeTemp.path;
    await AppTranslation.init();
  });

  setUp(() async {
    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    previousConfig = appdata.settings['webdav'];
    appdata.settings['webdav'] = <String>[];
    await DataSync().waitForStartupMerge();
  });

  tearDown(() async {
    final sync = DataSync.instance;
    if (sync != null) {
      await sync.waitForStartupMerge();
      await sync.waitForSync();
    }
    DataSync.resetForTesting();
    appdata.settings['webdav'] = previousConfig;
  });

  tearDownAll(() {
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    safeTemp.deleteSync(recursive: true);
  });

  testWidgets('unconfigured action opens configuration without starting sync', (
    tester,
  ) async {
    var configured = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SyncActionButton(
            onConfigure: () async {
              configured++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-sync-action')));
    await tester.pumpAndSettle();
    expect(configured, 1);
    expect(DataSync().isSyncing, isFalse);
    expect(find.byType(SyncConflictDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
