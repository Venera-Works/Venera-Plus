import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera_plus/foundation/appdata.dart';

import 'models.dart';
import 'openlist_rpc.dart';
import 'remote_file_store.dart';
import 'webdav_file_store.dart';
import '../webdav.dart';

const remoteStorageAccountsSetting = 'remoteStorageAccounts';
const remoteLibrariesSetting = 'remoteLibraries';

class RemoteStorageAccounts with ChangeNotifier {
  RemoteStorageAccounts({OpenListRpcClient? openListRpc})
    : _openListRpc = openListRpc;
  static final instance = RemoteStorageAccounts();
  OpenListRpcClient? _openListRpc;
  Future<void>? _initialization;
  String? _dataDir;
  final _uuid = const Uuid();
  final _activeStores = <String, Set<RemoteFileStore>>{};

  void configureOpenList(OpenListRpcClient rpc) => _openListRpc = rpc;

  Future<void> initialize({required String dataDir, String? proxy}) {
    final rpc = _openListRpc;
    if (rpc == null) return Future.value();
    return _initialization ??= _initialize(rpc, dataDir, proxy).catchError((
      Object error,
    ) {
      _initialization = null;
      throw error;
    });
  }

  Future<void> _initialize(
    OpenListRpcClient rpc,
    String dataDir,
    String? proxy,
  ) async {
    _dataDir = dataDir;
    _throwRpcError(
      await rpc.invoke('initialize', {
        'dataDir': dataDir,
        if (proxy != null && proxy.isNotEmpty)
          'proxy': proxy.contains('://') ? proxy : 'http://$proxy',
      }),
    );
    await _refreshNativeAccounts();
  }

  Future<void> updateProxy(String? proxy) async {
    final rpc = _openListRpc;
    final dataDir = _dataDir;
    if (rpc == null || dataDir == null) return;
    _throwRpcError(
      await rpc.invoke('initialize', {
        'dataDir': dataDir,
        if (proxy != null && proxy.isNotEmpty)
          'proxy': proxy.contains('://') ? proxy : 'http://$proxy',
      }),
    );
  }

  List<StorageAccount> get accounts => _readAccounts();
  List<RemoteLibrary> get libraries => _readLibraries();
  StorageAccount? account(String id) {
    for (final value in accounts) {
      if (value.id == id) return value;
    }
    return null;
  }

  Future<void> migrateLegacyWebDavLocations() async {
    final values = accounts;
    final legacyLibraryAccounts = libraries
        .where((library) => library.accountId.startsWith('legacy-'))
        .map((library) => library.accountId)
        .toSet();
    var changed = false;
    for (final (setting, locationKey, directory) in [
      ('webdav', 'syncRemoteLocation', '/VeneraPlus/'),
      (
        'backupWebdav',
        'backupRemoteLocation',
        appdata.settings['backupWebdavPath'] as String? ?? '/venera_backup/',
      ),
    ]) {
      final previousLocation = appdata.settings[locationKey];
      if (previousLocation is Map &&
          values.any((value) => value.id == previousLocation['accountId'])) {
        continue;
      }
      final raw = appdata.settings[setting];
      if (raw is! List ||
          raw.length != 3 ||
          raw.any((item) => item is! String)) {
        continue;
      }
      final endpoint = WebDavEndpoint(
        url: raw[0] as String,
        user: raw[1] as String,
        password: setting == 'backupWebdav'
            ? (raw[2] as String).trim()
            : raw[2] as String,
      );
      if (!endpoint.isValid) continue;
      StorageAccount? selected;
      for (final value in values.where(
        (a) => a.backend == StorageBackend.webdav,
      )) {
        if (setting == 'webdav' && legacyLibraryAccounts.contains(value.id)) {
          continue;
        }
        final existing = WebDavEndpoint(
          url: value.authorization['url'] as String? ?? '',
          user: value.authorization['user'] as String? ?? '',
          password: value.authorization['password'] as String? ?? '',
        );
        if (existing.url == endpoint.url &&
            existing.user == endpoint.user &&
            existing.password == endpoint.password) {
          selected = value;
          break;
        }
      }
      selected ??= StorageAccount(
        id:
            previousLocation is Map &&
                previousLocation['accountId'] is String &&
                (previousLocation['accountId'] as String).isNotEmpty
            ? previousLocation['accountId'] as String
            : _uuid.v4(),
        backend: StorageBackend.webdav,
        driver: 'webdav',
        name: setting == 'webdav' ? 'WebDAV同步' : 'WebDAV',
        authorization: {
          'url': endpoint.url,
          'user': endpoint.user,
          'password': endpoint.password,
        },
      );
      if (!values.any((a) => a.id == selected!.id)) values.add(selected);
      appdata.settings[locationKey] = RemoteLocation(
        accountId: selected.id,
        directory:
            previousLocation is Map && previousLocation['directory'] is String
            ? previousLocation['directory'] as String
            : directory,
      ).toJson();
      appdata.settings[setting] = const [];
      changed = true;
    }
    if (appdata.settings['legacyWebDavAccountNamesMigrated'] != true) {
      final syncLocation = appdata.settings['syncRemoteLocation'];
      for (var index = 0; index < values.length; index++) {
        final value = values[index];
        if (value.backend != StorageBackend.webdav || value.name != 'WebDAV') {
          continue;
        }
        final isLibrary = legacyLibraryAccounts.contains(value.id);
        final isSync =
            syncLocation is Map && syncLocation['accountId'] == value.id;
        if (!isLibrary && !isSync) continue;
        values[index] = value.copyWith(
          name: isLibrary ? 'WebDAV漫画库' : 'WebDAV同步',
        );
        if (isLibrary && isSync) {
          // The previous migration reused the library account for sync. Keep
          // the library identity and give the sync destination its own account.
          final syncAccount = StorageAccount(
            id: _uuid.v4(),
            backend: value.backend,
            driver: value.driver,
            name: 'WebDAV同步',
            authorization: value.authorization,
            status: value.status,
            statusMessage: value.statusMessage,
          );
          values.add(syncAccount);
          appdata.settings['syncRemoteLocation'] = {
            ...syncLocation,
            'accountId': syncAccount.id,
          };
        }
      }
      appdata.settings['legacyWebDavAccountNamesMigrated'] = true;
      changed = true;
    }
    if (!changed) return;
    appdata.settings[remoteStorageAccountsSetting] = values
        .map((value) => value.toJson())
        .toList();
    await appdata.saveData(false);
    notifyListeners();
  }

