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

  test(
    'applies sidecar chapters without rereading the ZIP or changing image versions',
    () async {
      const embedded = ComicMetaData(
        title: '包内漫画',
        author: '包内作者',
        tags: ['包内标签'],
        chapters: [
          ComicChapter(title: '包内第一章', start: 1, end: 2),
          ComicChapter(title: '包内第二章', start: 3, end: 4),
        ],
      );
      const sidecar = ComicMetaData(
        title: '旁车漫画',
        author: '旁车作者',
        tags: ['旁车标签'],
        description: '旁车简介',
        chapters: [ComicChapter(title: '选读章节', start: 2, end: 3)],
      );
      final fixture = _zip({
        'Book/cover.jpg': [0],
        'Book/1.jpg': [1],
        'Book/2.jpg': [2],
        'Book/3.jpg': [3],
        'Book/4.jpg': [4],
        'Book/.hidden/5.jpg': [5],
        '__MACOSX/6.jpg': [6],
        'Book/metadata.json': utf8.encode(jsonEncode(embedded.toJson())),
      });
      final comic = await RemoteArchiveComic(
        path: '/library/comic.cbz',
        size: fixture.bytes.length,
        eTag: '"archive-1"',
        modifiedAt: 123456789,
      ).inspect(fixture.read);
      expect(comic.embeddedMetadata!.toJson(), embedded.toJson());
      expect(comic.metadata, same(comic.embeddedMetadata));
      expect(comic.pageCount, 4);
      fixture.calls.clear();

      final overridden = comic.withMetadata(sidecar);
      expect(overridden.index, same(comic.index));
      expect(overridden.embeddedMetadata, same(comic.embeddedMetadata));
      expect(overridden.metadata, same(sidecar));
      expect(overridden.title, '旁车漫画');
      expect(overridden.metadata!.author, '旁车作者');
      expect(overridden.metadata!.tags, ['旁车标签']);
      expect(overridden.metadata!.description, '旁车简介');
      expect(overridden.chapters, {'__cbz_range_0': '选读章节'});
      expect(overridden.chapterImages, {
        '__cbz_range_0': ['Book/2.jpg', 'Book/3.jpg'],
      });
      expect(overridden.pageCount, 4);
      expect(overridden.coverEntry, comic.coverEntry);
      expect(overridden.version, comic.version);
      expect(overridden.imageKey(), comic.imageKey());
      expect(overridden.imageKey('Book/2.jpg'), comic.imageKey('Book/2.jpg'));
      expect(overridden.eTag, comic.eTag);
      expect(overridden.modifiedAt, comic.modifiedAt);
      expect(fixture.calls, isEmpty);

      final inspectedAgain = await overridden.inspect(_unexpectedRead);
      expect(inspectedAgain.index, same(comic.index));
      expect(inspectedAgain.metadata, same(sidecar));
      expect(inspectedAgain.chapterImages, overridden.chapterImages);
      final persisted = RemoteArchiveComic.fromJson(
        jsonDecode(jsonEncode(overridden.toJson())),
      );
      expect(persisted.metadata!.toJson(), sidecar.toJson());
      expect(persisted.embeddedMetadata!.toJson(), embedded.toJson());
      expect(persisted.pageCount, 4);
      expect(persisted.version, comic.version);
      expect(persisted.imageKey(), comic.imageKey());
      final cached = await persisted.inspect(_unexpectedRead);
      expect(cached.index, same(persisted.index));
      expect(cached.chapterImages, overridden.chapterImages);

      final restored = persisted.withMetadata(null);
      expect(restored.index, same(persisted.index));
      expect(restored.metadata!.toJson(), embedded.toJson());
      expect(restored.title, comic.title);
      expect(restored.chapters, comic.chapters);
      expect(restored.chapterImages, comic.chapterImages);
      expect(restored.coverEntry, comic.coverEntry);
      expect(restored.pageCount, 4);
      expect(restored.version, comic.version);
      expect(restored.imageKey(), comic.imageKey());
      expect(fixture.calls, isEmpty);
    },
  );

  test(
    'clearing sidecar metadata restores inferred directory chapters',
    () async {
      final fixture = _zip({
        'Book/cover.png': [0],
        'Book/Chapter 10/cover.jpg': [0],
        'Book/Chapter 10/2.jpg': [4],
        'Book/Chapter 2/2.jpg': [2],
        'Book/Chapter 10/1.jpg': [3],
        'Book/Chapter 2/1.jpg': [1],
      });
      final comic = await _inspect(fixture);
      fixture.calls.clear();
      final overridden = comic.withMetadata(
        const ComicMetaData(
          title: '旁车标题',
          author: '作者',
          tags: [],
          chapters: [ComicChapter(title: '合并章节', start: 2, end: 3)],
        ),
      );
      expect(overridden.embeddedMetadata, isNull);
      expect(overridden.pageCount, 4);
      expect(overridden.chapterImages, {
        '__cbz_range_0': ['Book/Chapter 2/2.jpg', 'Book/Chapter 10/1.jpg'],
      });

      final restored = overridden.withMetadata(null);
      expect(restored.index, same(comic.index));
      expect(restored.metadata, isNull);
      expect(restored.title, comic.title);
      expect(restored.chapters.keys.toList(), [
        'dir:Chapter 2',
        'dir:Chapter 10',
      ]);
      expect(restored.chapterImages, comic.chapterImages);
      expect(restored.coverEntry, 'Book/cover.png');
      expect(restored.imageKey(), comic.imageKey());
      expect(restored.pageCount, 4);
      expect(fixture.calls, isEmpty);
      final inspectedAgain = await restored.inspect(_unexpectedRead);
      expect(inspectedAgain.index, same(comic.index));
      expect(inspectedAgain.chapterImages, comic.chapterImages);
    },
  );

  test(
    'summary sidecar metadata stays distinct from embedded metadata after JSON',
    () async {
      const sidecar = ComicMetaData(
        title: '旁车标题',
        author: '旁车作者',
        tags: ['旁车标签'],
        chapters: [ComicChapter(title: '选读', start: 2, end: 2)],
      );
      const embedded = ComicMetaData(title: '包内标题', author: '包内作者', tags: []);
      final fixture = _zip({
        'cover.jpg': [0],
        '1.jpg': [1],
        '2.jpg': [2],
        '3.jpg': [3],
        'metadata.json': utf8.encode(jsonEncode(embedded.toJson())),
      });
      final summary = RemoteArchiveComic(
        path: '/library/comic.cbz',
        size: fixture.bytes.length,
      );
      final overridden = summary.withMetadata(sidecar);
      expect(overridden.title, '旁车标题');
      expect(overridden.isInspected, isFalse);
      expect(overridden.pageCount, isNull);
      expect(overridden.embeddedMetadata, isNull);
      expect(overridden.version, summary.version);
      expect(overridden.imageKey('1.jpg'), summary.imageKey('1.jpg'));
      expect(overridden.toJson(), containsPair('embeddedMetadata', null));
      expect(fixture.calls, isEmpty);

      final cached = RemoteArchiveComic.fromJson(
        jsonDecode(jsonEncode(overridden.toJson())),
      );
      expect(cached.embeddedMetadata, isNull);
      expect(cached.metadata!.toJson(), sidecar.toJson());
      expect(cached.pageCount, isNull);
      expect(cached.withMetadata(null).metadata, isNull);
      expect(cached.withMetadata(null).title, 'comic');
      expect(fixture.calls, isEmpty);

      final inspected = await cached.inspect(fixture.read);
      expect(inspected.metadata!.toJson(), sidecar.toJson());
      expect(inspected.embeddedMetadata!.toJson(), embedded.toJson());
      expect(inspected.chapterImages, {
        '__cbz_range_0': ['2.jpg'],
      });
      expect(inspected.pageCount, 3);
      final restored = inspected.withMetadata(null);
      expect(restored.title, '包内标题');
      expect(restored.chapterImages, {
        '__root__': ['1.jpg', '2.jpg', '3.jpg'],
      });
    },
  );

  test(
    'legacy metadata-only caches treat the saved metadata as embedded',
    () async {
      const embedded = ComicMetaData(
        title: '旧缓存标题',
        author: '包内作者',
        tags: ['旧标签'],
        chapters: [ComicChapter(title: '包内章节', start: 1, end: 1)],
      );
      final fixture = _zip({
        '1.jpg': [1],
        '2.jpg': [2],
        'metadata.json': utf8.encode(jsonEncode(embedded.toJson())),
      });
      final comic = await _inspect(fixture);
      final legacy = comic.toJson()..remove('embeddedMetadata');
      final cached = RemoteArchiveComic.fromJson(
        jsonDecode(jsonEncode(legacy)),
      );
      expect(cached.embeddedMetadata!.toJson(), embedded.toJson());
      expect(cached.metadata!.toJson(), embedded.toJson());
      expect(cached.pageCount, 2);
      expect(cached.toJson()['embeddedMetadata'], embedded.toJson());
      final overridden = cached.withMetadata(
        const ComicMetaData(title: '新旁车标题', author: '新作者', tags: []),
      );
      final restored = overridden.withMetadata(null);
      expect(restored.metadata!.toJson(), embedded.toJson());
      expect(restored.chapterImages, comic.chapterImages);
      expect(restored.version, comic.version);
      final inspected = await restored.inspect(_unexpectedRead);
      expect(inspected.index, same(cached.index));
      expect(inspected.title, '旧缓存标题');
    },
  );

  test('rejects invalid sidecar chapters before slicing pages', () async {
    final fixture = _zip({
      '1.jpg': [1],
      '2.jpg': [2],
    });
    final comic = await _inspect(fixture);
    fixture.calls.clear();
    const outOfRange = ComicMetaData(
      title: '超出页数',
      author: '',
      tags: [],
      chapters: [ComicChapter(title: '章节', start: 1, end: 3)],
    );
    const overlapping = ComicMetaData(
      title: '重叠章节',
      author: '',
      tags: [],
      chapters: [
        ComicChapter(title: '第一章', start: 1, end: 2),
        ComicChapter(title: '第二章', start: 2, end: 2),
      ],
    );
    expect(() => comic.withMetadata(outOfRange), throwsFormatException);
    expect(() => comic.withMetadata(overlapping), throwsFormatException);
    expect(comic.metadata, isNull);
    expect(comic.chapterImages, {
      '__root__': ['1.jpg', '2.jpg'],
    });
    expect(fixture.calls, isEmpty);

    final summary = RemoteArchiveComic(path: comic.path, size: comic.size);
    expect(() => summary.withMetadata(overlapping), throwsFormatException);
    final deferred = summary.withMetadata(outOfRange);
    expect(deferred.pageCount, isNull);
    await expectLater(deferred.inspect(fixture.read), throwsFormatException);
  });

  test(
    'uses Full book for a plain root without inferring numeric titles',
    () async {
      for (final folder in ['Book', '123', '漫画3', 'Book第03卷']) {
        final fixture = _zip({
          '$folder/2.jpg': [2],
          '$folder/1.jpg': [1],
        });
        final comic = await _inspect(fixture, path: '/library/Comic 2024.cbz');
        expect(comic.chapters, {'__root__': 'Images'}, reason: folder);
        expect(comic.chapterTitles, {'__root__': 'Full book'}, reason: folder);
        expect(comic.chapterPageCounts, {'__root__': 2});
      }
      final summary = RemoteArchiveComic(
        path: '/library/第03卷.cbz',
        size: 0,
        chapters: const {'old-id': '旧名称'},
      );
      expect(summary.chapterTitles, summary.chapters);
      expect(summary.chapterPageCounts, isEmpty);
    },
  );

  test('keeps a mixed root image group distinct from a full book', () async {
    for (final folder in ['Book', '第1卷']) {
      final fixture = _zip({
        '$folder/1.jpg': [1],
        '$folder/第2话/2.jpg': [2],
        '$folder/第2话/1.jpg': [1],
      });
      final comic = await _inspect(fixture, path: '/library/漫画 第99话.cbz');
      expect(comic.chapters, {'__root__': 'Images', 'dir:第2话': '第2话'});
      expect(comic.chapterTitles, {
        '__root__': 'Images',
        'dir:第2话': folder == 'Book' ? '第2话' : '第1卷/第2话',
      });
      expect(comic.chapterPageCounts, {'__root__': 1, 'dir:第2话': 2});
      expect(comic.chapterImages.keys.toList(), ['__root__', 'dir:第2话']);
    }
  });

  test(
    'retains an explicit stripped root as the single chapter title',
    () async {
      for (final folder in ['全1卷', '第01卷', '第1话', 'Chapter 3', 'Vol.2', '番外']) {
        final fixture = _zip({
          '$folder/cover.jpg': [0],
          '$folder/10.jpg': [10],
          '$folder/2.jpg': [2],
          '$folder/.hidden.jpg': [3],
          '__MACOSX/1.jpg': [4],
        });
        final comic = await _inspect(fixture, path: '/library/漫画 第99话.cbz');
        fixture.calls.clear();
        final version = comic.version;
        final key = comic.imageKey('$folder/2.jpg');
        expect(comic.chapters, {'__root__': 'Images'});
        expect(comic.chapterTitles, {'__root__': folder});
        expect(comic.chapterPageCounts, {'__root__': 2});
        expect(comic.chapterImages, {
          '__root__': ['$folder/2.jpg', '$folder/10.jpg'],
        });
        expect(comic.version, version);
        expect(comic.imageKey('$folder/2.jpg'), key);
        expect(fixture.calls, isEmpty);
      }
    },
  );

  test(
    'extracts only explicit Chinese or English chapter tokens from filenames',
    () async {
      final fixture = _zip({
        'Book/1.jpg': [1],
      });
      for (final entry in {
        '[作者] 漫画 第03卷 完整版.cbz': '第03卷',
        '漫画第12话.zip': '第12话',
        '漫画2024第03卷.cbz': '第03卷',
        'Manga Vol. 2 [Artist].cbz': 'Vol. 2',
        'Book Chapter 10.zip': 'Chapter 10',
        'Book Volume 3.cbz': 'Volume 3',
        'Comic2.cbz': 'Full book',
        'Comic 2024.cbz': 'Full book',
        'NovelVolume2Story.cbz': 'Full book',
      }.entries) {
        final comic = await _inspect(fixture, path: '/library/${entry.key}');
        expect(comic.chapterTitles, {
          '__root__': entry.value,
        }, reason: entry.key);
        expect(comic.chapters, {'__root__': 'Images'});
      }
    },
  );

  test(
    'keeps nested chapter IDs and page order while displaying a stripped volume',
    () async {
      final fixture = _zip({
        '第1卷/第10话/2.jpg': [2],
        '第1卷/第2话/10.jpg': [10],
        '第1卷/第2话/2.jpg': [2],
        '第1卷/第10话/1.jpg': [1],
        '第1卷/第2话/1.jpg': [1],
        '第1卷/cover.jpg': [0],
      });
      final comic = await _inspect(fixture);
      final saved = jsonDecode(jsonEncode(comic.toJson()));
      final version = comic.version;
      final key = comic.imageKey('第1卷/第2话/2.jpg');
      fixture.calls.clear();

      expect(comic.chapters, {'dir:第2话': '第2话', 'dir:第10话': '第10话'});
      expect(comic.chapterTitles, {
        'dir:第2话': '第1卷/第2话',
        'dir:第10话': '第1卷/第10话',
      });
      expect(comic.chapterPageCounts, {'dir:第2话': 3, 'dir:第10话': 2});
      expect(comic.chapterImages, {
        'dir:第2话': ['第1卷/第2话/1.jpg', '第1卷/第2话/2.jpg', '第1卷/第2话/10.jpg'],
        'dir:第10话': ['第1卷/第10话/1.jpg', '第1卷/第10话/2.jpg'],
      });
      expect(comic.toJson(), saved);
      expect(comic.version, version);
      expect(comic.imageKey('第1卷/第2话/2.jpg'), key);
      expect(fixture.calls, isEmpty);

      final cached = RemoteArchiveComic.fromJson(saved);
      expect(cached.chapterTitles, comic.chapterTitles);
      expect(cached.chapterPageCounts, comic.chapterPageCounts);
      expect(cached.toJson(), saved);
      expect(cached.version, version);
      expect(cached.imageKey('第1卷/第2话/2.jpg'), key);
    },
  );

  test(
    'keeps explicit metadata chapter titles ahead of directory and filename tokens',
    () async {
      const embedded = ComicMetaData(
        title: '漫画',
        author: '',
        tags: [],
        chapters: [
          ComicChapter(title: '开篇', start: 1, end: 2),
          ComicChapter(title: '后记', start: 3, end: 3),
        ],
      );
      final fixture = _zip({
        '第1卷/1.jpg': [1],
        '第1卷/2.jpg': [2],
        '第1卷/3.jpg': [3],
        '第1卷/metadata.json': utf8.encode(jsonEncode(embedded.toJson())),
      });
      final comic = await _inspect(fixture, path: '/library/漫画 第99话.cbz');
      expect(comic.chapterTitles, {
        '__cbz_range_0': '开篇',
        '__cbz_range_1': '后记',
      });
      expect(comic.chapterTitles, comic.chapters);
      expect(comic.chapterPageCounts, {'__cbz_range_0': 2, '__cbz_range_1': 1});
      final overridden = comic.withMetadata(
        const ComicMetaData(
          title: '旁车漫画',
          author: '',
          tags: [],
          chapters: [ComicChapter(title: '特别选读', start: 2, end: 3)],
        ),
      );
      expect(overridden.chapterTitles, {'__cbz_range_0': '特别选读'});
      expect(overridden.chapterPageCounts, {'__cbz_range_0': 2});
      expect(overridden.withMetadata(null).chapterTitles, comic.chapterTitles);
    },
  );

  test(
    'derives new titles from legacy cached indexes without rewriting raw chapters',
    () async {
      final fixture = _zip({
        '全1卷/1.jpg': [1],
        '全1卷/2.jpg': [2],
      });
      final comic = await _inspect(fixture);
      final legacy =
          jsonDecode(jsonEncode(comic.toJson())) as Map<String, dynamic>
            ..remove('embeddedMetadata');
      expect(legacy.containsKey('chapterTitles'), isFalse);
      final cached = RemoteArchiveComic.fromJson(legacy);
      final saved = jsonDecode(jsonEncode(cached.toJson()));
      fixture.calls.clear();
      expect(cached.chapters, {'__root__': 'Images'});
      expect(cached.chapterTitles, {'__root__': '全1卷'});
      expect(cached.chapterPageCounts, {'__root__': 2});
      expect(cached.toJson(), saved);
      expect(cached.toJson()['chapters'], {'__root__': 'Images'});
      expect(cached.version, comic.version);
      expect(cached.imageKey(), comic.imageKey());
      expect(fixture.calls, isEmpty);
      final inspected = await cached.inspect(_unexpectedRead);
      expect(inspected.index, same(cached.index));
      expect(inspected.chapterTitles, cached.chapterTitles);
      expect(inspected.chapterImages, comic.chapterImages);
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

Future<Uint8List> _unexpectedRead(int offset, int length) async {
  throw StateError('Cached index must not request ZIP range $offset:$length');
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
