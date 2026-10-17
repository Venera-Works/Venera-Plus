import 'models.dart';
import 'remote_file_store.dart';

abstract class OpenListRpcClient {
  Future<Map<String, dynamic>> invoke(
    String method,
    Map<String, dynamic> request,
  );
}

/// Native adapters provide this bridge. All messages deliberately use JSON-safe
/// values so Android/iOS channels and desktop C ABI have the same contract.
class OpenListFileStore implements RemoteFileStore {
  OpenListFileStore(this.account, this._rpc, {this.waitForInitialization});
  @override
  final StorageAccount account;
  final OpenListRpcClient _rpc;
  final Future<void> Function()? waitForInitialization;
  var _nextTransfer = 0;
  final _activeTasks = <String>{};
  final _submittedTasks = <String>{};
  final _cancelledTasks = <String>{};

  @override
  Future<void> test() async => _operation('test', const {});

  @override
  Future<List<RemoteEntry>> list(String directory) async {
    final value = await _operation('list', {
      'path': normalizeRemoteDirectory(directory),
    });
    final entries = value['entries'] as List? ?? const [];
    return entries.whereType<Map>().map((item) => _entry(item)).toList();
  }

  @override
  Future<RemoteEntry> stat(String path) async =>
      _entry(await _operation('stat', {'path': path}));

  @override
  Future<RemoteLink> link(String path) async {
    final value = await _operation('link', {'path': path});
    return RemoteLink(
      url: value['url'] as String? ?? '',
      headers: _stringMap(value['headers']),
    );
  }

  @override
  Future<RemoteTextFile> readText(String path) async {
    final value = await _operation('readText', {'path': path});
    return RemoteTextFile(
      content: value['content'] as String? ?? '',
      eTag: value['eTag'] as String?,
      modifiedAt: (value['modifiedAt'] as num?)?.toInt(),
    );
  }

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    final request = <String, dynamic>{
      'path': path,
      'content': content,
      'createOnly': createOnly,
    };
    if (ifMatch != null) {
      request['ifMatch'] = ifMatch;
    }
    if (ifUnmodifiedSince != null) {
      request['ifUnmodifiedSince'] = ifUnmodifiedSince;
    }
    final value = await _operation('writeText', request);
    return RemoteWriteResult(
      eTag: value['eTag'] as String?,
      modifiedAt: (value['modifiedAt'] as num?)?.toInt(),
    );
  }

  @override
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) => _transfer('upload', {
    'localPath': localPath,
    'path': remotePath,
  }, onProgress);

  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) => _transfer('download', {
    'path': remotePath,
    'localPath': localPath,
  }, onProgress);

  @override
  Future<void> mkdir(String path) async =>
      _operation('mkdir', {'path': normalizeRemoteDirectory(path)});

  @override
  Future<void> delete(String path) async =>
      _operation('delete', {'path': path});

  @override
  Future<void> cancel(String taskId) => _requestCancel(taskId);

  @override
  Future<void> cancelAll() async {
    await Future.wait(_activeTasks.toList().map(_requestCancel));
  }

  Future<Map<String, dynamic>> _operation(
    String method,
    Map<String, dynamic> request,
  ) async {
    final taskId = _newTaskId();
    _activeTasks.add(taskId);
    try {
      await waitForInitialization?.call();
      _throwIfCancelled(taskId);
      _submittedTasks.add(taskId);
      final data = await _data(method, {...request, 'taskId': taskId});
      _throwIfCancelled(taskId);
      return data;
    } finally {
      await _finishTask(taskId);
    }
  }

  Future<void> _transfer(
    String method,
    Map<String, dynamic> request,
    void Function(RemoteTransferProgress)? onProgress,
  ) async {
    final taskId = _newTaskId();
    _activeTasks.add(taskId);
    try {
      onProgress?.call(RemoteTransferProgress(taskId: taskId, completed: 0));
      await waitForInitialization?.call();
      _throwIfCancelled(taskId);
      _submittedTasks.add(taskId);
      await _data(method, {...request, 'taskId': taskId});
      _throwIfCancelled(taskId);
      while (true) {
        _throwIfCancelled(taskId);
        final status = await _data('taskStatus', {'taskId': taskId});
        onProgress?.call(
          RemoteTransferProgress(
            taskId: taskId,
            completed: (status['completed'] as num?)?.toInt() ?? 0,
            total: (status['total'] as num?)?.toInt(),
            message: status['message'] as String?,
          ),
        );
        if (status['error'] is Map) throw _error(status['error']);
        if (status['done'] == true) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      await _finishTask(taskId);
    }
  }

  String _newTaskId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_nextTransfer++}';

  Future<void> _requestCancel(String taskId) async {
    _cancelledTasks.add(taskId);
    if (!_submittedTasks.contains(taskId)) return;
    final response = await _rpc.invoke('cancel', {
      'accountId': account.id,
      'taskId': taskId,
    });
    final error = response['error'];
    if (error is Map) throw _error(error);
  }

  void _throwIfCancelled(String taskId) {
    if (_cancelledTasks.contains(taskId)) {
      throw const RemoteStorageException(
        'OpenList operation cancelled',
        code: 'cancelled',
      );
    }
  }

  Future<void> _finishTask(String taskId) async {
    _activeTasks.remove(taskId);
    _cancelledTasks.remove(taskId);
    if (!_submittedTasks.remove(taskId)) return;
    await _rpc.invoke('releaseTask', {
      'accountId': account.id,
      'taskId': taskId,
    });
  }

  Future<Map<String, dynamic>> _data(
    String method,
    Map<String, dynamic> request,
  ) async {
    final response = await _rpc.invoke(method, {
      'accountId': account.id,
      ...request,
    });
    final error = response['error'];
    if (error is Map) throw _error(error);
    return _map(response['data']);
  }

  RemoteStorageException _error(Map<Object?, Object?> error) =>
      RemoteStorageException(
        error['message'] as String? ?? 'OpenList operation failed',
        code: error['code']?.toString(),
      );
  RemoteEntry _entry(Map<Object?, Object?> item) => RemoteEntry(
    name: item['name'] as String? ?? '',
    path: item['path'] as String? ?? '',
    isDirectory: item['isDirectory'] == true,
    size: (item['size'] as num?)?.toInt(),
    modifiedAt: (item['modifiedAt'] as num?)?.toInt(),
    eTag: item['eTag'] as String?,
  );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.map((key, item) => MapEntry('$key', item)) : const {};
Map<String, String> _stringMap(Object? value) => value is Map
    ? value.map((key, item) => MapEntry('$key', '$item'))
    : const {};