  Future<StorageAccount> save(StorageAccount value) async {
    var account = value.id.isEmpty
        ? StorageAccount(
            id: _uuid.v4(),
            backend: value.backend,
            driver: value.driver,
            name: value.name,
            authorization: value.authorization,
            status: value.status,
            statusMessage: value.statusMessage,
          )
        : value;
    var previous = this.account(account.id);
    final replacesQuarkOpen =
        previous?.backend == StorageBackend.openlist &&
        account.backend == StorageBackend.openlist &&
        previous?.driver == 'QuarkOpen' &&
        account.driver == 'Quark';
    if (previous != null &&
        (previous.backend != account.backend ||
            previous.driver != account.driver) &&
        !replacesQuarkOpen) {
      throw ArgumentError(
        'Storage account backend and driver cannot be changed',
      );
    }
    if (previous != null &&
        previous.backend == StorageBackend.openlist &&
        jsonEncode(previous.authorization) ==
            jsonEncode(account.authorization)) {
      await _refreshNativeAccounts();
      final refreshed = this.account(account.id);
      if (refreshed != null) {
        previous = refreshed;
        account = refreshed.copyWith(
          name: account.name,
          status: account.status,
          statusMessage: account.statusMessage,
          clearStatusMessage: account.statusMessage == null,
        );
      }
    }
    if (previous != null &&
        (previous.driver != account.driver ||
            previous.backend != account.backend ||
            jsonEncode(previous.authorization) !=
                jsonEncode(account.authorization))) {
      await _cancelStores(account.id);
    }
    final values = accounts.where((item) => item.id != account.id).toList()
      ..add(account);
    appdata.settings[remoteStorageAccountsSetting] = values
        .map((item) => item.toJson())
        .toList();
    await appdata.saveData();
    final rpc = _openListRpc;
    if (account.backend == StorageBackend.openlist && rpc != null) {
      final response = await rpc.invoke('saveAccount', {
        'id': account.id,
        'driver': account.driver,
        'name': account.name,
        'addition': account.authorization,
      });
      try {
        _throwRpcError(response);
      } on RemoteStorageException catch (error) {
        final pending = account.copyWith(
          status: StorageAuthorizationStatus.unknown,
          statusMessage: error.message,
        );
        appdata.settings[remoteStorageAccountsSetting] = [
          ...values
              .where((item) => item.id != pending.id)
              .map((item) => item.toJson()),
          pending.toJson(),
        ];
        await appdata.saveData(false);
        notifyListeners();
        return pending;
      }
    }
    notifyListeners();
    return account;
  }

