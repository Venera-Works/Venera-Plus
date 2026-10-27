import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';

void main() {
  test(
    'uses spine order, retains repeated images and keeps a fallback cover in the body',
    () async {
      final book = _book(
        manifest: '''
        <item id="one" href="images/10.jpg" media-type="image/jpeg"/>
        <item id="two" href="images/2.jpg" media-type="image/jpeg"/>
        <item id="cover" href="images/cover.jpg" media-type="image/jpeg"/>
        <item id="unused" href="images/unused.jpg" media-type="image/jpeg"/>
      ''',
        spine:
            '<itemref idref="two"/><itemref idref="one"/><itemref idref="cover"/><itemref idref="two"/>',
        metadata:
            '<dc:title>漫画</dc:title><dc:creator>作者一</dc:creator><dc:creator>作者二</dc:creator><dc:description>简介 &amp; 内容</dc:description><dc:subject>冒险</dc:subject><dc:subject>彩色</dc:subject>',
        resources: {
          'OPS/images/10.jpg': [10],
          'OPS/images/2.jpg': [2],
          'OPS/images/cover.jpg': [0],
          'OPS/images/unused.jpg': [9],
        },
      );
      final zip = await book.index();
      final result = await RemoteEpubIndex.read(
        zip: zip,
        read: book.readControl,
      );
      expect(result.pages, [
        'OPS/images/2.jpg',
        'OPS/images/10.jpg',
        'OPS/images/cover.jpg',
        'OPS/images/2.jpg',
      ]);
      expect(result.coverEntry, result.pages.first);
      expect(result.metadata.title, '漫画');
      expect(result.metadata.author, '作者一, 作者二');
      expect(result.metadata.description, '简介 & 内容');
      expect(result.metadata.tags, ['冒险', '彩色']);
      expect(result.metadata.chapters, isNull);
      expect(book.controlNames(zip), [
        'META-INF/container.xml',
        'OPS/package.opf',
      ]);
      expect(() => result.pages.clear(), throwsUnsupportedError);
    },
  );

  test(
    'reads EPUB3 cover and toc chapters, skips non-linear and blank pages',
    () async {
      final book = _book(
        manifest: '''
        <item id="cover" href="images/jacket.jpg" media-type="image/jpeg" properties="cover-image"/>
        <item id="c" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
        <item id="p1" href="text/1.xhtml" media-type="application/xhtml+xml"/>
        <item id="p2" href="text/2.xhtml" media-type="application/xhtml+xml"/>
        <item id="p3" href="text/3.xhtml" media-type="application/xhtml+xml"/>
        <item id="blank" href="text/blank.xhtml" media-type="application/xhtml+xml"/>
        <item id="skip" href="text/skip.xhtml" media-type="application/xhtml+xml"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
      ''',
        spine:
            '<itemref idref="c"/><itemref idref="p3"/><itemref idref="blank"/><itemref idref="p1"/><itemref idref="skip" linear="no"/><itemref idref="p2"/>',
        resources: {
          'OPS/images/jacket.jpg': [0],
          for (var i = 1; i <= 3; i++) 'OPS/images/$i.jpg': [i],
          'OPS/text/cover.xhtml': _html('<img src="../images/jacket.jpg"/>'),
          'OPS/text/1.xhtml': _html(
            '<h2>Chapter title</h2><img alt="说明" src="../images/1.jpg"/>',
          ),
          'OPS/text/2.xhtml': _html('<img src="../images/2.jpg"/>'),
          'OPS/text/3.xhtml': _html('<h1>One</h1><img src="../images/3.jpg"/>'),
          'OPS/text/blank.xhtml': _html(' \n '),
          'OPS/text/skip.xhtml': _html('<p>Must not be read</p>'),
          'OPS/nav.xhtml': _text('''
          <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="landmarks"><a href="text/1.xhtml">Not a chapter</a></nav>
            <nav epub:type="toc"><ol>
              <li><a href="text/3.xhtml#start">One</a></li>
              <li><a href="text/2.xhtml?x=1#start">Two</a></li>
            </ol></nav>
          </body></html>
        '''),
        },
      );
      final zip = await book.index();
      final result = await RemoteEpubIndex.read(
        zip: zip,
        read: book.readControl,
      );
      expect(result.coverEntry, 'OPS/images/jacket.jpg');
      expect(result.pages, [
        'OPS/images/3.jpg',
        'OPS/images/1.jpg',
        'OPS/images/2.jpg',
      ]);
      expect(result.metadata.chapters!.map((chapter) => chapter.toJson()), [
        {'title': 'One', 'start': 1, 'end': 2},
        {'title': 'Two', 'start': 3, 'end': 3},
      ]);
      expect(book.controlNames(zip), isNot(contains('OPS/text/skip.xhtml')));
      expect(
        book.controlNames(zip).where((name) => name.endsWith('.jpg')),
        isEmpty,
      );
    },
  );

  test(
    'supports EPUB2 NCX and exporter heading pages with cover metadata',
    () async {
      final book = _book(
        opfPath: 'content.opf',
        metadata:
            '<dc:title>Exported &amp; Imported</dc:title><meta name="cover" content="cover"/>',
        manifest: '''
        <item id="cover" href="OEBPS/images/cover.jpg" media-type="image/jpeg"/>
        <item id="first" href="OEBPS/0.html" media-type="application/xhtml+xml"/>
        <item id="second" href="OEBPS/1.html" media-type="application/xhtml+xml"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
      ''',
        spineAttributes: 'toc="ncx"',
        spine: '<itemref idref="first"/><itemref idref="second"/>',
        resources: {
          'OEBPS/images/cover.jpg': [0],
          'OEBPS/images/1.jpg': [1],
          'OEBPS/images/2.jpg': [2],
          'OEBPS/0.html': _html(
            '<h1>One</h1><img src="images/2.jpg"/><img src="images/1.jpg"/>',
          ),
          'OEBPS/1.html': _html('<h1>Two</h1><img src="images/1.jpg"/>'),
          'toc.ncx': _text('''<ncx><navMap>
          <navPoint><navLabel><text>One</text></navLabel><content src="OEBPS/0.html"/></navPoint>
          <navPoint><navLabel><text>Two</text></navLabel><content src="OEBPS/1.html"/></navPoint>
        </navMap></ncx>'''),
        },
      );
      final zip = await book.index();
      final result = await RemoteEpubIndex.read(
        zip: zip,
        read: book.readControl,
      );
      expect(result.metadata.title, 'Exported & Imported');
      expect(result.coverEntry, 'OEBPS/images/cover.jpg');
      expect(result.pages, [
        'OEBPS/images/2.jpg',
        'OEBPS/images/1.jpg',
        'OEBPS/images/1.jpg',
      ]);
      expect(result.metadata.chapters!.map((chapter) => chapter.title), [
        'One',
        'Two',
      ]);
      expect(
        result.metadata.chapters!.map(
          (chapter) => chapter.end - chapter.start + 1,
        ),
        [2, 1],
      );
    },
  );

  test(
    'expands SVG wrappers and XHTML in DOM order and caches repeated documents',
    () async {
      final book = _book(
        manifest: '''
        <item id="svg" href="pages/one.svg" media-type="image/svg+xml"/>
        <item id="html" href="pages/two.xhtml" media-type="application/xhtml+xml"/>
      ''',
        spine:
            '<itemref idref="svg"/><itemref idref="html"/><itemref idref="svg"/>',
        resources: {
          'OPS/images/1.jpg': [1],
          'OPS/images/2.jpg': [2],
          'OPS/pages/one.svg': _text(
            '<svg xmlns:xlink="http://www.w3.org/1999/xlink"><title>说明</title><desc>替代说明</desc><image xlink:href="../images/2.jpg"/></svg>',
          ),
          'OPS/pages/two.xhtml': _html(
            '<img src="../images/1.jpg"/><svg><title>说明</title><image href="../images/2.jpg"/></svg><img src="../images/1.jpg"/>',
          ),
        },
      );
      final zip = await book.index();
      final result = await RemoteEpubIndex.read(
        zip: zip,
        read: book.readControl,
      );
      expect(result.pages, [
        'OPS/images/2.jpg',
        'OPS/images/1.jpg',
        'OPS/images/2.jpg',
        'OPS/images/1.jpg',
        'OPS/images/2.jpg',
      ]);
      expect(
        book.controlNames(zip).where((name) => name == 'OPS/pages/one.svg'),
        hasLength(1),
      );
      expect(result.metadata.chapters, isNull);
    },
  );

  test(
    'uses a guide cover, fallback title and no invented chapter for a single nav label',
    () async {
      final book = _book(
        metadata: '',
        manifest: '''
        <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
        <item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
      ''',
        guide:
            '<guide><reference type="cover" href="cover.xhtml#cover"/></guide>',
        spine: '<itemref idref="cover"/><itemref idref="page"/>',
        resources: {
          'OPS/jacket.png': [0],
          'OPS/1.jpg': [1],
          'OPS/cover.xhtml': _html('<img src="jacket.png"/>'),
          'OPS/page.xhtml': _html('<img src="1.jpg"/>'),
          'OPS/nav.xhtml': _text(
            '<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><a href="page.xhtml">One</a></nav></body></html>',
          ),
        },
      );
      final zip = await book.index();
      final result = await RemoteEpubIndex.read(
        zip: zip,
        read: book.readControl,
        fallbackTitle: 'Filename',
      );
      expect(result.metadata.title, 'Filename');
      expect(result.metadata.author, '');
      expect(result.metadata.tags, isEmpty);
      expect(result.coverEntry, 'OPS/jacket.png');
      expect(result.pages, ['OPS/1.jpg']);
      expect(result.metadata.chapters, isNull);
      expect(
        book.controlNames(zip).where((name) => name == 'OPS/cover.xhtml'),
        hasLength(1),
      );
    },
  );

  test(
    'resolves Unicode, spaces and percent paths once, with relative segments and fragments',
    () async {
      final book = _book(
        opfPath: 'OPS/目录 A/package.opf',
        containerPath: 'OPS/目录%20A/package.opf',
        manifest:
            '<item id="page" href="../文档%20页/one.xhtml?x=1#start" media-type="application/xhtml+xml"/>',
        spine: '<itemref idref="page"/>',
        resources: {
          'OPS/文档 页/one.xhtml': _html(
            '<img src="../图像/100%25%20%E9%A1%B5.jpg?cache=1#p"/><img src="../图像/%2520.jpg"/>',
          ),
          'OPS/图像/100% 页.jpg': [1],
          'OPS/图像/%20.jpg': [2],
        },
      );
      final zip = await book.index();
      final result = await RemoteEpubIndex.read(
        zip: zip,
        read: book.readControl,
      );
      expect(result.pages, ['OPS/图像/100% 页.jpg', 'OPS/图像/%20.jpg']);
    },
  );

  test('rejects DRM before reading control files', () async {
    final book = _basic(
      extra: {'META-INF/encryption.xml': _text('<encryption/>')},
    );
    final zip = await book.index();
    await expectLater(
      RemoteEpubIndex.read(zip: zip, read: book.readControl),
      throwsUnsupportedError,
    );
    expect(book.calls, isEmpty);
  });

  test(
    'rejects external, data, absolute and escaping image references',
    () async {
      for (final reference in [
        'https://example.com/a.jpg',
        '//example.com/a.jpg',
        'data:image/png;base64,AA',
        '/image.jpg',
        '%2fimage.jpg',
        '../../outside.jpg',
        'C%3A/image.jpg',
      ]) {
        final book = _basic(body: '<img src="$reference"/>');
        final zip = await book.index();
        await expectLater(
          RemoteEpubIndex.read(zip: zip, read: book.readControl),
          throwsFormatException,
          reason: reference,
        );
      }
      final external = _book(
        manifest:
            '<item id="page" href="https://example.com/1.jpg" media-type="image/jpeg"/>',
        spine: '<itemref idref="page"/>',
      );
      final zip = await external.index();
      await expectLater(
        RemoteEpubIndex.read(zip: zip, read: external.readControl),
        throwsFormatException,
      );
    },
  );

  test('rejects text, scripts and content requiring page rendering', () async {
    for (final body in [
      '<p>Text-only body</p>',
      '<div>Visible prose<img src="1.jpg"/></div>',
      '<p>Visible prose</p><img src="1.jpg"/>',
      '<script>run()</script><img src="1.jpg"/>',
      '<img onload="run()" src="1.jpg"/>',
      '<object data="1.jpg"/>',
      '<svg><rect width="10" height="10"/><image href="1.jpg"/></svg>',
      '<svg><text>Visible text</text><image href="1.jpg"/></svg>',
      '<div style="background:url(1.jpg)"/>',
      '<img src="1.jpg" srcset="2.jpg 2x"/>',
    ]) {
      final book = _basic(body: body);
      final zip = await book.index();
      await expectLater(
        RemoteEpubIndex.read(zip: zip, read: book.readControl),
        throwsUnsupportedError,
        reason: body,
      );
    }
  });

  test('rejects missing resources, empty books and invalid UTF8/XML', () async {
    final cases = [
      _zip({}),
      _book(
        manifest:
            '<item id="page" href="missing.xhtml" media-type="application/xhtml+xml"/>',
        spine: '<itemref idref="page"/>',
      ),
      _book(manifest: '', spine: '<itemref idref="missing"/>'),
      _basic(body: '<img/>'),
      _basic(body: '<img src="missing.jpg"/>'),
      _basic(body: ' \n '),
      _basic(
        extra: {
          'OPS/page.xhtml': [0xff],
        },
      ),
      _basic(extra: {'OPS/page.xhtml': _text('<html><body></html>')}),
    ];
    for (final book in cases) {
      final zip = await book.index();
      await expectLater(
        RemoteEpubIndex.read(zip: zip, read: book.readControl),
        throwsFormatException,
      );
    }
    final entity = _basic(
      extra: {
        'OPS/page.xhtml': _text(
          '<!DOCTYPE html [<!ENTITY x SYSTEM "file:///secret">]><html><body><img src="1.jpg"/></body></html>',
        ),
      },
    );
    final zip = await entity.index();
    await expectLater(
      RemoteEpubIndex.read(zip: zip, read: entity.readControl),
      throwsUnsupportedError,
    );
  });

  test(
    'checks the single control-document size limit before requesting it',
    () async {
      final book = _basic();
      final original = await book.index();
      final json = original.toJson();
      final items = json['entries'] as List;
      final page = items.cast<Map<String, dynamic>>().firstWhere(
        (item) => item['name'] == 'OPS/page.xhtml',
      );
      page['compressionMethod'] = 8;
      page['uncompressedSize'] = 4 * 1024 * 1024 + 1;
      final zip = RemoteZipIndex.fromJson(json);
      await expectLater(
        RemoteEpubIndex.read(zip: zip, read: book.readControl),
        throwsFormatException,
      );
      expect(book.controlNames(zip), isNot(contains('OPS/page.xhtml')));
    },
  );

  test(
    'bounds cumulative control bytes and never requests the over-budget document',
    () async {
      final padding = List.filled(3584 * 1024, 'x').join();
      final book = _book(
        manifest: [
          for (var i = 0; i < 5; i++)
            '<item id="p$i" href="p$i.xhtml" media-type="application/xhtml+xml"/>',
        ].join(),
        spine: [for (var i = 0; i < 5; i++) '<itemref idref="p$i"/>'].join(),
        resources: {
          'OPS/1.jpg': [1],
          for (var i = 0; i < 5; i++)
            'OPS/p$i.xhtml': _html('<!--$padding--><img src="1.jpg"/>'),
        },
      );
      final zip = await book.index();
      await expectLater(
        RemoteEpubIndex.read(zip: zip, read: book.readControl),
        throwsFormatException,
      );
      expect(book.controlNames(zip), contains('OPS/p3.xhtml'));
      expect(book.controlNames(zip), isNot(contains('OPS/p4.xhtml')));
    },
  );

  test('propagates cancellation and range errors unchanged', () async {
    final book = _basic();
    final zip = await book.index();
    final package = zip.entries.firstWhere(
      (entry) => entry.name == 'OPS/package.opf',
    );
    final cancelled = StateError('request cancelled');
    Future<Uint8List> read(int offset, int length) async {
      if (offset == package.localHeaderOffset) throw cancelled;
      return book.readControl(offset, length);
    }

    await expectLater(
      RemoteEpubIndex.read(zip: zip, read: read),
      throwsA(same(cancelled)),
    );
  });
}

