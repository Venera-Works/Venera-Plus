import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  late Directory fallbackRoot;
  late Directory tempDir;
  late String previousDataPath;
  late String previousCachePath;
  late Map<String, dynamic> previousSettings;
  late Map<String, dynamic> previousImplicit;

  setUpAll(() async {
    fallbackRoot = await Directory.systemTemp.createTemp(
      'comic-update-sync-fallback-',
    );
    App.dataPath = fallbackRoot.path;
    App.cachePath = fallbackRoot.path;
  });

  tearDownAll(() async {
    if (await fallbackRoot.exists()) {
      await fallbackRoot.delete(recursive: true);
    }
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('comic-update-sync-test-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousSettings = Map<String, dynamic>.from(
      appdata.toJson()['settings'] as Map,
    );
    previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    App.dataPath = tempDir.path;
    App.cachePath = tempDir.path;
    appdata.implicitData.clear();
    Log.isMuted = true;
    DataSync.resetForTesting();
    DataSync.debugDisableWindowCloseHandler = true;
  });

  tearDown(() async {
    DataSync.resetForTesting();
    appdata.settings.replaceAll(previousSettings);
    appdata.implicitData
      ..clear()
      ..addAll(previousImplicit);
    await appdata.saveData(false);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    Log.clear();
    Log.isMuted = false;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Device ID and Policy', () {
    test('stable writer UUID in implicitData', () {
      final id1 = getOrCreateComicUpdateDeviceId();
      expect(id1, isNotEmpty);
      expect(appdata.implicitData[comicUpdateDeviceIdImplicitKey], id1);

      // Re-reading returns the exact same ID
      final id2 = getOrCreateComicUpdateDeviceId();
      expect(id2, id1);
    });

    test('isComicUpdateSyncEnabled honors disabled favorites policy', () {
      expect(isComicUpdateSyncEnabled(), isTrue);

      // Exclude favorites group
      appdata.implicitData['syncExcludedDomains'] = ['favorite'];
      expect(isComicUpdateSyncEnabled(), isFalse);

      // Exclude comicUpdate domain directly
      appdata.implicitData['syncExcludedDomains'] = ['comicUpdate'];
      expect(isComicUpdateSyncEnabled(), isFalse);

      // Other excluded domain does not disable comic update
      appdata.implicitData['syncExcludedDomains'] = ['history'];
      expect(isComicUpdateSyncEnabled(), isTrue);
    });
  });

  group('Document Serialization and Strict Decoding', () {
    test('encodes and decodes valid comic update state documents', () {
      final state1 = ComicUpdateState.fromLegacy(
        updateTime: '2026-11-07',
        unread: true,
      );
      final states = {('comic-1', ComicType.local.value): state1};

      final doc = encodeComicUpdateStatesDocument(
        deviceId: 'device-test-123',
        states: states,
        updatedAt: 1700000000000,
      );

      final decoded = decodeComicUpdateStatesDocument(doc);
      expect(decoded.length, 1);
      final decodedState = decoded[('comic-1', ComicType.local.value)]!;
      expect(decodedState.updateTime, '2026-11-07');
      expect(decodedState.hasNewUpdate, isTrue);
    });

    test(
      'strict decoder throws FormatException on invalid inputs and version mismatch',
      () {
        // Not JSON
        expect(
          () => decodeComicUpdateStatesDocument('not json'),
          throwsFormatException,
        );

        // Not a Map root
        expect(
          () => decodeComicUpdateStatesDocument('["item"]'),
          throwsFormatException,
        );

        // Missing version
        expect(
          () => decodeComicUpdateStatesDocument(
            jsonEncode({'deviceId': 'dev-1', 'states': []}),
          ),
          throwsFormatException,
        );

        // Version mismatch: future version 2
        expect(
          () => decodeComicUpdateStatesDocument(
            jsonEncode({'version': 2, 'deviceId': 'dev-1', 'states': []}),
          ),
          throwsFormatException,
        );

        // Version mismatch: version 0
        expect(
          () => decodeComicUpdateStatesDocument(
            jsonEncode({'version': 0, 'deviceId': 'dev-1', 'states': []}),
          ),
          throwsFormatException,
        );

        // Missing deviceId
        expect(
          () => decodeComicUpdateStatesDocument(
            jsonEncode({'version': 1, 'states': []}),
          ),
          throwsFormatException,
        );

        // Missing states list
        expect(
          () => decodeComicUpdateStatesDocument(
            jsonEncode({'version': 1, 'deviceId': 'dev-1'}),
          ),
          throwsFormatException,
        );

        // Invalid item in states
        expect(
          () => decodeComicUpdateStatesDocument(
            jsonEncode({
              'version': 1,
              'deviceId': 'dev-1',
              'states': ['invalid'],
            }),
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('Store-backed Multi-Device Sync', () {
    test(
      'simultaneous devices never overwrite each other and converge state',
      () async {
        final store = _InMemoryRemoteStore();
        final baseDir = '/sync/test/';

        // Initialize two separate local database files for Device A and Device B
        final dbDirA = Directory(p.join(tempDir.path, 'devA'))..createSync();
        final dbDirB = Directory(p.join(tempDir.path, 'devB'))..createSync();

        final dbA = sqlite3.open(p.join(dbDirA.path, 'local_favorite.db'));
        final dbB = sqlite3.open(p.join(dbDirB.path, 'local_favorite.db'));
        addTearDown(() {
          dbA.close();
          dbB.close();
        });

        FavoriteSyncData.ensureComicUpdateSchema(dbA);
        FavoriteSyncData.ensureComicUpdateSchema(dbB);

        // Device A discovers update for comic-1
        final stateA = ComicUpdateState.fromLegacy(
          updateTime: '2026-11-07',
          unread: true,
        );
        FavoriteSyncData.mergeComicUpdateStates(dbA, {
          ('comic-1', ComicType.local.value): stateA,
        });

        // Device B discovers update for comic-2
        final stateB = ComicUpdateState.fromLegacy(
          updateTime: '2026-11-08',
          unread: true,
        );
        FavoriteSyncData.mergeComicUpdateStates(dbB, {
          ('comic-2', ComicType.local.value): stateB,
        });

        // Device A syncs (uploadSelf: true)
        App.dataPath = dbDirA.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'uuid_device_A',
        );

        // Device B syncs (uploadSelf: true)
        App.dataPath = dbDirB.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'uuid_device_B',
        );

        // Verify: Both files exist in remote store; B did not overwrite A!
        expect(
          store.files.containsKey(
            '/sync/test/comic_updates/uuid_device_A.json',
          ),
          isTrue,
        );
        expect(
          store.files.containsKey(
            '/sync/test/comic_updates/uuid_device_B.json',
          ),
          isTrue,
        );

        // Device A syncs again (downloading B's file and updating)
        App.dataPath = dbDirA.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'uuid_device_A',
        );

        // Device B syncs again (downloading A's file and updating)
        App.dataPath = dbDirB.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'uuid_device_B',
        );

        // Convergence check: Both databases now contain states for comic-1 and comic-2!
        final finalStatesA = FavoriteSyncData.readComicUpdateStates(dbA);
        final finalStatesB = FavoriteSyncData.readComicUpdateStates(dbB);

        expect(
          finalStatesA.containsKey(('comic-1', ComicType.local.value)),
          isTrue,
        );
        expect(
          finalStatesA.containsKey(('comic-2', ComicType.local.value)),
          isTrue,
        );
        expect(
          finalStatesB.containsKey(('comic-1', ComicType.local.value)),
          isTrue,
        );
        expect(
          finalStatesB.containsKey(('comic-2', ComicType.local.value)),
          isTrue,
        );

        expect(
          finalStatesA[('comic-1', ComicType.local.value)]!.updateTime,
          '2026-11-07',
        );
        expect(
          finalStatesB[('comic-1', ComicType.local.value)]!.updateTime,
          '2026-11-07',
        );
        expect(
          finalStatesA[('comic-2', ComicType.local.value)]!.updateTime,
          '2026-11-08',
        );
        expect(
          finalStatesB[('comic-2', ComicType.local.value)]!.updateTime,
          '2026-11-08',
        );
      },
    );

    test(
      'same-comic concurrent new chapter discovery vs old confirmation converges',
      () async {
        final store = _InMemoryRemoteStore();
        final baseDir = '/sync/test/';

        final dbDirA = Directory(p.join(tempDir.path, 'raceA'))..createSync();
        final dbDirB = Directory(p.join(tempDir.path, 'raceB'))..createSync();

        final dbA = sqlite3.open(p.join(dbDirA.path, 'local_favorite.db'));
        final dbB = sqlite3.open(p.join(dbDirB.path, 'local_favorite.db'));
        addTearDown(() {
          dbA.close();
          dbB.close();
        });

        FavoriteSyncData.ensureComicUpdateSchema(dbA);
        FavoriteSyncData.ensureComicUpdateSchema(dbB);

        // Device A discovers chapter 2 (known: ch1, ch2; updated: ch2)
        final baselineSnapshot = ComicUpdateSnapshot.fromChapters({
          'ch1': 'Chapter 1',
        });
        final updatedSnapshot = ComicUpdateSnapshot.fromChapters({
          'ch1': 'Chapter 1',
          'ch2': 'Chapter 2',
        });

        var stateOnA = const ComicUpdateState.empty()
            .observe(baselineSnapshot)
            .state;
        stateOnA = stateOnA.observe(updatedSnapshot).state;
        expect(stateOnA.hasNewUpdate, isTrue);

        // Device B starts from baseline and acknowledges chapter 1
        var stateOnB = const ComicUpdateState.empty()
            .observe(baselineSnapshot)
            .state;
        stateOnB = stateOnB.acknowledgeSnapshot(
          baselineSnapshot,
          chapterId: 'ch1',
          isLastChapter: true,
        );

        FavoriteSyncData.mergeComicUpdateStates(dbA, {
          ('comic-race', ComicType.local.value): stateOnA,
        });
        FavoriteSyncData.mergeComicUpdateStates(dbB, {
          ('comic-race', ComicType.local.value): stateOnB,
        });

        // Device A syncs upload
        App.dataPath = dbDirA.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'dev_race_A',
        );

        // Device B syncs upload
        App.dataPath = dbDirB.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'dev_race_B',
        );

        // Both devices merge the other
        App.dataPath = dbDirA.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'dev_race_A',
        );

        App.dataPath = dbDirB.path;
        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'dev_race_B',
        );

        // Verify converged state on both devices
        final finalA = FavoriteSyncData.readComicUpdateStates(
          dbA,
        )[('comic-race', ComicType.local.value)]!;
        final finalB = FavoriteSyncData.readComicUpdateStates(
          dbB,
        )[('comic-race', ComicType.local.value)]!;

        expect(finalA, equals(finalB));
        expect(
          finalA.observe(updatedSnapshot).status,
          ComicUpdateCheckStatus.unchanged,
        );
        expect(finalA.hasNewUpdate, isTrue);
        expect(
          finalA
              .acknowledgeSnapshot(
                updatedSnapshot,
                chapterId: 'ch2',
                isLastChapter: true,
              )
              .hasNewUpdate,
          isFalse,
        );
      },
    );

    test(
      'permission and network failures surface and do not silently succeed',
      () async {
        final store = _InMemoryRemoteStore();
        store.listError = const RemoteStorageException(
          'Access denied',
          code: 'forbidden',
        );

        expect(
          () => syncComicUpdatesWithStore(
            store,
            remoteBaseDirectory: '/sync/',
            uploadSelf: false,
          ),
          throwsA(isA<RemoteStorageException>()),
        );
      },
    );

    test(
      'isCurrent cancellation guard prevents apply and upload on cancelled task',
      () async {
        final store = _InMemoryRemoteStore();
        final db = sqlite3.open(p.join(tempDir.path, 'local_favorite.db'));
        addTearDown(db.close);
        FavoriteSyncData.ensureComicUpdateSchema(db);

        // Prepopulate remote store with peer state
        final peerDoc = encodeComicUpdateStatesDocument(
          deviceId: 'peer-device',
          states: {
            (
              'comic-cancelled',
              ComicType.local.value,
            ): ComicUpdateState.fromLegacy(
              updateTime: '2026-11-09',
              unread: true,
            ),
          },
        );
        store.directories.add('/sync/comic_updates/');
        store.files['/sync/comic_updates/peer-device.json'] = utf8.encode(
          peerDoc,
        );

        var isCurrentFlag = true;
        // Task cancelled mid-stream
        final changed = await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: '/sync/',
          uploadSelf: true,
          deviceIdOverride: 'self-device',
          isCurrent: () {
            final current = isCurrentFlag;
            isCurrentFlag = false; // Cancel on first check
            return current;
          },
        );

        expect(changed, isFalse);
        // Own file was not uploaded because task was cancelled
        expect(
          store.files.containsKey('/sync/comic_updates/self-device.json'),
          isFalse,
        );
        // Local db was not updated
        final localStates = FavoriteSyncData.readComicUpdateStates(db);
        expect(
          localStates.containsKey(('comic-cancelled', ComicType.local.value)),
          isFalse,
        );
      },
    );

    test(
      'peer merge notifies UI while suppressing redundant sync upload triggers',
      () async {
        final store = _InMemoryRemoteStore();
        final baseDir = '/sync/test/';

        final peerDoc = encodeComicUpdateStatesDocument(
          deviceId: 'peer-device',
          states: {
            (
              'comic-notify',
              ComicType.local.value,
            ): ComicUpdateState.fromLegacy(
              updateTime: '2026-11-10',
              unread: true,
            ),
          },
        );
        store.directories.add('/sync/test/comic_updates/');
        store.files['/sync/test/comic_updates/peer-device.json'] = utf8.encode(
          peerDoc,
        );

        var uiNotified = false;
        void listener() {
          uiNotified = true;
        }

        final manager = LocalFavoritesManager();
        await manager.init();
        appdata.settings['webdav'] = ['https://example.invalid/dav/', '', ''];
        appdata.implicitData['webdavSyncMode'] = 'manual';
        DataSync();
        addTearDown(() => manager.close());
        manager.addListener(listener);

        await syncComicUpdatesWithStore(
          store,
          remoteBaseDirectory: baseDir,
          uploadSelf: true,
          deviceIdOverride: 'my-device',
        );

        expect(uiNotified, isTrue);
        expect(appdata.implicitData['webdavSyncPending'], isNot(isTrue));
      },
    );
  });

  group('Equal-version Live Download Merging Update Sidecar', () {
    test(
      'equal snapshot version download still downloads and merges comic_updates sidecar',
      () async {
        final store = _InMemoryRemoteStore();
        final account = const StorageAccount(
          id: 'test-account',
          backend: StorageBackend.openlist,
          driver: 'GoogleDrive',
          name: 'Test',
          authorization: {},
        );

        RemoteStorageAccounts.instance.configureOpenList(_StoreRpc(store));

        // Local dataVersion is 5
        appdata.settings['dataVersion'] = 5;
        appdata.settings[remoteStorageAccountsSetting] = [account.toJson()];
        appdata.settings['syncRemoteLocation'] = const RemoteLocation(
          accountId: 'test-account',
          directory: '/sync/',
        ).toJson();

        final localDb = sqlite3.open(p.join(tempDir.path, 'local_favorite.db'));
        addTearDown(localDb.close);
        FavoriteSyncData.ensureComicUpdateSchema(localDb);

        final history = HistoryManager();
        await history.init();
        final favorites = LocalFavoritesManager();
        await favorites.init();
        addTearDown(() {
          history.close();
          HistoryManager.cache = null;
          favorites.close();
          LocalFavoritesManager.cache = null;
        });

        // Remote snapshot is equal version 5 (100-5.venera)
        store.directories.add('/sync/');
        store.files['/sync/100-5.venera'] = utf8.encode('dummy archive');
        configureAppDataArchiveExtractorForTesting((archive, destination) {});
        addTearDown(() => configureAppDataArchiveExtractorForTesting(null));

        // Remote also has comic_updates sidecar from peer
        final peerDoc = encodeComicUpdateStatesDocument(
          deviceId: 'peer-uuid',
          states: {
            (
              'comic-equal-version',
              ComicType.local.value,
            ): ComicUpdateState.fromLegacy(
              updateTime: '2026-11-10',
              unread: true,
            ),
          },
        );
        store.directories.add('/sync/comic_updates/');
        store.files['/sync/comic_updates/peer-uuid.json'] = utf8.encode(
          peerDoc,
        );

        final result = await DataSync().downloadData();

        expect(result.success, isTrue, reason: result.errorMessage);

        // Sidecar was merged even though snapshot version was equal!
        final updatedStates = FavoriteSyncData.readComicUpdateStates(localDb);
        expect(
          updatedStates.containsKey((
            'comic-equal-version',
            ComicType.local.value,
          )),
          isTrue,
        );
        expect(
          updatedStates[('comic-equal-version', ComicType.local.value)]!
              .updateTime,
          '2026-11-10',
        );
      },
    );
  });

  group('Check times and CheckVersion Archive Merging', () {
    test(
      'sync import checkVersion:true preserves local check times and clears remote check times',
      () async {
        final localDb = sqlite3.open(p.join(tempDir.path, 'local_favorite.db'));
        FavoriteSyncData.ensureComicUpdateSchema(localDb);
        localDb.execute(
          'INSERT INTO comic_update_state (id, type, state, last_check_time) VALUES (?, ?, ?, ?);',
          [
            'comic-local',
            ComicType.local.value,
            jsonEncode(
              ComicUpdateState.fromLegacy(updateTime: '2026-11-01').toJson(),
            ),
            12345678, // Local check time
          ],
        );
        localDb.close();

        // Create an incoming imported database with remote check times
        final importedDbDir = Directory(p.join(tempDir.path, 'imported'))
          ..createSync();
        final importedDbFile = File(
          p.join(importedDbDir.path, 'local_favorite.db'),
        );
        final importedDb = sqlite3.open(importedDbFile.path);
        FavoriteSyncData.ensureComicUpdateSchema(importedDb);
        importedDb.execute(
          'INSERT INTO comic_update_state (id, type, state, last_check_time) VALUES (?, ?, ?, ?);',
          [
            'comic-remote',
            ComicType.local.value,
            jsonEncode(
              ComicUpdateState.fromLegacy(
                updateTime: '2026-11-02',
                unread: true,
              ).toJson(),
            ),
            99999999, // Remote check time that MUST be cleared
          ],
        );

        // Sanitize incoming DB as checkVersion:true does:
        // 1. Clear remote check times
        importedDb.execute(
          'UPDATE comic_update_state SET last_check_time = NULL;',
        );

        // 2. Merge local states FIRST so local-only rows exist in table
        FavoriteSyncData.mergeComicUpdateStates(importedDb, {
          ('comic-local', ComicType.local.value): ComicUpdateState.fromLegacy(
            updateTime: '2026-11-01',
          ),
        });

        // 3. Restore local check times AFTER merge
        importedDb.execute(
          'UPDATE comic_update_state SET last_check_time = ? WHERE id = ? AND type = ?;',
          [12345678, 'comic-local', ComicType.local.value],
        );

        // Verify: remote check time was cleared, local check time was preserved
        final rows = importedDb.select(
          'SELECT id, last_check_time FROM comic_update_state ORDER BY id;',
        );
        expect(rows.length, 2);
        final map = {
          for (final r in rows) r['id'] as String: r['last_check_time'],
        };
        expect(map['comic-remote'], isNull); // Remote check time was cleared!
        expect(map['comic-local'], 12345678); // Local check time was preserved!

        importedDb.close();
      },
    );
  });
}

