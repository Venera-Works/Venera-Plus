import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';

part 'remote_library_repository_worker.dart';

const remoteLibrarySnapshotFormatVersion = 10;

class RemoteLibraryCachedComic {
  const RemoteLibraryCachedComic({
    required this.id,
    required this.sortIndex,
    required this.title,
    required this.author,
    required this.tags,
    required this.cover,
    required this.snapshot,
    required this.remoteETag,
    required this.remoteModifiedAt,
  });

  final String id;
  final int sortIndex;
  final String title;
  final String author;
  final List<String> tags;
  final String cover;
  final Map<String, dynamic>? snapshot;
  final String? remoteETag;
  final int? remoteModifiedAt;

  bool get isReady =>
      snapshot?['formatVersion'] == remoteLibrarySnapshotFormatVersion;

  bool shouldRetryMetadataScrape({
    required String scraperVersion,
    required int now,
  }) {
    if (!isReady || snapshot?['metadataFilePresent'] == true) return false;
    if (snapshot?['metadataScraperVersion'] != scraperVersion) return true;
    final status = snapshot?['metadataScrapeStatus'];
    if (status == 'pending') return true;
    if (status != 'failed') return false;
    final retryAt = snapshot?['metadataScrapeRetryAt'];
    return retryAt is! int || retryAt <= now;
  }

  bool hasSameRemoteVersion({String? eTag, int? modifiedAt}) {
    final hasVersion = (eTag?.isNotEmpty ?? false) || modifiedAt != null;
    if (!hasVersion) return false;
    return remoteETag == eTag && remoteModifiedAt == modifiedAt;
  }
}

class RemoteLibraryRemoteDirectory {
  const RemoteLibraryRemoteDirectory({
    required this.id,
    required this.sortIndex,
    this.eTag,
    this.modifiedAt,
  });

  final String id;
  final int sortIndex;
  final String? eTag;
  final int? modifiedAt;
}

/// 单个识别根的发现结果。完整远端路径作为漫画 ID，重叠根共享同一缓存。
class RemoteLibraryRootIndex {
  const RemoteLibraryRootIndex({
    required this.rootPath,
    required this.directories,
  });

  final String rootPath;
  final List<RemoteLibraryRemoteDirectory> directories;
}

class RemoteLibraryRepository {
  RemoteLibraryRepository._();

  static final instance = RemoteLibraryRepository._();

  _RemoteLibraryWorker? _worker;
  Future<void> _operations = Future<void>.value();

  // 在调用时捕获路径，并串行处理切库和关闭，避免排队请求写入其他数据目录。
  Future<T> _request<T>(
    _RemoteLibraryOperation operation,
    List<Object?> arguments,
  ) {
    final dataPath = App.dataPath;
    final next = _operations.then((_) async {
      var worker = _worker;
      if (worker == null || worker.dataPath != dataPath || worker.exited) {
        _worker = null;
        await worker?.close();
        worker = await _RemoteLibraryWorker.start(dataPath);
        _worker = worker;
      }
      return await worker.request(operation, arguments) as T;
    });
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<int> count(String configKey, {Iterable<String>? roots}) => _request(
    _RemoteLibraryOperation.count,
    [configKey, roots?.toList(growable: false)],
  );

  /// 只读取摘要和少量快照状态，完整快照通过 find 或 all 读取。
  Future<List<RemoteLibraryCachedComic>> page(
    String configKey, {
    required int page,
    required int pageSize,
    Iterable<String>? roots,
  }) => _request(_RemoteLibraryOperation.page, [
    configKey,
    page,
    pageSize,
    roots?.toList(growable: false),
  ]);

  Future<Map<String, RemoteLibraryCachedComic>> versions(String configKey) =>
      _request(_RemoteLibraryOperation.versions, [configKey]);

  Future<Map<String, RemoteLibraryCachedComic>> all(String configKey) =>
      _request(_RemoteLibraryOperation.all, [configKey]);

  Future<RemoteLibraryCachedComic?> find(String configKey, String id) =>
      _request(_RemoteLibraryOperation.find, [configKey, id]);

  Future<void> replaceDirectoryIndex(
    String configKey,
    List<RemoteLibraryRemoteDirectory> directories,
  ) => _request(_RemoteLibraryOperation.replaceDirectoryIndex, [
    configKey,
    directories,
  ]);

  Future<void> replaceRootDirectoryIndex(
    String configKey,
    RemoteLibraryRootIndex index,
  ) => _request(_RemoteLibraryOperation.replaceRootDirectoryIndex, [
    configKey,
    index,
  ]);

  Future<void> addRootMembership(
    String configKey,
    String rootPath,
    String comicId,
  ) => _request(_RemoteLibraryOperation.addRootMembership, [
    configKey,
    rootPath,
    comicId,
  ]);

  Future<void> markRootFailure(
    String configKey,
    String rootPath,
    String error,
  ) => _request(_RemoteLibraryOperation.markRootFailure, [
    configKey,
    rootPath,
    error,
  ]);

  Future<Map<String, String>> rootFailures(String configKey) =>
      _request(_RemoteLibraryOperation.rootFailures, [configKey]);

  /// 移除的根保留成员与快照，重新选中后即使刷新失败也能使用旧缓存。
  Future<void> removeRootsExcept(
    String configKey,
    Set<String> selectedRoots,
  ) async {}

  Future<void> upsertSnapshot(
    String configKey,
    RemoteLibraryCachedComic comic,
  ) => upsertSnapshots(configKey, [comic]);

  Future<void> upsertSnapshots(
    String configKey,
    List<RemoteLibraryCachedComic> comics,
  ) => _request(_RemoteLibraryOperation.upsertSnapshots, [configKey, comics]);

  /// 摘要和可选的根成员关系在同一事务写入，并保留已有完整快照及其版本。
  Future<void> upsertSummaries(
    String configKey,
    List<RemoteLibraryCachedComic> comics, {
    String? rootPath,
  }) => _request(_RemoteLibraryOperation.upsertSummaries, [
    configKey,
    comics,
    rootPath,
  ]);

  Future<int> lastSuccessfulSync(String configKey) =>
      _request(_RemoteLibraryOperation.lastSuccessfulSync, [configKey]);

  Future<bool> hasDirectoryIndex(String configKey) =>
      _request(_RemoteLibraryOperation.hasDirectoryIndex, [configKey]);

  Future<void> setLastSuccessfulSync(String configKey, int timestamp) =>
      _request(_RemoteLibraryOperation.setLastSuccessfulSync, [
        configKey,
        timestamp,
      ]);

  Future<void> clear(String configKey) =>
      _request(_RemoteLibraryOperation.clear, [configKey]);

  Future<void> close() {
    final next = _operations.then((_) async {
      final worker = _worker;
      _worker = null;
      await worker?.close();
    });
    _operations = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> resetForTesting() => close();
}
