import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pdfrx/pdfrx.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

const _pdfSize = 6 * 1024 * 1024;
const _pageOffsets = [512 * 1024, 5 * 512 * 1024, 9 * 512 * 1024];
typedef _TrackedRange = ({String path, int offset, int length});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  late _MultiFileStore store;
  late _PdfProbe probe;
  late HttpServer server;
  late WebDavLibraryEngine engine;
  late ComicSource source;
  final ranges = <_TrackedRange>[];
  final clients = <Dio>[];
  var nonRangeRequests = 0;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('remote-work-library-');
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
    nonRangeRequests = 0;
    probe = _PdfProbe();
    RemotePdfReader.debugOpenDocument = probe.open;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.headers.value('x-cloud-auth'), 'preserved');
      final path = request.uri.queryParameters['path'];
      final file = store.files[path];
      if (file == null) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final rangeHeader = request.headers.value('range');
      final match = RegExp(
        r'^bytes=(\d+)-(\d+)$',
      ).firstMatch(rangeHeader ?? '');
      if (match == null) {
        nonRangeRequests++;
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);
      ranges.add((path: path!, offset: start, length: end - start + 1));
      request.response.statusCode = 206;
      request.response.headers.set(
        'content-range',
        'bytes $start-$end/${file.bytes.length}',
      );
      if (file.eTag != null) {
        request.response.headers.set('etag', file.eTag!);
      }
      if (file.modifiedAt != null) {
        request.response.headers.set(
          'last-modified',
          HttpDate.format(
            DateTime.fromMillisecondsSinceEpoch(file.modifiedAt!),
          ),
        );
      }
      try {
        request.response.add(file.bytes.sublist(start, end + 1));
        await request.response.close();
      } on SocketException {
        // Client connection closed
      } on HttpException {
        // Client stream interrupted
      }
    });

    store = _MultiFileStore(
      RemoteLink(
        url: 'http://127.0.0.1:${server.port}/file',
        headers: const {'x-cloud-auth': 'preserved'},
      ),
    );
    engine = WebDavLibraryEngine(
      library: const RemoteLibrary(
        id: 'work-library',
        sourceKey: 'work-source',
        accountId: 'work-account',
        directories: ['/library/'],
        name: 'Work library',
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
    'one work groups mixed non-overlapping volumes without opening files',
    () async {
      store.addFile(
        '/library/混排作品 %/Nedpy_01.cbz',
        _createZip(1),
        eTag: '"cbz-v1"',
      );
      store.addFile(
        '/library/混排作品 %/Nedpy_02.epub',
        _createEpub(1),
        eTag: '"epub-v1"',
      );
      store.addFile(
        '/library/混排作品 %/Nedpy_03.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-v1"',
      );

      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      expect(ranges, isEmpty);
      expect(store.links, 0);
      expect(store.stats, 0);
      expect(store.downloads, 0);
      expect(nonRangeRequests, 0);

      final list = await source.explorePages.single.loadPage!(1);
      expect(list.data, hasLength(1));
      final item = list.data.single;
      expect(item.id.startsWith(remoteComicWorkPrefix), isTrue);
      final location = RemoteComicWork.location(item.id);
      expect(location.directory, '/library/混排作品 %/');
      expect(location.family, isNull);
      expect(item.title, '混排作品 %');
      expect(ranges, isEmpty);

      final info = await source.loadComicInfo!(item.id);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.title, '混排作品 %');
      expect(info.data.chapters!.isGrouped, isFalse);
      expect(info.data.chapters!.allChapters.length, 3);
      expect(info.data.chapters!.allChapters.keys.toList(), [
        '/library/混排作品 %/Nedpy_01.cbz',
        '/library/混排作品 %/Nedpy_02.epub',
        '/library/混排作品 %/Nedpy_03.pdf',
      ]);
      expect(info.data.chapters!.allChapters.values.toList(), [
        'Nedpy_01',
        'Nedpy_02',
        'Nedpy_03',
      ]);
      expect(ranges, isEmpty);

      final pagesRes = await source.loadComicPages!(
        item.id,
        '/library/混排作品 %/Nedpy_02.epub',
      );
      expect(pagesRes.success, isTrue, reason: pagesRes.errorMessage);
      expect(ranges, isNotEmpty);
      expect(
        ranges.every((r) => r.path == '/library/混排作品 %/Nedpy_02.epub'),
        isTrue,
        reason: 'Only the selected volume must be opened',
      );
    },
  );

  test(
    'selected EPUB, ZIP, and PDF volumes deliver exact image order and payload bytes',
    () async {
      store.addFile(
        '/library/混排作品 %/Nedpy_01.cbz',
        _createZip(1),
        eTag: '"cbz-v1"',
      );
      store.addFile(
        '/library/混排作品 %/Nedpy_02.epub',
        _createEpub(1),
        eTag: '"epub-v1"',
      );
      store.addFile(
        '/library/混排作品 %/Nedpy_03.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-v1"',
      );

      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final list = await source.explorePages.single.loadPage!(1);
      final workId = list.data.single.id;

      // 1. EPUB spine ordering & image keys
      final epubPages = await source.loadComicPages!(
        workId,
        '/library/混排作品 %/Nedpy_02.epub',
      );
      expect(epubPages.success, isTrue, reason: epubPages.errorMessage);
      expect(epubPages.data, hasLength(3));
      for (final key in epubPages.data) {
        expect(key.startsWith(remoteComicWorkImagePrefix), isTrue);
        final parsed = RemoteComicWork.parseImageKey(key);
        expect(parsed.work, workId);
        expect(parsed.volume, '/library/混排作品 %/Nedpy_02.epub');
        expect(parsed.image, isNotNull);
      }
      expect(
        await ImageDownloader.loadComicImageBytes(
          epubPages.data[0],
          source.key,
          workId,
          '/library/混排作品 %/Nedpy_02.epub',
        ),
        [3, 1], // three
      );
      expect(
        await ImageDownloader.loadComicImageBytes(
          epubPages.data[1],
          source.key,
          workId,
          '/library/混排作品 %/Nedpy_02.epub',
        ),
        [1, 1], // one
      );
      expect(
        await ImageDownloader.loadComicImageBytes(
          epubPages.data[2],
          source.key,
          workId,
          '/library/混排作品 %/Nedpy_02.epub',
        ),
        [2, 1], // two
      );

      // 2. ZIP images & payloads
      final zipPages = await source.loadComicPages!(
        workId,
        '/library/混排作品 %/Nedpy_01.cbz',
      );
      expect(zipPages.success, isTrue, reason: zipPages.errorMessage);
      expect(zipPages.data, hasLength(3));
      expect(
        await ImageDownloader.loadComicImageBytes(
          zipPages.data[0],
          source.key,
          workId,
          '/library/混排作品 %/Nedpy_01.cbz',
        ),
        [1, 1],
      );
      expect(
        await ImageDownloader.loadComicImageBytes(
          zipPages.data[1],
          source.key,
          workId,
          '/library/混排作品 %/Nedpy_01.cbz',
        ),
        [2, 1],
      );
      expect(
        await ImageDownloader.loadComicImageBytes(
          zipPages.data[2],
          source.key,
          workId,
          '/library/混排作品 %/Nedpy_01.cbz',
        ),
        [3, 1],
      );

      // 3. PDF page rendering
      final pdfPages = await source.loadComicPages!(
        workId,
        '/library/混排作品 %/Nedpy_03.pdf',
      );
      expect(pdfPages.success, isTrue, reason: pdfPages.errorMessage);
      expect(pdfPages.data, hasLength(3));
      final pdfBytes = await ImageDownloader.loadComicImageBytes(
        pdfPages.data.first,
        source.key,
        workId,
        '/library/混排作品 %/Nedpy_03.pdf',
      );
      final pixel = _decodeJpeg(pdfBytes);
      expect(pixel.r, greaterThan(180));
      expect(pixel.b, lessThan(80));
    },
  );

  test(
    'explicit edition directories create native groups with stable member paths and preserve bare serial labels',
    () async {
      store.addFile(
        '/library/Nedpy/Epub格式/Nedpy_01.epub',
        _createEpub(1),
        eTag: '"epub-1"',
      );
      store.addFile(
        '/library/Nedpy/Epub格式/Nedpy_02.epub',
        _createEpub(1),
        eTag: '"epub-2"',
      );
      store.addFile(
        '/library/Nedpy/PDF/Nedpy_01.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-1"',
      );
      store.addFile(
        '/library/Nedpy/PDF/Nedpy_02.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-2"',
      );
      store.addFile(
        '/library/Nedpy/PDF/Nedpy_03.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-3"',
      );
      store.addFile(
        '/library/Nedpy/PDF/Nedpy_04.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-4"',
      );
      store.addFile(
        '/library/Nedpy/PDF/Nedpy_05.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-5"',
      );
      store.addFile(
        '/library/Nedpy/PDF/Nedpy_45-53话.pdf',
        _createPdfBytes(1),
        eTag: '"pdf-45"',
      );

      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final list = await source.explorePages.single.loadPage!(1);
      expect(list.data, hasLength(1));
      final workId = list.data.single.id;

      final info = await source.loadComicInfo!(workId);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.chapters!.isGrouped, isTrue);
      expect(info.data.chapters!.groups.toSet(), {'Epub格式', 'PDF'});

      final epubGroup = info.data.chapters!.getGroup('Epub格式');
      expect(epubGroup, {
        '/library/Nedpy/Epub格式/Nedpy_01.epub': 'Nedpy_01',
        '/library/Nedpy/Epub格式/Nedpy_02.epub': 'Nedpy_02',
      });

      final pdfGroup = info.data.chapters!.getGroup('PDF');
      expect(pdfGroup.keys.toList(), [
        '/library/Nedpy/PDF/Nedpy_01.pdf',
        '/library/Nedpy/PDF/Nedpy_02.pdf',
        '/library/Nedpy/PDF/Nedpy_03.pdf',
        '/library/Nedpy/PDF/Nedpy_04.pdf',
        '/library/Nedpy/PDF/Nedpy_05.pdf',
        '/library/Nedpy/PDF/Nedpy_45-53话.pdf',
      ]);
      expect(pdfGroup['/library/Nedpy/PDF/Nedpy_01.pdf'], 'Nedpy_01');
      expect(pdfGroup['/library/Nedpy/PDF/Nedpy_05.pdf'], 'Nedpy_05');
      expect(pdfGroup['/library/Nedpy/PDF/Nedpy_45-53话.pdf'], '第45–53话');
    },
  );

  test(
    'duplicate same volume across formats creates real ComicChapters.grouped alternate editions',
    () async {
      store.addFile(
        '/library/重合格式系列/Series Vol. 01.cbz',
        _createZip(1),
        eTag: '"cbz-1"',
      );
      store.addFile(
        '/library/重合格式系列/Series Vol. 01.epub',
        _createEpub(1),
        eTag: '"epub-1"',
      );
      store.addFile(
        '/library/重合格式系列/Series Vol. 02.cbz',
        _createZip(1),
        eTag: '"cbz-2"',
      );
      store.addFile(
        '/library/重合格式系列/Series Vol. 02.epub',
        _createEpub(1),
        eTag: '"epub-2"',
      );

      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final list = await source.explorePages.single.loadPage!(1);
      expect(list.data, hasLength(1));
      final workId = list.data.single.id;

      final info = await source.loadComicInfo!(workId);
      expect(info.success, isTrue, reason: info.errorMessage);
      expect(info.data.chapters!.isGrouped, isTrue);
      expect(info.data.chapters!.groups.toSet(), {'CBZ', 'EPUB'});

      final cbzGroup = info.data.chapters!.getGroup('CBZ');
      expect(cbzGroup.keys.toList(), [
        '/library/重合格式系列/Series Vol. 01.cbz',
        '/library/重合格式系列/Series Vol. 02.cbz',
      ]);

      final epubGroup = info.data.chapters!.getGroup('EPUB');
      expect(epubGroup.keys.toList(), [
        '/library/重合格式系列/Series Vol. 01.epub',
        '/library/重合格式系列/Series Vol. 02.epub',
      ]);
      expect(info.data.chapters!.length, 4);
    },
  );

  test(
    'unrelated titles in flat library remain separate works and do not merge',
    () async {
      store.addFile(
        '/library/Series Alpha 01.cbz',
        _createZip(1),
        eTag: '"alpha-1"',
      );
      store.addFile(
        '/library/Series Alpha 02.cbz',
        _createZip(1),
        eTag: '"alpha-2"',
      );
      store.addFile(
        '/library/Series Beta 01.epub',
        _createEpub(1),
        eTag: '"beta-1"',
      );
      store.addFile(
        '/library/Series Beta 02.epub',
        _createEpub(1),
        eTag: '"beta-2"',
      );
      store.addFile(
        '/library/Standalone Special.cbz',
        _createZip(1),
        eTag: '"standalone-1"',
      );

      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final list = await source.explorePages.single.loadPage!(1);
      expect(list.data, hasLength(3));

      final workAlpha = list.data.firstWhere((c) => c.title == 'Series Alpha');
      expect(workAlpha.id.startsWith(remoteComicWorkPrefix), isTrue);
      final locA = RemoteComicWork.location(workAlpha.id);
      expect(locA.directory, '/library/');
      expect(locA.family, 'Series Alpha');

      final workBeta = list.data.firstWhere((c) => c.title == 'Series Beta');
      expect(workBeta.id.startsWith(remoteComicWorkPrefix), isTrue);
      final locB = RemoteComicWork.location(workBeta.id);
      expect(locB.directory, '/library/');
      expect(locB.family, 'Series Beta');

      final standalone = list.data.firstWhere(
        (c) => c.title == 'Standalone Special',
      );
      expect(standalone.id.startsWith(remoteComicWorkPrefix), isFalse);
      expect(standalone.id, '/library/Standalone Special.cbz');

      final infoA = await source.loadComicInfo!(workAlpha.id);
      expect(infoA.data.chapters!.allChapters.keys.toList(), [
        '/library/Series Alpha 01.cbz',
        '/library/Series Alpha 02.cbz',
      ]);

      final infoB = await source.loadComicInfo!(workBeta.id);
      expect(infoB.data.chapters!.allChapters.keys.toList(), [
        '/library/Series Beta 01.epub',
        '/library/Series Beta 02.epub',
      ]);
    },
  );

  test(
    'reopen retains per-member parsed index cache and detects replaced volume',
    () async {
      store.addFile(
        '/library/Cache Test/Vol. 01.cbz',
        _createZip(1),
        eTag: '"v1"',
      );
      store.addFile(
        '/library/Cache Test/Vol. 02.cbz',
        _createZip(1),
        eTag: '"v1"',
      );

      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final list = await source.explorePages.single.loadPage!(1);
      final workId = list.data.single.id;

      final pages1 = await source.loadComicPages!(
        workId,
        '/library/Cache Test/Vol. 01.cbz',
      );
      expect(pages1.success, isTrue, reason: pages1.errorMessage);
      final rangeCountBefore = ranges.length;

      // Reopen library: cache retention
      engine.cancel();
      engine = WebDavLibraryEngine(
        library: const RemoteLibrary(
          id: 'work-library',
          sourceKey: 'work-source',
          accountId: 'work-account',
          directories: ['/library/'],
          name: 'Work library',
          autoRefresh: false,
        ),
        store: store,
      );
      source = engine.create();

      final reopened = await source.loadComicPages!(
        workId,
        '/library/Cache Test/Vol. 01.cbz',
      );
      expect(reopened.success, isTrue, reason: reopened.errorMessage);
      expect(reopened.data, pages1.data);
      expect(
        ranges.length,
        rangeCountBefore,
        reason:
            'Cached parsed index must be retained without issuing new range requests',
      );

      // Replaced member with new revision
      store.addFile(
        '/library/Cache Test/Vol. 01.cbz',
        _createZip(2),
        eTag: '"v2"',
      );
      final sync2 = await engine.synchronize(force: true);
      expect(sync2.success, isTrue, reason: sync2.errorMessage);

      final newPages = await source.loadComicPages!(
        workId,
        '/library/Cache Test/Vol. 01.cbz',
      );
      expect(newPages.success, isTrue, reason: newPages.errorMessage);
      expect(ranges.length, greaterThan(rangeCountBefore));

      final newBytes = await ImageDownloader.loadComicImageBytes(
        newPages.data[0],
        source.key,
        workId,
        '/library/Cache Test/Vol. 01.cbz',
      );
      expect(newBytes, [1, 2]); // Revision 2 image bytes
    },
  );

  test(
    'metadata write targets root metadata.json for directory work and title.metadata.json for flat family',
    () async {
      store.addFile(
        '/library/Dir Comic/Vol. 01.cbz',
        _createZip(1),
        eTag: '"v1"',
      );
      store.addFile(
        '/library/Dir Comic/Vol. 02.cbz',
        _createZip(1),
        eTag: '"v1"',
      );
      store.addFile('/library/Flat Comic 01.cbz', _createZip(1), eTag: '"v1"');
      store.addFile('/library/Flat Comic 02.cbz', _createZip(1), eTag: '"v1"');

      final sync = await engine.synchronize();
      expect(sync.success, isTrue, reason: sync.errorMessage);
      final list = await source.explorePages.single.loadPage!(1);
      expect(list.data, hasLength(2));

      final dirItem = list.data.firstWhere((c) => c.title == 'Dir Comic');
      final flatItem = list.data.firstWhere((c) => c.title == 'Flat Comic');

      // 1. Directory work metadata write -> /library/Dir Comic/metadata.json
      await engine.writeMetadata(
        dirItem.id,
        const ComicMetaData(
          title: 'Updated Dir Comic',
          author: 'Dir Author',
          tags: ['Manga', 'Action'],
        ),
      );
      expect(
        store.texts.containsKey('/library/Dir Comic/metadata.json'),
        isTrue,
      );
      expect(store.textWrites.last.path, '/library/Dir Comic/metadata.json');
      final dirDocument =
          jsonDecode(store.texts['/library/Dir Comic/metadata.json']!.content)
              as Map;
      expect(dirDocument['title'], 'Updated Dir Comic');
      expect(dirDocument['author'], 'Dir Author');

      // 2. Flat family metadata write -> /library/Flat Comic.metadata.json
      await engine.writeMetadata(
        flatItem.id,
        const ComicMetaData(
          title: 'Updated Flat Comic',
          author: 'Flat Author',
          tags: ['Webtoon'],
        ),
      );
      expect(
        store.texts.containsKey('/library/Flat Comic.metadata.json'),
        isTrue,
      );
      expect(store.textWrites.last.path, '/library/Flat Comic.metadata.json');
      final flatDocument =
          jsonDecode(store.texts['/library/Flat Comic.metadata.json']!.content)
              as Map;
      expect(flatDocument['title'], 'Updated Flat Comic');
      expect(flatDocument['author'], 'Flat Author');
    },
  );
}

