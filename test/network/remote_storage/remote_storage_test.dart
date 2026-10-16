import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/storage/token_import.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  test('normalizes roots without collapsing parent child or case', () {
    expect(normalizeRemoteDirectories(['/A', '/B/C/', '/A/', '/a', '/封面%/']), [
      '/A/',
      '/B/C/',
      '/a/',
      '/封面%/',
    ]);
  });

  test('imports provider token forms into driver fields', () {
    for (final driver in openListSupportedDrivers) {
      if (driver == 'Quark') continue;
      final value = parseOpenListAuthorization(
        '{"access_token":"access","refresh_token":"refresh","client_uid":"id","client_key":"secret","app_id":"app","sign_key":"sign"}',
        driver: driver,
      );
      if (driver == '123 Open') {
        expect(value['AccessToken'], 'access');
        expect(value['RefreshToken'], 'refresh');
        expect(value['driver_txt'], '123cloud_oa');
      } else if (driver != 'BaiduNetdisk') {
        expect(value['client_id'], 'id');
        expect(value['client_secret'], 'secret');
      }
    }
  });

  test('canonicalizes Pascal tokens', () {
    final google = normalizeOpenListAuthorization({
      'AccessToken': 'old',
      'access_token': 'rotated',
      'RefreshToken': 'refresh',
    }, driver: 'GoogleDrive');
    expect(google['access_token'], 'rotated');
    expect(google.containsKey('AccessToken'), isFalse);

    final baidu = normalizeOpenListAuthorization({
      'access_token': 'new',
      'AccessToken': 'old',
      'refresh_token': 'refresh',
    }, driver: 'BaiduNetdisk');
    expect(baidu['AccessToken'], 'new');
    expect(baidu.containsKey('access_token'), isFalse);
  });

  test('official online API accounts only need a refresh token', () {
    for (final driver in [
      'BaiduNetdisk',
      '123 Open',
      'Onedrive',
      'GoogleDrive',
    ]) {
      final value = buildOpenListAuthorization(
        driver: driver,
        accessToken: '',
        refreshToken: ' refresh ',
      );
      expect(value['use_online_api'], isTrue);
      expect(
        value[driver == '123 Open' ? 'RefreshToken' : 'refresh_token'],
        'refresh',
      );
      expect(value.containsKey('client_id'), isFalse);
      expect(value.containsKey('ClientID'), isFalse);
    }
  });

  test('Quark uses Cookie authorization and preserves the root folder', () {
    final value = parseOpenListAuthorization(
      '{"Cookie":"__pus=old","root_folder_id":"123"}',
      driver: 'Quark',
    );
    expect(
      buildOpenListAuthorization(
        driver: 'Quark',
        accessToken: '',
        refreshToken: '',
        cookie: ' __pus=new; __puus=secret ',
        authorization: value,
      ),
      {'cookie': '__pus=new; __puus=secret', 'root_folder_id': '123'},
    );
  });

  test('edited tokens replace old aliases and retain account settings', () {
    for (final driver in ['BaiduNetdisk', '123 Open']) {
      final value = buildOpenListAuthorization(
        driver: driver,
        accessToken: '',
        refreshToken: 'new-refresh',
        authorization: const {
          'AccessToken': 'old-access',
          'RefreshToken': 'old-refresh',
          'root_folder_id': 'folder',
          'use_online_api': false,
        },
      );
      expect(value.values, isNot(contains('old-access')));
      expect(value.values, isNot(contains('old-refresh')));
      expect(value['root_folder_id'], 'folder');
      expect(value['use_online_api'], isFalse);
      expect(
        value[driver == '123 Open' ? 'RefreshToken' : 'refresh_token'],
        'new-refresh',
      );
    }
  });

  test('only explicit authentication errors invalidate an authorization', () {
    expect(
      const RemoteStorageException(
        'expired',
        code: '401',
      ).isAuthorizationFailure,
      isTrue,
    );
    expect(
      const RemoteStorageException(
        'denied',
        code: 'invalid_token',
      ).isAuthorizationFailure,
      isTrue,
    );
    expect(
      const RemoteStorageException(
        'directory denied',
        code: '403',
      ).isAuthorizationFailure,
      isFalse,
    );
  });

  test('invalid local account accepts matching imported credentials only', () {
    const local = StorageAccount(
      id: 'same',
      backend: StorageBackend.openlist,
      driver: 'GoogleDrive',
      name: 'old',
      authorization: {'refresh_token': 'expired'},
      status: StorageAuthorizationStatus.invalid,
    );
    const incoming = StorageAccount(
      id: 'same',
      backend: StorageBackend.openlist,
      driver: 'GoogleDrive',
      name: 'new',
      authorization: {'refresh_token': 'fresh'},
      status: StorageAuthorizationStatus.valid,
    );
    const mismatched = StorageAccount(
      id: 'same',
      backend: StorageBackend.openlist,
      driver: 'Onedrive',
      name: 'wrong',
      authorization: {'refresh_token': 'wrong'},
      status: StorageAuthorizationStatus.valid,
    );
    final accepted = mergeRemoteStorageAccounts([local], [incoming]).single;
    expect(accepted.authorization['refresh_token'], 'fresh');
    expect(accepted.driver, 'GoogleDrive');
    final rejected = mergeRemoteStorageAccounts([local], [mismatched]).single;
    expect(rejected.authorization['refresh_token'], 'expired');
    expect(rejected.driver, 'GoogleDrive');
  });

  test('native rotated credentials clear stale invalid status', () {
    const stale = StorageAccount(
      id: 'same',
      backend: StorageBackend.openlist,
      driver: 'GoogleDrive',
      name: 'Drive',
      authorization: {'refresh_token': 'old'},
      status: StorageAuthorizationStatus.invalid,
    );
    final refreshed = applyNativeAuthorization(stale, {'refresh_token': 'new'});
    expect(refreshed.status, StorageAuthorizationStatus.unknown);
    expect(refreshed.authorization['refresh_token'], 'new');
  });

  test('native default fields do not clear invalid authorization status', () {
    const stale = StorageAccount(
      id: 'same',
      backend: StorageBackend.openlist,
      driver: '123 Open',
      name: 'Drive',
      authorization: {'AccessToken': 'access', 'RefreshToken': 'refresh'},
      status: StorageAuthorizationStatus.invalid,
    );
    final unchanged = applyNativeAuthorization(stale, {
      'AccessToken': 'access',
      'RefreshToken': 'refresh',
      'driver_txt': '123cloud_oa',
      'server_use': true,
    });
    expect(unchanged.status, StorageAuthorizationStatus.invalid);
    expect(unchanged.authorization['driver_txt'], '123cloud_oa');

    final refreshed = applyNativeAuthorization(stale, {
      'AccessToken': 'access',
      'RefreshToken': 'rotated',
      'driver_txt': '123cloud_oa',
    });
    expect(refreshed.status, StorageAuthorizationStatus.unknown);
  });

  test('transfer reports native error even when task is marked done', () async {
    final rpc = _Rpc();
    final store = OpenListFileStore(_account, rpc);
    await expectLater(
      store.upload('local', '/remote'),
      throwsA(isA<RemoteStorageException>()),
    );
    expect(rpc.transferTaskId, isNotEmpty);
    expect(rpc.released, isTrue);
  });

  test('cancelAll cancels caller generated task ids', () async {
    final rpc = _WaitingRpc();
    final store = OpenListFileStore(_account, rpc);
    final future = store.download('/remote', 'local');
    await Future<void>.delayed(Duration.zero);
    await store.cancelAll();
    expect(rpc.cancelled, isNotEmpty);
    await expectLater(future, throwsA(isA<RemoteStorageException>()));
  });

  test(
    'cancelAll retains early cancellation for list and text reads',
    () async {
      final rpc = _BlockingOperationRpc();
      final store = OpenListFileStore(_account, rpc);
      final list = store.list('/');
      final text = store.readText('/metadata.json');
      await Future<void>.delayed(Duration.zero);
      await store.cancelAll();
      expect(rpc.cancelled, containsAll(rpc.operationTasks));
      rpc.complete();
      await expectLater(list, throwsA(isA<RemoteStorageException>()));
      await expectLater(text, throwsA(isA<RemoteStorageException>()));
      for (final task in rpc.operationTasks) {
        expect(rpc.cancelled.where((item) => item == task), hasLength(1));
      }
      expect(rpc.released, containsAll(rpc.operationTasks));
    },
  );
}

