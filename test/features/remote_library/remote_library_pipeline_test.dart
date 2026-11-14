import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/features/remote_library/remote_library_repository.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  late Directory dataDir;
  final engines = <RemoteLibraryEngine>[];

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('remote-library-pipeline-');
    App.dataPath = dataDir.path;
    await RemoteLibrarySource.resetCacheForTesting();
    RemoteLibrarySource.archiveSchedulerFactory = () =>
        RemoteReadScheduler(minInterval: Duration.zero);
    RemoteLibrarySource.configureMetadataScraper(null);
  });

  tearDown(() async {
    await Future.wait(engines.map((engine) => engine.cancel()));
    engines.clear();
    await RemoteLibrarySource.resetCacheForTesting();
    RemoteLibrarySource.configureMetadataScraper(null);
    RemoteLibrarySource.archiveSchedulerFactory = null;
    await dataDir.delete(recursive: true);
  });

  RemoteLibraryEngine open(_PipelineStore store, List<String> roots) {
    final engine = RemoteLibraryEngine(
      library: RemoteLibrary(
        id: 'pipeline',
        sourceKey: 'pipeline',
        accountId: store.account.id,
        directories: roots,
        name: '云端漫画库',
        autoRefresh: false,
      ),
      store: store,
    );
    engines.add(engine);
    return engine;
  }

  test('慢刮削期间新增作品先显示，后续作品与前台阅读继续推进', () async {
    final store = _PipelineStore();
    store.directories['/books/'] = [
      store.directory('/books/A/'),
      store.directory('/books/B/'),
    ];
    store.directories['/books/A/'] = [store.image('/books/A/001.jpg')];
    store.directories['/books/B/'] = [store.image('/books/B/001.jpg')];
    final scraperStarted = Completer<void>();
    final scrape = Completer<ComicMetaData?>();
    RemoteLibrarySource.configureMetadataScraper((input) {
      if (!scraperStarted.isCompleted) scraperStarted.complete();
      return scrape.future;
    });
    final engine = open(store, ['/books/']);
    try {
      expect((await engine.synchronize()).success, isTrue);
      await scraperStarted.future;
      final page = await engine.loadComics(1);
      expect(page.data.map((comic) => comic.title), ['A', 'B']);
      expect((await engine.loadComicPages('/books/B/', null)).data, [
        '/books/B/001.jpg',
      ]);
      expect(store.writes, isEmpty);
    } finally {
      scrape.complete(null);
      await engine.waitForBackgroundTasks();
    }
  });

  test('慢元数据文件不会阻塞后续发现，摘要和根成员同时可见', () async {
    final store = _PipelineStore();
    store.directories['/books/'] = [
      store.directory('/books/A/'),
      store.directory('/books/B/'),
    ];
    store.directories['/books/A/'] = [
      store.image('/books/A/001.jpg'),
      store.file('/books/A/metadata.json'),
    ];
    store.directories['/books/B/'] = [store.image('/books/B/001.jpg')];
    final metadata = Completer<void>();
    store.textGate = metadata;
    store.texts['/books/A/metadata.json'] = jsonEncode({
      'title': '作品 A',
      'author': '作者',
      'tags': [],
    });
    final engine = open(store, ['/books/']);
    try {
      expect((await engine.synchronize()).success, isTrue);
      await store.textStarted.future;
      final page = await engine.loadComics(1);
      expect(page.data.map((comic) => comic.id), ['/books/A/', '/books/B/']);
      expect(page.data.first.title, 'A');
      expect(
        await RemoteLibraryRepository.instance.count(
          'remote-library:pipeline',
          roots: ['/books/'],
        ),
        2,
      );
    } finally {
      metadata.complete();
      await engine.waitForBackgroundTasks();
    }
    expect((await engine.loadComics(1)).data.first.title, '作品 A');
  });

  test('运行中强刷重新读取目录，并拒绝旧扫描晚到结果', () async {
    final store = _PipelineStore();
    final oldRoot = Completer<List<RemoteEntry>>();
    final oldStarted = Completer<void>();
    store.onList = (path, refresh) async {
      if (path == '/books/' && !refresh) {
        if (!oldStarted.isCompleted) oldStarted.complete();
        return oldRoot.future;
      }
      if (path == '/books/') return [store.directory('/books/New/')];
      return [
        store.image(
          '$path'
          '001.jpg',
        ),
      ];
    };
    final engine = open(store, ['/books/']);
    final oldSync = engine.synchronize();
    await oldStarted.future;
    try {
      expect((await engine.synchronize(force: true)).success, isTrue);
      expect(store.lists, contains((path: '/books/', refresh: true)));
      expect(store.lists, contains((path: '/books/New/', refresh: true)));
    } finally {
      oldRoot.complete([store.directory('/books/Old/')]);
      await oldSync;
      await engine.waitForBackgroundTasks();
    }
    expect((await engine.loadComics(1)).data.map((comic) => comic.id), [
      '/books/New/',
    ]);
  });

  test('强刷取新目录，版本未变时保留摘要并跳过元数据重读', () async {
    final store = _PipelineStore();
    store.directories['/books/'] = [store.directory('/books/Book/')];
    store.directories['/books/Book/'] = [
      store.image('/books/Book/001.jpg'),
      store.file('/books/Book/metadata.json'),
    ];
    store.texts['/books/Book/metadata.json'] = jsonEncode({
      'title': '正式书名',
      'author': '作者',
      'tags': ['标签'],
    });
    final engine = open(store, ['/books/']);
    await engine.synchronize();
    await engine.waitForBackgroundTasks();
    final reads = store.textReads;
    await engine.synchronize(force: true);
    await engine.waitForBackgroundTasks();
    expect(
      store.lists.where((item) => item.refresh).map((item) => item.path),
      containsAll(['/books/', '/books/Book/']),
    );
    expect(store.textReads, reads);
    final page = await engine.loadComics(1);
    expect(page.data.single.title, '正式书名');
    expect(page.data.single.tags, ['标签']);
  });

  test('慢根与失败根保留各自状态，其他根先显示且缓存不被删除', () async {
    final store = _PipelineStore();
    store.directories['/slow/'] = [store.directory('/slow/Old/')];
    store.directories['/slow/Old/'] = [store.image('/slow/Old/001.jpg')];
    store.directories['/fast/'] = [store.directory('/fast/New/')];
    store.directories['/fast/New/'] = [store.image('/fast/New/001.jpg')];
    final engine = open(store, ['/slow/', '/fast/']);
    await engine.synchronize();
    final slow = Completer<List<RemoteEntry>>();
    store.onList = (path, refresh) async {
      if (path == '/slow/') return slow.future;
      return store.directories[path] ?? [];
    };
    final published = Completer<void>();
    void changed() async {
      if (published.isCompleted) return;
      final page = await engine.loadComics(1);
      if (page.data.any((comic) => comic.id == '/fast/New/') &&
          !published.isCompleted) {
        published.complete();
      }
    }

    engine.contentVersion.addListener(changed);
    final sync = engine.synchronize(force: true);
    try {
      await published.future.timeout(const Duration(seconds: 2));
      expect(engine.syncStatus.value.isSyncing, isTrue);
      slow.completeError(StateError('根目录不可用'));
      expect((await sync).error, isTrue);
      expect(engine.failedRoots.keys, ['/slow/']);
      expect(
        (await engine.loadComics(1)).data.map((comic) => comic.id),
        containsAll(['/slow/Old/', '/fast/New/']),
      );
    } finally {
      engine.contentVersion.removeListener(changed);
      if (!slow.isCompleted) slow.complete([]);
      await sync;
    }
  });

  test('ZIP EPUB PDF 首次扫描仅登记作品，退出拒绝晚到刮削写回', () async {
    final store = _PipelineStore();
    store.directories['/books/'] = [
      store.file('/books/book.zip'),
      store.file('/books/story.epub'),
      store.file('/books/document.pdf'),
      store.directory('/books/Images/'),
    ];
    store.directories['/books/Images/'] = [
      store.image('/books/Images/001.jpg'),
    ];
    final scrape = Completer<ComicMetaData?>();
    final started = Completer<void>();
    RemoteLibrarySource.configureMetadataScraper((_) {
      if (!started.isCompleted) started.complete();
      return scrape.future;
    });
    final engine = open(store, ['/books/']);
    await engine.synchronize();
    await started.future;
    expect((await engine.loadComics(1)).data, hasLength(4));
    expect(store.statCalls, 0);
    await engine.cancel().timeout(const Duration(seconds: 2));
    expect(store.cancellations, 1);
    scrape.complete(const ComicMetaData(title: '晚到书名', author: '', tags: []));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, isEmpty);
    expect(
      (await RemoteLibraryRepository.instance.find(
        'remote-library:pipeline',
        '/books/Images/',
      ))?.title,
      'Images',
    );
  });
}

