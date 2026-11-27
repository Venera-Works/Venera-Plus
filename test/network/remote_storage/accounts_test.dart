import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/appdata_sync_policy.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  late Directory dataDir;
  late RemoteStorageAccounts storage;
  late Map<String, dynamic> previousImplicitData;
  final cancelled = throwsA(
    isA<RemoteStorageException>().having(
      (error) => error.code,
      'code',
      'cancelled',
    ),
  );

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('venera-remote-accounts-');
    App.dataPath = dataDir.path;
    appdata.settings.replaceAll({});
    previousImplicitData = appdata.implicitData;
    appdata.implicitData = {};
    storage = RemoteStorageAccounts();
  });

  tearDown(() async {
    storage.dispose();
    appdata.implicitData = previousImplicitData;
    await dataDir.delete(recursive: true);
  });

  test('115 新建漫画库默认手动更新，保留已有库明确开启的设置', () {
    const account115 = StorageAccount(
      id: 'account',
      backend: StorageBackend.openlist,
      driver: '115 Open',
      name: '115',
      authorization: {'access_token': 'access', 'refresh_token': 'refresh'},
    );
    appdata.settings[remoteStorageAccountsSetting] = [account115.toJson()];
    final library = RemoteComicLibraryRegistry.create(
      accountId: account115.id,
      directories: ['/Comics'],
      name: '115 漫画',
    );
    expect(library.autoRefresh, isFalse);
    expect(
      RemoteLibrary.fromJson(
        library.copyWith(autoRefresh: true).toJson(),
      ).autoRefresh,
      isTrue,
    );
  });

  test('限流跨用途与重启生效，并写入本机冷却时间', () async {
    final rpc = _RateLimitedRpc();
    storage.configureOpenList(rpc);
    appdata.settings[remoteStorageAccountsSetting] = [_account.toJson()];
    final browsing = storage.open(_account);
    final sync = storage.open(_account);
    await expectLater(
      browsing.list('/Comics/'),
      throwsA(isA<RemoteStorageException>()),
    );
    await expectLater(
      sync.readText('/sync.json'),
      throwsA(
        isA<RemoteStorageException>().having(
          (error) => error.retryAt,
          '冷却时间',
          isNotNull,
        ),
      ),
    );
    final persisted =
        jsonDecode(
              await File('${dataDir.path}/implicitData.json').readAsString(),
            )
            as Map;
    expect(
      (persisted['remoteStorageCooldowns'] as Map)[_account.id],
      isA<int>(),
    );
    appdata.implicitData = Map<String, dynamic>.from(persisted);
    final restarted = RemoteStorageAccounts(openListRpc: rpc);
    await expectLater(
      restarted.open(_account).link('/cover.jpg'),
      throwsA(isA<RemoteStorageException>()),
    );
    restarted.dispose();
    expect(rpc.operations, 1);
  });

  test('账号存储手动刷新缓存目录后返回新增文件并更新后续列表', () async {
    final rpc = _CachedDirectoryRpc();
    storage.configureOpenList(rpc);
    appdata.settings[remoteStorageAccountsSetting] = [_account.toJson()];
    final store = storage.storeFor(_account.id);
    addTearDown(() => storage.release(store));

    final initial = await store.list('/Comics');
    expect(initial.map((entry) => entry.name), ['已有.cbz']);

    rpc.files.add('新增.cbz');
    final cached = await store.list('/Comics/');
    expect(cached.map((entry) => entry.name), ['已有.cbz']);

    final refreshed = await store.list('/Comics', refresh: true);
    expect(refreshed.map((entry) => entry.path), [
      '/Comics/已有.cbz',
      '/Comics/新增.cbz',
    ]);
    expect(refreshed.every((entry) => !entry.isDirectory), isTrue);
    final afterRefresh = await store.list('/Comics/');
    expect(afterRefresh.map((entry) => entry.name), ['已有.cbz', '新增.cbz']);
  });

  test('saves the first library when no library setting exists', () async {
    appdata.settings[remoteStorageAccountsSetting] = [_account.toJson()];
    expect(appdata.settings[remoteLibrariesSetting], isNull);

    final library = await storage.saveLibrary(
      const RemoteLibrary(
        id: '',
        sourceKey: '',
        accountId: 'account',
        directories: ['/Comics'],
        name: 'Comics',
      ),
    );

    expect(library.id, isNotEmpty);
    expect(library.sourceKey, 'remote_library_${library.id}');
    expect(library.directories, ['/Comics/']);
    expect(storage.libraries.single.toJson(), library.toJson());
    final saved =
        jsonDecode(await File('${dataDir.path}/appdata.json').readAsString())
            as Map<String, dynamic>;
    expect(saved['settings'][remoteLibrariesSetting], [library.toJson()]);
  });

  test('saves the first account when no account setting exists', () async {
    expect(appdata.settings[remoteStorageAccountsSetting], isNull);

    await storage.save(_account);

    expect(storage.accounts.single.toJson(), _account.toJson());
    final saved =
        jsonDecode(await File('${dataDir.path}/appdata.json').readAsString())
            as Map<String, dynamic>;
    expect(saved['settings'][remoteStorageAccountsSetting], [
      _account.toJson(),
    ]);
  });

  test('account names are unique when adding and renaming', () async {
    await storage.save(_account);
    await expectLater(
      storage.save(_account.copyWith(id: '', name: ' drive ')),
      throwsArgumentError,
    );
    final other = _account.copyWith(id: 'other', name: 'Other');
    await storage.save(other);
    await expectLater(
      storage.save(other.copyWith(name: 'DRIVE')),
      throwsArgumentError,
    );
    await storage.save(_account.copyWith(name: ' Drive '));
    expect(storage.accounts, hasLength(2));
    expect(storage.account(_account.id)?.name, 'Drive');
    expect(storage.availableName('Drive'), 'Drive (2)');
    expect(storage.account(other.id)?.name, 'Other');
  });

  for (final localWinsId in [false, true]) {
    test(
      'name merge preserves library identities and paths, local id wins=$localWinsId',
      () async {
        final local = _account.copyWith(
          id: localWinsId ? 'a-local' : 'z-local',
        );
        final incoming = local.copyWith(
          id: localWinsId ? 'z-remote' : 'a-remote',
          authorization: {'refresh_token': 'remote'},
        );
        final canonicalId = localWinsId ? local.id : incoming.id;
        appdata.settings[remoteStorageAccountsSetting] = [local.toJson()];
        final captured = storage.captureLocalAccounts();
        appdata.settings.replaceAll({
          remoteStorageAccountsSetting: [incoming.toJson()],
          'syncRemoteLocation': {
            'accountId': local.id,
            'directory': '/Local sync/',
          },
          'backupRemoteLocation': {
            'accountId': incoming.id,
            'directory': '/漫画 100%/CBZ/',
          },
          remoteLibrariesSetting: [
            {
              'id': 'local-library',
              'sourceKey': 'local-source',
              'accountId': local.id,
              'directories': ['/Local/'],
              'name': 'Local library',
            },
            {
              'id': 'remote-library',
              'sourceKey': 'remote-source',
              'accountId': incoming.id,
              'directories': ['/Remote/'],
              'name': 'Remote library',
            },
          ],
        });
        await storage.mergeImportedSettings([
          incoming.toJson(),
        ], localBeforeImport: captured);
        final expectedLibraries = [
          for (final library
              in appdata.settings[remoteLibrariesSetting] as List)
            Map<String, dynamic>.from(library as Map),
        ];
        expect(storage.accounts.single.id, canonicalId);
        expect(storage.accounts.single.authorization, local.authorization);
        expect(appdata.settings['syncRemoteLocation'], {
          'accountId': canonicalId,
          'directory': '/Local sync/',
        });
        expect(appdata.settings['backupRemoteLocation'], {
          'accountId': canonicalId,
          'directory': '/漫画 100%/CBZ/',
        });
        expect(storage.libraries.map((library) => library.id), [
          'local-library',
          'remote-library',
        ]);
        expect(storage.libraries.map((library) => library.sourceKey), [
          'local-source',
          'remote-source',
        ]);
        expect(
          storage.libraries.every(
            (library) => library.accountId == canonicalId,
          ),
          isTrue,
        );
        expect(storage.libraries.map((library) => library.directories.single), [
          '/Local/',
          '/Remote/',
        ]);
        await storage.mergeImportedSettings([incoming.toJson()]);
        await appdata.loadDataForTesting(dataDir.path);
        expect(storage.accounts.single.id, canonicalId);
        expect(storage.accounts.single.authorization, local.authorization);
        expect(appdata.settings[remoteLibrariesSetting], expectedLibraries);
      },
    );
  }

  test('恢复快照会移除已删除的账号、连接、备份引用和内核挂载', () async {
    final retained = _account.copyWith(id: 'retained', name: 'Retained');
    final listStarted = Completer<String>();
    final listResponse = Completer<Map<String, dynamic>>();
    final rpc =
        _MergeRpc(
            onList: (request) {
              listStarted.complete(request['taskId'] as String);
              return listResponse.future;
            },
          )
          ..values.addAll({
            _account.id: _account.authorization,
            retained.id: retained.authorization,
          });
    storage.configureOpenList(rpc, dataDir: dataDir.path);
    appdata.settings[remoteStorageAccountsSetting] = [
      _account.toJson(),
      retained.toJson(),
    ];
    await storage.ensureInitialized();
    final scheduler = storage.readSchedulerFor(_account);
    final listing = expectLater(
      storage.storeFor(_account.id).list('/'),
      cancelled,
    );
    final taskId = await listStarted.future;
    try {
      rpc.calls.clear();
      rpc.values.addAll({
        'deleted-alias': _account.authorization,
        'retained-alias': retained.authorization,
      });
      appdata.settings[appdataPendingOpenListAccountsKey] = {
        _account.id: ['deleted-alias', 'retained-alias'],
        retained.id: ['retained-alias'],
      };
      appdata.settings['backupRemoteLocation'] = {
        'accountId': _account.id,
        'directory': '/Backup/',
      };
      final changes = <List<String>>[];
      storage.addListener(() {
        changes.add(storage.accounts.map((item) => item.id).toList());
      });

      await storage.mergeImportedSettings([retained.toJson()]);

      expect(storage.accounts.single.toJson(), retained.toJson());
      expect(storage.readSchedulerFor(_account), isNot(same(scheduler)));
      expect(appdata.settings['backupRemoteLocation'], isNull);
      expect(changes, [
        [retained.id],
      ]);
      expect(rpc.calls.map((call) => [call.$1, call.$2]), [
        [
          'cancel',
          {'accountId': _account.id, 'taskId': taskId},
        ],
        [
          'cancelAccount',
          {'accountId': _account.id},
        ],
        [
          'deleteAccount',
          {'id': _account.id},
        ],
        [
          'cancelAccount',
          {'accountId': 'deleted-alias'},
        ],
        [
          'deleteAccount',
          {'id': 'deleted-alias'},
        ],
      ]);
      expect(rpc.values.keys, unorderedEquals([retained.id, 'retained-alias']));
      expect(appdata.settings[appdataPendingOpenListAccountsKey], {
        retained.id: ['retained-alias'],
      });
      await appdata.loadDataForTesting(dataDir.path);
      expect(storage.accounts.single.toJson(), retained.toJson());
      expect(appdata.settings['backupRemoteLocation'], isNull);
    } finally {
      listResponse.complete(const {'data': {}});
      await listing;
    }
  });

  test('删除账号的快照在内核初始化期间也能导入并取消等待中的操作', () async {
    final initializationGate = Completer<void>();
    final rpc = _MergeRpc(initializationGate: initializationGate.future)
      ..values[_account.id] = _account.authorization;
    storage.configureOpenList(rpc, dataDir: dataDir.path);
    appdata.settings[remoteStorageAccountsSetting] = [_account.toJson()];
    final initialized = storage.ensureInitialized();
    final listing = expectLater(
      storage.storeFor(_account.id).list('/'),
      cancelled,
    );
    const timeout = Duration(seconds: 3);
    try {
      await storage.mergeImportedSettings([]).timeout(timeout);
      await listing.timeout(timeout);
      expect(storage.accounts, isEmpty);
      expect(rpc.calls.map((call) => call.$1), ['initialize']);
    } finally {
      initializationGate.complete();
      await initialized;
    }
    expect(rpc.calls.map((call) => call.$1), [
      'initialize',
      'accounts',
      'deleteAccount',
    ]);
    expect(rpc.values, isEmpty);
  });

  for (final hasIncomingAccount in [false, true]) {
    test('恢复快照时保留本机同步账号，快照有账号=$hasIncomingAccount', () async {
      final localSync = _account.copyWith(id: 'local-sync', name: 'Local sync');
      final remote = _account.copyWith(id: 'remote', name: 'Remote');
      final syncLocation = {'accountId': localSync.id, 'directory': '/Sync/'};
      appdata.settings[remoteStorageAccountsSetting] = [
        localSync.toJson(),
        _account.toJson(),
      ];
      appdata.settings['syncRemoteLocation'] = syncLocation;

      await storage.mergeImportedSettings([
        if (hasIncomingAccount) remote.toJson(),
      ]);

      expect(storage.accounts.map((item) => item.toJson()), [
        localSync.toJson(),
        if (hasIncomingAccount) remote.toJson(),
      ]);
      expect(appdata.settings['syncRemoteLocation'], syncLocation);
    });
  }

  test('快照中的账号改名时按 ID 匹配并移除本机同名旧账号', () async {
    final alpha = _account.copyWith(id: 'x', name: 'Alpha');
    final beta = _account.copyWith(
      id: 'y',
      name: 'Beta',
      authorization: {'refresh_token': 'other'},
    );
    appdata.settings[remoteStorageAccountsSetting] = [
      alpha.toJson(),
      beta.toJson(),
    ];
    appdata.settings['backupRemoteLocation'] = {
      'accountId': beta.id,
      'directory': '/Backup/',
    };
    final renamed = alpha.copyWith(name: 'Beta');

    await storage.mergeImportedSettings([renamed.toJson()]);

    expect(storage.accounts.single.toJson(), renamed.toJson());
    expect(appdata.settings['backupRemoteLocation'], isNull);
  });

  test('恢复后的账号在首次使用时应用最新授权并清理旧挂载', () async {
    const local = StorageAccount(
      id: 'z-local',
      backend: StorageBackend.openlist,
      driver: '123 Open',
      name: '123 Drive',
      authorization: {'refresh_token': 'local', 'token_updated_at': 1},
    );
    final incoming = local.copyWith(
      id: 'a-remote',
      authorization: {'refresh_token': 'remote', 'token_updated_at': 2},
    );
    final rotated = {'refresh_token': 'rotated', 'token_updated_at': 3};
    final rpc = _MergeRpc()..values[local.id] = rotated;
    storage.configureOpenList(rpc, dataDir: dataDir.path);
    appdata.settings[remoteStorageAccountsSetting] = [incoming.toJson()];
    await storage.mergeImportedSettings(
      [incoming.toJson()],
      localBeforeImport: [local],
    );
    expect(storage.accounts.single.id, incoming.id);
    expect(storage.accounts.single.authorization, incoming.authorization);
    expect(rpc.values, {local.id: rotated});

    await appdata.loadDataForTesting(dataDir.path);
    expect(await storage.storeFor(incoming.id).list('/'), isEmpty);
    expect(rpc.values, {incoming.id: rotated});
    expect(storage.accounts.single.authorization, rotated);
  });

  test(
    'replacing QuarkOpen keeps account references and requires the same provider',
    () async {
      const previous = StorageAccount(
        id: 'quark',
        backend: StorageBackend.openlist,
        driver: 'QuarkOpen',
        name: 'Quark',
        authorization: {'refresh_token': 'old'},
      );
      await storage.save(previous);
      appdata.settings['syncRemoteLocation'] = {
        'accountId': previous.id,
        'directory': '/Comics/',
      };
      final replacement = StorageAccount(
        id: previous.id,
        backend: previous.backend,
        driver: 'Quark',
        name: previous.name,
        authorization: const {'cookie': '__pus=session; __puus=secret'},
      );
      await storage.save(replacement);
      expect(storage.accounts.single.toJson(), replacement.toJson());
      expect(appdata.settings['syncRemoteLocation']['accountId'], previous.id);
      await expectLater(storage.save(previous), throwsArgumentError);
      expect(storage.accounts.single.driver, 'Quark');
    },
  );

  test(
    'legacy WebDAV locations reuse accounts and preserve remote paths',
    () async {
      const account = StorageAccount(
        id: 'shared-webdav',
        backend: StorageBackend.webdav,
        driver: 'webdav',
        name: 'Shared WebDAV',
        authorization: {
          'url': 'https://example.com/dav',
          'user': 'user',
          'password': 'password',
        },
      );
      await storage.save(account);
      for (final key in ['webdav', 'backupWebdav']) {
        appdata.settings[key] = [
          'https://example.com/dav/',
          ' user ',
          'password',
        ];
      }
      appdata.settings['backupWebdavPath'] = '/漫画 100%/CBZ/';
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts.single.toJson(), account.toJson());
      expect(appdata.settings['syncRemoteLocation'], {
        'accountId': account.id,
        'directory': '/VeneraPlus/',
      });
      expect(appdata.settings['backupRemoteLocation'], {
        'accountId': account.id,
        'directory': '/漫画 100%/CBZ/',
      });
      await storage.migrateLegacyWebDavLocations();
      await appdata.loadDataForTesting(dataDir.path);
      expect(storage.accounts.single.toJson(), account.toJson());
      expect(
        appdata.settings['backupRemoteLocation']['directory'],
        '/漫画 100%/CBZ/',
      );
      await storage.remove(account.id);
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, isEmpty);
      expect(appdata.settings['webdav'], isEmpty);
      expect(appdata.settings['backupWebdav'], isEmpty);
    },
  );

  test(
    'legacy migration keeps distinct credentials and explicit destinations',
    () async {
      appdata.settings['webdav'] = ['https://example.com/dav', 'user', 'one'];
      appdata.settings['backupWebdav'] = [
        'https://example.com/dav',
        'user',
        'two',
      ];
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, hasLength(2));
      final syncAccountId = appdata.settings['syncRemoteLocation']['accountId'];
      expect(storage.account(syncAccountId)?.name, 'WebDAV同步');
      final destination = Map<String, dynamic>.from(
        appdata.settings['syncRemoteLocation'],
      );
      appdata.settings['webdav'] = ['https://other.example.com', 'new', 'new'];
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, hasLength(2));
      expect(appdata.settings['syncRemoteLocation'], destination);
    },
  );

  for (final sharedCredentials in [false, true]) {
    test(
      'legacy library and sync get distinct names, shared=$sharedCredentials',
      () async {
        appdata.settings['webdavComicLibrary'] = [
          'https://example.com/dav',
          'user',
          'library-password',
        ];
        appdata.settings['webdavComicLibraryPath'] = '/漫画/';
        appdata.settings['webdav'] = [
          'https://example.com/dav',
          'user',
          sharedCredentials ? 'library-password' : 'sync-password',
        ];

        await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
        await storage.migrateLegacyWebDavLocations();

        final library = storage.libraries.single;
        final sync = RemoteLocation.fromJson(
          appdata.settings['syncRemoteLocation'],
        );
        expect(storage.accounts, hasLength(2));
        expect(storage.account(library.accountId)?.name, 'WebDAV漫画库');
        expect(storage.account(sync.accountId)?.name, 'WebDAV同步');
        expect(sync.accountId, isNot(library.accountId));
        expect(library.directories, ['/漫画/']);
        expect(sync.directory, '/VeneraPlus/');
        final before = storage.accounts.map((a) => a.toJson()).toList();
        await RemoteComicLibraryRegistry.migrateLegacyRemoteLibrary();
        await storage.migrateLegacyWebDavLocations();
        await appdata.loadDataForTesting(dataDir.path);
        expect(storage.accounts.map((a) => a.toJson()).toList(), before);
      },
    );
  }

  test(
    'repairs a missing sync account from retained legacy credentials',
    () async {
      appdata.settings['legacyWebDavAccountNamesMigrated'] = true;
      appdata.settings['webdav'] = ['https://example.com/dav', 'user', 'pass'];
      final location = {
        'accountId': 'lost-sync',
        'directory': '/Existing sync/',
      };
      appdata.settings['syncRemoteLocation'] = location;

      await storage.migrateLegacyWebDavLocations();

      expect(appdata.settings['syncRemoteLocation'], location);
      expect(storage.account('lost-sync')?.authorization, {
        'url': 'https://example.com/dav',
        'user': 'user',
        'password': 'pass',
      });
      expect(storage.account('lost-sync')?.name, 'WebDAV同步');
    },
  );

  test(
    'repairs previously migrated shared account without changing library ids',
    () async {
      const account = StorageAccount(
        id: 'legacy-library-account',
        backend: StorageBackend.webdav,
        driver: 'webdav',
        name: 'WebDAV',
        authorization: {
          'url': 'https://example.com/dav',
          'user': 'user',
          'password': 'pass',
        },
        status: StorageAuthorizationStatus.invalid,
        statusMessage: 'Existing authorization error',
      );
      await storage.save(account);
      final library = await storage.saveLibrary(
        RemoteLibrary(
          id: 'library',
          sourceKey: 'webdav_library',
          accountId: account.id,
          directories: ['/Comics/'],
          name: 'Library',
        ),
      );
      appdata.settings['syncRemoteLocation'] = {
        'accountId': account.id,
        'directory': '/Existing sync/',
      };

      await storage.migrateLegacyWebDavLocations();

      final sync = RemoteLocation.fromJson(
        appdata.settings['syncRemoteLocation'],
      );
      final syncAccount = storage.account(sync.accountId)!;
      expect(storage.libraries.single.toJson(), library.toJson());
      expect(storage.account(account.id)?.name, 'WebDAV漫画库');
      expect(syncAccount.name, 'WebDAV同步');
      expect(syncAccount.authorization, account.authorization);
      expect(syncAccount.status, account.status);
      expect(syncAccount.statusMessage, account.statusMessage);
      expect(sync.directory, '/Existing sync/');
      expect(sync.accountId, isNot(account.id));
      await storage.migrateLegacyWebDavLocations();
      expect(storage.accounts, hasLength(2));
      expect(
        appdata.settings['syncRemoteLocation']['accountId'],
        sync.accountId,
      );
    },
  );

  test(
    'repairs separate default names once and preserves user account names',
    () async {
      for (final (id, name) in [('sync', 'WebDAV'), ('custom', 'My WebDAV')]) {
        await storage.save(
          StorageAccount(
            id: id,
            backend: StorageBackend.webdav,
            driver: 'webdav',
            name: name,
            authorization: const {},
          ),
        );
      }
      appdata.settings['syncRemoteLocation'] = {
        'accountId': 'sync',
        'directory': '/sync/',
      };
      await storage.migrateLegacyWebDavLocations();
      expect(storage.account('sync')?.name, 'WebDAV同步');
      expect(storage.account('custom')?.name, 'My WebDAV');

      await storage.save(storage.account('sync')!.copyWith(name: 'WebDAV'));
      await storage.migrateLegacyWebDavLocations();
      expect(storage.account('sync')?.name, 'WebDAV');
    },
  );
}