image.Pixel _decodeJpeg(Uint8List bytes) {
  expect(bytes.take(2), [0xff, 0xd8]);
  final decoded = image.decodeJpg(bytes);
  expect(decoded, isNotNull);
  return decoded!.getPixel(decoded.width ~/ 2, decoded.height ~/ 2);
}

Uint8List _createPdfBytes(int revision, {bool bookmarks = true}) {
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

Uint8List _createEpub(int revision) {
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
    <dc:title>Spine ordered work volume</dc:title><dc:creator>EPUB author</dc:creator>
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
    xml(
      'OPS/Text/$number.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page $number</title></head><body><img src="../Images/$number.jpg" alt="Page $number"/></body></html>',
    );
  }
  add('before-images.padding', List.filled(2 * 1024 * 1024, 42));
  final imageBytes = <String, List<int>>{
    'OPS/Images/jacket.jpg': [9, revision],
    'OPS/Images/1.jpg': [1, revision],
    'OPS/Images/2.jpg': [2, revision],
    'OPS/Images/3.jpg': [3, revision],
  };
  for (final image in imageBytes.entries) {
    add(image.key, image.value);
  }
  add('after-images.padding', List.filled(2 * 1024 * 1024, 43));
  return Uint8List.fromList(archive.ZipEncoder().encodeBytes(book, level: 0));
}

