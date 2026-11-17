import 'dart:convert';
import 'dart:io' show File, HttpDate;

import 'package:dio/dio.dart';
import 'package:venera_plus/network/webdav.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

import 'models.dart';
import 'remote_file_store.dart';

class WebDavFileStore implements RemoteFileStore {
  WebDavFileStore(
    this.account, {
    Client? client,
    this.optimizeTransfers = false,
  }) : _client = client,
       _endpoint = WebDavEndpoint(
         url: account.authorization['url'] as String? ?? '',
         user: account.authorization['user'] as String? ?? '',
         password: account.authorization['password'] as String? ?? '',
       );

  @override
  final StorageAccount account;
  final WebDavEndpoint _endpoint;
  final bool optimizeTransfers;
  Client? _client;
  final _tokens = <String, CancelToken>{};
  var _nextTask = 0;
  Client get _webdav =>
      _client ??= _endpoint.createClient(reuseConnections: optimizeTransfers);

  void close() {
    _client?.c.close(force: true);
    _client = null;
  }

  @override
  Future<void> test() async => _run((token) => _webdav.readDir('/', token));

  @override
  Future<List<RemoteEntry>> list(
    String directory, {
    bool refresh = false,
  }) async {
    final normalized = normalizeRemoteDirectory(directory);
    // WebDAV 每次调用都会实时读取目录。
    final entries = await _run((token) => _webdav.readDir(normalized, token));
    return entries
        .where((item) => item.name != null)
        .map(
          (item) => RemoteEntry(
            name: item.name!,
            path: '$normalized${item.name!}',
            isDirectory: item.isDir == true,
            size: item.size,
            modifiedAt: item.mTime?.millisecondsSinceEpoch,
            eTag: item.eTag?.isEmpty == true ? null : item.eTag,
          ),
        )
        .toList();
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    try {
      final item = await _run((token) => _webdav.readProps(path, token));
      return RemoteEntry(
        name:
            item.name ?? path.split('/').where((item) => item.isNotEmpty).last,
        path: path,
        isDirectory: item.isDir == true,
        size: item.size,
        modifiedAt: item.mTime?.millisecondsSinceEpoch,
        eTag: item.eTag?.isEmpty == true ? null : item.eTag,
      );
    } on DioException catch (error) {
      throw _webDavError(error, path);
    }
  }

  @override
  Future<RemoteLink> link(String path, {bool refresh = false}) async =>
      RemoteLink(url: _endpoint.fileUrl(path), headers: _endpoint.authHeaders);