const _account = StorageAccount(
  id: 'account',
  backend: StorageBackend.openlist,
  driver: 'GoogleDrive',
  name: 'Drive',
  authorization: {},
);

class _Rpc implements OpenListRpcClient {
  String? transferTaskId;
  var released = false;
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    if (method == 'upload') {
      transferTaskId = request['taskId'] as String;
      return const {'data': {}};
    }
    if (method == 'taskStatus') {
      return const {
        'data': {
          'done': true,
          'error': {'code': 'failed', 'message': 'failed'},
        },
      };
    }
    if (method == 'releaseTask') {
      released = true;
      return const {'data': {}};
    }
    return const {'data': {}};
  }
}

class _WaitingRpc implements OpenListRpcClient {
  final cancelled = <String>[];
  var _done = false;
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    if (method == 'download') return const {'data': {}};
    if (method == 'cancel') {
      cancelled.add(request['taskId'] as String);
      _done = true;
      return const {'data': {}};
    }
    if (method == 'taskStatus') {
      return {
        'data': {'done': _done},
      };
    }
    return const {'data': {}};
  }
}

class _BlockingOperationRpc implements OpenListRpcClient {
  final gate = Completer<void>();
  final operationTasks = <String>[];
  final cancelled = <String>[];
  final released = <String>[];

  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async {
    if (method == 'list' || method == 'readText') {
      operationTasks.add(request['taskId'] as String);
      await gate.future;
      return method == 'list'
          ? const {
              'data': {'entries': []},
            }
          : const {
              'data': {'content': '{}'},
            };
    }
    if (method == 'cancel') {
      cancelled.add(request['taskId'] as String);
      return const {'data': {}};
    }
    if (method == 'releaseTask') {
      released.add(request['taskId'] as String);
      return const {'data': {}};
    }
    return const {'data': {}};
  }

  void complete() => gate.complete();
}
