import 'package:venera_plus/foundation/translations.dart';
import 'dart:isolate';

import 'package:uuid/uuid.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/features/local_comics/local.dart';
import 'package:venera_plus/foundation/file_type.dart';
import 'package:venera_plus/foundation/file_interaction.dart';
import 'package:zip_flutter/zip_flutter.dart';

class EpubData {
  final String title;

  final String author;

  final File cover;

  final List<({String title, List<File> images})> chapters;

  const EpubData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
  });
}

Future<File> createEpubComic(
  EpubData data,
  String cacheDir,
  String outFilePath,
) async {
  final cache = await Directory(cacheDir).create(recursive: true);
  final workingDir = await cache.createTemp('epub-');
  try {
    _writeEpubArchive(data, workingDir, outFilePath);
    return File(outFilePath);
  } finally {
    await workingDir.deleteIgnoreError(recursive: true);
  }
}

void _writeEpubArchive(
  EpubData data,
  Directory workingDir,
  String outFilePath,
) {
  // mimetype
  workingDir.joinFile('mimetype').writeAsStringSync('application/epub+zip');

  // META-INF
  Directory(FilePath.join(workingDir.path, 'META-INF')).createSync();
  File(
    FilePath.join(workingDir.path, 'META-INF', 'container.xml'),
  ).writeAsStringSync('''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
  ''');

  Directory(FilePath.join(workingDir.path, 'OEBPS')).createSync();

  // copy images, create html files
  final imageDir = Directory(FilePath.join(workingDir.path, 'OEBPS', 'images'));
  imageDir.createSync();
  final coverExt = data.cover.extension;
  final coverMime = FileType.fromExtension(coverExt).mime;
  imageDir
      .joinFile('cover.$coverExt')
      .writeAsBytesSync(data.cover.readAsBytesSync());
  int imgIndex = 0;
  int chapterIndex = 0;
  var manifestStrBuilder = StringBuffer();
  manifestStrBuilder.writeln(
    '        <item id="cover_image" href="OEBPS/images/cover.$coverExt" media-type="$coverMime"/>',
  );
  manifestStrBuilder.writeln(
    '        <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
  );
  for (final chapter in data.chapters) {
    var images = <String>[];
    for (final image in chapter.images) {
      final ext = image.extension;
      imageDir
          .joinFile('img$imgIndex.$ext')
          .writeAsBytesSync(image.readAsBytesSync());
      images.add('images/img$imgIndex.$ext');
      var mime = FileType.fromExtension(ext).mime;
      manifestStrBuilder.writeln(
        '        <item id="img$imgIndex" href="OEBPS/images/img$imgIndex.$ext" media-type="$mime"/>',
      );
      imgIndex++;
    }
    var html = File(
      FilePath.join(workingDir.path, 'OEBPS', '$chapterIndex.html'),
    );
    html.writeAsStringSync('''
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" 
    "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <title>${_escapeEpubXml(chapter.title)}</title>
    <style type="text/css">
        img { 
            max-width: 100%;
            height: auto;
        }
        body {
            margin: 0;
            padding: 0;
        }
    </style>
</head>
<body>
    <h1>${_escapeEpubXml(chapter.title)}</h1>
    <div>
${images.map((e) => '        <img src="$e" alt="$e"/>').join('\n')}
    </div>
</body>
</html>
    ''');
    manifestStrBuilder.writeln(
      '        <item id="chapter$chapterIndex" href="OEBPS/$chapterIndex.html" media-type="application/xhtml+xml"/>',
    );
    chapterIndex++;
  }

  // content.opf
  final contentOpf = File(FilePath.join(workingDir.path, 'content.opf'));
  final uuid = const Uuid().v4();
  var spineStrBuilder = StringBuffer();
  for (var i = 0; i < chapterIndex; i++) {
    var idRef = 'idref="chapter$i"';
    spineStrBuilder.writeln('        <itemref $idRef/>');
  }
  contentOpf.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<package version="3.0" 
    xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <metadata>
        <dc:title>${_escapeEpubXml(data.title)}</dc:title>
        <dc:creator>${_escapeEpubXml(data.author)}</dc:creator>
        <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
        <meta name="cover" content="cover_image"/>
    </metadata>
    <manifest>
${manifestStrBuilder.toString()}       
    </manifest>
    <spine toc="toc">
${spineStrBuilder.toString()}
    </spine>
</package>
  ''');

  // toc.ncx
  final tocNcx = File(FilePath.join(workingDir.path, 'toc.ncx'));
  var navMapStrBuilder = StringBuffer();
  var playOrder = 2;
  for (var i = 0; i < chapterIndex; i++) {
    navMapStrBuilder.writeln(
      '        <navPoint id="chapter$i" playOrder="$playOrder">',
    );
    navMapStrBuilder.writeln(
      '            <navLabel><text>${_escapeEpubXml(data.chapters[i].title)}</text></navLabel>',
    );
    navMapStrBuilder.writeln('            <content src="OEBPS/$i.html"/>');
    navMapStrBuilder.writeln('        </navPoint>');
    playOrder++;
  }

  tocNcx.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
    <head>
        <meta name="dtb:uid" content="urn:uuid:$uuid"/>
        <meta name="dtb:depth" content="1"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
    </head>
    <docTitle>
        <text>${_escapeEpubXml(data.title)}</text>
    </docTitle>
    <navMap>
${navMapStrBuilder.toString()}
    </navMap>
</ncx>
  ''');

  ZipFile.compressFolder(workingDir.path, outFilePath);
}

String _escapeEpubXml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

Future<File> createEpubWithLocalComic(
  LocalComic comic,
  String outFilePath,
) async {
  if (comic.isIncomplete) {
    throw StateError('Retry missing images before exporting this comic.'.tl);
  }
  final chapters = <({String title, List<String> paths})>[];
  final comicChapters = comic.chapters;
  if (comicChapters == null) {
    chapters.add((
      title: comic.title,
      paths: await LocalManager().getImages(comic.id, comic.comicType, 0),
    ));
  } else {
    for (final chapterId in comic.downloadedChapters) {
      chapters.add((
        title: comicChapters[chapterId]!,
        paths: await LocalManager().getImages(
          comic.id,
          comic.comicType,
          chapterId,
        ),
      ));
    }
  }
  // SAF files own native handles via finalizers. Transfer paths only and
  // acquire fresh handles in the worker isolate.
  final title = comic.title;
  final author = comic.subtitle;
  final coverPath = comic.coverFile.path;

  final cacheDir = App.cachePath;

  return Isolate.run(
    () => overrideIO(() async {
      final data = EpubData(
        title: title,
        author: author,
        cover: File(coverPath),
        chapters: [
          for (final chapter in chapters)
            (
              title: chapter.title,
              images: chapter.paths.map(File.new).toList(),
            ),
        ],
      );
      return createEpubComic(data, cacheDir, outFilePath);
    }),
  );
}
