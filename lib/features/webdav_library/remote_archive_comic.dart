import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:venera_plus/features/comic_storage/comic_storage.dart';

const remoteArchiveImagePrefix = 'remote-zip:';

bool isRemoteComicArchive(String name) =>
    const {'zip', 'cbz', 'epub', 'pdf'}.contains(comicFileExtension(name));

/// A persisted remote comic page index, without image contents or native handles.
class RemoteArchiveComic {
  RemoteArchiveComic({
    required this.path,
    required this.size,
    this.eTag,
    this.modifiedAt,
    this.index,
    this.epubPages,
    this.pdfPageCount,
    String? pdfReadId,
    this.metadata,
    this.embeddedMetadata,
    this.chapters = const {},
    this.chapterImages = const {},
    this.coverEntry,
  }) : pdfReadId =
           pdfReadId ??
           (comicFileExtension(path) == 'pdf' &&
                   !(eTag?.isNotEmpty ?? false) &&
                   modifiedAt == null
               ? '${DateTime.now().microsecondsSinceEpoch}-${_nextPdfReadId++}'
               : null);

  static int _nextPdfReadId = 0;

  final String path;
  final int size;
  final String? eTag;
  final int? modifiedAt;
  final RemoteZipIndex? index;

  /// EPUB spine images in reading order, including repeated references.
  final List<String>? epubPages;

  final int? pdfPageCount;

  /// An unvalidated PDF has no ZIP directory fingerprint; refreshes must not
  /// reuse bytes from a previous same-size file. Clones keep this identity.
  final String? pdfReadId;

  bool get isPdf => comicFileExtension(path) == 'pdf';
  bool get _isEpub => comicFileExtension(path) == 'epub';

  /// Effective metadata after any sidecar fields have been merged by the source.
  final ComicMetaData? metadata;

  /// Metadata read from the ZIP before applying a sidecar override.
  final ComicMetaData? embeddedMetadata;
  final Map<String, String> chapters;
  final Map<String, List<String>> chapterImages;
  final String? coverEntry;

  bool get isInspected => isPdf
      ? (pdfPageCount ?? 0) > 0
      : index != null && (!_isEpub || epubPages != null);

  /// Display titles retain an explicit volume/chapter root without changing IDs.
  Map<String, String> get chapterTitles {
    final zip = index;
    if ((zip == null && !isPdf) || metadata?.chapters?.isNotEmpty == true) {
      return chapters;
    }
    final root = _isEpub || isPdf ? '' : _archiveLayout(zip!).root;
    final rootName = root.isEmpty
        ? ''
        : root.substring(0, root.length - 1).trim();
    final prefix = _wholeChapterTitle.hasMatch(rootName) ? rootName : null;
    final fullBook =
        prefix ??
        _chapterTitleToken.firstMatch(comicFileStem(path))?.group(0)?.trim() ??
        'Full book';
    return {
      for (final chapter in chapters.entries)
        chapter.key: chapter.key == '__root__'
            ? chapters.length == 1
                  ? fullBook
                  : chapter.value
            : prefix == null
            ? chapter.value
            : '$prefix/${chapter.value}',
    };
  }

  /// Image counts use the existing chapter IDs and exclude named covers.
  Map<String, int> get chapterPageCounts => {
    for (final chapter in chapterImages.entries)
      chapter.key: chapter.value.length,
  };

  /// All visible image pages, independent of metadata chapter ranges.
  int? get pageCount => isPdf
      ? pdfPageCount
      : _isEpub
      ? epubPages?.length
      : index?.entries
            .where(
              (entry) =>
                  _isVisibleEntry(entry) &&
                  isComicImageFileName(entry.name) &&
                  !isNamedComicCover(entry.name),
            )
            .length;

