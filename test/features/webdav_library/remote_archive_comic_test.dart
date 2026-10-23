import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/webdav_library/remote_archive_comic.dart';

void main() {
  test('recognizes only ZIP and CBZ archives for remote reading', () {
    expect(isRemoteComicArchive('/library/漫画.CBZ'), isTrue);
    expect(isRemoteComicArchive('comic.ZIP'), isTrue);
    for (final name in [
      'comic.pdf',
      'comic.epub',
      'comic.7z',
      'comic.cb7',
      'comic.zip.jpg',
    ]) {
      expect(isRemoteComicArchive(name), isFalse);
    }
  });

  test(
    'unwraps a single root, naturally sorts pages and ignores hidden entries',
    () async {
      final fixture = _zip({
        'Book/': [],
        'Book/10.jpg': [10],
        'Book/2.JPG': [2],
        'Book/1.jpg': [1],
        'Book/cover.JPG': [0],
        'Book/readme.txt': utf8.encode('notes'),
        'Book/.hidden/99.jpg': [99],
        'Book/.DS_Store': [0],
        '__MACOSX/._Book.jpg': [100],
      });
      final comic = await _inspect(fixture, path: '/library/远端漫画.CBZ');

      expect(comic.isInspected, isTrue);
      expect(comic.title, '远端漫画');
      expect(comic.metadata, isNull);
      expect(comic.chapters, {'__root__': 'Images'});
      expect(comic.chapterImages, {
        '__root__': ['Book/1.jpg', 'Book/2.JPG', 'Book/10.jpg'],
      });
      expect(comic.coverEntry, 'Book/cover.JPG');
    },
  );

  test(
    'naturally orders directory chapters and their pages without metadata',
    () async {
      final fixture = _zip({
        'Book/Chapter 10/10.jpg': [10],
        'Book/Chapter 2/10.jpg': [10],
        'Book/Chapter 2/2.jpg': [2],
        'Book/Chapter 10/2.jpg': [2],
        'Book/Chapter 2/1.jpg': [1],
        'Book/Chapter 2/cover.png': [0],
        'Book/Chapter 10/1.jpg': [1],
        'Book/Chapter 2/.ignored.jpg': [99],
      });
      final comic = await _inspect(fixture);

      expect(comic.chapters.keys.toList(), ['dir:Chapter 2', 'dir:Chapter 10']);
      expect(comic.chapters.values.toList(), ['Chapter 2', 'Chapter 10']);
      expect(comic.chapterImages, {
        'dir:Chapter 2': [
          'Book/Chapter 2/1.jpg',
          'Book/Chapter 2/2.jpg',
          'Book/Chapter 2/10.jpg',
        ],
        'dir:Chapter 10': [
          'Book/Chapter 10/1.jpg',
          'Book/Chapter 10/2.jpg',
          'Book/Chapter 10/10.jpg',
        ],
      });
      expect(comic.coverEntry, 'Book/Chapter 2/cover.png');
    },
  );

  test(
    'prefers a root cover for a comic containing chapter directories',
    () async {
      final comic = await _inspect(
        _zip({
          'Book/Chapter 2/1.jpg': [1],
          'Book/Chapter 2/cover.jpg': [0],
          'Book/cover.jpg': [2],
          'Book/Chapter 1/1.jpg': [3],
        }),
      );

      expect(comic.coverEntry, 'Book/cover.jpg');
      expect(comic.chapterImages.keys.toList(), [
        'dir:Chapter 1',
        'dir:Chapter 2',
      ]);
      expect(comic.chapterImages.values.expand((pages) => pages), [
        'Book/Chapter 1/1.jpg',
        'Book/Chapter 2/1.jpg',
      ]);
    },
  );

  test(
    'uses metadata page ranges, title, author and tags with a separate cover',
    () async {
      const metadata = ComicMetaData(
        title: '云端漫画',
        author: '作者',
        tags: ['冒险', '彩色'],
        description: '漫画简介',
        bangumiSubjectId: 42,
        chapters: [
          ComicChapter(title: '第一章', start: 1, end: 2),
          ComicChapter(title: '第二章', start: 3, end: 4),
        ],
      );
      final fixture = _zip({
        'Book/11.jpg': [11],
        'Book/2.jpg': [2],
        'Book/cover.jpg': [0],
        'Book/10.jpg': [10],
        'Book/1.jpg': [1],
        'Book/Metadata.JSON': utf8.encode(jsonEncode(metadata.toJson())),
      });
      final comic = await _inspect(fixture);

      expect(comic.title, '云端漫画');
      expect(comic.metadata!.author, '作者');
      expect(comic.metadata!.tags, ['冒险', '彩色']);
      expect(comic.metadata!.description, '漫画简介');
      expect(comic.metadata!.bangumiSubjectId, 42);
      expect(comic.chapters, {'__cbz_range_0': '第一章', '__cbz_range_1': '第二章'});
      expect(comic.chapterImages, {
        '__cbz_range_0': ['Book/1.jpg', 'Book/2.jpg'],
        '__cbz_range_1': ['Book/10.jpg', 'Book/11.jpg'],
      });
      expect(comic.coverEntry, 'Book/cover.jpg');
    },
  );

  test(
    'falls back to naturally ordered pages for malformed or invalid metadata',
    () async {
      final invalidMetadata = [
        '{invalid json',
        jsonEncode(['not', 'an', 'object']),
        jsonEncode({
          'title': 'Out of range',
          'author': '',
          'tags': [],
          'chapters': [
            {'title': 'Chapter', 'start': 1, 'end': 3},
          ],
        }),
        jsonEncode({
          'title': 'Overlapping',
          'author': '',
          'tags': [],
          'chapters': [
            {'title': 'One', 'start': 1, 'end': 2},
            {'title': 'Two', 'start': 2, 'end': 2},
          ],
        }),
      ];
      for (final text in invalidMetadata) {
        final fixture = _zip({
          '2.jpg': [2],
          '1.jpg': [1],
          'metadata.json': utf8.encode(text),
        });
        final comic = await _inspect(
          fixture,
          path: '/library/Fallback Name.zip',
        );

        expect(comic.metadata, isNull);
        expect(comic.title, 'Fallback Name');
        expect(comic.chapters, {'__root__': 'Images'});
        expect(comic.chapterImages, {
          '__root__': ['1.jpg', '2.jpg'],
        });
        expect(comic.coverEntry, '1.jpg');
      }
    },
  );

  test(
    'uses the filename for a blank metadata title while preserving its author',
    () async {
      final fixture = _zip({
        '1.jpg': [1],
        'metadata.json': utf8.encode(
          jsonEncode({
            'title': '  ',
            'author': '作者',
            'tags': ['标签'],
          }),
        ),
      });
      final comic = await _inspect(fixture, path: '/library/Filename.cbz');

      expect(comic.title, 'Filename');
      expect(comic.metadata!.author, '作者');
      expect(comic.metadata!.tags, ['标签']);
    },
  );

  test(
    'restores the index and stable image keys without rescanning the archive',
    () async {
      const path = '/library/漫画 100%.cbz';
      final fixture = _zip({
        'cover.jpg': [0],
        '1.jpg': [1, 2, 3],
      });
      final pending = RemoteArchiveComic(
        path: path,
        size: fixture.bytes.length,
        eTag: '"archive-1"',
        modifiedAt: 123456789,
      );
      expect(pending.isInspected, isFalse);
      final comic = await pending.inspect(fixture.read);
      final restored = RemoteArchiveComic.fromJson(
        jsonDecode(jsonEncode(comic.toJson())),
      );

      expect(restored.toJson(), comic.toJson());
      expect(restored.isInspected, isTrue);
      expect(restored.version, comic.version);
      expect(restored.imageKey(), comic.imageKey());
      expect(restored.imageKey('1.jpg'), comic.imageKey('1.jpg'));
      expect(RemoteArchiveComic.parseImageKey(restored.imageKey()), (
        path: path,
        version: comic.version,
        entry: 'cover.jpg',
      ));
      expect(RemoteArchiveComic.parseImageKey(restored.imageKey('1.jpg')), (
        path: path,
        version: comic.version,
        entry: '1.jpg',
      ));
      expect(
        RemoteArchiveComic.parseImageKey('https://example.com/page.jpg'),
        isNull,
      );

      fixture.calls.clear();
      final entry = restored.index!.entries.firstWhere(
        (entry) => entry.name == '1.jpg',
      );
      expect(await restored.index!.readEntry(entry, fixture.read), [1, 2, 3]);
      expect(fixture.calls, [
        (0, restored.index!.toJson()['centralDirectoryOffset'] as int),
      ]);
      expect(
        restored.matches(
          size: fixture.bytes.length,
          eTag: '"archive-1"',
          modifiedAt: 123456789,
        ),
        isTrue,
      );
      expect(
        restored.matches(
          size: fixture.bytes.length,
          eTag: '"archive-2"',
          modifiedAt: 123456789,
        ),
        isFalse,
      );
      expect(
        restored.matches(
          size: fixture.bytes.length + 1,
          eTag: '"archive-1"',
          modifiedAt: 123456789,
        ),
        isFalse,
      );
    },
  );

  test(
    'changes image versions when same-size ZIP contents have different CRCs',
    () async {
      final firstFixture = _zip({
        '1.jpg': [1, 2, 3, 4],
      }, store: true);
      final changedFixture = _zip({
        '1.jpg': [4, 3, 2, 1],
      }, store: true);
      expect(firstFixture.bytes.length, changedFixture.bytes.length);
      final first = await _inspect(firstFixture);
      final changed = await _inspect(changedFixture);

      expect(first.size, changed.size);
      expect(
        first.index!.entries.single.crc32,
        isNot(changed.index!.entries.single.crc32),
      );
      expect(first.version, isNot(changed.version));
      expect(first.imageKey('1.jpg'), isNot(changed.imageKey('1.jpg')));
      expect(
        RemoteArchiveComic.parseImageKey(changed.imageKey('1.jpg'))!.version,
        changed.version,
      );
      expect(first.matches(size: first.size), isFalse);
    },
  );

  test('rejects archives with no visible comic pages', () async {
    for (final files in [
      {
        'metadata.json': utf8.encode(
          '{"title":"No pages","author":"","tags":[]}',
        ),
      },
      {'notes.txt': utf8.encode('not an image')},
      {
        '.hidden.jpg': [1],
        '__MACOSX/1.jpg': [2],
      },
    ]) {
      final fixture = _zip(files);
      await expectLater(_inspect(fixture), throwsFormatException);
    }
  });
}

Future<RemoteArchiveComic> _inspect(
  _MemoryZip fixture, {
  String path = '/library/comic.cbz',
}) => RemoteArchiveComic(
  path: path,
  size: fixture.bytes.length,
).inspect(fixture.read);

_MemoryZip _zip(Map<String, List<int>> files, {bool store = false}) {
  final content = archive.Archive();
  for (final entry in files.entries) {
    final file = entry.key.endsWith('/')
        ? archive.ArchiveFile.directory(entry.key)
        : archive.ArchiveFile.bytes(entry.key, entry.value);
    if (store) file.compression = archive.CompressionType.none;
    content.addFile(file);
  }
  return _MemoryZip(
    archive.ZipEncoder().encodeBytes(
      content,
      modified: DateTime.utc(2000, 1, 1),
    ),
  );
}

class _MemoryZip {
  _MemoryZip(this.bytes);
  final Uint8List bytes;
  final calls = <(int, int)>[];

  Future<Uint8List> read(int offset, int length) async {
    calls.add((offset, length));
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}
