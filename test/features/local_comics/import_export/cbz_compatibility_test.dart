import 'dart:convert';

import 'package:archive/archive_io.dart' as archive_io;
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/local_comics/import_export/import_export.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/file_system.dart';

import '../../../support/sqlite.dart';

void main() {
  group('CBZ compatibility helpers', () {
    test(
      'compatiblePageFileName pads to four digits and preserves extension',
      () {
        expect(CBZ.compatiblePageFileName(1, 'jpg'), '0001.jpg');
      },
    );

    test(
      'buildComicInfoXmlForTesting includes page metadata without cover',
      () {
        final xml = CBZ.buildComicInfoXmlForTesting(
          ComicMetaData(
            title: 'Title & <Story>',
            author: 'Author "A" & Co',
            tags: ['tag <one>', 'tag & two'],
          ),
          pageCount: 3,
        );

        expect(xml, contains('<Title>Title &amp; &lt;Story&gt;</Title>'));
        expect(xml, contains('<Writer>Author &quot;A&quot; &amp; Co</Writer>'));
        expect(xml, contains('<Tags>tag &lt;one&gt;, tag &amp; two</Tags>'));
        expect(xml, isNot(contains('<Genre>')));
        expect(xml, contains('<PageCount>3</PageCount>'));
        expect(xml, contains('<Manga>Unknown</Manga>'));
        expect(xml, contains('<BlackAndWhite>Unknown</BlackAndWhite>'));
        expect(xml, contains('<Page Image="0" Type="Story" />'));
        expect(xml, contains('<Page Image="1" Type="Story" />'));
        expect(xml, contains('<Page Image="2" Type="Story" />'));
        expect(xml, isNot(contains('Type="FrontCover"')));
      },
    );

    test('buildChapterRangesForTesting calculates contiguous page ranges', () {
      final chapters = CBZ.buildChapterRangesForTesting({
        'Chapter 1': 2,
        'Chapter 2': 3,
      });

      expect(chapters, hasLength(2));
      expect(chapters[0].title, 'Chapter 1');
      expect(chapters[0].start, 1);
      expect(chapters[0].end, 2);
      expect(chapters[1].title, 'Chapter 2');
      expect(chapters[1].start, 3);
      expect(chapters[1].end, 5);
    });

    test('localFilePathFromImageUriForTesting strips file URI prefix', () {
      final result = CBZ.localFilePathFromImageUriForTesting(
        'file:///tmp/a.jpg',
      );

      expect(result.startsWith('file://'), isFalse);
      expect(result, contains('a.jpg'));
    });

    test(
      'localFilePathFromImageUriForTesting leaves plain paths unchanged',
      () {
        const plainPath = '/tmp/a.jpg';

        expect(CBZ.localFilePathFromImageUriForTesting(plainPath), plainPath);
      },
    );

    test(
      'inspectImportLayoutForTesting detects chapter folders under a root folder',
      () {
        final temp = Directory.systemTemp.createTempSync('cbz_layout_');
        try {
          final root = Directory(FilePath.join(temp.path, '猫之眼[北条司]'))
            ..createSync();
          File(FilePath.join(root.path, 'cover.jpg')).writeAsBytesSync([1]);
          final chapter1 = Directory(FilePath.join(root.path, '第01卷'))
            ..createSync();
          final chapter2 = Directory(FilePath.join(root.path, '第02卷'))
            ..createSync();
          File(FilePath.join(chapter1.path, '002.jpg')).writeAsBytesSync([1]);
          File(FilePath.join(chapter1.path, '001.jpg')).writeAsBytesSync([1]);
          File(FilePath.join(chapter2.path, '001.jpg')).writeAsBytesSync([1]);

          final layout = CBZ.inspectImportLayoutForTesting(temp);
          final chapters = layout['chapters'] as Map<String, List<String>>;

          expect(layout['root'], '猫之眼[北条司]');
          expect(layout['cover'], 'cover.jpg');
          expect(layout['useChapterDirectories'], isTrue);
          expect(chapters.keys.toList(), ['第01卷', '第02卷']);
          expect(chapters['第01卷'], ['001.jpg', '002.jpg']);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'inspectImportLayoutForTesting uses first chapter image as cover when needed',
      () {
        final temp = Directory.systemTemp.createTempSync('cbz_layout_');
        try {
          final root = Directory(FilePath.join(temp.path, 'Book'))
            ..createSync();
          final chapter = Directory(FilePath.join(root.path, 'Chapter 1'))
            ..createSync();
          File(FilePath.join(chapter.path, '001.png')).writeAsBytesSync([1]);

          final layout = CBZ.inspectImportLayoutForTesting(temp);

          expect(layout['cover'], '001.png');
          expect(layout['useChapterDirectories'], isTrue);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'inspectImportLayoutForTesting keeps flat layout when root has pages',
      () {
        final temp = Directory.systemTemp.createTempSync('cbz_layout_');
        try {
          File(FilePath.join(temp.path, '001.jpg')).writeAsBytesSync([1]);
          final chapter = Directory(FilePath.join(temp.path, 'Chapter 1'))
            ..createSync();
          File(FilePath.join(chapter.path, '001.jpg')).writeAsBytesSync([1]);

          final layout = CBZ.inspectImportLayoutForTesting(temp);

          expect(layout['rootImages'], ['001.jpg']);
          expect(layout['useChapterDirectories'], isFalse);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'extractArchiveForTesting retries zip extraction with 7z fallback',
      () async {
        final temp = Directory.systemTemp.createTempSync('cbz_extract_');
        try {
          final archive = File(FilePath.join(temp.path, 'legacy.cbz'))
            ..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04]);
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();
          final calls = <String>[];

          await CBZ.extractArchiveForTesting(
            archive,
            out,
            zipExtractor: (archivePath, outputPath, threads) async {
              calls.add('zip');
              File(
                FilePath.join(outputPath, 'partial.jpg'),
              ).writeAsBytesSync([1]);
              throw const FormatException('Missing extension byte', null, 24);
            },
            sevenZipExtractor: (archivePath, outputPath, threads) async {
              calls.add('7z');
              expect(
                File(FilePath.join(outputPath, 'partial.jpg')).existsSync(),
                isFalse,
              );
              File(FilePath.join(outputPath, '001.jpg')).writeAsBytesSync([1]);
            },
          );

          expect(calls, ['zip', '7z']);
          expect(File(FilePath.join(out.path, '001.jpg')).existsSync(), isTrue);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'extractArchiveForTesting retries Dart zip extraction when native extractors fail',
      () async {
        final temp = Directory.systemTemp.createTempSync('cbz_extract_');
        try {
          final archive = File(FilePath.join(temp.path, 'legacy.cbz'))
            ..writeAsBytesSync([0x50, 0x4B, 0x03, 0x04]);
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();
          final calls = <String>[];

          await CBZ.extractArchiveForTesting(
            archive,
            out,
            zipExtractor: (archivePath, outputPath, threads) async {
              calls.add('zip');
              throw const FormatException('Missing extension byte', null, 24);
            },
            sevenZipExtractor: (archivePath, outputPath, threads) async {
              calls.add('7z');
              throw Exception('Failed to open archive.');
            },
            dartZipExtractor: (archivePath, outputPath) async {
              calls.add('dart');
              File(FilePath.join(outputPath, '001.jpg')).writeAsBytesSync([1]);
            },
          );

          expect(calls, ['zip', '7z', 'dart']);
          expect(File(FilePath.join(out.path, '001.jpg')).existsSync(), isTrue);
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    for (final (description, encoding) in <(String, Encoding)>[
      ('UTF-8', utf8),
      ('UTF-8 without its ZIP flag', latin1),
      ('GBK', const GbkCodec()),
    ]) {
      test('Dart ZIP fallback preserves $description entry names', () async {
        final temp = Directory.systemTemp.createTempSync('cbz_extract_');
        try {
          String storedName(String name) =>
              encoding == latin1 ? latin1.decode(utf8.encode(name)) : name;
          final archive = archive_io.Archive()
            ..addFile(archive_io.ArchiveFile.directory(storedName('猫之眼[北条司]/')))
            ..addFile(
              archive_io.ArchiveFile.bytes(
                storedName('猫之眼[北条司]/第01卷/001.jpg'),
                [1, 2, 3],
              ),
            );
          final archiveFile = File(FilePath.join(temp.path, 'book.cbz'))
            ..writeAsBytesSync(
              archive_io.ZipEncoder(
                filenameEncoding: encoding,
              ).encodeBytes(archive),
            );
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();

          await CBZ.extractArchiveForTesting(
            archiveFile,
            out,
            zipExtractor: (archivePath, outputPath, threads) async {
              throw const FormatException('Missing extension byte', null, 24);
            },
            sevenZipExtractor: (archivePath, outputPath, threads) async {
              throw Exception('Failed to open archive.');
            },
          );

          expect(
            File(
              FilePath.join(out.path, '猫之眼[北条司]', '第01卷', '001.jpg'),
            ).readAsBytesSync(),
            [1, 2, 3],
          );
        } finally {
          temp.deleteSync(recursive: true);
        }
      });
    }

    test('Dart ZIP fallback reports damaged compressed data', () async {
      final temp = Directory.systemTemp.createTempSync('cbz_extract_');
      try {
        final archive = archive_io.Archive()
          ..addFile(
            archive_io.ArchiveFile.bytes('001.jpg', List.filled(256, 1))
              ..compression = archive_io.CompressionType.deflate,
          );
        final bytes = archive_io.ZipEncoder().encodeBytes(archive);
        final header = ByteData.sublistView(bytes);
        final contentOffset =
            30 +
            header.getUint16(26, Endian.little) +
            header.getUint16(28, Endian.little);
        bytes[contentOffset] = 0x07; // Reserved DEFLATE block type.
        final archiveFile = File(FilePath.join(temp.path, 'damaged.cbz'))
          ..writeAsBytesSync(bytes);
        final out = Directory(FilePath.join(temp.path, 'out'))..createSync();

        await expectLater(
          CBZ.extractArchiveForTesting(
            archiveFile,
            out,
            zipExtractor: (archivePath, outputPath, threads) async {
              throw const FormatException('Native ZIP extraction failed');
            },
            sevenZipExtractor: (archivePath, outputPath, threads) async {
              throw const FormatException('7z extraction failed');
            },
          ),
          throwsA(isA<archive_io.ArchiveException>()),
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
    });

    test(
      'allocateExportFileName handles duplicate, case and sanitized collisions',
      () {
        final used = <String>{};
        expect(CBZ.allocateExportFileName('中文漫画', '.cbz', used), '中文漫画.cbz');
        expect(
          CBZ.allocateExportFileName('中文漫画', '.cbz', used),
          '中文漫画 (2).cbz',
        );
        expect(CBZ.allocateExportFileName('Comic', '.cbz', used), 'Comic.cbz');
        expect(
          CBZ.allocateExportFileName('comic', '.cbz', used),
          'comic (2).cbz',
        );
        expect(CBZ.allocateExportFileName('A:B', '.cbz', used), 'A B.cbz');
        expect(CBZ.allocateExportFileName('A/B', '.cbz', used), 'A B (2).cbz');
        expect(
          CBZ.allocateExportFileName('测试 (2)', '.cbz', used),
          '测试 (2).cbz',
        );
        expect(CBZ.allocateExportFileName('测试', '.cbz', used), '测试.cbz');
        expect(CBZ.allocateExportFileName('测试', '.cbz', used), '测试 (3).cbz');
        final fallbackUsed = <String>{};
        expect(
          CBZ.allocateExportFileName('???', '.cbz', fallbackUsed),
          'comic.cbz',
        );
        expect(
          CBZ.allocateExportFileName('***', '.cbz', fallbackUsed),
          'comic (2).cbz',
        );
      },
    );

    test(
      'resolveSafeArchiveEntryPath rejects traversal and absolute paths while allowing safe entries',
      () {
        final temp = Directory.systemTemp.createTempSync('cbz_safe_path_');
        try {
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();
          expect(
            CBZ.resolveSafeArchiveEntryPath(out.path, '001.jpg'),
            contains('001.jpg'),
          );
          expect(
            CBZ.resolveSafeArchiveEntryPath(out.path, './001.jpg'),
            contains('001.jpg'),
          );
          expect(
            CBZ.resolveSafeArchiveEntryPath(out.path, 'dir/./sub/001.jpg'),
            contains('sub'),
          );
          expect(
            CBZ.resolveSafeArchiveEntryPath(out.path, 'foo..bar/001.jpg'),
            contains('foo..bar'),
          );
          expect(
            CBZ.resolveSafeArchiveEntryPath(out.path, '中文\\第01话\\001.jpg'),
            contains('第01话'),
          );
          expect(CBZ.resolveSafeArchiveEntryPath(out.path, ''), isNull);
          expect(CBZ.resolveSafeArchiveEntryPath(out.path, '.'), isNull);
          expect(CBZ.resolveSafeArchiveEntryPath(out.path, './'), isNull);

          for (final unsafe in [
            '../evil.jpg',
            'a/../../evil.jpg',
            r'a\..\..\evil.jpg',
            '/etc/passwd',
            r'\Windows\evil.dll',
            r'C:\evil.jpg',
            'C:/evil.jpg',
            'd:relative.jpg',
            '001.jpg\u0000.txt',
          ]) {
            expect(
              () => CBZ.resolveSafeArchiveEntryPath(out.path, unsafe),
              throwsFormatException,
              reason: 'Expected unsafe path rejection for $unsafe',
            );
          }
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'Dart ZIP fallback rejects path traversal without writing partial files',
      () async {
        final temp = Directory.systemTemp.createTempSync('cbz_zip_slip_');
        try {
          final archive = archive_io.Archive()
            ..addFile(archive_io.ArchiveFile.bytes('001.jpg', [1, 2, 3]))
            ..addFile(archive_io.ArchiveFile.bytes('../escape.txt', [9, 8, 7]));
          final archiveFile = File(FilePath.join(temp.path, 'traversal.cbz'))
            ..writeAsBytesSync(archive_io.ZipEncoder().encodeBytes(archive));
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();

          await expectLater(
            CBZ.extractArchiveForTesting(
              archiveFile,
              out,
              zipExtractor: (archivePath, outputPath, threads) async {
                throw const FormatException('Native ZIP extraction failed');
              },
              sevenZipExtractor: (archivePath, outputPath, threads) async {
                throw const FormatException('7z extraction failed');
              },
            ),
            throwsFormatException,
          );

          expect(
            File(FilePath.join(temp.path, 'escape.txt')).existsSync(),
            isFalse,
          );
          expect(
            File(FilePath.join(out.path, '001.jpg')).existsSync(),
            isFalse,
          );
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );

    test(
      'Dart ZIP fallback rejects STORE entries with corrupted CRC32',
      () async {
        final temp = Directory.systemTemp.createTempSync('cbz_store_crc_');
        try {
          final archive = archive_io.Archive()
            ..addFile(
              archive_io.ArchiveFile.bytes('001.jpg', List.filled(64, 0x42))
                ..compression = archive_io.CompressionType.none,
            );
          final bytes = archive_io.ZipEncoder().encodeBytes(archive);
          final header = ByteData.sublistView(bytes);
          final contentOffset =
              30 +
              header.getUint16(26, Endian.little) +
              header.getUint16(28, Endian.little);
          bytes[contentOffset] ^= 0xff;
          final archiveFile = File(FilePath.join(temp.path, 'bad_store.cbz'))
            ..writeAsBytesSync(bytes);
          final out = Directory(FilePath.join(temp.path, 'out'))..createSync();

          await expectLater(
            CBZ.extractArchiveForTesting(
              archiveFile,
              out,
              zipExtractor: (archivePath, outputPath, threads) async {
                throw const FormatException('Native ZIP extraction failed');
              },
              sevenZipExtractor: (archivePath, outputPath, threads) async {
                throw const FormatException('7z extraction failed');
              },
            ),
            throwsA(isA<archive_io.ArchiveException>()),
          );
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
    );
  });

  group(
    'CBZ collection export and import',
    () {
      late Directory root;
      late String previousDataPath;
      late String previousCachePath;

      setUp(() async {
        try {
          previousDataPath = App.dataPath;
        } on Error {
          previousDataPath = Directory.systemTemp.path;
        }
        try {
          previousCachePath = App.cachePath;
        } on Error {
          previousCachePath = Directory.systemTemp.path;
        }
        root = Directory.systemTemp.createTempSync('cbz-collection-');
        App.dataPath = (Directory(
          FilePath.join(root.path, 'data1'),
        )..createSync()).path;
        App.cachePath = (Directory(
          FilePath.join(root.path, 'cache'),
        )..createSync()).path;
        LocalManager.resetForTesting();
        LocalManager.debugSkipComicSourceInit = true;
        await LocalManager().init();
      });

      tearDown(() async {
        await LocalManager().pendingDownloadTaskWrites;
        LocalManager.resetForTesting();
        App.dataPath = previousDataPath;
        App.cachePath = previousCachePath;
        if (root.existsSync()) {
          root.deleteSync(recursive: true);
        }
      });

      Future<LocalComic> createComic({
        required String id,
        required String title,
        required String author,
        required List<String> tags,
        required String directoryName,
        required Uint8List coverBytes,
        required List<({String title, List<Uint8List> pages})> chapters,
      }) async {
        final comicDir = Directory(
          FilePath.join(LocalManager().path, directoryName),
        )..createSync(recursive: true);
        File(
          FilePath.join(comicDir.path, 'cover.jpg'),
        ).writeAsBytesSync(coverBytes);
        final chapterMap = <String, String>{};
        final downloaded = <String>[];
        for (var i = 0; i < chapters.length; i++) {
          final chapterId = '$i';
          chapterMap[chapterId] = chapters[i].title;
          downloaded.add(chapterId);
          final chapterDir = Directory(FilePath.join(comicDir.path, chapterId))
            ..createSync(recursive: true);
          for (var j = 0; j < chapters[i].pages.length; j++) {
            File(
              FilePath.join(
                chapterDir.path,
                '${(j + 1).toString().padLeft(4, '0')}.jpg',
              ),
            ).writeAsBytesSync(chapters[i].pages[j]);
          }
        }
        final comic = LocalComic(
          id: id,
          title: title,
          subtitle: author,
          tags: tags,
          directory: directoryName,
          chapters: ComicChapters(chapterMap),
          cover: 'cover.jpg',
          comicType: ComicType.local,
          downloadedChapters: downloaded,
          createdAt: DateTime(2026, 1, 1),
        );
        await LocalManager().add(comic);
        return comic;
      }

      Future<void> switchToFreshLibrary(String name) async {
        await LocalManager().pendingDownloadTaskWrites;
        LocalManager.resetForTesting();
        App.dataPath = (Directory(
          FilePath.join(root.path, name),
        )..createSync()).path;
        LocalManager.debugSkipComicSourceInit = true;
        await LocalManager().init();
      }

      test(
        'roundtrips duplicate Chinese comics via batch CBZ zip without overwrite',
        () async {
          final coverA = Uint8List.fromList([0xff, 0xd8, 0x01, 0x01]);
          final coverB = Uint8List.fromList([0xff, 0xd8, 0x02, 0x02]);
          final aCh1 = [
            Uint8List.fromList([10, 11, 12]),
            Uint8List.fromList([13, 14, 15]),
          ];
          final aCh2 = [
            Uint8List.fromList([16, 17, 18]),
          ];
          final bCh1 = [
            Uint8List.fromList([20, 21, 22]),
          ];
          final bCh2 = [
            Uint8List.fromList([23, 24, 25]),
            Uint8List.fromList([26, 27, 28]),
          ];

          final comicA = await createComic(
            id: '1',
            title: '同名中文漫画',
            author: '作者甲',
            tags: ['标签甲', '奇幻'],
            directoryName: '同名中文漫画',
            coverBytes: coverA,
            chapters: [
              (title: '第1话', pages: aCh1),
              (title: '第2话', pages: aCh2),
            ],
          );
          final comicB = await createComic(
            id: '2',
            title: '同名中文漫画',
            author: '作者乙',
            tags: ['标签乙'],
            directoryName: '同名中文漫画(1)',
            coverBytes: coverB,
            chapters: [(title: '序章', pages: bCh1), (title: '终章', pages: bCh2)],
          );

          final exportDir = Directory(
            FilePath.join(root.path, '中文导出目录', 'comics'),
          )..createSync(recursive: true);
          final used = <String>{};
          final nameA = CBZ.allocateExportFileName(comicA.title, '.cbz', used);
          final nameB = CBZ.allocateExportFileName(comicB.title, '.cbz', used);
          expect(nameA, '同名中文漫画.cbz');
          expect(nameB, '同名中文漫画 (2).cbz');

          await CBZ.export(comicA, FilePath.join(exportDir.path, nameA));
          await CBZ.export(comicB, FilePath.join(exportDir.path, nameB));
          final outerZip = File(
            FilePath.join(root.path, '中文导出目录', 'comics_export.zip'),
          );
          await CBZ.compressDirectory(exportDir.path, outerZip.path);

          await switchToFreshLibrary('data2');
          final result = await CBZ.importArchive(
            outerZip,
            registerComic: (comic) => const ImportComic().registerComic(comic),
          );

          expect(result.importedCount, 2);
          expect(result.failures, isEmpty);

          final imported = LocalManager().getComics(LocalSortType.name);
          expect(imported, hasLength(2));
          expect(imported.map((c) => c.title), ['同名中文漫画', '同名中文漫画']);
          expect(imported[0].id, isNot(imported[1].id));
          expect(imported[0].directory, isNot(imported[1].directory));

          final first = imported.singleWhere((c) => c.subtitle == '作者甲');
          final second = imported.singleWhere((c) => c.subtitle == '作者乙');

          expect(first.tags, ['标签甲', '奇幻']);
          expect(first.chapters!.titles.toList(), ['第1话', '第2话']);
          expect(first.coverFile.readAsBytesSync(), coverA);
          final firstCh1 = await LocalManager().getImages(
            first.id,
            ComicType.local,
            1,
          );
          final firstCh2 = await LocalManager().getImages(
            first.id,
            ComicType.local,
            2,
          );
          expect(
            firstCh1.map((u) => File(u.substring(7)).readAsBytesSync()),
            aCh1,
          );
          expect(
            firstCh2.map((u) => File(u.substring(7)).readAsBytesSync()),
            aCh2,
          );

          expect(second.tags, ['标签乙']);
          expect(second.chapters!.titles.toList(), ['序章', '终章']);
          expect(second.coverFile.readAsBytesSync(), coverB);
          final secondCh1 = await LocalManager().getImages(
            second.id,
            ComicType.local,
            1,
          );
          final secondCh2 = await LocalManager().getImages(
            second.id,
            ComicType.local,
            2,
          );
          expect(
            secondCh1.map((u) => File(u.substring(7)).readAsBytesSync()),
            bCh1,
          );
          expect(
            secondCh2.map((u) => File(u.substring(7)).readAsBytesSync()),
            bCh2,
          );
        },
      );

      test(
        'imports nested single-directory CBZ collection and reports damaged child',
        () async {
          final page1 = Uint8List.fromList([1, 2, 3, 4]);
          final page2 = Uint8List.fromList([5, 6, 7, 8]);
          final comic1 = await createComic(
            id: '10',
            title: '第一本',
            author: '作者1',
            tags: ['tag1'],
            directoryName: '第一本',
            coverBytes: page1,
            chapters: [
              (title: 'Ch1', pages: [page1]),
            ],
          );
          final comic2 = await createComic(
            id: '11',
            title: '第二本',
            author: '作者2',
            tags: ['tag2'],
            directoryName: '第二本',
            coverBytes: page2,
            chapters: [
              (title: 'Ch1', pages: [page2]),
            ],
          );

          final stageDir = Directory(FilePath.join(root.path, 'nested_stage'))
            ..createSync();
          final innerDir = Directory(FilePath.join(stageDir.path, '中文合集'))
            ..createSync();
          await CBZ.export(comic1, FilePath.join(innerDir.path, '第一本.cbz'));
          await CBZ.export(comic2, FilePath.join(innerDir.path, '第二本.cbz'));

          final brokenArchive = archive_io.Archive()
            ..addFile(
              archive_io.ArchiveFile.bytes('001.jpg', List.filled(128, 7))
                ..compression = archive_io.CompressionType.deflate,
            );
          final brokenBytes = archive_io.ZipEncoder().encodeBytes(
            brokenArchive,
          );
          final header = ByteData.sublistView(brokenBytes);
          final contentOffset =
              30 +
              header.getUint16(26, Endian.little) +
              header.getUint16(28, Endian.little);
          brokenBytes[contentOffset] = 0x07;
          File(
            FilePath.join(innerDir.path, '损坏包.cbz'),
          ).writeAsBytesSync(brokenBytes);

          final collectionZip = File(
            FilePath.join(root.path, 'nested_collection.zip'),
          );
          await CBZ.compressDirectory(stageDir.path, collectionZip.path);

          await switchToFreshLibrary('data_nested');
          final result = await CBZ.importArchive(
            collectionZip,
            registerComic: (comic) => const ImportComic().registerComic(comic),
          );

          expect(result.importedCount, 2);
          expect(result.failures, hasLength(1));
          expect(result.failures.single, contains('损坏包.cbz'));

          final imported1 = LocalManager().findByName('第一本')!;
          final imported2 = LocalManager().findByName('第二本')!;
          final imgs1 = await LocalManager().getImages(
            imported1.id,
            ComicType.local,
            1,
          );
          final imgs2 = await LocalManager().getImages(
            imported2.id,
            ComicType.local,
            1,
          );
          expect(File(imgs1.single.substring(7)).readAsBytesSync(), page1);
          expect(File(imgs2.single.substring(7)).readAsBytesSync(), page2);
        },
      );

      test('imports ZIP containing root images as a single comic', () async {
        final stageDir = Directory(FilePath.join(root.path, 'image_zip_stage'))
          ..createSync();
        final p1 = Uint8List.fromList([31, 32, 33]);
        final p2 = Uint8List.fromList([41, 42, 43]);
        File(FilePath.join(stageDir.path, '0001.jpg')).writeAsBytesSync(p1);
        File(FilePath.join(stageDir.path, '0002.jpg')).writeAsBytesSync(p2);
        File(FilePath.join(stageDir.path, 'ignored.cbz')).writeAsBytesSync([0]);

        final imageZip = File(FilePath.join(root.path, '普通图片包.zip'));
        await CBZ.compressDirectory(stageDir.path, imageZip.path);

        final result = await CBZ.importArchive(
          imageZip,
          registerComic: (comic) => const ImportComic().registerComic(comic),
        );

        expect(result.importedCount, 1);
        expect(result.failures, isEmpty);
        final comic = LocalManager().findByName('普通图片包')!;
        final imgs = await LocalManager().getImages(
          comic.id,
          ComicType.local,
          1,
        );
        expect(imgs.map((u) => File(u.substring(7)).readAsBytesSync()), [
          p1,
          p2,
        ]);
      });

      test(
        'collection import rejects child CBZ with corrupted STORE CRC32 or unsafe path',
        () async {
          final validPage = Uint8List.fromList([7, 8, 9, 10]);
          final validComic = await createComic(
            id: '20',
            title: '有效作品',
            author: '作者',
            tags: ['tag'],
            directoryName: '有效作品',
            coverBytes: validPage,
            chapters: [
              (title: '第1话', pages: [validPage]),
            ],
          );

          final stageDir = Directory(FilePath.join(root.path, 'security_stage'))
            ..createSync();
          await CBZ.export(
            validComic,
            FilePath.join(stageDir.path, 'valid.cbz'),
          );

          final badStoreArchive = archive_io.Archive()
            ..addFile(
              archive_io.ArchiveFile.bytes('001.jpg', List.filled(64, 0x42))
                ..compression = archive_io.CompressionType.none,
            );
          final badStoreBytes = archive_io.ZipEncoder().encodeBytes(
            badStoreArchive,
          );
          final header = ByteData.sublistView(badStoreBytes);
          final contentOffset =
              30 +
              header.getUint16(26, Endian.little) +
              header.getUint16(28, Endian.little);
          badStoreBytes[contentOffset] ^= 0xff;
          File(
            FilePath.join(stageDir.path, 'bad_crc.cbz'),
          ).writeAsBytesSync(badStoreBytes);

          final traversalArchive = archive_io.Archive()
            ..addFile(archive_io.ArchiveFile.bytes('001.jpg', [1, 2, 3]))
            ..addFile(archive_io.ArchiveFile.bytes('../escape.txt', [9, 8, 7]));
          File(
            FilePath.join(stageDir.path, 'unsafe_path.cbz'),
          ).writeAsBytesSync(
            archive_io.ZipEncoder().encodeBytes(traversalArchive),
          );

          final collectionZip = File(
            FilePath.join(root.path, 'security_collection.zip'),
          );
          await CBZ.compressDirectory(stageDir.path, collectionZip.path);

          await switchToFreshLibrary('data_security');
          final result = await CBZ.importArchive(
            collectionZip,
            registerComic: (comic) => const ImportComic().registerComic(comic),
          );

          expect(result.importedCount, 1);
          expect(result.failures, hasLength(2));
          final combinedFailures = result.failures.join('\n');
          expect(combinedFailures, contains('bad_crc.cbz'));
          expect(combinedFailures, contains('unsafe_path.cbz'));
          expect(
            LocalManager().getComics(LocalSortType.name).map((c) => c.title),
            ['有效作品'],
          );
          expect(
            File(FilePath.join(App.cachePath, 'escape.txt')).existsSync(),
            isFalse,
          );
        },
      );

      test(
        'single CBZ import rejects duplicate titles while collection children allow duplicates',
        () async {
          final page = Uint8List.fromList([11, 22, 33, 44]);
          final sourceComic = await createComic(
            id: '30',
            title: '单本防重',
            author: '作者',
            tags: const [],
            directoryName: '单本防重',
            coverBytes: page,
            chapters: [
              (title: '第1话', pages: [page]),
            ],
          );
          final singleCbz = File(FilePath.join(root.path, 'single.cbz'));
          await CBZ.export(sourceComic, singleCbz.path);

          await switchToFreshLibrary('data_single');
          final first = await CBZ.importArchive(
            singleCbz,
            registerComic: (comic) => const ImportComic().registerComic(comic),
          );
          expect(first.importedCount, 1);
          expect(first.failures, isEmpty);

          await expectLater(
            CBZ.import(singleCbz),
            throwsA(
              isA<Exception>().having(
                (e) => e.toString(),
                'message',
                contains('already exists'),
              ),
            ),
          );
          await expectLater(
            CBZ.importArchive(
              singleCbz,
              registerComic: (comic) =>
                  const ImportComic().registerComic(comic),
            ),
            throwsA(
              isA<Exception>().having(
                (e) => e.toString(),
                'message',
                contains('already exists'),
              ),
            ),
          );
          expect(LocalManager().getComics(LocalSortType.name), hasLength(1));
          expect(
            Directory(LocalManager().path).listSync().whereType<Directory>(),
            hasLength(1),
          );
        },
      );
    },
    skip: isSqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
