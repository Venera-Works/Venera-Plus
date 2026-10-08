import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  late Directory fallbackDataDir;

  setUpAll(() {
    fallbackDataDir = Directory.systemTemp.createTempSync(
      'venera-appdata-fallback-',
    );
  });

  setUp(() {
    App.dataPath = fallbackDataDir.path;
  });

  tearDownAll(() {
    if (fallbackDataDir.existsSync()) {
      fallbackDataDir.deleteSync(recursive: true);
    }
  });

  test('does not configure a comic source list by default', () {
    expect(appdata.settings['comicSourceListUrl'], isEmpty);
  });

  test('reader settings resolve from global, device, then comic scope', () {
    final previousDeviceId = appdata.settings['deviceId'];
    final previousDeviceSettings = appdata.settings['deviceSpecificSettings'];
    final previousComicSettings = appdata.settings['comicSpecificSettings'];
    final previousPageNumber = appdata.settings['showPageNumberInReader'];
    final previousClockInfo =
        appdata.settings['enableClockAndBatteryInfoInReader'];

    try {
      appdata.settings['deviceId'] = 'reader-settings-test-device';
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
      appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
      appdata.settings['showPageNumberInReader'] = true;
      appdata.settings['enableClockAndBatteryInfoInReader'] = true;

      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setDeviceReaderSetting('showPageNumberInReader', false);
      appdata.settings.setDeviceReaderSetting(
        'enableClockAndBatteryInfoInReader',
        false,
      );

      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'showPageNumberInReader',
        ),
        isFalse,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'enableClockAndBatteryInfoInReader',
        ),
        isFalse,
      );

      appdata.settings.setEnabledComicSpecificSettings(
        'comic-id',
        'source-key',
        true,
      );
      appdata.settings.setReaderSetting(
        'comic-id',
        'source-key',
        'showPageNumberInReader',
        true,
      );

      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'showPageNumberInReader',
        ),
        isTrue,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'enableClockAndBatteryInfoInReader',
        ),
        isFalse,
      );
    } finally {
      appdata.settings['deviceId'] = previousDeviceId;
      appdata.settings['deviceSpecificSettings'] = previousDeviceSettings;
      appdata.settings['comicSpecificSettings'] = previousComicSettings;
      appdata.settings['showPageNumberInReader'] = previousPageNumber;
      appdata.settings['enableClockAndBatteryInfoInReader'] = previousClockInfo;
    }
  });

  test('active reader setting writes to the current settings scope', () {
    final previousDeviceId = appdata.settings['deviceId'];
    final previousDeviceSettings = appdata.settings['deviceSpecificSettings'];
    final previousComicSettings = appdata.settings['comicSpecificSettings'];
    final previousBrightness = appdata.settings['readerBrightness'];

    try {
      appdata.settings['deviceId'] = 'reader-brightness-test-device';
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
      appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
      appdata.settings['readerBrightness'] = 50;

      appdata.settings.setActiveReaderSetting(
        'comic-id',
        'source-key',
        'readerBrightness',
        60,
      );
      expect(appdata.settings['readerBrightness'], 60);

      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setActiveReaderSetting(
        'comic-id',
        'source-key',
        'readerBrightness',
        40,
      );
      expect(appdata.settings['readerBrightness'], 60);
      expect(appdata.settings.getDeviceReaderSetting('readerBrightness'), 40);

      appdata.settings.setEnabledComicSpecificSettings(
        'comic-id',
        'source-key',
        true,
      );
      appdata.settings.setActiveReaderSetting(
        'comic-id',
        'source-key',
        'readerBrightness',
        30,
      );
      expect(
        appdata.settings.getReaderSetting(
          'comic-id',
          'source-key',
          'readerBrightness',
        ),
        30,
      );
      expect(appdata.settings.getDeviceReaderSetting('readerBrightness'), 40);
    } finally {
      appdata.settings['deviceId'] = previousDeviceId;
      appdata.settings['deviceSpecificSettings'] = previousDeviceSettings;
      appdata.settings['comicSpecificSettings'] = previousComicSettings;
      appdata.settings['readerBrightness'] = previousBrightness;
    }
  });

  test(
    'saveData queues concurrent writes and keeps the latest snapshot',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-appdata-');
      addTearDown(() {
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['proxy'] = 'system';
        appdata.searchHistory = [];
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      appdata.settings['disableSyncFields'] = 'proxy';
      appdata.settings['proxy'] = 'first';
      appdata.searchHistory = ['first'];

      final firstSave = appdata.saveData(false);
      appdata.settings['proxy'] = 'second';
      appdata.searchHistory = ['second'];
      final secondSave = appdata.saveData(false);

      await Future.wait([firstSave, secondSave]);

      final appDataFile = File('${dataDir.path}/appdata.json');
      final syncDataFile = File('${dataDir.path}/syncdata.json');
      final appData = jsonDecode(appDataFile.readAsStringSync());
      final syncData = jsonDecode(syncDataFile.readAsStringSync());

      expect(appData['settings']['proxy'], 'second');
      expect(appData['searchHistory'], ['second']);
      expect(syncData['settings'].containsKey('proxy'), isFalse);
    },
  );

  test('sync snapshot always filters device-local WebDAV settings', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-appdata-sync-policy-',
    );
    addTearDown(() {
      App.dataPath = fallbackDataDir.path;
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['webdav'] = [];
      appdata.settings['backupWebdav'] = [];
      appdata.settings['backupWebdavPath'] = '/venera_backup/';
      appdata.settings['backupWebdavSyncEnabled'] = false;
      appdata.settings['webdavComicLibrary'] = [];
      appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
      appdata.settings['webdavComicLibraryAutoSync'] = true;
      appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
      appdata.settings['webdavComicLibrarySyncEnabled'] = false;
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });

    App.dataPath = dataDir.path;
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['webdav'] = [
      'https://sync.example/dav',
      'sync-user',
      'main-secret',
    ];
    appdata.settings['backupWebdav'] = [
      'https://backup.example/dav',
      'backup-user',
      'backup-secret',
    ];
    appdata.settings['backupWebdavPath'] = '/backup/';
    appdata.settings['backupWebdavSyncEnabled'] = false;
    appdata.settings['webdavComicLibrary'] = [
      'https://library.example/dav',
      'library-user',
      'comic-secret',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/library/';
    appdata.settings['webdavComicLibraryAutoSync'] = false;
    appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 15;
    appdata.settings['webdavComicLibrarySyncEnabled'] = false;

    await appdata.saveData(false);

    final syncContent = File(
      '${dataDir.path}/syncdata.json',
    ).readAsStringSync();
    final syncSettings =
        (jsonDecode(syncContent) as Map<String, dynamic>)['settings']
            as Map<String, dynamic>;
    expect(syncSettings.containsKey('webdav'), isFalse);
    expect(syncSettings.containsKey('backupWebdav'), isFalse);
    expect(syncSettings.containsKey('backupWebdavPath'), isFalse);
    expect(syncSettings.containsKey('webdavComicLibrary'), isFalse);
    expect(syncSettings.containsKey('webdavComicLibraryPath'), isFalse);
    expect(syncSettings.containsKey('webdavComicLibraryAutoSync'), isFalse);
    expect(
      syncSettings.containsKey('webdavComicLibrarySyncIntervalMinutes'),
      isFalse,
    );
    expect(syncSettings.containsKey('webdavComicLibrarySyncEnabled'), isFalse);
    expect(syncContent, isNot(contains('main-secret')));
    expect(syncContent, isNot(contains('backup-secret')));
    expect(syncContent, isNot(contains('comic-secret')));
  });

  test('sync snapshot includes opted-in comic library config', () async {
    final dataDir = Directory.systemTemp.createTempSync(
      'venera-appdata-library-sync-',
    );
    addTearDown(() {
      App.dataPath = fallbackDataDir.path;
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['webdavComicLibrary'] = [];
      appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
      appdata.settings['webdavComicLibraryAutoSync'] = true;
      appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
      appdata.settings['webdavComicLibrarySyncEnabled'] = false;
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });

    App.dataPath = dataDir.path;
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['webdavComicLibrary'] = [
      'https://library.example/dav',
      'library-user',
      'comic-secret',
    ];
    appdata.settings['webdavComicLibraryPath'] = '/library/';
    appdata.settings['webdavComicLibraryAutoSync'] = false;
    appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 15;
    appdata.settings['webdavComicLibrarySyncEnabled'] = true;

    await appdata.saveData(false);

    final syncSettings =
        (jsonDecode(File('${dataDir.path}/syncdata.json').readAsStringSync())
                as Map<String, dynamic>)['settings']
            as Map<String, dynamic>;
    expect(syncSettings['webdavComicLibrary'], [
      'https://library.example/dav',
      'library-user',
      'comic-secret',
    ]);
    expect(syncSettings['webdavComicLibraryPath'], '/library/');
    expect(syncSettings['webdavComicLibraryAutoSync'], isFalse);
    expect(syncSettings['webdavComicLibrarySyncIntervalMinutes'], 15);
    expect(syncSettings.containsKey('webdavComicLibrarySyncEnabled'), isFalse);
  });

  test(
    'remote data preserves the local sync endpoint and gated library config',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-import-policy-',
      );
      addTearDown(() {
        App.dataPath = fallbackDataDir.path;
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['webdav'] = [];
        appdata.settings['webdavComicLibrary'] = [];
        appdata.settings['webdavComicLibraryPath'] = '/venera_comics/';
        appdata.settings['webdavComicLibraryAutoSync'] = true;
        appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
        appdata.settings['webdavComicLibrarySyncEnabled'] = false;
        appdata.implicitData.remove('webdavAutoSync');
        appdata.implicitData.remove('webdavSyncDirection');
        appdata.implicitData.remove('webdavSyncTiming');
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      });

      App.dataPath = dataDir.path;
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['webdav'] = [
        'https://local-sync.example/dav',
        'local-user',
        'local-secret',
      ];
      appdata.implicitData['webdavAutoSync'] = false;
      appdata.implicitData['webdavSyncDirection'] = 'uploadOnly';
      appdata.implicitData['webdavSyncTiming'] = 'manual';
      appdata.settings['webdavComicLibrary'] = [
        'https://local-library.example/dav',
        'local-user',
        'local-secret',
      ];
      appdata.settings['webdavComicLibraryPath'] = '/local/';
      appdata.settings['webdavComicLibraryAutoSync'] = true;
      appdata.settings['webdavComicLibrarySyncIntervalMinutes'] = 360;
      appdata.settings['webdavComicLibrarySyncEnabled'] = false;

      final remoteSettings = <String, dynamic>{
        'webdav': [
          'https://remote-sync.example/dav',
          'remote-user',
          'remote-secret',
        ],
        'webdavAutoSync': true,
        'webdavSyncDirection': 'downloadOnly',
        'webdavSyncTiming': 'realtime',
        'webdavComicLibrary': [
          'https://remote-library.example/dav',
          'remote-user',
          'remote-secret',
        ],
        'webdavComicLibraryPath': '/remote/',
        'webdavComicLibraryAutoSync': false,
        'webdavComicLibrarySyncIntervalMinutes': 15,
        'webdavComicLibrarySyncEnabled': true,
      };

      await appdata.syncData({
        'settings': remoteSettings,
        'searchHistory': <String>[],
      });

      expect(appdata.settings['webdav'], [
        'https://local-sync.example/dav',
        'local-user',
        'local-secret',
      ]);
      expect(appdata.implicitData['webdavAutoSync'], isFalse);
      expect(appdata.implicitData['webdavSyncDirection'], 'uploadOnly');
      expect(appdata.implicitData['webdavSyncTiming'], 'manual');
      expect(appdata.settings['webdavComicLibrary'], [
        'https://local-library.example/dav',
        'local-user',
        'local-secret',
      ]);
      expect(appdata.settings['webdavComicLibraryPath'], '/local/');
      expect(appdata.settings['webdavComicLibrarySyncEnabled'], isFalse);

      appdata.settings['webdavComicLibrarySyncEnabled'] = true;
      await appdata.syncData({
        'settings': remoteSettings,
        'searchHistory': <String>[],
      });

      expect(appdata.settings['webdavComicLibrary'], [
        'https://remote-library.example/dav',
        'remote-user',
        'remote-secret',
      ]);
      expect(appdata.settings['webdavComicLibraryPath'], '/remote/');
      expect(appdata.settings['webdavComicLibraryAutoSync'], isFalse);
      expect(appdata.settings['webdavComicLibrarySyncIntervalMinutes'], 15);
    },
  );

  test(
    'Bangumi connection and bindings sync while pending progress stays local',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-bangumi-',
      );
      addTearDown(() {
        App.dataPath = fallbackDataDir.path;
        appdata.settings['disableSyncFields'] = '';
        appdata.settings['bangumiAccessToken'] = '';
        appdata.settings['bangumiUsername'] = '';
        appdata.settings['bangumiAutoSyncEnabled'] = true;
        appdata.settings['bangumiBindings'] = <String, dynamic>{};
        appdata.implicitData.remove('bangumiPendingProgress');
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
      });

      App.dataPath = dataDir.path;
      appdata.settings['disableSyncFields'] = 'proxy';
      appdata.settings['bangumiAccessToken'] = 'token';
      appdata.settings['bangumiUsername'] = 'alice';
      appdata.settings['bangumiAutoSyncEnabled'] = false;
      appdata.settings['bangumiBindings'] = {
        'source@comic': {'subjectId': 42},
      };
      appdata.implicitData['bangumiPendingProgress'] = {
        'source@comic': {
          'ep_status': {'value': 12},
        },
      };

      await appdata.saveData(false);
      await appdata.writeImplicitData();
      await appdata.saveData(false);

      final syncData = jsonDecode(
        File('${dataDir.path}/syncdata.json').readAsStringSync(),
      );
      final implicitData = jsonDecode(
        File('${dataDir.path}/implicitData.json').readAsStringSync(),
      );
      expect(syncData['settings']['bangumiAccessToken'], 'token');
      expect(syncData['settings']['bangumiUsername'], 'alice');
      expect(appdata.exportSyncSettings()['bangumiAccessToken'], 'token');
      expect(appdata.exportSyncSettings()['bangumiUsername'], 'alice');
      expect(syncData['settings']['bangumiAutoSyncEnabled'], isFalse);
      expect(syncData['settings']['bangumiBindings'], isNotEmpty);
      expect(
        syncData['settings'].containsKey('bangumiPendingProgress'),
        isFalse,
      );
      expect(implicitData['bangumiPendingProgress'], isNotEmpty);

      await appdata.syncData({
        'settings': {
          'bangumiAccessToken': 'remote-secret',
          'bangumiUsername': 'remote-user',
          'bangumiAutoSyncEnabled': true,
          'bangumiBindings': {
            'remote@comic': {'subjectId': 99},
          },
        },
        'implicitData': {'bangumiPendingProgress': <String, dynamic>{}},
        'searchHistory': <String>[],
      });
      expect(appdata.settings['bangumiAccessToken'], 'remote-secret');
      expect(appdata.settings['bangumiUsername'], 'remote-user');
      expect(appdata.settings['bangumiAutoSyncEnabled'], isTrue);
      expect(
        appdata.settings['bangumiBindings']['remote@comic']['subjectId'],
        99,
      );
      expect(
        appdata.implicitData['bangumiPendingProgress'],
        implicitData['bangumiPendingProgress'],
      );
      final persisted = jsonDecode(
        File('${dataDir.path}/appdata.json').readAsStringSync(),
      );
      expect(persisted['settings']['bangumiAccessToken'], 'remote-secret');
      expect(persisted['settings']['bangumiUsername'], 'remote-user');
      final reexported = jsonDecode(
        File('${dataDir.path}/syncdata.json').readAsStringSync(),
      );
      expect(reexported['settings']['bangumiAccessToken'], 'remote-secret');
      expect(reexported['settings']['bangumiUsername'], 'remote-user');
    },
  );

  test('saveData keeps the previous appdata snapshot as backup', () async {
    final dataDir = Directory.systemTemp.createTempSync('venera-appdata-');
    addTearDown(() {
      appdata.settings['disableSyncFields'] = '';
      appdata.settings['proxy'] = 'system';
      appdata.searchHistory = [];
      if (dataDir.existsSync()) {
        dataDir.deleteSync(recursive: true);
      }
    });

    App.dataPath = dataDir.path;
    appdata.settings['proxy'] = 'first';
    appdata.searchHistory = ['first'];
    await appdata.saveData(false);

    appdata.settings['proxy'] = 'second';
    appdata.searchHistory = ['second'];
    await appdata.saveData(false);

    final appDataFile = File('${dataDir.path}/appdata.json');
    final appData = jsonDecode(appDataFile.readAsStringSync());
    final backupData = jsonDecode(
      File('${appDataFile.path}.bak').readAsStringSync(),
    );

    expect(appData['settings']['proxy'], 'second');
    expect(appData['searchHistory'], ['second']);
    expect(backupData['settings']['proxy'], 'first');
    expect(backupData['searchHistory'], ['first']);
  });

  test(
    'recovers appdata from backup without deleting the invalid file',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-load-',
      );
      addTearDown(() {
        appdata.settings['proxy'] = 'system';
        appdata.searchHistory = [];
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });

      final appDataFile = File(p.join(dataDir.path, 'appdata.json'))
        ..writeAsStringSync('{invalid');
      File('${appDataFile.path}.bak').writeAsStringSync(
        jsonEncode({
          'settings': {'proxy': 'http://127.0.0.1:7890'},
          'searchHistory': ['restored'],
        }),
      );

      await appdata.loadDataForTesting(dataDir.path);

      expect(appdata.settings['proxy'], 'http://127.0.0.1:7890');
      expect(appdata.searchHistory, ['restored']);
      expect(jsonDecode(appDataFile.readAsStringSync()), isA<Map>());
      expect(
        dataDir.listSync().whereType<File>().any(
          (file) => p.basename(file.path).startsWith('appdata.json.corrupt-'),
        ),
        isTrue,
      );
    },
  );

  test(
    'drops obsolete settings on load and sync without persisting them',
    () async {
      final dataDir = Directory.systemTemp.createTempSync(
        'venera-appdata-obsolete-',
      );
      final previousProxy = appdata.settings['proxy'];
      final previousQuickFavorite = appdata.settings['quickFavorite'];
      final previousSearchHistory = List<String>.from(appdata.searchHistory);
      final previousDataPath = App.dataPath;

      addTearDown(() async {
        App.dataPath = previousDataPath;
        appdata.settings['proxy'] = previousProxy;
        appdata.settings['quickFavorite'] = previousQuickFavorite;
        appdata.searchHistory = previousSearchHistory;
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;

      final appDataFile = File(p.join(dataDir.path, 'appdata.json'));
      appDataFile.writeAsStringSync(
        jsonEncode({
          'settings': {
            'proxy': 'http://127.0.0.1:9090',
            'quickFavorite': 'Favorites',
            'readLaterFolder': 'Old Later Folder',
          },
          'searchHistory': ['sample'],
        }),
      );

      await appdata.loadDataForTesting(dataDir.path);

      expect(appdata.settings['proxy'], 'http://127.0.0.1:9090');
      expect(appdata.settings['quickFavorite'], 'Favorites');
      expect(appdata.settings['readLaterFolder'], isNull);

      await appdata.saveData(false);

      final savedAppData =
          jsonDecode(appDataFile.readAsStringSync()) as Map<String, dynamic>;
      final savedAppSettings = savedAppData['settings'] as Map<String, dynamic>;
      expect(savedAppSettings.containsKey('readLaterFolder'), isFalse);
      expect(savedAppSettings['proxy'], 'http://127.0.0.1:9090');
      expect(savedAppSettings['quickFavorite'], 'Favorites');

      final syncDataFile = File(p.join(dataDir.path, 'syncdata.json'));
      final savedSyncData =
          jsonDecode(syncDataFile.readAsStringSync()) as Map<String, dynamic>;
      final savedSyncSettings =
          savedSyncData['settings'] as Map<String, dynamic>;
      expect(savedSyncSettings.containsKey('readLaterFolder'), isFalse);
      expect(savedSyncSettings['quickFavorite'], 'Favorites');

      await appdata.syncData({
        'settings': {
          'quickFavorite': 'Updated Favorites',
          'readLaterFolder': 'Synced Obsolete Folder',
        },
        'searchHistory': ['synced-sample'],
      });

      expect(appdata.settings['quickFavorite'], 'Updated Favorites');
      expect(appdata.settings['readLaterFolder'], isNull);

      final afterSyncData =
          jsonDecode(appDataFile.readAsStringSync()) as Map<String, dynamic>;
      final afterSyncSettings =
          afterSyncData['settings'] as Map<String, dynamic>;
      expect(afterSyncSettings.containsKey('readLaterFolder'), isFalse);
      expect(afterSyncSettings['quickFavorite'], 'Updated Favorites');
    },
  );

  test(
    'save requests notify synchronously before queued disk persistence',
    () async {
      final previousSearch = appdata.fullSearchHistory;
      var changes = 0;
      appdata.registerSyncDataRequestHandler(() {
        changes++;
      });
      addTearDown(() {
        appdata.registerSyncDataRequestHandler(null);
        appdata.setFullSearchHistory(previousSearch);
      });
      final pending = appdata.saveData();
      expect(changes, 1);
      appdata.addSearchHistory('immediate-notification');
      expect(changes, 2);
      appdata.removeSearchHistory('immediate-notification');
      expect(changes, 3);
      appdata.clearSearchHistory();
      expect(changes, 4);
      await pending;
      await appdata.saveData(false);
      expect(changes, 4);
    },
  );

  test('invalid known setting types recover a valid backup', () async {
    final directory = Directory.systemTemp.createTempSync(
      'venera-setting-type-',
    );
    final previous = appdata.settings['comicTileScale'];
    addTearDown(() {
      appdata.settings['comicTileScale'] = previous;
      directory.deleteSync(recursive: true);
    });
    File('${directory.path}/appdata.json').writeAsStringSync(
      jsonEncode({
        'settings': {'comicTileScale': 'bad'},
        'searchHistory': [],
      }),
    );
    File('${directory.path}/appdata.json.bak').writeAsStringSync(
      jsonEncode({
        'settings': {'comicTileScale': 1.0},
        'searchHistory': [],
      }),
    );
    await appdata.loadDataForTesting(directory.path);
    expect(appdata.settings['comicTileScale'], 1.0);
    final recovered = jsonDecode(
      File('${directory.path}/appdata.json').readAsStringSync(),
    );
    expect(recovered['settings']['comicTileScale'], 1.0);
  });

  test(
    'removed known settings read defaults without reviving persisted membership',
    () async {
      final previousSettings =
          jsonDecode(jsonEncode(appdata.toJson()['settings']))
              as Map<String, dynamic>;
      final previousSearch = appdata.fullSearchHistory;
      addTearDown(() {
        appdata.settings.replaceAll(previousSettings);
        appdata.setFullSearchHistory(previousSearch);
      });
      for (final root in [
        'comicTileScale',
        'comicSpecificSettings',
        'comicLayoutDetections',
        'blockedWords',
      ]) {
        appdata.removeSyncSetting(root);
      }
      expect(appdata.settings['comicTileScale'], 1.0);
      expect(appdata.settings['comicSpecificSettings'], isEmpty);
      expect(
        appdata.settings.comicReaderModeOverride('comic', 'source'),
        isNull,
      );
      expect(
        appdata.settings.isComicSpecificSettingsEnabled('comic', 'source'),
        isFalse,
      );
      appdata.settings.getReaderSetting('comic', 'source', 'comicTileScale');
      appdata.settings.comicLayout('comic', 'source');
      for (final root in [
        'comicTileScale',
        'comicSpecificSettings',
        'comicLayoutDetections',
        'blockedWords',
      ]) {
        expect(appdata.exportSyncSettings().containsKey(root), isFalse);
      }
      await appdata.saveData(false);
      await appdata.loadDataForTesting(App.dataPath);
      expect(appdata.settings['comicTileScale'], 1.0);
      expect(appdata.settings['comicSpecificSettings'], isEmpty);
      expect(
        appdata.exportSyncSettings().containsKey('comicTileScale'),
        isFalse,
      );
      expect(
        appdata.exportSyncSettings().containsKey('comicSpecificSettings'),
        isFalse,
      );
      appdata.settings.setReaderSetting(
        'comic',
        'source',
        'splitDualPage',
        true,
      );
      appdata.settings['blockedWords'].add('new-user-edit');
      await appdata.saveData(false);
      expect(appdata.exportSyncSettings()['comicSpecificSettings'], {
        'comic@source': {'splitDualPage': true},
      });
      expect(appdata.exportSyncSettings()['blockedWords'], ['new-user-edit']);
    },
  );
}
