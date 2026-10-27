import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/webdav_library/remote_archive_comic.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

const _bookId = '/library/Book.epub';
const _sidecar = '$_bookId.metadata.json';
const _coverEntry = 'OPS/Images/jacket.jpg';
const _spineImages = [
  'OPS/Images/3.jpg',
  'OPS/Images/1.jpg',
  'OPS/Images/2.jpg',
];
typedef _ByteRange = ({int offset, int length});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These are actual loopback HTTP Range responses, not widget HTTP mocks.
  HttpOverrides.global = null;
  late Directory directory;
  late _EpubPackage epub;
  late _EpubStore store;
  late HttpServer server;
  late WebDavLibraryEngine engine;
  late ComicSource source;
  var revision = 1;
  var archivePath = _bookId;
  var nonRangeRequests = 0;
  final ranges = <_ByteRange>[];
  final clients = <Dio>[];
  Completer<void>? responseGate;
  Completer<void>? responseStarted;

  WebDavLibraryEngine createEngine() => WebDavLibraryEngine(
    library: const RemoteLibrary(
      id: 'epub-library',
      sourceKey: 'epub-source',
      accountId: 'epub-account',
      directories: ['/library/'],
      name: 'EPUB library',
      autoRefresh: false,
    ),
    store: store,
  );

  Future<List<String>> chapterPages(ComicDetails details) async {
    final pages = <String>[];
    for (final chapter in details.chapters!.ids) {
      final result = await source.loadComicPages!(details.id, chapter);
      expect(result.success, isTrue, reason: result.errorMessage);
      pages.addAll(result.data);
    }
    return pages;
  }

  void expectNoImagePayloadRead() {
    expect(epub.imagePayloads, hasLength(5));
    expect(
      ranges.any(
        (range) => epub.imagePayloads.values.any(
          (payload) => _overlaps(range, payload),
        ),
      ),
      isFalse,
      reason:
          'Opening an EPUB must read control documents without fetching image payloads',
    );
  }

  void expectNoFullDownload() {
    expect(nonRangeRequests, 0);
    expect(store.downloads, 0);
    expect(
      ranges.fold(0, (sum, range) => sum + range.length),
      lessThan(epub.bytes.length),
    );
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('remote-epub-library-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    CacheManager.debugDisableInitialScan = true;
    WebDavLibrarySource.resetCacheForTesting();
    WebDavLibrarySource.configureMetadataScraper(null);
    WebDavLibrarySource.configureMetadataWriteGuard(null);
    appdata.implicitData.clear();
    WebDavLibrarySource.archiveSchedulerFactory = () =>
        RemoteReadScheduler(minInterval: Duration.zero);
    ranges.clear();
    revision = 1;
    archivePath = _bookId;
    nonRangeRequests = 0;
    responseGate = null;
    responseStarted = null;
    epub = _createEpub(revision);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('x-epub-auth'), 'preserved');
      final match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(request.headers.value('range') ?? '');
      if (match == null) {
        nonRangeRequests++;
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      final bytes = epub.bytes;
      final etag = '"epub-$revision"';
      ranges.add((offset: start, length: end - start + 1));
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
      request.response.headers.set('etag', etag);
      try {
        request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
      } on SocketException {
        // Cancelling an entry read may close its socket before the gate opens.
      } on HttpException {
        // The client can also close the response while the fixture is flushing.
      }
    });
    store = _EpubStore(
      () => RemoteEntry(
        name: 'Book.epub',
        path: archivePath,
        isDirectory: false,
        size: epub.bytes.length,
        eTag: '"epub-$revision"',
        modifiedAt: DateTime.utc(2026, 10, 27).millisecondsSinceEpoch,
      ),
      RemoteLink(
        url: 'http://127.0.0.1:${server.port}/book',
        headers: const {'x-epub-auth': 'preserved'},
      ),
    );
    engine = createEngine();
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
    responseGate?.complete();
    ImageDownloader.cancelAllLoadingImages();
    engine.cancel();
    ImageDownloader.debugResetSourceImageLoading();
    await ImageDownloader.debugFlushImageCacheWrites();
    await CacheManager.resetForTesting();
    WebDavLibrarySource.archiveDioFactory = null;
    WebDavLibrarySource.archiveSchedulerFactory = null;
    WebDavLibrarySource.configureMetadataScraper(null);
    WebDavLibrarySource.configureMetadataWriteGuard(null);
    appdata.implicitData.clear();
    WebDavLibrarySource.resetCacheForTesting();
    for (final client in clients) {
      client.close(force: true);
    }
    clients.clear();
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });

  test(
    'lazy discovery and first details read only EPUB control documents',
    () async {
      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final listed = await source.explorePages.single.loadPage!(1);
      expect(listed.success, isTrue, reason: listed.errorMessage);
      expect(listed.data.single.id, _bookId);
      expect(listed.data.single.title, 'Book');
      expect(ranges, isEmpty);
      expect(store.linkedPaths, isEmpty);
      expect(store.statPaths, isEmpty);

      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.title, 'Spine ordered book');
      expect(info.data.tags['作者'], ['EPUB author']);
      expect(info.data.tags['标签'], ['manga']);
      expect(info.data.description, 'OPF description');
      expect(info.data.maxPage, 3);
      expect(info.data.chapters!.isGrouped, isFalse);
      expect(info.data.chapters!.titles, ['Opening', 'Finale']);
      expect(info.data.chapterPageCounts.values, [2, 1]);
      expect(info.data.chapterGroups, isEmpty);
      expect(ranges, isNotEmpty);
      expectNoImagePayloadRead();
      expectNoFullDownload();
    },
  );

  test(
    'spine order, declared cover and chapter layout survive a disk-cache reopen',
    () async {
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      final pages = await chapterPages(info.data);
      expect(
        pages.map((key) => RemoteArchiveComic.parseImageKey(key)!.entry),
        _spineImages,
      );
      expect(pages, everyElement(startsWith(remoteArchiveImagePrefix)));
      expect(pages, isNot(contains(info.data.cover)));
      expectNoImagePayloadRead();

      for (var i = 0; i < pages.length; i++) {
        expect(
          await ImageDownloader.loadComicImageBytes(
            pages[i],
            source.key,
            _bookId,
            '',
          ),
          epub.imageBytes[_spineImages[i]],
        );
      }
      final cover = await ImageDownloader.loadThumbnail(
        info.data.cover,
        source.key,
      ).last;
      expect(cover.imageBytes, epub.imageBytes[_coverEntry]);
      expectNoFullDownload();

      final requestCount = ranges.length;
      final listCount = store.listPaths.length;
      final statCount = store.statPaths.length;
      engine.cancel();
      WebDavLibrarySource.resetCacheForTesting();
      engine = createEngine();
      source = engine.create();
      final reopened = await source.loadComicInfo!(_bookId);
      expect(reopened.success, isTrue, reason: reopened.errorMessage);
      expect(
        reopened.data.chapters!.allChapters,
        info.data.chapters!.allChapters,
      );
      expect(reopened.data.chapterPageCounts, info.data.chapterPageCounts);
      expect(reopened.data.cover, info.data.cover);
      expect(await chapterPages(reopened.data), pages);
      expect(ranges, hasLength(requestCount));
      expect(store.listPaths, hasLength(listCount));
      expect(store.statPaths, hasLength(statCount));
      expect(store.downloads, 0);
    },
  );

  test(
    'EPUB sidecar overrides nav ranges, inherits OPF fields and writes conditionally',
    () async {
      store.texts[_sidecar] = RemoteTextFile(
        content: jsonEncode({
          'title': 'Sidecar title',
          'custom': 'kept',
          'chapters': [
            {'title': 'Exact/first', 'start': 1, 'end': 1},
            {'title': 'Remaining', 'start': 2, 'end': 3},
          ],
        }),
        eTag: '"sidecar-before"',
      );
      store.texts['/library/metadata.json'] = RemoteTextFile(
        content: jsonEncode({'title': 'Directory metadata is unrelated'}),
      );
      final original = Uint8List.fromList(epub.bytes);
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.title, 'Sidecar title');
      expect(info.data.description, 'OPF description');
      expect(info.data.tags['作者'], ['EPUB author']);
      expect(info.data.tags['标签'], ['manga']);
      expect(info.data.chapters!.titles, ['Exact/first', 'Remaining']);
      expect(info.data.chapterPageCounts.values, [1, 2]);
      final pages = await chapterPages(info.data);
      expect(
        pages.map((key) => RemoteArchiveComic.parseImageKey(key)!.entry),
        _spineImages,
      );
      expect(store.textReads, contains(_sidecar));
      expect(store.textReads, isNot(contains('/library/metadata.json')));
      expectNoImagePayloadRead();

      final requestCount = ranges.length;
      await engine.writeMetadata(
        _bookId,
        const ComicMetaData(
          title: 'Bound title',
          author: 'Bound author',
          tags: ['bound'],
          bangumiSubjectId: 123,
        ),
      );
      expect(store.textWrites.single.path, _sidecar);
      expect(store.textWrites.single.ifMatch, '"sidecar-before"');
      expect(store.textWrites.single.createOnly, isFalse);
      final document = jsonDecode(store.texts[_sidecar]!.content) as Map;
      expect(document['custom'], 'kept');
      expect(document['chapters'], [
        {'title': 'Exact/first', 'start': 1, 'end': 1},
        {'title': 'Remaining', 'start': 2, 'end': 3},
      ]);
      expect(document['bangumiSubjectId'], 123);
      final updated = await source.loadComicInfo!(_bookId);
      expect(updated.success, isTrue, reason: updated.errorMessage);
      expect(updated.data.title, 'Bound title');
      expect(updated.data.chapters!.titles, ['Exact/first', 'Remaining']);
      expect(await chapterPages(updated.data), pages);
      expect(ranges, hasLength(requestCount));
      expect(epub.bytes, original);
      expectNoFullDownload();
    },
  );

  test(
    'new EPUB binding creates its full-name sidecar and retains OPF nav chapters',
    () async {
      final original = Uint8List.fromList(epub.bytes);
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      final pages = await chapterPages(info.data);
      final requestCount = ranges.length;
      await engine.writeMetadata(
        _bookId,
        const ComicMetaData(
          title: 'New binding',
          author: 'Matched author',
          tags: ['matched'],
          bangumiSubjectId: 456,
        ),
      );
      expect(store.textWrites.single.path, _sidecar);
      expect(store.textWrites.single.createOnly, isTrue);
      expect(store.textWrites.single.ifMatch, isNull);
      expect(store.texts.containsKey('/library/Book.metadata.json'), isFalse);
      final updated = await source.loadComicInfo!(_bookId);
      expect(updated.success, isTrue, reason: updated.errorMessage);
      expect(updated.data.title, 'New binding');
      expect(updated.data.chapters!.titles, ['Opening', 'Finale']);
      expect(updated.data.chapterPageCounts.values, [2, 1]);
      expect(await chapterPages(updated.data), pages);
      expect(ranges, hasLength(requestCount));
      expect(epub.bytes, original);
      expectNoFullDownload();
    },
  );

  test(
    'image directories beside an EPUB keep their own pages and identity',
    () async {
      archivePath = '/library/Mixed/Book.epub';
      store.mixed = true;
      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final comics = await source.explorePages.single.loadPage!(1);
      expect(comics.success, isTrue, reason: comics.errorMessage);
      expect(
        comics.data.map((comic) => comic.id),
        unorderedEquals(['/library/Mixed/', archivePath]),
      );
      expect(ranges, isEmpty);
      expect(store.linkedPaths, isEmpty);
      final directoryInfo = await source.loadComicInfo!('/library/Mixed/');
      expect(directoryInfo.success, isTrue, reason: directoryInfo.errorMessage);
      expect(directoryInfo.data.maxPage, 2);
      final pages = await source.loadComicPages!('/library/Mixed/', null);
      expect(pages.success, isTrue, reason: pages.errorMessage);
      expect(pages.data, ['/library/Mixed/001.jpg', '/library/Mixed/002.jpg']);
      expect(ranges, isEmpty);
      final archiveInfo = await source.loadComicInfo!(archivePath);
      expect(archiveInfo.success, isTrue, reason: archiveInfo.errorMessage);
      expect(archiveInfo.data.maxPage, 3);
      expectNoImagePayloadRead();
      expectNoFullDownload();
    },
  );

  test(
    'refreshing a replaced EPUB changes page identities and reads the new bytes',
    () async {
      await engine.synchronize();
      final first = await source.loadComicInfo!(_bookId);
      expect(first.success, isTrue, reason: first.errorMessage);
      final firstPages = await chapterPages(first.data);
      revision = 2;
      epub = _createEpub(revision);
      final sync = await engine.synchronize(force: true);
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final next = await source.loadComicInfo!(_bookId);
      expect(next.success, isTrue, reason: next.errorMessage);
      final nextPages = await chapterPages(next.data);
      expect(nextPages.first, isNot(firstPages.first));
      expect(
        nextPages.map((key) => RemoteArchiveComic.parseImageKey(key)!.entry),
        _spineImages,
      );
      expect(
        await ImageDownloader.loadComicImageBytes(
          nextPages.first,
          source.key,
          _bookId,
          '',
        ),
        epub.imageBytes[_spineImages.first],
      );
      expect(store.textWrites, isEmpty);
      expectNoFullDownload();
    },
  );

  test(
    'text EPUBs fail without downloading the package or unrelated images',
    () async {
      epub = _createEpub(revision, textOnly: true);
      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      expect(ranges, isEmpty);
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isFalse);
      expect(info.errorMessage, isNotEmpty);
      expectNoImagePayloadRead();
      expectNoFullDownload();
      expect(store.textWrites, isEmpty);
    },
  );

  test(
    'cancelling an EPUB image range terminates the loader and permits retry',
    () async {
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      final pages = await chapterPages(info.data);
      expectNoImagePayloadRead();
      final config = await source.getImageLoadingConfig!(
        pages.first,
        _bookId,
        '',
      );
      final loader = config['loadBytes'] as ComicImageBytesLoader;
      final token = CancelToken();
      final gate = responseGate = Completer<void>();
      final started = responseStarted = Completer<void>();
      final cancelled = expectLater(
        loader(token),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      try {
        await started.future.timeout(const Duration(seconds: 5));
        token.cancel('Reader disposed');
        await cancelled.timeout(const Duration(seconds: 5));
      } finally {
        gate.complete();
      }
      expect(await loader(CancelToken()), epub.imageBytes[_spineImages.first]);
      expect(store.downloads, 0);
      expect(nonRangeRequests, 0);
    },
  );
}