_Book _basic({
  String body = '<img src="1.jpg"/>',
  Map<String, List<int>> extra = const {},
}) => _book(
  manifest:
      '<item id="page" href="page.xhtml" media-type="application/xhtml+xml"/>',
  spine: '<itemref idref="page"/>',
  resources: {
    'OPS/1.jpg': [1],
    'OPS/page.xhtml': _html(body),
    ...extra,
  },
);

_Book _book({
  required String manifest,
  required String spine,
  String metadata = '<dc:title>Example</dc:title>',
  String opfPath = 'OPS/package.opf',
  String? containerPath,
  String spineAttributes = '',
  String guide = '',
  Map<String, List<int>> resources = const {},
}) => _zip({
  'META-INF/container.xml': _text(
    '<container><rootfiles><rootfile full-path="${containerPath ?? opfPath}" media-type="application/oebps-package+xml"/></rootfiles></container>',
  ),
  opfPath: _text(
    '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata>$metadata</metadata><manifest>$manifest</manifest><spine $spineAttributes>$spine</spine>$guide</package>',
  ),
  ...resources,
});

_Book _zip(Map<String, List<int>> files) {
  final content = archive.Archive();
  for (final entry in files.entries) {
    content.addFile(archive.ArchiveFile.bytes(entry.key, entry.value));
  }
  return _Book(
    archive.ZipEncoder().encodeBytes(content, modified: DateTime.utc(2000)),
  );
}

