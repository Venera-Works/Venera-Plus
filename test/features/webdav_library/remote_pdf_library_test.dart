import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/webdav_library/remote_archive_comic.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

const _bookId = '/library/Book.pdf';
const _sidecar = '$_bookId.metadata.json';
const _pdfSize = 6 * 1024 * 1024;
const _pageOffsets = [512 * 1024, 5 * 512 * 1024, 9 * 512 * 1024];
typedef _ByteRange = ({int offset, int length});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Exercise the real HTTP adapter; the only PDF substitution is its opener.
  HttpOverrides.global = null;
  late Directory directory;
  late Uint8List pdf;
  late _PdfStore store;
  late _PdfProbe probe;
  late HttpServer server;
  late WebDavLibraryEngine engine;
  late ComicSource source;
  var revision = 1;
  var archivePath = _bookId;
  var return200 = false;
  var nonRangeRequests = 0;
  final ranges = <_ByteRange>[];
  final clients = <Dio>[];
  final otherEngines = <WebDavLibraryEngine>[];
  final gates = <Completer<void>>[];
  Completer<void>? nextResponseGate;
  Completer<void>? responseStarted;

  WebDavLibraryEngine createEngine({String id = 'pdf-library'}) =>
      WebDavLibraryEngine(
        library: RemoteLibrary(
          id: id,
          sourceKey: '$id-source',
          accountId: 'pdf-account',
          directories: const ['/library/'],
          name: 'PDF library',
          autoRefresh: false,
        ),
        store: store,
      );

  Future<List<String>> chapterPages(
    ComicDetails details, {
    ComicSource? from,
  }) async {
    final result = <String>[];
    for (final id in details.chapters!.ids) {
      final pages = await (from ?? source).loadComicPages!(details.id, id);
      expect(pages.success, isTrue, reason: pages.errorMessage);
      result.addAll(pages.data);
    }
    return result;
  }

  Future<Uint8List> loadPage(
    String key, {
    CancelToken? token,
    ComicSource? from,
  }) async {
    final config = await (from ?? source).getImageLoadingConfig!(
      key,
      archivePath,
      '',
    );
    return (config['loadBytes'] as ComicImageBytesLoader)(
      token ?? CancelToken(),
    );
  }

  void expectBoundedRequests() {
    expect(nonRangeRequests, 0);
    expect(store.downloads, 0);
    expect(
      ranges,
      everyElement(
        predicate<_ByteRange>(
          (range) =>
              range.offset >= 0 &&
              range.length > 0 &&
              range.length <= 2 * 1024 * 1024 &&
              range.length < pdf.length,
        ),
      ),
    );
    expect(
      ranges.fold(0, (sum, range) => sum + range.length),
      lessThan(pdf.length),
    );
  }

  void expectClosedDocuments() {
    expect(
      probe.documents,
      everyElement(
        predicate<_PdfDocument>((document) => document.disposeCount == 1),
      ),
    );
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('remote-pdf-library-');
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
    return200 = false;
    nonRangeRequests = 0;
    nextResponseGate = null;
    responseStarted = null;
    pdf = _createPdfBytes(revision);
    probe = _PdfProbe();
    RemotePdfReader.debugOpenDocument = probe.open;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('x-pdf-auth'), 'preserved');
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
      final bytes = pdf;
      final etag = '"pdf-$revision"';
      ranges.add((offset: start, length: end - start + 1));
      final secondPageOffset = _pageOffsets[1];
      final gate = start <= secondPageOffset && end >= secondPageOffset
          ? nextResponseGate
          : null;
      if (gate != null) {
        nextResponseGate = null;
        responseStarted?.complete();
        responseStarted = null;
      }
      await gate?.future;
      request.response.statusCode = return200 ? 200 : 206;
      request.response.headers.set('etag', etag);
      if (!return200) {
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${bytes.length}',
        );
      }
      try {
        // A server ignoring Range is rejected from its headers; there is no
        // reason for the fixture to push a full six-MiB body into that socket.
        request.response.add(
          return200 ? bytes.sublist(0, 64) : bytes.sublist(start, end + 1),
        );
        await request.response.close();
      } on SocketException {
        // The cancelled client can close its socket before its gate opens.
      } on HttpException {
        // Cancelling a streaming response can also interrupt its flush.
      }
    });
    store = _PdfStore(
      () => RemoteEntry(
        name: 'Book.pdf',
        path: archivePath,
        isDirectory: false,
        size: pdf.length,
        eTag: '"pdf-$revision"',
        modifiedAt: DateTime.utc(2026, 10, 27).millisecondsSinceEpoch,
      ),
      RemoteLink(
        url: 'http://127.0.0.1:${server.port}/book',
        headers: const {'x-pdf-auth': 'preserved'},
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
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    ImageDownloader.cancelAllLoadingImages();
    for (final other in otherEngines) {
      other.cancel();
    }
    otherEngines.clear();
    engine.cancel();
    ImageDownloader.debugResetSourceImageLoading();
    await ImageDownloader.debugFlushImageCacheWrites();
    await CacheManager.resetForTesting();
    RemotePdfReader.debugOpenDocument = null;
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
    'PDF discovery stays lazy and native bookmarks include the first page',
    () async {
      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final listed = await source.explorePages.single.loadPage!(1);
      expect(listed.success, isTrue, reason: listed.errorMessage);
      expect(listed.data.single.id, _bookId);
      expect(listed.data.single.title, 'Book');
      expect(ranges, isEmpty);
      expect(probe.openCount, 0);
      expect(store.linkedPaths, isEmpty);
      expect(store.statPaths, isEmpty);

      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.title, 'Book');
      expect(info.data.maxPage, 3);
      expect(info.data.chapters!.ids, ['__pdf_range_0', '__pdf_range_1']);
      expect(info.data.chapters!.titles, ['Opening', 'Finale']);
      expect(info.data.chapterPageCounts.values, [2, 1]);
      expect(info.data.chapterGroups, isEmpty);
      final pages = await chapterPages(info.data);
      expect(pages.map((key) => RemoteArchiveComic.parseImageKey(key)!.entry), [
        'pdf:1',
        'pdf:2',
        'pdf:3',
      ]);
      expect(RemoteArchiveComic.parseImageKey(info.data.cover)!.entry, 'pdf:1');
      expect(probe.openCount, 1);
      expect(probe.documents.single.renderedPages, isEmpty);
      expect(
        probe.nativeReads,
        containsAll([
          (offset: 0, length: 32),
          (offset: pdf.length - 32, length: 32),
        ]),
      );
      expectClosedDocuments();
      expectBoundedRequests();
    },
  );

  test(
    'unbookmarked PDFs render actual JPEGs and reopen cached indexes with independent documents',
    () async {
      pdf = _createPdfBytes(revision, bookmarks: false);
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.chapters!.allChapters, {'__root__': 'Full book'});
      expect(info.data.chapterPageCounts, {'__root__': 3});
      expect(info.data.maxPage, 3);
      final pages = await chapterPages(info.data);
      expect(pages, hasLength(3));
      final cover = await ImageDownloader.loadThumbnail(
        info.data.cover,
        source.key,
      ).last;
      final first = _decodeJpeg(cover.imageBytes!, width: 12, height: 9);
      expect(first.r, greaterThan(180));
      expect(first.b, lessThan(80));
      final second = _decodeJpeg(
        await loadPage(pages[1]),
        width: 6,
        height: 12,
      );
      expect(second.b, greaterThan(180));
      expect(second.r, lessThan(80));
      expect(probe.documents.map((document) => document.renderedPages), [
        [],
        [1],
        [2],
      ]);
      expectClosedDocuments();

      final opens = probe.openCount;
      final requests = ranges.length;
      final lists = store.listPaths.length;
      final stats = store.statPaths.length;
      engine.cancel();
      WebDavLibrarySource.resetCacheForTesting();
      engine = createEngine();
      source = engine.create();
      final reopened = await source.loadComicInfo!(_bookId);
      expect(reopened.success, isTrue, reason: reopened.errorMessage);
      expect(reopened.data.chapterPageCounts, info.data.chapterPageCounts);
      expect(await chapterPages(reopened.data), pages);
      expect(probe.openCount, opens);
      expect(ranges, hasLength(requests));
      expect(store.listPaths, hasLength(lists));
      expect(store.statPaths, hasLength(stats));
      final again = _decodeJpeg(await loadPage(pages[1]), width: 6, height: 12);
      expect(again.b, greaterThan(180));
      expect(probe.openCount, opens + 1);
      expect(probe.documents.last, isNot(same(probe.documents[2])));
      expect(probe.documents.last.renderedPages, [2]);
      expectClosedDocuments();
      expectBoundedRequests();
    },
  );

  test(
    'PDF sidecars inherit native bookmarks and use If-Match without changing the file',
    () async {
      store.texts[_sidecar] = RemoteTextFile(
        content: jsonEncode({'title': 'Sidecar PDF', 'custom': 'kept'}),
        eTag: '"sidecar-before"',
      );
      store.texts['/library/metadata.json'] = RemoteTextFile(
        content: jsonEncode({'title': 'Directory only'}),
      );
      final original = Uint8List.fromList(pdf);
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.title, 'Sidecar PDF');
      expect(info.data.chapters!.titles, ['Opening', 'Finale']);
      expect(info.data.chapterPageCounts.values, [2, 1]);
      final pages = await chapterPages(info.data);
      expect(store.textReads, contains(_sidecar));
      expect(store.textReads, isNot(contains('/library/metadata.json')));
      final requests = ranges.length;
      final opens = probe.openCount;
      await engine.writeMetadata(
        _bookId,
        const ComicMetaData(
          title: 'Bound PDF',
          author: 'Writer',
          tags: ['bound'],
          bangumiSubjectId: 123,
        ),
      );
      expect(store.textWrites.single.path, _sidecar);
      expect(store.textWrites.single.ifMatch, '"sidecar-before"');
      expect(store.textWrites.single.createOnly, isFalse);
      final written = jsonDecode(store.texts[_sidecar]!.content) as Map;
      expect(written['custom'], 'kept');
      expect(written['chapters'], [
        {'title': 'Opening', 'start': 1, 'end': 2},
        {'title': 'Finale', 'start': 3, 'end': 3},
      ]);
      final updated = await source.loadComicInfo!(_bookId);
      expect(updated.success, isTrue, reason: updated.errorMessage);
      expect(updated.data.title, 'Bound PDF');
      expect(await chapterPages(updated.data), pages);
      expect(ranges, hasLength(requests));
      expect(probe.openCount, opens);
      expect(pdf, original);
      expectClosedDocuments();
      expectBoundedRequests();
    },
  );

  test(
    'new PDF sidecar ranges and pending binding retain the full filename and page identities',
    () async {
      pdf = _createPdfBytes(revision, bookmarks: false);
      final original = Uint8List.fromList(pdf);
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      final pages = await chapterPages(info.data);
      const binding = ComicMetaData(
        title: 'New binding',
        author: 'Writer',
        tags: ['bound'],
        bangumiSubjectId: 456,
        chapters: [
          ComicChapter(title: 'First page', start: 1, end: 1),
          ComicChapter(title: 'Remaining', start: 2, end: 3),
        ],
      );
      store.failNextWrite = true;
      await expectLater(
        engine.writeMetadata(_bookId, binding),
        throwsA(isA<WebDavTransientException>()),
      );
      final pendingStorageKey = 'webdavMetadataPending:${engine.library.id}';
      final pendingWrites = appdata.implicitData[pendingStorageKey] as Map;
      expect(pendingWrites, hasLength(1));
      final pending = pendingWrites.values.single as Map;
      expect(pending['libraryId'], engine.library.id);
      expect(pending['comicId'], _bookId);
      expect(pending['subjectId'], 456);
      expect(pending['failure'], WebDavMetadataPendingFailure.transient.name);
      expect(pending['attempts'], 1);
      expect(pending['metadata'], binding.toJson());
      expect(store.texts.containsKey(_sidecar), isFalse);
      await engine.writeMetadata(_bookId, binding);
      expect(appdata.implicitData[pendingStorageKey] as Map, isEmpty);
      expect(store.textWrites.map((write) => write.path), [_sidecar, _sidecar]);
      expect(
        store.textWrites.every(
          (write) => write.createOnly && write.ifMatch == null,
        ),
        isTrue,
      );
      expect(store.texts.containsKey('/library/Book.metadata.json'), isFalse);
      final updated = await source.loadComicInfo!(_bookId);
      expect(updated.success, isTrue, reason: updated.errorMessage);
      expect(updated.data.chapters!.titles, ['First page', 'Remaining']);
      expect(updated.data.chapterPageCounts.values, [1, 2]);
      expect(await chapterPages(updated.data), pages);
      expect(pdf, original);
      expectClosedDocuments();
      expectBoundedRequests();
    },
  );

  test(
    'a replaced PDF changes keys, rejects the old epoch and renders new bytes',
    () async {
      await engine.synchronize();
      final first = await source.loadComicInfo!(_bookId);
      expect(first.success, isTrue, reason: first.errorMessage);
      final oldPages = await chapterPages(first.data);
      revision = 2;
      pdf = _createPdfBytes(revision);
      final sync = await engine.synchronize(force: true);
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final next = await source.loadComicInfo!(_bookId);
      expect(next.success, isTrue, reason: next.errorMessage);
      final newPages = await chapterPages(next.data);
      expect(newPages[1], isNot(oldPages[1]));
      final opens = probe.openCount;
      await expectLater(loadPage(oldPages[1]), throwsFormatException);
      expect(probe.openCount, opens);
      final rendered = _decodeJpeg(
        await loadPage(newPages[1]),
        width: 6,
        height: 12,
      );
      expect(rendered.g, greaterThan(180));
      expect(rendered.b, lessThan(90));
      expect(probe.documents.last.renderedPages, [2]);
      expect(store.textWrites, isEmpty);
      expectClosedDocuments();
      expectBoundedRequests();
    },
  );

  test(
    'HTTP 200 preserves the range error and does not fall back to a full PDF download',
    () async {
      return200 = true;
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isFalse);
      final errorMessage = info.errorMessage!;
      expect(errorMessage, contains('bounded range'));
      expect(errorMessage.toLowerCase(), isNot(contains('password')));
      expect(probe.openCount, 1);
      expect(probe.documents, isEmpty);
      expectBoundedRequests();
    },
  );

  test(
    'cancelling one PDF image disposes only its document and permits a fresh retry',
    () async {
      final info = await source.loadComicInfo!(_bookId);
      expect(info.success, isTrue, reason: info.errorMessage);
      final pages = await chapterPages(info.data);
      final other = createEngine(id: 'other-pdf-library');
      otherEngines.add(other);
      final otherSource = other.create();
      final otherInfo = await otherSource.loadComicInfo!(_bookId);
      expect(otherInfo.success, isTrue, reason: otherInfo.errorMessage);
      final otherPages = await chapterPages(otherInfo.data, from: otherSource);

      final httpGate = Completer<void>();
      gates.add(httpGate);
      nextResponseGate = httpGate;
      final started = responseStarted = Completer<void>();
      final token = CancelToken();
      final cancelled = expectLater(
        loadPage(pages[1], token: token),
        throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue),
        ),
      );
      await started.future.timeout(const Duration(seconds: 5));
      final cancelledDocument = probe.documents.last;
      expect(cancelledDocument.renderedPages, [2]);
      final otherGate = Completer<void>();
      gates.add(otherGate);
      probe.renderGates[3] = otherGate;
      final otherStarted = probe.renderStarted[3] = Completer<void>();
      final otherBytes = loadPage(otherPages[2], from: otherSource);
      await otherStarted.future.timeout(const Duration(seconds: 5));
      final otherDocument = probe.documents.last;
      expect(otherDocument, isNot(same(cancelledDocument)));
      token.cancel('Reader disposed');
      await cancelled.timeout(const Duration(seconds: 5));
      expect(cancelledDocument.disposeCount, 1);
      expect(otherDocument.disposeCount, 0);
      otherGate.complete();
      _decodeJpeg(await otherBytes, width: 12, height: 12);
      expect(otherDocument.disposeCount, 1);
      httpGate.complete();
      final retry = _decodeJpeg(await loadPage(pages[1]), width: 6, height: 12);
      expect(retry.b, greaterThan(180));
      expect(probe.documents.last, isNot(same(cancelledDocument)));
      expectClosedDocuments();
      expectBoundedRequests();
    },
  );

  test(
    'PDFs inside an image directory remain separate comics with their own pages',
    () async {
      archivePath = '/library/Mixed/Book.pdf';
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
      expect(probe.openCount, 0);
      final info = await source.loadComicInfo!('/library/Mixed/');
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.maxPage, 2);
      final pages = await source.loadComicPages!('/library/Mixed/', null);
      expect(pages.success, isTrue, reason: pages.errorMessage);
      expect(pages.data, ['/library/Mixed/001.jpg', '/library/Mixed/002.jpg']);
      expect(probe.openCount, 0);
      expect(ranges, isEmpty);
      final archive = await source.loadComicInfo!(archivePath);
      expect(archive.success, isTrue, reason: archive.errorMessage);
      expect(archive.data.maxPage, 3);
      expectClosedDocuments();
      expectBoundedRequests();
    },
  );
}