bool _overlaps(_ByteRange left, _ByteRange right) =>
    left.offset < right.offset + right.length &&
    right.offset < left.offset + left.length;

class _EpubPackage {
  const _EpubPackage(this.bytes, this.imageBytes, this.imagePayloads);
  final Uint8List bytes;
  final Map<String, List<int>> imageBytes;
  final Map<String, _ByteRange> imagePayloads;
}

_EpubPackage _createEpub(int revision, {bool textOnly = false}) {
  final book = archive.Archive();
  void add(String name, List<int> bytes) =>
      book.addFile(archive.ArchiveFile.noCompress(name, bytes.length, bytes));
  void xml(String name, String content) => add(name, utf8.encode(content));
  add('mimetype', utf8.encode('application/epub+zip'));
  xml('META-INF/container.xml', '''<?xml version="1.0" encoding="utf-8"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  xml('OPS/package.opf', '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">epub-test</dc:identifier>
    <dc:title>Spine ordered book</dc:title><dc:creator>EPUB author</dc:creator>
    <dc:description>OPF description</dc:description><dc:subject>manga</dc:subject>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="jacket" href="Images/jacket.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="cover-page" href="Text/jacket.xhtml" media-type="application/xhtml+xml"/>
    <item id="one" href="Text/1.xhtml" media-type="application/xhtml+xml"/>
    <item id="two" href="Text/2.xhtml" media-type="application/xhtml+xml"/>
    <item id="three" href="Text/3.xhtml" media-type="application/xhtml+xml"/>
    <item id="image-one" href="Images/1.jpg" media-type="image/jpeg"/>
    <item id="image-two" href="Images/2.jpg" media-type="image/jpeg"/>
    <item id="image-three" href="Images/3.jpg" media-type="image/jpeg"/>
    <item id="unreferenced" href="Images/unreferenced.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine><itemref idref="cover-page"/><itemref idref="three"/><itemref idref="one"/><itemref idref="two"/></spine>
</package>''');
  xml(
    'OPS/nav.xhtml',
    '''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Contents</title></head><body><nav epub:type="toc"><ol>
    <li><a href="Text/3.xhtml">Opening</a></li><li><a href="Text/2.xhtml">Finale</a></li>
  </ol></nav></body></html>''',
  );
  xml(
    'OPS/Text/jacket.xhtml',
    '''<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Jacket</title></head>
<body><img src="../Images/jacket.jpg" alt="Jacket"/></body></html>''',
  );
  for (final number in [1, 2, 3]) {
    final body = textOnly
        ? '<p>This narrative is not an image comic.</p>'
        : number == 1
        ? '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="../Images/1.jpg"/></svg>'
        : '<img src="../Images/$number.jpg" alt="Page $number"/>';
    xml(
      'OPS/Text/$number.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page $number</title></head><body>$body</body></html>',
    );
  }
  // The image area is isolated from both control-document blocks and the EOCD
  // tail. A detail scan cannot accidentally pass by reading a small whole ZIP.
  add('before-images.padding', List.filled(2 * 1024 * 1024, 42));
  final imageBytes = <String, List<int>>{
    _coverEntry: [9, revision],
    'OPS/Images/1.jpg': [1, revision],
    'OPS/Images/2.jpg': [2, revision],
    'OPS/Images/3.jpg': [3, revision],
    'OPS/Images/unreferenced.jpg': [99, revision],
  };
  for (final image in imageBytes.entries) {
    add(image.key, image.value);
  }
  add('after-images.padding', List.filled(2 * 1024 * 1024, 43));
  final bytes = archive.ZipEncoder().encodeBytes(book, level: 0);
  // Read the fixture's stored local headers independently of RemoteZipIndex.
  final data = ByteData.sublistView(bytes);
  final payloads = <String, _ByteRange>{};
  var offset = 0;
  while (offset + 30 <= bytes.length &&
      data.getUint32(offset, Endian.little) == 0x04034b50) {
    final length = data.getUint32(offset + 18, Endian.little);
    final nameLength = data.getUint16(offset + 26, Endian.little);
    final extraLength = data.getUint16(offset + 28, Endian.little);
    final name = utf8.decode(
      bytes.sublist(offset + 30, offset + 30 + nameLength),
    );
    final start = offset + 30 + nameLength + extraLength;
    if (imageBytes.containsKey(name)) {
      payloads[name] = (offset: start, length: length);
    }
    offset = start + length;
  }
  return _EpubPackage(bytes, imageBytes, payloads);
}