List<int> _text(String text) => utf8.encode(text);
List<int> _html(String body) => _text(
  '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Page</title></head><body>$body</body></html>',
);

class _Book {
  _Book(this.bytes);
  final Uint8List bytes;
  final calls = <(int, int)>[];
  final _imageRanges = <(int, int)>[];

  Future<RemoteZipIndex> index() async {
    final zip = await RemoteZipIndex.read(fileSize: bytes.length, read: _read);
    final data = ByteData.sublistView(bytes);
    _imageRanges.clear();
    for (final entry in zip.entries.where(
      (entry) => isComicImageFileName(entry.name),
    )) {
      final offset = entry.localHeaderOffset;
      final start =
          offset +
          30 +
          data.getUint16(offset + 26, Endian.little) +
          data.getUint16(offset + 28, Endian.little);
      _imageRanges.add((start, start + entry.compressedSize));
    }
    calls.clear();
    return zip;
  }

  Future<Uint8List> _read(int offset, int length) async {
    calls.add((offset, length));
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  Future<Uint8List> readControl(int offset, int length) async {
    for (final range in _imageRanges) {
      if (offset < range.$2 && offset + length > range.$1) {
        fail('EPUB indexing read an image payload at $offset + $length');
      }
    }
    return _read(offset, length);
  }

  List<String> controlNames(RemoteZipIndex zip) => [
    for (final call in calls)
      for (final entry in zip.entries)
        if (call.$1 == entry.localHeaderOffset && call.$2 == 30) entry.name,
  ];
}
