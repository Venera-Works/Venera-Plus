import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_runtime/app_runtime.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  test('Bangumi startup waits for data sync before initialization', () async {
    final download = Completer<void>();
    final events = <String>[];
    var initializerCreated = false;

    final initialization = initializeBangumiAfterDataSync(
      waitForDownload: () async {
        events.add('download-started');
        await download.future;
        events.add('download-finished');
      },
      createInitializer: () {
        initializerCreated = true;
        return () async => events.add('bangumi-initialized');
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, ['download-started']);
    expect(initializerCreated, isFalse);
    download.complete();
    await initialization;
    expect(initializerCreated, isTrue);
    expect(events, [
      'download-started',
      'download-finished',
      'bangumi-initialized',
    ]);
  });

  test('Bangumi startup does not wait for network initialization', () async {
    final initialization = Completer<void>();
    var started = false;

    startBangumiAfterDataSync(
      waitForDownload: () async {},
      createInitializer: () {
        return () {
          started = true;
          return initialization.future;
        };
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(started, isTrue);
    expect(initialization.isCompleted, isFalse);
    initialization.complete();
    await Future<void>.delayed(Duration.zero);
  });

  group('scrapeBangumiMetadataForWebDav', () {
    tearDown(() {
      appdata.settings['bangumiAccessToken'] = '';
      appdata.settings['bangumiUsername'] = '';
    });

    test('throws StateError when Bangumi is not connected', () async {
      appdata.settings['bangumiAccessToken'] = '';
      appdata.settings['bangumiUsername'] = '';
      final service = BangumiService.forTesting(
        gatewayFactory: (_) => throw UnimplementedError(),
      );

      await expectLater(
        scrapeBangumiMetadataForWebDav('Cat Eye', service: service),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Bangumi is not connected',
          ),
        ),
      );
    });
  });
  group('sync preference migration', () {
    late Directory tempDir;
    late String originalDataPath;
    late Map<String, dynamic> previousImplicit;
    late Map<String, dynamic> previousSettings;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('init-migration-test-');
      try {
        originalDataPath = App.dataPath;
      } catch (_) {
        originalDataPath = Directory.systemTemp.path;
      }
      previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
      previousSettings = Map<String, dynamic>.from(
        appdata.toJson()['settings'],
      );
      appdata.implicitData.clear();
      App.dataPath = tempDir.path;
    });

    tearDown(() {
      App.dataPath = originalDataPath;
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
      appdata.implicitData
        ..clear()
        ..addAll(previousImplicit);
      (appdata.toJson()['settings'] as Map)
        ..clear()
        ..addAll(previousSettings);
    });

    test(
      'maps new scheduled timing to the restored mode and keeps local upload pending',
      () async {
        appdata.settings['webdav'] = [
          'https://example.com',
          'user',
          'password',
        ];
        appdata.implicitData['webdavSyncTiming'] = 'scheduled';
        appdata.implicitData['webdavSyncDirection'] = 'downloadOnly';

        await checkOldConfigsForTesting();

        expect(appdata.implicitData['webdavSyncMode'], 'scheduled');
        expect(appdata.implicitData['webdavSyncDirection'], isNull);
        expect(appdata.implicitData['webdavSyncTiming'], isNull);
        expect(appdata.implicitData['webdavSyncIntervalMinutes'], 30);
        expect(appdata.implicitData['webdavAutoSync'], isTrue);
        expect(appdata.implicitData['webdavSyncPending'], isTrue);
      },
    );

    test(
      'preserves old disabled auto-sync when no new timing exists',
      () async {
        appdata.implicitData['webdavAutoSync'] = false;

        await checkOldConfigsForTesting();

        expect(appdata.implicitData['webdavSyncMode'], 'manual');
        expect(appdata.implicitData['webdavAutoSync'], isFalse);
      },
    );
    test(
      'migration is idempotent and leaves old protocol state intact',
      () async {
        appdata.implicitData.addAll({
          'webdavSyncDirection': 'downloadOnly',
          'webdavSyncTiming': 'manual',
          'webdavSyncIntervalMinutes': 15,
          'webdavSyncMode': 'realtime',
          'webdavAutoSync': true,
        });
        await checkOldConfigsForTesting();
        appdata.implicitData['sync_state_device'] = 'preserved';
        await checkOldConfigsForTesting();
        expect(appdata.implicitData['webdavSyncDirection'], isNull);
        expect(appdata.implicitData['webdavSyncTiming'], isNull);
        expect(appdata.implicitData['webdavSyncMode'], 'realtime');
        expect(appdata.implicitData['webdavAutoSync'], isTrue);
        expect(appdata.implicitData['sync_state_device'], 'preserved');
      },
    );
  });
}