Uint8List _createZip(int revision) {
  final book = archive.Archive();
  void add(String name, List<int> bytes) =>
      book.addFile(archive.ArchiveFile.noCompress(name, bytes.length, bytes));
  add('Book/cover.jpg', [9, revision]);
  add('Book/01.jpg', [1, revision]);
  add('Book/02.jpg', [2, revision]);
  add('Book/03.jpg', [3, revision]);
  add('Book/padding.bin', List.filled(2 * 1024 * 1024, 42));
  return Uint8List.fromList(archive.ZipEncoder().encodeBytes(book, level: 0));
}

class _PdfProbe {
  var openCount = 0;
  final documents = <_PdfDocument>[];
  final nativeReads = <({int offset, int length})>[];

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
    final buffer = await read(_pageOffsets[pageNumber - 1], 64);
    if (buffer.length != 64) {
      throw const FormatException('Native bridge could not render the page');
    }
    expect(buffer[0], pageNumber);
    const width = 12;
    const height = 9;
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

class _FileFixture {
  _FileFixture({
    required this.path,
    required this.bytes,
    this.eTag,
    this.modifiedAt,
  });

  final String path;
  final Uint8List bytes;
  final String? eTag;
  final int? modifiedAt;

  String get name => path.split('/').where((part) => part.isNotEmpty).last;
  int get size => bytes.length;
}

class _MultiFileStore implements RemoteFileStore {
  _MultiFileStore(this.remoteLink);