image.Pixel _decodeJpeg(
  Uint8List bytes, {
  required int width,
  required int height,
}) {
  expect(bytes.take(2), [0xff, 0xd8]);
  final decoded = image.decodeJpg(bytes);
  expect(decoded, isNotNull);
  expect(decoded!.width, width);
  expect(decoded.height, height);
  return decoded.getPixel(width ~/ 2, height ~/ 2);
}

Uint8List _createPdfBytes(int revision, {bool bookmarks = true}) {
  // Only the injected PDF backend interprets these markers. The transport,
  // model, source, pixel conversion and JPEG encoder remain real.
  final bytes = Uint8List(_pdfSize)..fillRange(0, _pdfSize, 46);
  bytes.setRange(0, 10, ascii.encode('%PDF-FAKE\n'));
  bytes[16] = revision;
  bytes[17] = bookmarks ? 1 : 0;
  bytes.setRange(bytes.length - 5, bytes.length, ascii.encode('%%EOF'));
  final colors = revision == 1
      ? const [
          [220, 40, 20],
          [20, 40, 220],
          [210, 200, 20],
        ]
      : const [
          [30, 210, 50],
          [30, 210, 50],
          [30, 210, 50],
        ];
  for (var i = 0; i < _pageOffsets.length; i++) {
    bytes.setRange(_pageOffsets[i], _pageOffsets[i] + 4, [i + 1, ...colors[i]]);
  }
  return bytes;
}