class _PipelineStore extends Fake implements RemoteFileStore {
  @override
  final account = const StorageAccount(
    id: 'pipeline-account',
    backend: StorageBackend.openlist,
    driver: 'test',
    name: '测试账号',
    authorization: {},
  );
  final directories = <String, List<RemoteEntry>>{};
  final texts = <String, String>{};
  final writes = <String>[];
  final lists = <({String path, bool refresh})>[];
  final textStarted = Completer<void>();
  Completer<void>? textGate;
  Future<List<RemoteEntry>> Function(String path, bool refresh)? onList;
  int textReads = 0;
  int statCalls = 0;
  int cancellations = 0;

  RemoteEntry directory(String path) => RemoteEntry(
    name: path.split('/').where((part) => part.isNotEmpty).last,
    path: path,
    isDirectory: true,
    eTag: 'directory-v1',
  );
  RemoteEntry file(String path) => RemoteEntry(
    name: path.split('/').last,
    path: path,
    isDirectory: false,
    eTag: 'file-v1',
    size: 4096,
  );
  RemoteEntry image(String path) => file(path);

  @override
  Future<List<RemoteEntry>> list(String path, {bool refresh = false}) async {
    lists.add((path: path, refresh: refresh));
    return onList != null
        ? await onList!(path, refresh)
        : directories[path] ?? [];
  }

  @override
  Future<RemoteTextFile> readText(String path) async {
    textReads++;
    if (!textStarted.isCompleted) textStarted.complete();
    await textGate?.future;
    return RemoteTextFile(content: texts[path]!, eTag: 'metadata-v1');
  }

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    writes.add(path);
    texts[path] = content;
    return const RemoteWriteResult();
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    statCalls++;
    return file(path);
  }

  @override
  Future<RemoteLink> link(String path) async => RemoteLink(url: path);
  @override
  Future<void> cancelAll() async {
    cancellations++;
  }
}