  Future<void> remove(String id) async {
    final previous = account(id);
    await _cancelStores(id);
    final rpc = _openListRpc;
    if (previous?.backend == StorageBackend.openlist && rpc != null) {
      try {
        _throwRpcError(await rpc.invoke('cancelAccount', {'accountId': id}));
        _throwRpcError(await rpc.invoke('deleteAccount', {'id': id}));
      } catch (_) {}
    }
    appdata.settings[remoteStorageAccountsSetting] = accounts
        .where((item) => item.id != id)
        .map((item) => item.toJson())
        .toList();
    for (final key in const ['syncRemoteLocation', 'backupRemoteLocation']) {
      final value = appdata.settings[key];
      if (value is Map && value['accountId'] == id) {
        appdata.settings[key] = null;
      }
    }
    await appdata.saveData();
    notifyListeners();
  }

  RemoteFileStore storeFor(String accountId) {
    final value = account(accountId);
    if (value == null) {
      throw ArgumentError.value(
        accountId,
        'accountId',
        'Unknown storage account',
      );
    }
    final store = open(value);
    (_activeStores[accountId] ??= {}).add(store);
    return store;
  }

  void release(RemoteFileStore store) {
    _activeStores[store.account.id]?.remove(store);
  }

  /// Stops outstanding transfers and releases native OpenList drivers. The
  /// account manager remains reusable if this process later initializes again.
  Future<void> close() async {
    final stores = _activeStores.values.expand((items) => items).toList();
    _activeStores.clear();
    try {
      await Future.wait(stores.map((store) => store.cancelAll()));
    } finally {
      final rpc = _openListRpc;
      try {
        if (rpc != null) _throwRpcError(await rpc.invoke('close', const {}));
      } finally {
        _initialization = null;
        _dataDir = null;
      }
    }
  }

  Future<void> updateStatus(StorageAccount value) async {
    final current = account(value.id);
    if (current == null) return;
    final updated = current.copyWith(
      status: value.status,
      statusMessage: value.statusMessage,
      clearStatusMessage: value.statusMessage == null,
    );
    appdata.settings[remoteStorageAccountsSetting] = [
      ...accounts
          .where((item) => item.id != updated.id)
          .map((item) => item.toJson()),
      updated.toJson(),
    ];
    await appdata.saveData(false);
    notifyListeners();
  }

  RemoteFileStore open(StorageAccount account) {
    final delegate = switch (account.backend) {
      StorageBackend.webdav => WebDavFileStore(account),
      StorageBackend.openlist => OpenListFileStore(
        account,
        _openListRpc ?? _UnavailableOpenListRpc(),
      ),
    };
    return _StatusTrackingStore(delegate, _recordResult);
  }

  Future<void> _recordResult(StorageAccount account, Object? error) async {
    final current = this.account(account.id);
    if (current == null) return;
    StorageAccount? updated;
    if (error == null && current.authorizationIsKnownInvalid) {
      updated = current.copyWith(
        status: StorageAuthorizationStatus.valid,
        clearStatusMessage: true,
      );
    } else if (error is RemoteStorageException &&
        error.isAuthorizationFailure) {
      updated = current.copyWith(
        status: StorageAuthorizationStatus.invalid,
        statusMessage: error.message,
      );
    }
    if (updated != null) await updateStatus(updated);
  }

  Future<void> _cancelStores(String accountId) async {
    final stores =
        _activeStores.remove(accountId)?.toList() ?? const <RemoteFileStore>[];
    await Future.wait(stores.map((store) => store.cancelAll()));
  }

  /// Called by app-data export plumbing. It obtains rotated native additions,
  /// then exports only account credentials rather than OpenList's database.
  Future<List<Map<String, dynamic>>> beforeExportSettings() async {
    try {
      await _refreshNativeAccounts();
    } on RemoteStorageException {
      // Keep ordinary local/WebDAV backup export available while a pending
      // OpenList account cannot be reached.
    }
    return accounts.map((item) => item.toJson()).toList();
  }