  String get title => metadata?.title.trim().isNotEmpty == true
      ? metadata!.title
      : comicFileStem(path);
  late final String version = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            path,
            size,
            eTag,
            modifiedAt,
            index?.toJson(),
            if (isPdf && pdfReadId != null) pdfReadId,
          ]),
        ),
      )
      .toString();

  bool matches({required int size, String? eTag, int? modifiedAt}) =>
      this.size == size &&
      this.eTag == eTag &&
      this.modifiedAt == modifiedAt &&
      ((eTag?.isNotEmpty ?? false) || modifiedAt != null);

  String imageKey([String? entry]) =>
      '$remoteArchiveImagePrefix${base64Url.encode(utf8.encode(jsonEncode([path, version, entry ?? coverEntry])))}';

  static ({String path, String version, String? entry})? parseImageKey(
    String key,
  ) {
    if (!key.startsWith(remoteArchiveImagePrefix)) return null;
    final value = jsonDecode(
      utf8.decode(
        base64Url.decode(key.substring(remoteArchiveImagePrefix.length)),
      ),
    );
    if (value is! List ||
        value.length != 3 ||
        value[0] is! String ||
        value[1] is! String ||
        (value[2] != null && value[2] is! String)) {
      throw const FormatException('Invalid remote archive image');
    }
    return (
      path: value[0] as String,
      version: value[1] as String,
      entry: value[2] as String?,
    );
  }

  /// Applies already-merged sidecar metadata without reading archive bytes.
  /// Passing null restores the embedded metadata and its original layout.
  RemoteArchiveComic withMetadata(ComicMetaData? metadata) {
    final effective = metadata ?? embeddedMetadata;
    if (isPdf && pdfPageCount != null) {
      return _withPdfLayout(pdfPageCount!, effective, embeddedMetadata);
    }
    final zip = index;
    if (zip == null || (_isEpub && epubPages == null)) {
      effective?.validateChapterRanges();
      return RemoteArchiveComic(
        path: path,
        size: size,
        eTag: eTag,
        modifiedAt: modifiedAt,
        index: zip,
        epubPages: epubPages,
        pdfPageCount: pdfPageCount,
        pdfReadId: pdfReadId,
        metadata: effective,
        embeddedMetadata: embeddedMetadata,
        chapters: chapters,
        chapterImages: chapterImages,
        coverEntry: coverEntry,
      );
    }
    if (_isEpub) {
      return _withEpubLayout(
        zip,
        epubPages!,
        effective,
        embeddedMetadata,
        cover: coverEntry!,
      );
    }
    return _withLayout(zip, _archiveLayout(zip), effective, embeddedMetadata);
  }

  Future<RemoteArchiveComic> inspect(
    ZipRangeRead read, {
    CancelToken? cancelToken,
  }) async {
    if (isInspected) return withMetadata(metadata);
    if (isPdf) {
      final pdf = await RemotePdfReader.inspect(
        size: size,
        read: read,
        sourceName: 'remote-pdf:$version',
        fallbackTitle: comicFileStem(path),
        cancelToken: cancelToken,
      );
      return _withPdfLayout(
        pdf.pageCount,
        metadata ?? pdf.metadata,
        pdf.metadata,
      );
    }
    final zip = index ?? await RemoteZipIndex.read(fileSize: size, read: read);
    if (_isEpub) {
      final epub = await RemoteEpubIndex.read(
        zip: zip,
        read: read,
        fallbackTitle: comicFileStem(path),
      );
      return _withEpubLayout(
        zip,
        epub.pages,
        metadata ?? epub.metadata,
        epub.metadata,
        cover: epub.coverEntry,
      );
    }
    final layout = _archiveLayout(zip);
    ComicMetaData? embedded;
    final metadataEntries = layout.visible.where(
      (entry) =>
          entry.name.substring(layout.root.length).toLowerCase() ==
          'metadata.json',
    );
    if (metadataEntries.isNotEmpty) {
      try {
        embedded = ComicMetaData.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(
                  utf8.decode(await zip.readEntry(metadataEntries.first, read)),
                )
                as Map,
          ),
        );
        embedded.validateChapterRanges(pageCount: layout.pages.length);
      } on FormatException {
        embedded = null;
      } on TypeError {
        embedded = null;
      }
    }
    return _withLayout(zip, layout, metadata ?? embedded, embedded);
  }

  RemoteArchiveComic _withLayout(
    RemoteZipIndex zip,
    _ArchiveLayout layout,
    ComicMetaData? effective,
    ComicMetaData? embedded,
  ) {
    final images = layout.images;
    final pages = layout.pages;
    String relative(RemoteZipEntry entry) =>
        entry.name.substring(layout.root.length);
    effective?.validateChapterRanges(pageCount: pages.length);
    final names = <String, String>{};
    final groups = <String, List<String>>{};
    if (effective?.chapters?.isNotEmpty == true) {
      for (var i = 0; i < effective!.chapters!.length; i++) {
        final chapter = effective.chapters![i];
        final id = '__cbz_range_$i';
        names[id] = chapter.title;
        groups[id] = pages
            .sublist(chapter.start - 1, chapter.end)
            .map((entry) => entry.name)
            .toList();
      }
    } else {
      for (final entry in pages) {
        final name = relative(entry);
        final slash = name.lastIndexOf('/');
        final directory = slash < 0 ? '' : name.substring(0, slash);
        final id = directory.isEmpty ? '__root__' : 'dir:$directory';
        names[id] = directory.isEmpty ? 'Images' : directory;
        (groups[id] ??= []).add(entry.name);
      }
    }
    final rootCovers = images.where(
      (entry) =>
          !relative(entry).contains('/') && isNamedComicCover(entry.name),
    );
    final rootPages = pages.where((entry) => !relative(entry).contains('/'));
    final covers = images.where((entry) => isNamedComicCover(entry.name));
    final cover =
        rootCovers.firstOrNull ??
        rootPages.firstOrNull ??
        covers.firstOrNull ??
        pages.first;
    return RemoteArchiveComic(
      path: path,
      size: size,
      eTag: eTag,
      modifiedAt: modifiedAt,
      index: zip,
      metadata: effective,
      embeddedMetadata: embedded,
      chapters: names,
      chapterImages: groups,
      coverEntry: cover.name,
    );
  }

  RemoteArchiveComic _withEpubLayout(
    RemoteZipIndex zip,
    List<String> pages,
    ComicMetaData? effective,
    ComicMetaData? embedded, {
    required String cover,
  }) {
    effective?.validateChapterRanges(pageCount: pages.length);
    final names = <String, String>{};
    final groups = <String, List<String>>{};
    if (effective?.chapters?.isNotEmpty == true) {
      for (var i = 0; i < effective!.chapters!.length; i++) {
        final chapter = effective.chapters![i];
        final id = '__epub_range_$i';
        names[id] = chapter.title;
        groups[id] = pages.sublist(chapter.start - 1, chapter.end);
      }
    } else {
      names['__root__'] = 'Images';
      groups['__root__'] = List<String>.from(pages);
    }
    return RemoteArchiveComic(
      path: path,
      size: size,
      eTag: eTag,
      modifiedAt: modifiedAt,
      index: zip,
      epubPages: List<String>.unmodifiable(pages),
      metadata: effective,
      embeddedMetadata: embedded,
      chapters: names,
      chapterImages: groups,
      coverEntry: cover,
    );
  }

  RemoteArchiveComic _withPdfLayout(
    int count,
    ComicMetaData? effective,
    ComicMetaData? embedded,
  ) {
    if (count <= 0) throw const FormatException('PDF contains no pages');
    effective?.validateChapterRanges(pageCount: count);
    final names = <String, String>{};
    final groups = <String, List<String>>{};
    List<String> pages(int start, int end) => [
      for (var page = start; page <= end; page++) 'pdf:$page',
    ];
    if (effective?.chapters?.isNotEmpty == true) {
      for (var i = 0; i < effective!.chapters!.length; i++) {
        final chapter = effective.chapters![i];
        final id = '__pdf_range_$i';
        names[id] = chapter.title;
        groups[id] = pages(chapter.start, chapter.end);
      }
    } else {
      names['__root__'] = 'Images';
      groups['__root__'] = pages(1, count);
    }
    return RemoteArchiveComic(
      path: path,
      size: size,
      eTag: eTag,
      modifiedAt: modifiedAt,
      pdfPageCount: count,
      pdfReadId: pdfReadId,
      metadata: effective,
      embeddedMetadata: embedded,
      chapters: names,
      chapterImages: groups,
      coverEntry: 'pdf:1',
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'size': size,
    'eTag': eTag,
    'modifiedAt': modifiedAt,
    if (index != null) 'index': index!.toJson(),
    if (epubPages != null) 'epubPages': epubPages,
    if (pdfPageCount != null) 'pdfPageCount': pdfPageCount,
    if (pdfReadId != null) 'pdfReadId': pdfReadId,
    if (metadata != null) 'metadata': metadata!.toJson(),
    'embeddedMetadata': embeddedMetadata?.toJson(),
    'chapters': chapters,
    'chapterImages': chapterImages,
    'coverEntry': coverEntry,
  };

  factory RemoteArchiveComic.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'] is Map
        ? ComicMetaData.fromJson(
            Map<String, dynamic>.from(json['metadata'] as Map),
          )
        : null;
    final embedded = json.containsKey('embeddedMetadata')
        ? json['embeddedMetadata']
        : json['metadata'];
    return RemoteArchiveComic(
      path: json['path'] as String,
      size: json['size'] as int,
      eTag: json['eTag'] as String?,
      modifiedAt: json['modifiedAt'] as int?,
      index: json['index'] is Map
          ? RemoteZipIndex.fromJson(
              Map<String, dynamic>.from(json['index'] as Map),
            )
          : null,
      epubPages: json['epubPages'] is List
          ? List<String>.from(json['epubPages'] as List)
          : null,
      pdfPageCount: json['pdfPageCount'] as int?,
      pdfReadId: json['pdfReadId'] as String?,
      metadata: metadata,
      embeddedMetadata: embedded is Map
          ? ComicMetaData.fromJson(Map<String, dynamic>.from(embedded))
          : null,
      chapters: Map<String, String>.from(json['chapters'] as Map? ?? const {}),
      chapterImages: {
        for (final entry in (json['chapterImages'] as Map? ?? const {}).entries)
          entry.key as String: List<String>.from(entry.value as List),
      },
      coverEntry: json['coverEntry'] as String?,
    );
  }
}

