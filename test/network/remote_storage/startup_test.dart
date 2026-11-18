import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  late Directory dataDir;
  late RemoteStorageAccounts storage;
  late _StartupRpc rpc;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('remote-startup-');
    App.dataPath = dataDir.path;
    appdata.settings.replaceAll({
      remoteStorageAccountsSetting: [_account.toJson()],
    });
    rpc = _StartupRpc();
    storage = RemoteStorageAccounts()
      ..configureOpenList(rpc, dataDir: dataDir.path);
  });

  tearDown(() async {
    storage.dispose();
    await dataDir.delete(recursive: true);
  });

  test('内核初始化前重新解析代理，不沿用应用启动时的地址', () async {
    String? proxy = '127.0.0.1:7890';
    storage.configureOpenList(
      rpc,
      dataDir: dataDir.path,
      proxy: proxy,
      proxyResolver: () async => proxy,
    );
    proxy = null;
    rpc.ready.complete(const {
      'data': {'ready': true},
    });
    await storage.ensureInitialized();
    expect(rpc.configurations.single.containsKey('proxy'), isFalse);
  });

  test('系统代理变化后网盘操作等待更新，并发操作共享代理更新', () async {
    String? proxy = '127.0.0.1:7890';
    storage.configureOpenList(
      rpc,
      dataDir: dataDir.path,
      proxyResolver: () async => proxy,
    );
    rpc.ready.complete(const {
      'data': {'ready': true},
    });
    await storage.ensureInitialized();
    expect(rpc.configurations.single['proxy'], 'http://127.0.0.1:7890');
    final store = storage.storeFor(_account.id);

    proxy = null;
    rpc.ready = Completer<Map<String, dynamic>>();
    final ready = storage.ensureInitialized();
    final listing = store.list('/');
    await pumpEventQueue();
    expect(rpc.configurations, hasLength(2));
    expect(rpc.configurations.last.containsKey('proxy'), isFalse);
    expect(rpc.calls, isNot(contains('list')));
    rpc.ready.complete(const {
      'data': {'ready': true},
    });
    await ready;
    expect(await listing, isEmpty);
    expect(rpc.configurations, hasLength(2));
    expect(
      rpc.calls.lastIndexOf('initialize'),
      lessThan(rpc.calls.indexOf('list')),
    );

    proxy = '127.0.0.1:7891';
    expect(await store.list('/other/'), isEmpty);
    expect(rpc.configurations, hasLength(3));
    expect(rpc.configurations.last['proxy'], 'http://127.0.0.1:7891');
    expect(rpc.calls.where((method) => method == 'accounts'), hasLength(1));
  });

  test('代理更新失败后保留账号并允许下次操作重试', () async {
    String? proxy = '127.0.0.1:7890';
    storage.configureOpenList(
      rpc,
      dataDir: dataDir.path,
      proxyResolver: () async => proxy,
    );
    rpc.ready.complete(const {
      'data': {'ready': true},
    });
    await storage.ensureInitialized();
    proxy = null;
    rpc.ready = Completer<Map<String, dynamic>>()
      ..complete(const {
        'error': {'code': 'unavailable', 'message': 'Offline'},
      });
    final store = storage.storeFor(_account.id);
    await expectLater(store.list('/'), throwsA(isA<RemoteStorageException>()));
    expect(rpc.calls, isNot(contains('list')));
    expect(storage.accounts.single.authorization['refresh_token'], 'rotated');

    rpc.ready = Completer<Map<String, dynamic>>()
      ..complete(const {
        'data': {'ready': true},
      });
    expect(await store.list('/'), isEmpty);
    expect(rpc.configurations, hasLength(3));
    expect(rpc.configurations.last.containsKey('proxy'), isFalse);
  });

  test(
    'concurrent operations share initialization and keep rotated tokens',
    () async {
      final ready = storage.ensureInitialized();
      final list = storage.storeFor(_account.id).list('/');
      final rename = storage.save(_account.copyWith(name: 'Renamed'));
      await rpc.started.future;
      expect(rpc.calls, ['initialize']);

      rpc.ready.complete(const {
        'data': {'ready': true},
      });
      await ready;
      expect(await list, isEmpty);
      final renamed = await rename;
      expect(rpc.calls.where((method) => method == 'initialize'), hasLength(1));
      expect(renamed.name, 'Renamed');
      expect(renamed.authorization['refresh_token'], 'rotated');
      expect(rpc.saved.single['addition'], {'refresh_token': 'rotated'});
    },
  );

  test('快照授权读取和合并在内核初始化期间完成', () async {
    final previous = _account.copyWith(
      status: StorageAuthorizationStatus.invalid,
    );
    appdata.settings[remoteStorageAccountsSetting] = [previous.toJson()];
    final imported = _account.copyWith(
      authorization: {'refresh_token': 'imported'},
    );
    final ready = storage.ensureInitialized();
    await rpc.started.future;
    try {
      final exported = await storage.beforeExportSettings().timeout(
        const Duration(seconds: 3),
      );
      expect(exported, [previous.toJson()]);
      await storage
          .mergeImportedSettings([imported.toJson()])
          .timeout(const Duration(seconds: 3));
      expect(storage.accounts.single.authorization, imported.authorization);
      expect(rpc.calls, ['initialize']);
    } finally {
      rpc.ready.complete(const {
        'data': {'ready': true},
      });
      await ready;
    }
    expect(await storage.beforeExportSettings(), [imported.toJson()]);
    expect(rpc.saved, isEmpty);
  });

  test('快照读取就绪内核已轮换的令牌', () async {
    rpc.ready.complete(const {
      'data': {'ready': true},
    });
    await storage.ensureInitialized();
    rpc.nativeRefreshToken = 'rotated-again';
    final unregistered = _account.copyWith(id: 'unregistered');
    appdata.settings[remoteStorageAccountsSetting] = [
      storage.accounts.single.toJson(),
      unregistered.toJson(),
    ];
    rpc.calls.clear();
    await storage.beforeExportSettings();
    expect(
      storage.account(_account.id)!.authorization['refresh_token'],
      'rotated-again',
    );
    expect(
      storage.account(unregistered.id)!.authorization,
      unregistered.authorization,
    );
    expect(rpc.calls, ['accounts']);
  });

  test('删除账号会等待内核初始化', () async {
    final removal = storage.remove(_account.id);
    await rpc.started.future;
    expect(rpc.calls, ['initialize']);

    rpc.ready.complete(const {
      'data': {'ready': true},
    });
    await removal;
    expect(storage.accounts, isEmpty);
    expect(rpc.calls, contains('deleteAccount'));
    expect(rpc.calls.where((method) => method == 'initialize'), hasLength(1));
  });

  test('multiple accounts wait for the same native initialization', () async {
    const other = StorageAccount(
      id: 'other',
      backend: StorageBackend.openlist,
      driver: 'Onedrive',
      name: 'Other drive',
      authorization: {'refresh_token': 'other-saved'},
    );
    appdata.settings[remoteStorageAccountsSetting] = [
      _account.toJson(),
      other.toJson(),
    ];
    final lists = [
      storage.storeFor(_account.id).list('/'),
      storage.storeFor(other.id).list('/'),
    ];
    await rpc.started.future;
    expect(rpc.calls, ['initialize']);
    rpc.ready.complete(const {
      'data': {'ready': true},
    });
    expect(await Future.wait(lists), [isEmpty, isEmpty]);
    expect(rpc.calls.where((method) => method == 'initialize'), hasLength(1));
    expect(rpc.saved.single['id'], other.id);
  });

  test(
    'saving during failed initialization retains entered credentials',
    () async {
      final saving = storage.save(
        _account.copyWith(authorization: {'refresh_token': 'entered'}),
      );
      await rpc.started.future;
      rpc.ready.complete(const {
        'error': {'code': 'unavailable', 'message': 'Offline'},
      });
      final saved = await saving;
      expect(saved.authorization['refresh_token'], 'entered');
      expect(saved.statusMessage, 'Offline');
      expect(storage.accounts.single.authorization, saved.authorization);
    },
  );

  test(
    'failed initialization can retry without losing saved authorization',
    () async {
      final operation = storage.storeFor(_account.id).list('/');
      final failed = expectLater(
        operation,
        throwsA(isA<RemoteStorageException>()),
      );
      await rpc.started.future;
      rpc.ready.complete(const {
        'error': {'code': 'unavailable', 'message': 'Offline'},
      });
      await failed;
      expect(storage.accounts.single.authorization, _account.authorization);
      expect(rpc.calls, ['initialize']);

      rpc.ready = Completer<Map<String, dynamic>>()
        ..complete(const {
          'data': {'ready': true},
        });
      expect(await storage.storeFor(_account.id).list('/'), isEmpty);
      expect(rpc.calls.where((method) => method == 'initialize'), hasLength(2));
    },
  );

  test(
    'cancelling while initializing never submits the queued operation',
    () async {
      final store = storage.storeFor(_account.id);
      final list = store.list('/');
      final cancelled = expectLater(
        list,
        throwsA(
          isA<RemoteStorageException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      await rpc.started.future;
      await store.cancelAll();
      rpc.ready.complete(const {
        'data': {'ready': true},
      });
      await cancelled;
      await storage.ensureInitialized();
      expect(rpc.calls, isNot(contains('list')));
      expect(rpc.calls, isNot(contains('cancel')));
      expect(rpc.calls, isNot(contains('releaseTask')));
    },
  );

  test(
    'closing during initialization waits and closes the completed core',
    () async {
      final ready = storage.ensureInitialized();
      await rpc.started.future;
      final close = storage.close();
      expect(rpc.calls, ['initialize']);
      rpc.ready.complete(const {
        'data': {'ready': true},
      });
      await ready;
      await close;
      expect(rpc.calls.last, 'close');
    },
  );

  test(
    'WebDAV configuration and links remain available while OpenList is pending',
    () async {
      final ready = storage.ensureInitialized();
      await rpc.started.future;
      try {
        final account = await storage.save(
          const StorageAccount(
            id: 'webdav',
            backend: StorageBackend.webdav,
            driver: 'webdav',
            name: 'WebDAV',
            authorization: {
              'url': 'https://example.com/dav/',
              'user': 'user',
              'password': 'password',
            },
          ),
        );
        final link = await storage.storeFor(account.id).link('/metadata.json');
        expect(link.url, 'https://example.com/dav/metadata.json');
        expect(rpc.calls, ['initialize']);
      } finally {
        rpc.ready.complete(const {
          'data': {'ready': true},
        });
        await ready;
      }
    },
  );
}

const _account = StorageAccount(
  id: 'drive',
  backend: StorageBackend.openlist,
  driver: 'GoogleDrive',
  name: 'Drive',
  authorization: {'refresh_token': 'saved'},
);

class _StartupRpc implements OpenListRpcClient {
  final started = Completer<void>();
  var ready = Completer<Map<String, dynamic>>();
  final calls = <String>[];
  final saved = <Map<String, dynamic>>[];
  final configurations = <Map<String, dynamic>>[];
  var nativeRefreshToken = 'rotated';

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    calls.add(method);
    if (method == 'initialize') {
      configurations.add(Map.of(request));
      if (!started.isCompleted) started.complete();
      return ready.future;
    }
    if (method == 'accounts') {
      return {
        'data': {
          'accounts': [
            {
              'id': _account.id,
              'addition': {'refresh_token': nativeRefreshToken},
            },
          ],
        },
      };
    }
    if (method == 'saveAccount') saved.add(request);
    return const {
      'data': {'entries': []},
    };
  }
}