class _EpubStore implements RemoteFileStore {
  _EpubStore(this.file, this.remoteLink);
  final RemoteEntry Function() file;
  final RemoteLink remoteLink;
  final texts = <String, RemoteTextFile>{};
  final textReads = <String>[];
  final listPaths = <String>[];
  final statPaths = <String>[];
  final linkedPaths = <String>[];
  final textWrites =
      <
        ({
          String path,
          bool createOnly,
          String? ifMatch,
          int? ifUnmodifiedSince,
        })
      >[];
  var mixed = false;
  var downloads = 0;

  @override
  StorageAccount get account => const StorageAccount(
    id: 'epub-account',
    backend: StorageBackend.webdav,
    driver: 'webdav',
    name: 'EPUB account',
    authorization: {},
  );

  @override
  Future<List<RemoteEntry>> list(String directory) async {
    listPaths.add(directory);
    if (mixed && directory == '/library/') {
      return const [
        RemoteEntry(name: 'Mixed', path: '/library/Mixed/', isDirectory: true),
      ];
    }
    return [
      if (mixed && directory == '/library/Mixed/')
        for (final name in ['cover.jpg', '002.jpg', '001.jpg'])
          RemoteEntry(
            name: name,
            path: '/library/Mixed/$name',
            isDirectory: false,
          ),
      file(),
      for (final text in texts.entries)
        if (text.key.substring(0, text.key.lastIndexOf('/') + 1) == directory)
          RemoteEntry(
            name: text.key.split('/').last,
            path: text.key,
            isDirectory: false,
            eTag: text.value.eTag,
            modifiedAt: text.value.modifiedAt,
          ),
    ];
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    statPaths.add(path);
    expect(path, file().path);
    return file();
  }

