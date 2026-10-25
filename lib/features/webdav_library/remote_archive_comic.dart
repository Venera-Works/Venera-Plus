import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';

const remoteArchiveImagePrefix = 'remote-zip:';

bool isRemoteComicArchive(String name) =>
    const {'zip', 'cbz'}.contains(comicFileExtension(name));

/// A persisted ZIP directory and its comic page order, without image contents.
class RemoteArchiveComic {
  RemoteArchiveComic({
    required this.path,
    required this.size,
    this.eTag,
    this.modifiedAt,
    this.index,
    this.metadata,
    this.embeddedMetadata,
    this.chapters = const {},
    this.chapterImages = const {},
    this.coverEntry,
  });

  final String path;
  final int size;
  final String? eTag;
  final int? modifiedAt;
  final RemoteZipIndex? index;

  /// Effective metadata after any sidecar fields have been merged by the source.
  final ComicMetaData? metadata;

  /// Metadata read from the ZIP before applying a sidecar override.
  final ComicMetaData? embeddedMetadata;
  final Map<String, String> chapters;
  final Map<String, List<String>> chapterImages;
  final String? coverEntry;

  bool get isInspected => index != null;

  /// Display titles retain an explicit volume/chapter root without changing IDs.
  Map<String, String> get chapterTitles {
    final zip = index;
    if (zip == null || metadata?.chapters?.isNotEmpty == true) return chapters;
    final root = _archiveLayout(zip).root;
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
  int? get pageCount => index?.entries
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
          jsonEncode([path, size, eTag, modifiedAt, index?.toJson()]),
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
    final zip = index;
    if (zip == null) {
      effective?.validateChapterRanges();
      return RemoteArchiveComic(
        path: path,
        size: size,
        eTag: eTag,
        modifiedAt: modifiedAt,
        metadata: effective,
        embeddedMetadata: embeddedMetadata,
        chapters: chapters,
        chapterImages: chapterImages,
        coverEntry: coverEntry,
      );
    }
    return _withLayout(zip, _archiveLayout(zip), effective, embeddedMetadata);
  }

  Future<RemoteArchiveComic> inspect(ZipRangeRead read) async {
    if (index != null) return withMetadata(metadata);
    final zip = await RemoteZipIndex.read(fileSize: size, read: read);
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

  Map<String, dynamic> toJson() => {
    'path': path,
    'size': size,
    'eTag': eTag,
    'modifiedAt': modifiedAt,
    if (index != null) 'index': index!.toJson(),
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