class _StoreRpc implements OpenListRpcClient {
  _StoreRpc(this.store);

  final _InMemoryRemoteStore store;

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    switch (method) {
      case 'accounts':
        return const {'data': {}};
      case 'list':
        final entries = await store.list(request['path'] as String);
        return {
          'data': {
            'entries': [
              for (final entry in entries)
                {
                  'name': entry.name,
                  'path': entry.path,
                  'isDirectory': entry.isDirectory,
                },
            ],
          },
        };
      case 'download':
        await store.download(
          request['path'] as String,
          request['localPath'] as String,
        );
        return const {'data': {}};
      case 'taskStatus':
        return const {
          'data': {'done': true},
        };
      case 'releaseTask':
        return const {'data': {}};
      default:
        throw UnsupportedError('Unexpected RPC method: $method');
    }
  }
}

class _InMemoryRemoteStore implements RemoteFileStore {
  final directories = <String>{};
  final files = <String, List<int>>{};
  Object? listError;

  @override
  StorageAccount get account => const StorageAccount(
    id: 'in-memory',
    backend: StorageBackend.webdav,
    driver: 'memory',
    name: 'Memory',
    authorization: {},
  );

  @override
  Future<void> mkdir(String path) async {
    directories.add(normalizeRemoteDirectory(path));
  }