const _chapterNumber = r'[0-9０-９零〇一二三四五六七八九十百千两]+(?:[.．][0-9０-９]+)?';
const _chapterTitlePattern =
    '(?:(?:第|全)?\\s*$_chapterNumber\\s*[卷巻话話回章册冊]|'
    '(?<![a-z0-9])(?:vol(?:ume)?|chapter|ch)\\.?\\s*$_chapterNumber(?![a-z0-9])|'
    '番外(?:篇)?|特典|特别篇|特別篇|序章|终章|終章)';
final _chapterTitleToken = RegExp(_chapterTitlePattern, caseSensitive: false);
final _wholeChapterTitle = RegExp(
  '^(?:$_chapterTitlePattern)\$',
  caseSensitive: false,
);

typedef _ArchiveLayout = ({
  List<RemoteZipEntry> visible,
  List<RemoteZipEntry> images,
  List<RemoteZipEntry> pages,
  String root,
});

bool _isVisibleEntry(RemoteZipEntry entry) =>
    !entry.isDirectory &&
    !entry.name.split('/').any(isIgnoredComicStorageEntry);

_ArchiveLayout _archiveLayout(RemoteZipIndex zip) {
  final visible = zip.entries.where(_isVisibleEntry).toList();
  final paths = visible.map((entry) => entry.name).toList();
  final firstSlash = paths.isEmpty ? -1 : paths.first.indexOf('/');
  final prefix = firstSlash < 0 ? '' : paths.first.substring(0, firstSlash + 1);
  final root =
      prefix.isNotEmpty && paths.every((name) => name.startsWith(prefix))
      ? prefix
      : '';
  final images =
      visible.where((entry) => isComicImageFileName(entry.name)).toList()..sort(
        (a, b) => _comparePaths(
          a.name.substring(root.length),
          b.name.substring(root.length),
        ),
      );
  final pages = images
      .where((entry) => !isNamedComicCover(entry.name))
      .toList();
  if (pages.isEmpty) {
    throw const FormatException('No images found in the ZIP/CBZ comic');
  }
  return (visible: visible, images: images, pages: pages, root: root);
}

int _comparePaths(String left, String right) {
  final a = left.split('/');
  final b = right.split('/');
  for (var i = 0; i < a.length && i < b.length; i++) {
    final order = compareComicFileNames(a[i], b[i]);
    if (order != 0) return order;
  }
  return a.length.compareTo(b.length);
}
