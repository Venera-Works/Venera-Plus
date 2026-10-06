import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_runtime/app_runtime.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  group('runtime sources after settings import', () {
    const webDavSourceKey = 'webdav_library';
    late bool webDavConfigIsValid;
    late Set<String> runtimeSourceKeys;
    late List<String> events;

    Future<void> notifySettingsImported() {
      return refreshRuntimeAfterSettingsImport(
        resetWebDavLibrary: () => events.add('webdav-reset'),
        reloadComicSources: () async {
          events.add('sources-reloaded');
          runtimeSourceKeys = {if (webDavConfigIsValid) webDavSourceKey};
        },
        initializeBangumi: () async => events.add('bangumi-initialized'),
        checkForAutomaticSync: () => events.add('automatic-sync-checked'),
      );
    }

    setUp(() {
      webDavConfigIsValid = false;
      runtimeSourceKeys = {};
      events = [];
    });

    test('adds a source when imported settings make it valid', () async {
      webDavConfigIsValid = true;

      await notifySettingsImported();

      expect(runtimeSourceKeys, contains(webDavSourceKey));
      expect(events, [
        'webdav-reset',
        'sources-reloaded',
        'bangumi-initialized',
        'automatic-sync-checked',
      ]);
    });

    test('removes a source when imported settings make it invalid', () async {
      webDavConfigIsValid = true;
      runtimeSourceKeys.add(webDavSourceKey);
      webDavConfigIsValid = false;

      await notifySettingsImported();

      expect(runtimeSourceKeys, isNot(contains(webDavSourceKey)));
    });
  });

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
      'migrates legacy scheduled webdavSyncMode to timing and bidirectional direction',
      () async {
        appdata.implicitData['webdavSyncMode'] = 'scheduled';
        appdata.implicitData.remove('webdavSyncDirection');
        appdata.implicitData.remove('webdavSyncTiming');

        await checkOldConfigsForTesting();

        expect(appdata.implicitData['webdavSyncDirection'], 'bidirectional');
        expect(appdata.implicitData['webdavSyncTiming'], 'scheduled');
        expect(appdata.implicitData['webdavSyncIntervalMinutes'], 30);
        expect(appdata.implicitData.containsKey('webdavSyncMode'), isFalse);
        expect(appdata.implicitData.containsKey('webdavAutoSync'), isFalse);
      },
    );

    test('migrates legacy webdavAutoSync to realtime timing', () async {
      appdata.implicitData['webdavAutoSync'] = true;
      appdata.implicitData.remove('webdavSyncDirection');
      appdata.implicitData.remove('webdavSyncTiming');

      await checkOldConfigsForTesting();

      expect(appdata.implicitData['webdavSyncDirection'], 'bidirectional');
      expect(appdata.implicitData['webdavSyncTiming'], 'realtime');
      expect(appdata.implicitData.containsKey('webdavAutoSync'), isFalse);
    });
    test('removes old keys even when new preferences already exist', () async {
      appdata.implicitData.addAll({
        'webdavSyncDirection': 'downloadOnly',
        'webdavSyncTiming': 'manual',
        'webdavSyncIntervalMinutes': 15,
        'webdavSyncMode': 'realtime',
        'webdavAutoSync': true,
      });
      await checkOldConfigsForTesting();
      expect(appdata.implicitData['webdavSyncDirection'], 'downloadOnly');
      expect(appdata.implicitData['webdavSyncTiming'], 'manual');
      expect(appdata.implicitData.containsKey('webdavSyncMode'), isFalse);
      expect(appdata.implicitData.containsKey('webdavAutoSync'), isFalse);
    });
  });
}
