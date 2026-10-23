import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This suite exercises real loopback Range responses.
  HttpOverrides.global = null;
  late Directory directory;
  late _ArchiveStore store;
  late WebDavLibraryEngine engine;
  late ComicSource source;
  late HttpServer server;
  late Uint8List zip;
  var revision = 1;
  String? downloadETagPrefix = 'version';
  DateTime? downloadModified;
  final conditions = <(String?, String?)>[];
  final ranges = <(int, int)>[];
  final clients = <Dio>[];
  Completer<void>? responseGate;
  Completer<void>? responseStarted;

  Uint8List createZip(int revision, {bool distantPage = false}) {
    final book = archive.Archive();
    void add(String name, List<int> bytes) =>
        book.addFile(archive.ArchiveFile(name, bytes.length, bytes));
    add('Book/cover.jpg', [9, revision]);
    add('Book/10.jpg', [10, revision]);
    add('Book/2.jpg', [2, revision]);
    add('Book/padding.bin', List.filled(2 * 1024 * 1024, 42));
    if (distantPage) add('Book/20.jpg', [20, revision]);
    add(
      'Book/metadata.json',
      utf8.encode(
        jsonEncode({
          'title': 'Cloud book',
          'author': 'Author',
          'tags': ['comic'],
        }),
      ),
    );
    return archive.ZipEncoder().encodeBytes(book, level: 0);
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('remote-zip-library-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    CacheManager.debugDisableInitialScan = true;
    WebDavLibrarySource.resetCacheForTesting();
    WebDavLibrarySource.archiveSchedulerFactory = () =>
        RemoteReadScheduler(minInterval: Duration.zero);
    ranges.clear();
    conditions.clear();
    downloadETagPrefix = 'version';
    downloadModified = null;
    responseGate = null;
    responseStarted = null;
    revision = 1;
    zip = createZip(revision);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('x-cloud-auth'), 'preserved');
      conditions.add((
        request.headers.value('if-match'),
        request.headers.value('if-unmodified-since'),
      ));
      final match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(request.headers.value('range') ?? '');
      if (match == null) {
        request.response.statusCode = 400;
      } else {
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        ranges.add((start, end - start + 1));
        final bytes = zip;
        final currentRevision = revision;
        final gate = responseGate;
        responseGate = null;
        responseStarted?.complete();
        responseStarted = null;
        await gate?.future;
        request.response.statusCode = 206;
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${bytes.length}',
        );
        if (downloadETagPrefix != null) {
          request.response.headers.set(
            'etag',
            '"$downloadETagPrefix-$currentRevision"',
          );
        }
        if (downloadModified != null) {
          request.response.headers.set(
            'last-modified',
            HttpDate.format(downloadModified!),
          );
        }
        request.response.add(bytes.sublist(start, end + 1));
      }
      await request.response.close();
    });
    store = _ArchiveStore(
      () => RemoteEntry(
        name: '漫画 %.cbz',
        path: '/library/漫画 %.cbz',
        isDirectory: false,
        size: zip.length,
        eTag: '"version-$revision"',
        modifiedAt: DateTime.utc(2026, 10, 20).millisecondsSinceEpoch,
      ),
      RemoteLink(
        url: 'http://127.0.0.1:${server.port}/book',
        headers: {'x-cloud-auth': 'preserved'},
      ),
    );
    engine = WebDavLibraryEngine(
      library: const RemoteLibrary(
        id: 'archive-library',
        sourceKey: 'archive-source',
        accountId: 'archive-account',
        directories: ['/library/'],
        name: 'Archive library',
        autoRefresh: false,
      ),
      store: store,
    );
    source = engine.create();
    WebDavLibrarySource.archiveDioFactory = () {
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      clients.add(dio);
      return dio;
    };
    ImageDownloader.configureSourceImageLoading(
      thumbnailLoadingConfig: (_, key) =>
          source.getThumbnailLoadingConfig!(key),
      comicImageLoadingConfig: (_, key, cid, eid, {target}) =>
          source.getImageLoadingConfig!(key, cid, eid, target: target),
    );
  });

  tearDown(() async {
    ImageDownloader.cancelAllLoadingImages();
    engine.cancel();
    ImageDownloader.debugResetSourceImageLoading();
    await ImageDownloader.debugFlushImageCacheWrites();
    await CacheManager.resetForTesting();
    WebDavLibrarySource.archiveDioFactory = null;
    WebDavLibrarySource.archiveSchedulerFactory = null;
    WebDavLibrarySource.resetCacheForTesting();
    for (final client in clients) {
      client.close(force: true);
    }
    clients.clear();
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });

  test(
    'discovery stays lazy and a page uses only its entry ranges and cache',
    () async {
      expect((await engine.synchronize()).success, isTrue);
      expect(ranges, isEmpty);
      expect(store.links, 0);
      expect(store.stats, 0);
      final list = await source.explorePages.single.loadPage!(1);
      expect(list.data.single.id, '/library/漫画 %.cbz');
      expect(list.data.single.title, '漫画 %');

      final info = await source.loadComicInfo!('/library/漫画 %.cbz');
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.title, 'Cloud book');
      expect(info.data.chapters, isNull);
      expect(
        ranges.fold(0, (sum, range) => sum + range.$2),
        lessThan(zip.length),
      );
      final pages = await source.loadComicPages!('/library/漫画 %.cbz', null);
      expect(pages.success, isTrue, reason: pages.errorMessage);
      expect(pages.data, hasLength(2));
      ranges.clear();
      expect(
        await ImageDownloader.loadComicImageBytes(
          pages.data.first,
          source.key,
          info.data.id,
          '',
        ),
        [2, 1],
      );
      expect(ranges, hasLength(1));
      expect(ranges.single.$2, 256 * 1024);
      final count = ranges.length;
      expect(
        await ImageDownloader.loadComicImageBytes(
          pages.data.last,
          source.key,
          info.data.id,
          '',
        ),
        [10, 1],
      );
      expect(ranges.length, count);
      expect(
        await ImageDownloader.loadComicImageBytes(
          pages.data.first,
          source.key,
          info.data.id,
          '',
        ),
        [2, 1],
      );
      expect(ranges.length, count);

      final cover = await ImageDownloader.loadThumbnail(
        info.data.cover,
        source.key,
      ).last;
      expect(cover.imageBytes, [9, 1]);
      final afterCover = ranges.length;
      await ImageDownloader.loadThumbnail(info.data.cover, source.key).last;
      expect(ranges.length, afterCover);
      final library = engine.library;
      engine.cancel();
      engine = WebDavLibraryEngine(library: library, store: store);
      source = engine.create();
      final reopened = await source.loadComicPages!('/library/漫画 %.cbz', null);
      expect(reopened.data, pages.data);
      expect(
        await ImageDownloader.loadComicImageBytes(
          reopened.data.first,
          source.key,
          info.data.id,
          '',
        ),
        [2, 1],
      );
      expect(ranges.length, afterCover);
      expect(store.downloads, 0);
    },
  );

  test(
    'closing a library cancels archive queries queued during cooldown',
    () async {
      WebDavLibrarySource.archiveSchedulerFactory = () =>
          RemoteReadScheduler(minInterval: Duration.zero)
            ..defer(retryAfter: '3600');
      final reading = source.loadComicInfo!('/library/漫画 %.cbz');
      await pumpEventQueue();
      expect(store.stats, 0);
      engine.cancel();
      final result = await reading;
      expect(result.success, isFalse);
      expect(store.stats, 0);
      expect(ranges, isEmpty);
    },
  );

  test(
    'libraries on one account share their scheduler and range cache',
    () async {
      var schedulers = 0;
      WebDavLibrarySource.archiveSchedulerFactory = () {
        schedulers++;
        return RemoteReadScheduler(minInterval: Duration.zero);
      };
      final first = await source.loadComicInfo!('/library/漫画 %.cbz');
      expect(first.success, isTrue, reason: first.errorMessage);
      final requests = ranges.length;
      final other = WebDavLibraryEngine(
        library: const RemoteLibrary(
          id: 'second-library',
          sourceKey: 'second-source',
          accountId: 'archive-account',
          directories: ['/library/'],
          name: 'Second library',
          autoRefresh: false,
        ),
        store: store,
      );
      try {
        final info = await other.create().loadComicInfo!('/library/漫画 %.cbz');
        expect(info.success, isTrue, reason: info.errorMessage);
        expect(info.data.title, first.data.title);
        expect(schedulers, 1);
        expect(ranges.length, requests);
      } finally {
        other.cancel();
      }
    },
  );

  test(
    'opening the lazy list cover resolves the ZIP index and cover entry',
    () async {
      await engine.synchronize();
      final list = await source.explorePages.single.loadPage!(1);
      final cover = await ImageDownloader.loadThumbnail(
        list.data.single.cover,
        source.key,
      ).last;
      expect(cover.imageBytes, [9, 1]);
      expect(
        ranges.fold(0, (sum, range) => sum + range.$2),
        lessThan(zip.length),
      );
    },
  );

  for (final hasDownloadETag in [false, true]) {
    test('uses CDN validators independently of directory metadata '
        '(download ETag: $hasDownloadETag)', () async {
      downloadETagPrefix = hasDownloadETag ? 'cdn' : null;
      downloadModified = DateTime.utc(2026, 7, 5, 18, 10, 49);
      zip = createZip(revision, distantPage: true);
      expect((await engine.synchronize()).success, isTrue);
      final list = await source.explorePages.single.loadPage!(1);
      final cover = await ImageDownloader.loadThumbnail(
        list.data.single.cover,
        source.key,
      ).last;
      expect(cover.imageBytes, [9, 1]);
      final pages = await source.loadComicPages!('/library/漫画 %.cbz', null);
      expect(pages.success, isTrue, reason: pages.errorMessage);
      expect(
        await ImageDownloader.loadComicImageBytes(
          pages.data.first,
          source.key,
          '/library/漫画 %.cbz',
          '',
        ),
        [2, 1],
      );
      expect(
        await ImageDownloader.loadComicImageBytes(
          pages.data.last,
          source.key,
          '/library/漫画 %.cbz',
          '',
        ),
        [20, 1],
      );
      expect(conditions.first, (null, null));
      final expected = hasDownloadETag
          ? ('"cdn-1"', null)
          : (null, HttpDate.format(downloadModified!));
      expect(conditions, contains(expected));
      expect(
        conditions.where((condition) => condition != (null, null)),
        everyElement(expected),
      );
      expect(
        ranges.fold(0, (sum, range) => sum + range.$2),
        lessThan(zip.length),
      );
    });
  }

  test(
    'refresh changes page identities and never writes metadata into a file',
    () async {
      await engine.synchronize();
      final first = await source.loadComicPages!('/library/漫画 %.cbz', null);
      expect(first.success, isTrue, reason: first.errorMessage);
      revision = 2;
      zip = createZip(revision);
      await engine.synchronize(force: true);
      final next = await source.loadComicPages!('/library/漫画 %.cbz', null);
      expect(next.success, isTrue, reason: next.errorMessage);
      expect(next.data.first, isNot(first.data.first));
      expect(
        await ImageDownloader.loadComicImageBytes(
          next.data.first,
          source.key,
          '/library/漫画 %.cbz',
          '',
        ),
        [2, 2],
      );
      expect(store.writes, 0);
    },
  );

  test(
    'a cancelled thumbnail does not cancel an active details waiter',
    () async {
      await engine.synchronize();
      final list = await source.explorePages.single.loadPage!(1);
      final config = await source.getThumbnailLoadingConfig!(
        list.data.single.cover,
      );
      final token = CancelToken();
      final gate = responseGate = Completer<void>();
      final started = responseStarted = Completer<void>();
      final first = (config['loadBytes'] as ComicImageBytesLoader)(token);
      final cancelled = expectLater(first, throwsA(isA<DioException>()));
      await started.future;
      final details = source.loadComicInfo!('/library/漫画 %.cbz');
      token.cancel('Thumbnail unmounted');
      gate.complete();
      await cancelled;
      final result = await details;
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.data.title, 'Cloud book');
    },
  );

  test(
    'force refresh applies the new version while an old index is loading',
    () async {
      await engine.synchronize();
      final gate = responseGate = Completer<void>();
      final started = responseStarted = Completer<void>();
      final oldOpen = source.loadComicInfo!('/library/漫画 %.cbz');
      await started.future;
      revision = 2;
      zip = createZip(revision);
      final listed = store.listed = Completer<void>();
      final refreshing = engine.synchronize(force: true);
      await listed.future;
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await oldOpen;
      final refreshed = await refreshing;
      expect(refreshed.success, isTrue, reason: refreshed.errorMessage);
      final pages = await source.loadComicPages!('/library/漫画 %.cbz', null);
      expect(pages.success, isTrue, reason: pages.errorMessage);
      expect(
        await ImageDownloader.loadComicImageBytes(
          pages.data.first,
          source.key,
          '/library/漫画 %.cbz',
          '',
        ),
        [2, 2],
      );
    },
  );

  test(
    'classification and overlapping roots retain full archive identities',
    () async {
      engine.cancel();
      store.nested = true;
      engine = WebDavLibraryEngine(
        library: const RemoteLibrary(
          id: 'nested',
          sourceKey: 'nested-source',
          accountId: 'archive-account',
          directories: ['/library/', '/library/category/'],
          name: 'Nested',
          autoRefresh: false,
        ),
        store: store,
      );
      source = engine.create();
      expect((await engine.synchronize()).success, isTrue);
      final list = await source.explorePages.single.loadPage!(1);
      expect(list.data.map((comic) => comic.id), [
        '/library/category/漫画 %.cbz',
      ]);
      expect(ranges, isEmpty);
      expect(store.links, 0);
    },
  );
}

class _ArchiveStore implements RemoteFileStore {
  _ArchiveStore(this.file, this.remoteLink);
  final RemoteEntry Function() file;
  final RemoteLink remoteLink;
  var nested = false;
  var links = 0;
  var stats = 0;
  var downloads = 0;
  var writes = 0;
  Completer<void>? listed;

  @override
  final account = const StorageAccount(
    id: 'archive-account',
    backend: StorageBackend.openlist,
    driver: 'GoogleDrive',
    name: 'Archive account',
    authorization: {},
  );
  @override
  Future<List<RemoteEntry>> list(String directory) async {
    listed?.complete();
    listed = null;
    return nested && directory == '/library/'
        ? const [
            RemoteEntry(
              name: 'category',
              path: '/library/category/',
              isDirectory: true,
            ),
          ]
        : [file()];
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    stats++;
    return file();
  }

  @override
  Future<RemoteLink> link(String path) async {
    links++;
    return remoteLink;
  }

  @override
  Future<void> cancelAll() async {}
  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress)? onProgress,
  }) async {
    downloads++;
  }

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    writes++;
    return const RemoteWriteResult();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