class _PdfProbe {
  var openCount = 0;
  final documents = <_PdfDocument>[];
  final nativeReads = <_ByteRange>[];
  final renderGates = <int, Completer<void>>{};
  final renderStarted = <int, Completer<void>>{};

  Future<Uint8List> _readAligned(
    ZipRangeRead read,
    int position,
    int length,
    int size,
  ) async {
    nativeReads.add((offset: position, length: length));
    if (position < 0 ||
        length < 0 ||
        position > size ||
        length > size - position) {
      throw const FormatException('PDF byte range is outside the document');
    }
    const window = 256 * 1024;
    const maxRead = 2 * 1024 * 1024;
    var copied = 0;
    final result = Uint8List(length);
    while (copied < length) {
      final current = position + copied;
      final start = current ~/ window * window;
      final room = maxRead - (current - start);
      final count = length - copied < room ? length - copied : room;
      final roundedEnd = (current + count + window - 1) ~/ window * window;
      final end = roundedEnd < size ? roundedEnd : size;
      final bytes = await read(start, end - start);
      if (bytes.length != end - start) {
        throw const FormatException(
          'PDF range response has an unexpected length',
        );
      }
      result.setRange(copied, copied + count, bytes, current - start);
      copied += count;
    }
    return result;
  }

  Future<RemotePdfDocument> open({
    required ZipRangeRead read,
    required int size,
    required String sourceName,
    CancelToken? cancelToken,
  }) async {
    openCount++;
    expect(size, _pdfSize);
    expect(sourceName, isNotEmpty);
    final header = await _readAligned(read, 0, 32, size);
    if (header.length != 32 || ascii.decode(header.sublist(0, 5)) != '%PDF-') {
      throw const FormatException('Native bridge could not open the PDF');
    }
    final document = _PdfDocument(
      this,
      (offset, length) => _readAligned(read, offset, length, size),
      size,
      header[17] == 1,
    );
    documents.add(document);
    return document;
  }
}