  Future<void> _refreshNativeAccounts() async {
    final rpc = _openListRpc;
    if (rpc == null) return;
    final response = await rpc.invoke('accounts', const {});
    final data = response['data'];
    if (data is! Map || data['accounts'] is! List) return;
    final additions = <String, Map<String, dynamic>>{};
    for (final item in data['accounts'] as List) {
      if (item is Map && item['id'] is String && item['addition'] is Map) {
        additions[item['id'] as String] = (item['addition'] as Map).map(
          (key, value) => MapEntry('$key', value),
        );
      }
    }
    final current = accounts;
    final localIds = current.map((item) => item.id).toSet();
    for (final nativeId in additions.keys.where(
      (id) => !localIds.contains(id),
    )) {
      try {
        await rpc.invoke('deleteAccount', {'id': nativeId});
      } catch (_) {}
    }
    for (final account in current.where(
      (item) =>
          item.backend == StorageBackend.openlist &&
          !additions.containsKey(item.id),
    )) {
      try {
        _throwRpcError(
          await rpc.invoke('saveAccount', {
            'id': account.id,
            'driver': account.driver,
            'name': account.name,
            'addition': account.authorization,
          }),
        );
      } on RemoteStorageException {
        // A pending native account must not make local or WebDAV snapshots
        // impossible to export. Its stored authorization remains available for
        // a later core initialization.
      }
    }
    final updated = current.map((account) {
      final addition = additions[account.id];
      return addition == null
          ? account
          : applyNativeAuthorization(account, addition);
    }).toList();
    appdata.settings[remoteStorageAccountsSetting] = updated
        .map((item) => item.toJson())
        .toList();
    await appdata.saveData(false);
  }

  /// Capture before importing app-data because importing settings may replace
  /// the current value before credentials are merged.
  List<StorageAccount> captureLocalAccounts() => List.unmodifiable(accounts);

  /// Applies imported credentials only to new or explicitly invalid accounts.
  /// Connection/list errors never mark an authorization invalid by themselves.
  Future<void> mergeImportedSettings(
    Object? raw, {
    List<StorageAccount>? localBeforeImport,
  }) async {
    if (raw is! List) return;
    final incoming = raw
        .whereType<Map>()
        .map((item) => StorageAccount.fromJson(item))
        .where((item) => item.isConfigured)
        .toList();
    final local = localBeforeImport ?? accounts;
    final merged = mergeRemoteStorageAccounts(local, incoming);
    final nativeUpdates = merged.where((value) {
      final existing = _accountById(local, value.id);
      return existing == null ||
          (existing.authorizationIsKnownInvalid &&
              existing.backend == value.backend &&
              existing.driver == value.driver);
    }).toList();
    appdata.settings[remoteStorageAccountsSetting] = merged
        .map((item) => item.toJson())
        .toList();
    await appdata.saveData(false);
    final rpc = _openListRpc;
    if (rpc != null) {
      for (final value in nativeUpdates.where(
        (item) => item.backend == StorageBackend.openlist,
      )) {
        try {
          _throwRpcError(
            await rpc.invoke('saveAccount', {
              'id': value.id,
              'driver': value.driver,
              'name': value.name,
              'addition': value.authorization,
            }),
          );
        } catch (_) {
          // An unavailable core must not roll back the remaining app-data import.
        }
      }
    }
  }

  Future<RemoteLibrary> saveLibrary(RemoteLibrary value) async {
    final id = value.id.isEmpty ? _uuid.v4() : value.id;
    final library = RemoteLibrary(
      id: id,
      sourceKey: value.sourceKey.isEmpty
          ? 'remote_library_$id'
          : value.sourceKey,
      accountId: value.accountId,
      directories: value.directories,
      name: value.name,
      autoRefresh: value.autoRefresh,
      refreshIntervalMinutes: value.refreshIntervalMinutes,
    ).normalized();
    final values = libraries.where((item) => item.id != library.id).toList()
      ..add(library);
    appdata.settings[remoteLibrariesSetting] = values
        .map((item) => item.toJson())
        .toList();
    await appdata.saveData(false);
    notifyListeners();
    return library;
  }

  Future<void> removeLibrary(String id) async {
    appdata.settings[remoteLibrariesSetting] = libraries
        .where((item) => item.id != id)
        .map((item) => item.toJson())
        .toList();
    await appdata.saveData(false);
    notifyListeners();
  }

  List<StorageAccount> _readAccounts() => _readList(
    appdata.settings[remoteStorageAccountsSetting],
    StorageAccount.fromJson,
  );
  List<RemoteLibrary> _readLibraries() => _readList(
    appdata.settings[remoteLibrariesSetting],
    RemoteLibrary.fromJson,
  );
}