  @override
  Future<RemoteLink> link(String path) async {
    linkedPaths.add(path);
    expect(path, file().path);
    return remoteLink;
  }

  @override
  Future<RemoteTextFile> readText(String path) async {
    textReads.add(path);
    return texts[path] ??
        (throw const RemoteStorageException('Not found', code: '404'));
  }

  @override
  Future<RemoteWriteResult> writeText(
    String path,
    String content, {
    bool createOnly = false,
    String? ifMatch,
    int? ifUnmodifiedSince,
  }) async {
    expect(path, '${file().path}.metadata.json');
    textWrites.add((
      path: path,
      createOnly: createOnly,
      ifMatch: ifMatch,
      ifUnmodifiedSince: ifUnmodifiedSince,
    ));
    final previous = texts[path];
    if (createOnly && previous != null ||
        ifMatch != null && previous?.eTag != ifMatch ||
        ifUnmodifiedSince != null &&
            previous?.modifiedAt != ifUnmodifiedSince) {
      throw WebDavPreconditionFailedException(path);
    }
    final eTag = '"epub-sidecar-${textWrites.length}"';
    texts[path] = RemoteTextFile(
      content: content,
      eTag: eTag,
      modifiedAt: textWrites.length,
    );
    return RemoteWriteResult(eTag: eTag, modifiedAt: textWrites.length);
  }

  @override
  Future<void> download(
    String remotePath,
    String localPath, {
    void Function(RemoteTransferProgress)? onProgress,
  }) async {
    downloads++;
    throw StateError('Remote EPUBs must use Range reads, not package download');
  }

  @override
  Future<void> cancelAll() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