const _account = StorageAccount(
  id: 'account',
  backend: StorageBackend.openlist,
  driver: 'GoogleDrive',
  name: 'Drive',
  authorization: {'refresh_token': 'refresh'},
);

class _RateLimitedRpc implements OpenListRpcClient {
  var operations = 0;
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    if (method == 'list' || method == 'link' || method == 'readText') {
      operations++;
      return const {
        'error': {
          'code': 'operation_failed',
          'message': 'HTTP 429 Too Many Requests',
        },
      };
    }
    return const {'data': {}};
  }
}

class _CachedDirectoryRpc implements OpenListRpcClient {
  final files = ['已有.cbz'];
  final _cache = <String, List<Map<String, dynamic>>>{};

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    if (method != 'list') return const {'data': {}};
    final directory = request['path'] as String;
    if (request['refresh'] == true || !_cache.containsKey(directory)) {
      _cache[directory] = [
        for (final name in files)
          {'name': name, 'path': '$directory$name', 'isDirectory': false},
      ];
    }
    return {
      'data': {'entries': _cache[directory]},
    };
  }
}

class _MergeRpc implements OpenListRpcClient {
  _MergeRpc({this.initializationGate, this.onList});

  final Future<void>? initializationGate;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>)? onList;
  final values = <String, Map<String, dynamic>>{};
  final calls = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    calls.add((method, request));
    if (method == 'initialize') await initializationGate;
    final list = onList;
    if (method == 'list' && list != null) return list(request);
    if (method == 'accounts') {
      return {
        'data': {
          'accounts': [
            for (final entry in values.entries)
              {'id': entry.key, 'addition': entry.value},
          ],
        },
      };
    }
    if (method == 'saveAccount') {
      values[request['id'] as String] = Map<String, dynamic>.from(
        request['addition'] as Map,
      );
    } else if (method == 'deleteAccount') {
      values.remove(request['id']);
    }
    return const {'data': {}};
  }
}