/// Merges credentials from an app-data snapshot without changing an existing
/// account's backend or driver identity.
List<StorageAccount> mergeRemoteStorageAccounts(
  Iterable<StorageAccount> local,
  Iterable<StorageAccount> incoming,
) {
  final merged = <StorageAccount>[...local];
  for (final value in incoming) {
    final index = merged.indexWhere((item) => item.id == value.id);
    if (index < 0) {
      merged.add(value);
      continue;
    }
    final existing = merged[index];
    if (existing.authorizationIsKnownInvalid &&
        existing.backend == value.backend &&
        existing.driver == value.driver) {
      merged[index] = existing.copyWith(
        name: value.name,
        authorization: value.authorization,
        status: value.status,
        statusMessage: value.statusMessage,
      );
    } else {
      merged[index] = existing.copyWith(name: value.name);
    }
  }
  return merged;
}

StorageAccount? _accountById(Iterable<StorageAccount> values, String id) {
  for (final value in values) {
    if (value.id == id) return value;
  }
  return null;
}

List<T> _readList<T>(
  Object? raw,
  T Function(Map<Object?, Object?> value) converter,
) {
  if (raw is! List) return <T>[];
  final values = <T>[];
  for (final item in raw) {
    if (item is Map) values.add(converter(item));
  }
  return values;
}

bool _hasActualAuthorization(Map<String, dynamic> value) {
  for (final key in const [
    'access_token',
    'refresh_token',
    'AccessToken',
    'RefreshToken',
  ]) {
    if ((value[key] as String? ?? '').isNotEmpty) return true;
  }
  return false;
}

StorageAccount applyNativeAuthorization(
  StorageAccount account,
  Map<String, dynamic> authorization,
) {
  final rotated =
      _hasActualAuthorization(authorization) &&
      _authorizationTokensChanged(account.authorization, authorization);
  return account.copyWith(
    authorization: authorization,
    status: rotated && account.authorizationIsKnownInvalid
        ? StorageAuthorizationStatus.unknown
        : account.status,
    clearStatusMessage: rotated && account.authorizationIsKnownInvalid,
  );
}

bool _authorizationTokensChanged(
  Map<String, dynamic> previous,
  Map<String, dynamic> current,
) {
  for (final key in const [
    'access_token',
    'refresh_token',
    'AccessToken',
    'RefreshToken',
  ]) {
    final next = current[key] as String? ?? '';
    if (next.isNotEmpty && next != (previous[key] as String? ?? '')) {
      return true;
    }
  }
  return false;
}

class _StatusTrackingStore implements RemoteFileStore {
  _StatusTrackingStore(this._delegate, this._record);
  final RemoteFileStore _delegate;
  final Future<void> Function(StorageAccount account, Object? error) _record;
  @override
  StorageAccount get account => _delegate.account;
  Future<T> _run<T>(Future<T> Function() operation) async {
    try {
      final value = await operation();
      await _record(account, null);
      return value;
    } catch (error) {
      await _record(account, error);
      rethrow;
    }
  }

  @override
  Future<void> test() => _run(_delegate.test);
  @override
  Future<List<RemoteEntry>> list(String directory) =>
      _run(() => _delegate.list(directory));
  @override
  Future<RemoteEntry> stat(String path) => _run(() => _delegate.stat(path));
  @override
  Future<RemoteLink> link(String path) => _run(() => _delegate.link(path));
  @override
  Future<RemoteTextFile> readText(String path) =>
      _run(() => _delegate.readText(path));
  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) => _run(
    () => _delegate.writeText(
      path,
      content,
      createOnly: createOnly,
      ifMatch: ifMatch,
      ifUnmodifiedSince: ifUnmodifiedSince,
    ),
  );
  @override
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) => _run(
    () => _delegate.upload(localPath, remotePath, onProgress: onProgress),
  );
  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) => _run(
    () => _delegate.download(remotePath, localPath, onProgress: onProgress),
  );
  @override
  Future<void> mkdir(String path) => _run(() => _delegate.mkdir(path));
  @override
  Future<void> delete(String path) => _run(() => _delegate.delete(path));
  @override
  Future<void> cancel(String taskId) => _delegate.cancel(taskId);
  @override
  Future<void> cancelAll() => _delegate.cancelAll();
}

class _UnavailableOpenListRpc implements OpenListRpcClient {
  @override
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  ) async => {
    'error': {
      'code': 'unavailable',
      'message': 'OpenList native core is unavailable',
    },
  };
}

void _throwRpcError(Map<String, dynamic> response) {
  final error = response['error'];
  if (error is Map) {
    throw RemoteStorageException(
      error['message'] as String? ?? 'OpenList operation failed',
      code: error['code']?.toString(),
    );
  }
}