  @override
  Future<RemoteTextFile> readText(String path) async {
    try {
      final response = await _run(
        (token) => _webdav.c.req<List<int>>(
          _webdav,
          'GET',
          path,
          cancelToken: token,
          optionsHandler: (options) =>
              options.responseType = ResponseType.bytes,
        ),
      );
      _checkStatus(response.statusCode, path);
      return RemoteTextFile(
        content: utf8.decode(response.data ?? const [], allowMalformed: false),
        eTag: _header(response.headers.map, 'etag'),
        modifiedAt: _modifiedAt(response.headers.map),
      );
    } on DioException catch (error) {
      throw _webDavError(error, path);
    }
  }

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    if (createOnly && (ifMatch != null || ifUnmodifiedSince != null)) {
      throw ArgumentError(
        'createOnly cannot be combined with update preconditions',
      );
    }
    try {
      final response = await _run(
        (token) => _webdav.c.req<Object?>(
          _webdav,
          'PUT',
          path,
          cancelToken: token,
          data: utf8.encode(content),
          optionsHandler: (options) {
            options.headers ??= {};
            options.headers!['content-type'] =
                'application/json; charset=utf-8';
            if (createOnly) {
              options.headers!['if-none-match'] = '*';
            } else if (ifMatch != null) {
              options.headers!['if-match'] = ifMatch;
            } else if (ifUnmodifiedSince != null) {
              options.headers!['if-unmodified-since'] = HttpDate.format(
                DateTime.fromMillisecondsSinceEpoch(
                  ifUnmodifiedSince,
                  isUtc: true,
                ),
              );
            }
          },
        ),
      );
      _checkStatus(response.statusCode, path);
      return RemoteWriteResult(
        eTag: _header(response.headers.map, 'etag'),
        modifiedAt: _modifiedAt(response.headers.map),
      );
    } on DioException catch (error) {
      throw _webDavError(error, path);
    }
  }

  @override
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) => _transfer(
    (token, id) => optimizeTransfers
        ? _uploadSnapshot(localPath, remotePath, token, id, onProgress)
        : _webdav.writeFromFile(
            localPath,
            remotePath,
            cancelToken: token,
            onProgress: (done, total) => onProgress?.call(
              RemoteTransferProgress(taskId: id, completed: done, total: total),
            ),
          ),
  );

  Future<void> _uploadSnapshot(
    String localPath,
    String remotePath,
    CancelToken token,
    String taskId,
    void Function(RemoteTransferProgress)? onProgress,
  ) async {
    final file = File(localPath);
    final length = await file.length();
    final marker = Object();
    // 鉴权重试时重新打开文件流，保留 Basic/Digest 的质询处理。
    final body = InterceptorsWrapper(
      onRequest: (options, handler) {
        if (identical(options.extra['webdavUpload'], marker)) {
          options.data = file.openRead();
        }
        handler.next(options);
      },
    );
    _webdav.c.interceptors.add(body);
    try {
      final response = await _webdav.c.req<Object?>(
        _webdav,
        'PUT',
        remotePath,
        cancelToken: token,
        optionsHandler: (options) {
          options.extra = {'webdavUpload': marker};
          options.headers!['content-length'] = length;
          options.headers!['content-type'] = 'application/octet-stream';
        },
        onSendProgress: (done, total) => onProgress?.call(
          RemoteTransferProgress(taskId: taskId, completed: done, total: total),
        ),
      );
      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 204) {
        throw RemoteStorageException(
          'WebDAV 上传失败',
          code: '${response.statusCode}',
          retryAfter: _header(response.headers.map, 'retry-after'),
        );
      }
    } finally {
      _webdav.c.interceptors.remove(body);
    }
  }

  Future<void> uploadCreateOnly(String localPath, String remotePath) async {
    final guard = InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.method == 'PUT') options.headers['If-None-Match'] = '*';
        handler.next(options);
      },
    );
    _webdav.c.interceptors.add(guard);
    try {
      await upload(localPath, remotePath);
    } finally {
      _webdav.c.interceptors.remove(guard);
    }
  }

  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  }) => _transfer(
    (token, id) => optimizeTransfers
        ? _downloadSnapshot(remotePath, localPath, token, id, onProgress)
        : _webdav.read2File(
            remotePath,
            localPath,
            cancelToken: token,
            onProgress: (done, total) => onProgress?.call(
              RemoteTransferProgress(taskId: id, completed: done, total: total),
            ),
          ),
  );

  Future<void> _downloadSnapshot(
    String remotePath,
    String localPath,
    CancelToken token,
    String taskId,
    void Function(RemoteTransferProgress)? onProgress,
  ) async {
    final response = await _webdav.c.req<ResponseBody>(
      _webdav,
      'GET',
      remotePath,
      cancelToken: token,
      optionsHandler: (options) => options.responseType = ResponseType.stream,
    );
    if (response.statusCode != 200) {
      await response.data?.stream.listen((_) {}).cancel();
      throw RemoteStorageException(
        'WebDAV 下载失败',
        code: response.statusCode == 404
            ? 'not_found'
            : '${response.statusCode}',
        retryAfter: _header(response.headers.map, 'retry-after'),
      );
    }
    final total = int.tryParse(response.headers.value('content-length') ?? '');
    var completed = 0;
    final output = File(localPath).openWrite();
    try {
      await output.addStream(
        response.data!.stream.map((bytes) {
          completed += bytes.length;
          onProgress?.call(
            RemoteTransferProgress(
              taskId: taskId,
              completed: completed,
              total: total,
            ),
          );
          return bytes;
        }),
      );
    } finally {
      await output.close();
    }
  }

  @override
  Future<void> mkdir(String path) =>
      _run((token) => _webdav.mkdirAll(normalizeRemoteDirectory(path), token));
  @override
  Future<void> delete(String path) =>
      _run((token) => _webdav.remove(path, token));
  @override
  Future<void> cancel(String taskId) async =>
      _tokens[taskId]?.cancel('Cancelled');
  @override
  Future<void> cancelAll() async {
    for (final token in _tokens.values) {
      token.cancel('Cancelled');
    }
  }

  Future<T> _run<T>(Future<T> Function(CancelToken token) action) async {
    final taskId = 'webdav-${_nextTask++}';
    final token = CancelToken();
    _tokens[taskId] = token;
    try {
      return await action(token);
    } on DioException catch (error) {
      throw _webDavError(error, 'WebDAV operation');
    } finally {
      _tokens.remove(taskId);
    }
  }

  Future<void> _transfer(
    Future<void> Function(CancelToken token, String taskId) action,
  ) async {
    final taskId = 'webdav-${_nextTask++}';
    final token = CancelToken();
    _tokens[taskId] = token;
    try {
      await action(token, taskId);
    } on DioException catch (error) {
      throw _webDavError(error, 'WebDAV transfer');
    } finally {
      _tokens.remove(taskId);
    }
  }

  static String? _header(Map<String, List<String>> headers, String name) {
    for (final value in headers[name] ?? const []) {
      if (value.trim().isNotEmpty) return value;
    }
    return null;
  }

  static int? _modifiedAt(Map<String, List<String>> headers) {
    final value = _header(headers, 'last-modified');
    if (value == null) return null;
    try {
      return HttpDate.parse(value).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static void _checkStatus(int? status, String path) {
    if (status != null && status >= 200 && status < 300) return;
    throw RemoteStorageException(
      'WebDAV request failed: $path',
      code: status == 404 ? 'not_found' : '$status',
    );
  }

  static RemoteStorageException _webDavError(DioException error, String path) {
    final retryAfter = error.response?.headers['retry-after'];
    return RemoteStorageException(
      error.message ?? 'WebDAV request failed: $path',
      code: error.response?.statusCode == 404
          ? 'not_found'
          : '${error.response?.statusCode}',
      cause: error,
      retryAfter: retryAfter?.length == 1 ? retryAfter!.single : null,
    );
  }
}
