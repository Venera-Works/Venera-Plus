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
    this.chapters = const {},
    this.chapterImages = const {},
    this.coverEntry,
  });

  final String path;
  final int size;
  final String? eTag;
  final int? modifiedAt;
  final RemoteZipIndex? index;
  final ComicMetaData? metadata;
  final Map<String, String> chapters;
  final Map<String, List<String>> chapterImages;
  final String? coverEntry;

  bool get isInspected => index != null;
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

  Future<RemoteArchiveComic> inspect(ZipRangeRead read) async {
    final zip = await RemoteZipIndex.read(fileSize: size, read: read);
    final visible = zip.entries
        .where(
          (entry) =>
              !entry.isDirectory &&
              !entry.name.split('/').any(isIgnoredComicStorageEntry),
        )
        .toList();
    final paths = visible.map((entry) => entry.name).toList();
    final firstSlash = paths.isEmpty ? -1 : paths.first.indexOf('/');
    final prefix = firstSlash < 0
        ? ''
        : paths.first.substring(0, firstSlash + 1);
    final root =
        prefix.isNotEmpty && paths.every((name) => name.startsWith(prefix))
        ? prefix
        : '';
    String relative(RemoteZipEntry entry) => entry.name.substring(root.length);
    final images =
        visible.where((entry) => isComicImageFileName(entry.name)).toList()
          ..sort((a, b) => _comparePaths(relative(a), relative(b)));
    final pages = images
        .where((entry) => !isNamedComicCover(entry.name))
        .toList();
    if (pages.isEmpty) {
      throw const FormatException('No images found in the ZIP/CBZ comic');
    }
    ComicMetaData? meta;
    final metadataEntries = visible.where(
      (entry) => relative(entry).toLowerCase() == 'metadata.json',
    );
    if (metadataEntries.isNotEmpty) {
      try {
        meta = ComicMetaData.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(
                  utf8.decode(await zip.readEntry(metadataEntries.first, read)),
                )
                as Map,
          ),
        );
        meta.validateChapterRanges(pageCount: pages.length);
      } on FormatException {
        meta = null;
      } on TypeError {
        meta = null;
      }
    }
    final names = <String, String>{};
    final groups = <String, List<String>>{};
    if (meta?.chapters?.isNotEmpty == true) {
      for (var i = 0; i < meta!.chapters!.length; i++) {
        final chapter = meta.chapters![i];
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
      metadata: meta,
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
    'chapters': chapters,
    'chapterImages': chapterImages,
    'coverEntry': coverEntry,
  };

  factory RemoteArchiveComic.fromJson(
    Map<String, dynamic> json,
  ) => RemoteArchiveComic(
    path: json['path'] as String,
    size: json['size'] as int,
    eTag: json['eTag'] as String?,
    modifiedAt: json['modifiedAt'] as int?,
    index: json['index'] is Map
        ? RemoteZipIndex.fromJson(
            Map<String, dynamic>.from(json['index'] as Map),
          )
        : null,
    metadata: json['metadata'] is Map
        ? ComicMetaData.fromJson(
            Map<String, dynamic>.from(json['metadata'] as Map),
          )
        : null,
    chapters: Map<String, String>.from(json['chapters'] as Map? ?? const {}),
    chapterImages: {
      for (final entry in (json['chapterImages'] as Map? ?? const {}).entries)
        entry.key as String: List<String>.from(entry.value as List),
    },
    coverEntry: json['coverEntry'] as String?,
  );
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