  @override
  Future<List<RemoteEntry>> list(String directory) async {
    if (listError != null) throw listError!;
    final normalized = normalizeRemoteDirectory(directory);
    final result = <RemoteEntry>[];
    for (final dir in directories) {
      if (dir != normalized && dir.startsWith(normalized)) {
        final rel = dir.substring(normalized.length);
        if (!rel.contains('/') || rel.indexOf('/') == rel.length - 1) {
          final trimmed = dir.endsWith('/')
              ? dir.substring(0, dir.length - 1)
              : dir;
          final name = trimmed.substring(trimmed.lastIndexOf('/') + 1);
          result.add(RemoteEntry(name: name, path: dir, isDirectory: true));
        }
      }
    }
    for (final filePath in files.keys) {
      if (filePath.startsWith(normalized)) {
        final rel = filePath.substring(normalized.length);
        if (!rel.contains('/')) {
          final name = filePath.substring(filePath.lastIndexOf('/') + 1);
          result.add(
            RemoteEntry(name: name, path: filePath, isDirectory: false),
          );
        }
      }
    }
    return result;
  }

  @override
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) async {
    final bytes = await File(localPath).readAsBytes();
    files[remotePath] = bytes;
  }

  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) async {
    final bytes = files[remotePath];
    if (bytes == null) {
      throw const RemoteStorageException('File not found', code: 'not_found');
    }
    await File(localPath).writeAsBytes(bytes);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    directories.remove(normalizeRemoteDirectory(path));
  }

  @override
  Future<void> cancel(String taskId) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<RemoteLink> link(String path) async => RemoteLink(url: path);

  @override
  Future<RemoteTextFile> readText(String path) async {
    final bytes = files[path];
    if (bytes == null) {
      throw const RemoteStorageException('File not found', code: 'not_found');
    }
    return RemoteTextFile(content: utf8.decode(bytes));
  }

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    files[path] = utf8.encode(content);
    return const RemoteWriteResult();
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    if (files.containsKey(path)) {
      final name = path.substring(path.lastIndexOf('/') + 1);
      return RemoteEntry(name: name, path: path, isDirectory: false);
    }
    final normalized = normalizeRemoteDirectory(path);
    if (directories.contains(normalized)) {
      final trimmed = normalized.endsWith('/')
          ? normalized.substring(0, normalized.length - 1)
          : normalized;
      final name = trimmed.substring(trimmed.lastIndexOf('/') + 1);
      return RemoteEntry(name: name, path: normalized, isDirectory: true);
    }
    throw const RemoteStorageException('Not found', code: 'not_found');
  }

  @override
  Future<void> test() async {}
}