  final RemoteLink remoteLink;
  final files = <String, _FileFixture>{};
  final texts = <String, RemoteTextFile>{};
  final textReads = <String>[];
  final textWrites =
      <
        ({
          String path,
          bool createOnly,
          String? ifMatch,
          int? ifUnmodifiedSince,
        })
      >[];
  var links = 0;
  var stats = 0;
  var downloads = 0;
  var backend = StorageBackend.openlist;

  void addFile(String path, Uint8List bytes, {String? eTag, int? modifiedAt}) {
    files[path] = _FileFixture(
      path: path,
      bytes: bytes,
      eTag: eTag ?? '"etag-${files.length + 1}"',
      modifiedAt: modifiedAt ?? 1730000000000,
    );
  }

  @override
  StorageAccount get account => StorageAccount(
    id: 'work-account',
    backend: backend,
    driver: 'GoogleDrive',
    name: 'Work account',
    authorization: {},
  );

  @override
  Future<List<RemoteEntry>> list(String directory) async {
    final normalized = directory.endsWith('/') ? directory : '$directory/';
    final entries = <RemoteEntry>[];
    final subdirs = <String>{};

    for (final file in files.values) {
      if (!file.path.startsWith(normalized)) continue;
      final rest = file.path.substring(normalized.length);
      final slash = rest.indexOf('/');
      if (slash == -1) {
        entries.add(
          RemoteEntry(
            name: file.name,
            path: file.path,
            isDirectory: false,
            size: file.size,
            eTag: file.eTag,
            modifiedAt: file.modifiedAt,
          ),
        );
      } else {
        final dirName = rest.substring(0, slash);
        subdirs.add(dirName);
      }
    }

    for (final dirName in subdirs) {
      entries.add(
        RemoteEntry(
          name: dirName,
          path: '$normalized$dirName/',
          isDirectory: true,
        ),
      );
    }

    for (final entry in texts.entries) {
      if (!entry.key.startsWith(normalized)) continue;
      final rest = entry.key.substring(normalized.length);
      if (!rest.contains('/')) {
        entries.add(
          RemoteEntry(
            name: entry.key.split('/').last,
            path: entry.key,
            isDirectory: false,
            eTag: entry.value.eTag,
            modifiedAt: entry.value.modifiedAt,
          ),
        );
      }
    }

    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    stats++;
    final file = files[path];
    if (file != null) {
      return RemoteEntry(
        name: file.name,
        path: file.path,
        isDirectory: false,
        size: file.size,
        eTag: file.eTag,
        modifiedAt: file.modifiedAt,
      );
    }
    final text = texts[path];
    if (text != null) {
      return RemoteEntry(
        name: path.split('/').last,
        path: path,
        isDirectory: false,
        eTag: text.eTag,
        modifiedAt: text.modifiedAt,
      );
    }
    final normalized = path.endsWith('/') ? path : '$path/';
    if (files.keys.any((k) => k.startsWith(normalized))) {
      final name = path.endsWith('/')
          ? path.substring(0, path.length - 1).split('/').last
          : path.split('/').last;
      return RemoteEntry(name: name, path: normalized, isDirectory: true);
    }
    throw const RemoteStorageException('Not found', code: '404');
  }

  @override
  Future<RemoteLink> link(String path) async {
    links++;
    return RemoteLink(
      url: '${remoteLink.url}?path=${Uri.encodeQueryComponent(path)}',
      headers: remoteLink.headers,
    );
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
    textWrites.add((
      path: path,
      createOnly: createOnly,
      ifMatch: ifMatch,
      ifUnmodifiedSince: ifUnmodifiedSince,
    ));
    final existing = texts[path];
    if (createOnly && existing != null) {
      throw const WebDavPreconditionFailedException('Conflict');
    }
    if (ifMatch != null && existing?.eTag != ifMatch) {
      throw const WebDavPreconditionFailedException('ETag mismatch');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final text = RemoteTextFile(
      content: content,
      eTag: '"text-${textWrites.length}"',
      modifiedAt: now,
    );
    texts[path] = text;
    return RemoteWriteResult(eTag: text.eTag, modifiedAt: now);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected remote operation: ${invocation.memberName}');
}