class _PdfDocument implements RemotePdfDocument {
  _PdfDocument(this.probe, this.read, this.size, this.bookmarks);
  final _PdfProbe probe;
  final ZipRangeRead read;
  final int size;
  final bool bookmarks;
  var disposeCount = 0;
  final renderedPages = <int>[];

  @override
  int get pageCount => 3;

  @override
  bool get isEncrypted => false;

  @override
  Future<List<PdfOutlineNode>> loadOutline() async {
    final trailer = await read(size - 32, 32);
    if (trailer.length != 32) {
      throw const FormatException('Native bridge could not load the outline');
    }
    return bookmarks
        ? const [
            PdfOutlineNode(
              title: 'Opening',
              dest: PdfDest(1, PdfDestCommand.fit, null),
              children: [],
            ),
            PdfOutlineNode(
              title: 'Finale',
              dest: PdfDest(3, PdfDestCommand.fit, null),
              children: [],
            ),
          ]
        : const [];
  }

  @override
  Future<Uint8List> renderPage(int pageNumber) async {
    renderedPages.add(pageNumber);
    final buffer = await read(_pageOffsets[pageNumber - 1], 64);
    if (buffer.length != 64) {
      throw const FormatException('Native bridge could not render the page');
    }
    expect(buffer[0], pageNumber);
    probe.renderStarted.remove(pageNumber)?.complete();
    await probe.renderGates.remove(pageNumber)?.future;
    expect(disposeCount, 0);
    final (width, height) = switch (pageNumber) {
      1 => (12, 9),
      2 => (6, 12),
      _ => (12, 12),
    };
    final img = image.Image(width: width, height: height);
    for (final pixel in img) {
      pixel
        ..r = buffer[1]
        ..g = buffer[2]
        ..b = buffer[3];
    }
    return Uint8List.fromList(image.encodeJpg(img, quality: 92));
  }

  @override
  Future<void> dispose() async => disposeCount++;
}

class _PdfStore implements RemoteFileStore {
  _PdfStore(this.file, this.remoteLink);
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
  var failNextWrite = false;
  var downloads = 0;

  @override
  StorageAccount get account => const StorageAccount(
    id: 'pdf-account',
    backend: StorageBackend.webdav,
    driver: 'webdav',
    name: 'PDF account',
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
    if (failNextWrite) {
      failNextWrite = false;
      throw WebDavTransientException(path);
    }
    final previous = texts[path];
    if (createOnly && previous != null ||
        ifMatch != null && previous?.eTag != ifMatch ||
        ifUnmodifiedSince != null &&
            previous?.modifiedAt != ifUnmodifiedSince) {
      throw WebDavPreconditionFailedException(path);
    }
    final eTag = '"pdf-sidecar-${textWrites.length}"';
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
    throw StateError('Remote PDFs must use Range reads');
  }

  @override
  Future<void> cancelAll() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
