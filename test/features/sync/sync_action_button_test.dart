import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/file_system.dart';
import 'package:venera_plus/foundation/res.dart';

void main() {
  late Directory fallbackDirectory;
  late List<dynamic> previousConfig;
  late Map<String, dynamic> previousImplicit;
  late Directory testDirectory;
  late String previousDataPath;

  setUpAll(() {
    fallbackDirectory = Directory.systemTemp.createTempSync(
      'sync-action-button-fallback-',
    );
    App.dataPath = fallbackDirectory.path;
  });

  tearDownAll(() async {
    if (fallbackDirectory.existsSync()) {
      await fallbackDirectory.delete(recursive: true);
    }
  });

  setUp(() {
    previousConfig = List<dynamic>.from(appdata.settings['webdav'] as List);
    previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    previousDataPath = App.dataPath;
    testDirectory = Directory.systemTemp.createTempSync('sync-action-button-');
    App.dataPath = testDirectory.path;
    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
    appdata.settings['webdav'] = <String>[];
    appdata.implicitData
      ..clear()
      ..['webdavAutoSync'] = false;
  });

  tearDown(() async {
    DataSync.resetForTesting();
    await appdata.saveData(false);
    appdata.settings['webdav'] = previousConfig;
    appdata.implicitData
      ..clear()
      ..addAll(previousImplicit);
    App.dataPath = previousDataPath;
    if (testDirectory.existsSync()) {
      await testDirectory.delete(recursive: true);
    }
  });

  Future<void> pumpButton(
    WidgetTester tester, {
    required Future<void> Function() onConfigure,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncActionButton(onConfigure: onConfigure)),
      ),
    );
  }

  testWidgets(
    'opens the current settings entry when WebDAV is not configured',
    (tester) async {
      var configureCalls = 0;
      await pumpButton(tester, onConfigure: () async => configureCalls++);

      await tester.tap(find.byKey(const Key('data-sync-action')));

      expect(configureCalls, 1);
      expect(find.text('Choose a sync action'), findsNothing);
    },
  );

  testWidgets('chooses upload and download actions for configured WebDAV', (
    tester,
  ) async {
    appdata.settings['webdav'] = [
      'https://example.com/dav',
      'user',
      'password',
    ];
    var uploads = 0;
    var downloads = 0;
    DataSync.debugUploadOverride = () async {
      uploads++;
      return const Res(true);
    };
    DataSync.debugDownloadOverride = () async {
      downloads++;
      return const Res(true);
    };
    await pumpButton(tester, onConfigure: () async {});

    // Starting the dialog in the real zone keeps its selected action and
    // persistence writes in that zone.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('data-sync-action')));
    });
    await tester.pumpAndSettle();
    expect(find.text('Upload'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Upload'));
      await Future<void>.delayed(Duration.zero);
      await DataSync().debugWaitForUploadBeforeClose();
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(uploads, 1);
    expect(downloads, 0);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('data-sync-action')));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Download'));
      await Future<void>.delayed(Duration.zero);
      await DataSync().waitForDownload();
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(uploads, 1);
    expect(downloads, 1);
  });

  testWidgets('shows busy state while a selected transfer is running', (
    tester,
  ) async {
    appdata.settings['webdav'] = [
      'https://example.com/dav',
      'user',
      'password',
    ];
    late Completer<Res<bool>> upload;
    DataSync.debugUploadOverride = () {
      upload = Completer<Res<bool>>();
      return upload.future;
    };
    await pumpButton(tester, onConfigure: () async {});

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('data-sync-action')));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Upload'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();

    expect(DataSync().isUploading, isTrue);
    expect(find.byType(RotationTransition), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('data-sync-action')))
          .tooltip,
      'Syncing data...',
    );

    await tester.runAsync(() async {
      upload.complete(const Res(true));
      await DataSync().debugWaitForUploadBeforeClose();
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(DataSync().isSyncing, isFalse);
  });
}
