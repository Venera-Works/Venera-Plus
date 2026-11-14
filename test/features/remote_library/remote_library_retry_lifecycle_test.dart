import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  late Directory dataDir;
  late Map<String, dynamic> previousImplicitData;
  late _RetryStore store;
  late RemoteLibraryEngine engine;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('remote-library-retry-');
    App.dataPath = dataDir.path;
    previousImplicitData = appdata.implicitData;
    appdata.implicitData = {};
    await RemoteLibrarySource.resetCacheForTesting();
    RemoteLibrarySource.configureMetadataScraper(null);
    RemoteLibrarySource.archiveSchedulerFactory = () =>
        RemoteReadScheduler(minInterval: Duration.zero);
    store = _RetryStore();
    engine = RemoteLibraryEngine(library: _library, store: store);
  });

  tearDown(() async {
    store.releaseBlockedList();
    await engine.cancel();
    await RemoteLibrarySource.resetCacheForTesting();
    RemoteLibrarySource.archiveSchedulerFactory = null;
    appdata.implicitData = previousImplicitData;
    await dataDir.delete(recursive: true);
  });

  test('首项重试 I/O 阻塞时关闭保留两项持久记录，恢复后仍可写回', () async {
    for (final entry in _metadata.entries) {
      await expectLater(
        engine.writeMetadata(entry.key, entry.value),
        throwsA(isA<RemoteLibraryTransientException>()),
      );
    }
    expect(engine.metadataPendingStatuses.map((pending) => pending.comicId), [
      '/books/A/',
      '/books/B/',
    ]);
    final implicitFile = File('${dataDir.path}/implicitData.json');
    final persistedBefore =
        jsonDecode(await implicitFile.readAsString()) as Map;
    expect(persistedBefore[_pendingKey], hasLength(2));

    store.failWrites = false;
    store.blockNextList = true;
    final retry = engine.retryPendingMetadata(force: true);
    try {
      await store.listStarted.future.timeout(const Duration(seconds: 2));
      final closing = engine.cancel();
      // cancelAll 不会终止这个受控 I/O，释放后再等待引擎关闭与请求收尾。
      store.releaseBlockedList();
      await Future.wait([retry, closing, store.listFinished.future]);
    } finally {
      store.releaseBlockedList();
      await retry;
    }

    expect(store.texts, isEmpty);
    final persistedAfter = jsonDecode(await implicitFile.readAsString()) as Map;
    expect(persistedAfter[_pendingKey], persistedBefore[_pendingKey]);

    appdata.implicitData = Map<String, dynamic>.from(persistedAfter);
    store = _RetryStore()..failWrites = false;
    engine = RemoteLibraryEngine(library: _library, store: store);
    await engine.retryPendingMetadata(force: true);

    expect(engine.metadataPendingStatuses, isEmpty);
    for (final entry in _metadata.entries) {
      final written =
          jsonDecode(store.texts['${entry.key}metadata.json']!) as Map;
      expect(written['title'], entry.value.title);
      expect(written['bangumiSubjectId'], entry.value.bangumiSubjectId);
    }
    final persistedDone = jsonDecode(await implicitFile.readAsString()) as Map;
    expect(persistedDone[_pendingKey], isEmpty);
  });

  test('活动引擎重试时删除过期绑定并继续写回有效记录', () async {
    for (final entry in _metadata.entries) {
      await expectLater(
        engine.writeMetadata(entry.key, entry.value),
        throwsA(isA<RemoteLibraryTransientException>()),
      );
    }
    store.failWrites = false;
    RemoteLibrarySource.configureMetadataWriteGuard(
      (_, comicId, _) => comicId != '/books/A/',
    );

    await engine.retryPendingMetadata(force: true);

    expect(engine.metadataPendingStatuses, isEmpty);
    expect(store.texts.keys, ['/books/B/metadata.json']);
    final written = jsonDecode(store.texts.values.single) as Map;
    expect(written['title'], _metadata['/books/B/']!.title);
    expect(written['bangumiSubjectId'], 102);
    final persisted =
        jsonDecode(
              await File('${dataDir.path}/implicitData.json').readAsString(),
            )
            as Map;
    expect(persisted[_pendingKey], isEmpty);
  });

  test('直接写回在受阻 I/O 后排队时关闭，保留既有 pending 并可恢复', () async {
    const comicId = '/books/A/';
    final metadata = _metadata[comicId]!;
    await expectLater(
      engine.writeMetadata(comicId, metadata),
      throwsA(isA<RemoteLibraryTransientException>()),
    );
    final implicitFile = File('${dataDir.path}/implicitData.json');
    final persistedBefore =
        jsonDecode(await implicitFile.readAsString()) as Map;
    expect(persistedBefore[_pendingKey], hasLength(1));

    store.failWrites = false;
    store.blockNextList = true;
    final interrupted = expectLater(
      engine.writeMetadata(comicId, metadata),
      throwsA(
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    try {
      await store.listStarted.future.timeout(const Duration(seconds: 2));
      final rejected = expectLater(
        engine.writeMetadata(comicId, metadata),
        throwsA(isA<RemoteLibraryMetadataWriteRejectedException>()),
      );
      final closing = engine.cancel();
      store.releaseBlockedList();
      await Future.wait([
        interrupted,
        rejected,
        closing,
        store.listFinished.future,
      ]);
    } finally {
      store.releaseBlockedList();
      await interrupted;
    }

    expect(store.texts, isEmpty);
    expect(engine.metadataPendingStatuses.single.comicId, comicId);
    final persistedAfter = jsonDecode(await implicitFile.readAsString()) as Map;
    final pendingBefore =
        (persistedBefore[_pendingKey] as Map).values.single as Map;
    final pendingAfter =
        (persistedAfter[_pendingKey] as Map).values.single as Map;
    expect(pendingAfter['metadata'], pendingBefore['metadata']);

    appdata.implicitData = Map<String, dynamic>.from(persistedAfter);
    store = _RetryStore()..failWrites = false;
    engine = RemoteLibraryEngine(library: _library, store: store);
    await engine.retryPendingMetadata(force: true);

    expect(engine.metadataPendingStatuses, isEmpty);
    final written = jsonDecode(store.texts['${comicId}metadata.json']!) as Map;
    expect(written['title'], metadata.title);
    expect(written['bangumiSubjectId'], metadata.bangumiSubjectId);
    final persistedDone = jsonDecode(await implicitFile.readAsString()) as Map;
    expect(persistedDone[_pendingKey], isEmpty);
  });

  test('直接写回仍删除已有 pending 中的失效绑定', () async {
    const comicId = '/books/A/';
    final metadata = _metadata[comicId]!;
    await expectLater(
      engine.writeMetadata(comicId, metadata),
      throwsA(isA<RemoteLibraryTransientException>()),
    );
    store.failWrites = false;
    RemoteLibrarySource.configureMetadataWriteGuard((_, _, _) => false);

    await expectLater(
      engine.writeMetadata(comicId, metadata),
      throwsA(isA<RemoteLibraryMetadataWriteRejectedException>()),
    );

    expect(engine.metadataPendingStatuses, isEmpty);
    expect(store.texts, isEmpty);
    final persisted =
        jsonDecode(
              await File('${dataDir.path}/implicitData.json').readAsString(),
            )
            as Map;
    expect(persisted[_pendingKey], isEmpty);
  });
}

const _pendingKey = 'webdavMetadataPending:retry-lifecycle';
const _library = RemoteLibrary(
  id: 'retry-lifecycle',
  sourceKey: 'retry-lifecycle-source',
  accountId: 'retry-account',
  directories: ['/books/'],
  name: '重试测试库',
  autoRefresh: false,
);
const _metadata = {
  '/books/A/': ComicMetaData(
    title: '作品 A',
    author: '作者 A',
    tags: ['标签 A'],
    bangumiSubjectId: 101,
  ),
  '/books/B/': ComicMetaData(
    title: '作品 B',
    author: '作者 B',
    tags: ['标签 B'],
    bangumiSubjectId: 102,
  ),
};

class _RetryStore extends Fake implements RemoteFileStore {
  @override
  final account = const StorageAccount(
    id: 'retry-account',
    backend: StorageBackend.openlist,
    driver: 'test',
    name: '重试测试账号',
    authorization: {},
  );
  final texts = <String, String>{};
  var failWrites = true;
  var blockNextList = false;
  final listStarted = Completer<void>();
  final _listRelease = Completer<void>();
  final listFinished = Completer<void>();

  void releaseBlockedList() {
    if (!_listRelease.isCompleted) _listRelease.complete();
  }

  @override
  Future<List<RemoteEntry>> list(
    String directory, {
    bool refresh = false,
  }) async {
    if (blockNextList) {
      blockNextList = false;
      listStarted.complete();
      await _listRelease.future;
      listFinished.complete();
    }
    return [
      RemoteEntry(
        name: '001.jpg',
        path: '${directory}001.jpg',
        isDirectory: false,
      ),
      if (texts.containsKey('${directory}metadata.json'))
        RemoteEntry(
          name: 'metadata.json',
          path: '${directory}metadata.json',
          isDirectory: false,
        ),
    ];
  }

  @override
  Future<RemoteTextFile> readText(String path) async =>
      RemoteTextFile(content: texts[path]!, eTag: 'metadata-v1');

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    if (failWrites) throw RemoteLibraryTransientException(path);
    texts[path] = content;
    return const RemoteWriteResult();
  }

  @override
  Future<void> cancelAll() async {}
}
