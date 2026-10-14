import 'dart:async';

import 'models.dart';

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.modifiedAt,
    this.eTag,
  });
  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final int? modifiedAt;
  final String? eTag;
}

class RemoteTextFile {
  const RemoteTextFile({required this.content, this.eTag, this.modifiedAt});
  final String content;
  final String? eTag;
  final int? modifiedAt;
}

class RemoteWriteResult {
  const RemoteWriteResult({this.eTag, this.modifiedAt});
  final String? eTag;
  final int? modifiedAt;
}

class RemoteLink {
  const RemoteLink({required this.url, this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

class RemoteTransferProgress {
  const RemoteTransferProgress({
    required this.taskId,
    required this.completed,
    this.total,
    this.message,
  });
  final String taskId;
  final int completed;
  final int? total;
  final String? message;
}

abstract class RemoteFileStore {
  StorageAccount get account;
  Future<void> test();
  Future<List<RemoteEntry>> list(String directory);
  Future<RemoteEntry> stat(String path);
  Future<RemoteLink> link(String path);
  Future<RemoteTextFile> readText(String path);
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  });
  Future<void> upload(
    String localPath,
    String remotePath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  });
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress progress)? onProgress,
  });
  Future<void> mkdir(String path);
  Future<void> delete(String path);
  Future<void> cancel(String taskId);
  Future<void> cancelAll();
}

class RemoteStorageException implements Exception {
  const RemoteStorageException(this.message, {this.code, this.cause});
  final String message;
  final String? code;
  final Object? cause;
  bool get isAuthorizationFailure =>
      code == 'unauthorized' || code == 'invalid_token' || code == '401';
  @override
  String toString() => message;
}
