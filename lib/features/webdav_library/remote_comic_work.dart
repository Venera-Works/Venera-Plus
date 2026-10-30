import 'dart:convert';

import 'package:venera_plus/features/comic_storage/comic_storage.dart';

import 'remote_archive_comic.dart';

const remoteComicWorkPrefix = 'remote-work:';
const remoteComicWorkImagePrefix = 'remote-work-image:';

/// A file remains an independent range-readable archive inside a work.
class RemoteComicVolume {
  RemoteComicVolume({
    required this.archive,
    required this.title,
    this.edition = '',
  });

  RemoteArchiveComic archive;
  final String title;
  final String edition;

  String get id => archive.path;

  Map<String, dynamic> toJson() => {
    'archive': archive.toJson(),
    'title': title,
    'edition': edition,
  };

  factory RemoteComicVolume.fromJson(Map<String, dynamic> json) =>
      RemoteComicVolume(
        archive: RemoteArchiveComic.fromJson(
          Map<String, dynamic>.from(json['archive'] as Map),
        ),
        title: json['title'] as String,
        edition: json['edition'] as String? ?? '',
      );
}

class RemoteComicWork {
  RemoteComicWork({
    required this.directory,
    required this.title,
    required this.volumes,
    this.family,
  });

  final String directory;
  final String title;

  /// Null for a work directory; a title for a family in a flat library folder.
  final String? family;
  final List<RemoteComicVolume> volumes;

  String get id =>
      '$remoteComicWorkPrefix${base64Url.encode(utf8.encode(jsonEncode([directory, family])))}';

  String get metadataFileName =>
      family == null ? 'metadata.json' : '$family.metadata.json';

  static ({String directory, String? family}) location(String id) {
    final values =
        jsonDecode(
              utf8.decode(
                base64Url.decode(id.substring(remoteComicWorkPrefix.length)),
              ),
            )
            as List;
    return (directory: values[0] as String, family: values[1] as String?);
  }

  RemoteComicVolume? volume(String id) {
    for (final volume in volumes) {
      if (volume.id == id) return volume;
    }
    return null;
  }

  Map<String, dynamic> get chapters {
    if (volumes.every((volume) => volume.edition.isEmpty)) {
      return {for (final volume in volumes) volume.id: volume.title};
    }
    final groups = <String, Map<String, String>>{};
    for (final volume in volumes) {
      (groups[volume.edition] ??= {})[volume.id] = volume.title;
    }
    return groups;
  }

  Map<String, int> get pageCounts => {
    for (final volume in volumes)
      if (volume.archive.pageCount case final int count) volume.id: count,
  };

  String imageKey(RemoteComicVolume volume, [String? entry]) =>
      '$remoteComicWorkImagePrefix${base64Url.encode(utf8.encode(jsonEncode([id, volume.id, volume.archive.isInspected ? volume.archive.imageKey(entry) : null])))}';

  static ({String work, String volume, String? image}) parseImageKey(
    String key,
  ) {
    final values =
        jsonDecode(
              utf8.decode(
                base64Url.decode(
                  key.substring(remoteComicWorkImagePrefix.length),
                ),
              ),
            )
            as List;
    return (
      work: values[0] as String,
      volume: values[1] as String,
      image: values[2] as String?,
    );
  }

  void retainIndexes(RemoteComicWork? previous) {
    if (previous == null) return;
    for (final volume in volumes) {
      final old = previous.volume(volume.id)?.archive;
      if (old != null &&
          old.matches(
            size: volume.archive.size,
            eTag: volume.archive.eTag,
            modifiedAt: volume.archive.modifiedAt,
          )) {
        volume.archive = old;
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'directory': directory,
    'title': title,
    'family': family,
    'volumes': volumes.map((volume) => volume.toJson()).toList(),
  };

  factory RemoteComicWork.fromJson(Map<String, dynamic> json) =>
      RemoteComicWork(
        directory: json['directory'] as String,
        title: json['title'] as String,
        family: json['family'] as String?,
        volumes: [
          for (final volume in json['volumes'] as List)
            RemoteComicVolume.fromJson(
              Map<String, dynamic>.from(volume as Map),
            ),
        ],
      );
}

/// Naming evidence used by discovery, without opening the archive.
class RemoteComicVolumeName {
  const RemoteComicVolumeName({
    required this.series,
    required this.title,
    required this.unit,
    required this.first,
    required this.last,
  });

  final String series;
  final String title;
  final String unit;
  final int? first;
  final int? last;

  bool get numbered => first != null;
  String get identity => first == null ? title : '$unit:$first:$last';

  static const _number = r'(?:\d+|[零〇一二三四五六七八九十百千两兩]+)';
  static final _unitNumber = RegExp(
    '(?:第\\s*)?($_number)\\s*(?:[-~～–—]\\s*($_number)\\s*)?([卷巻册冊话話章回])|'
    '([卷巻册冊话話章回]|vol(?:ume)?|ch(?:apter)?)\\.?\\s*($_number)(?:\\s*[-~～–—]\\s*($_number))?',
    caseSensitive: false,
  );
  static final _serial = RegExp(r'^(.*?)[\s_.-]+(\d+)(?:\s*[-~～–—]\s*(\d+))?$');
  static final _fullWidthDigits = RegExp(r'[０-９]');
  static final _seriesSuffix = RegExp(r'[\s_—–-]+$');

  static RemoteComicVolumeName parse(String fileName) {
    var stem = comicFileStem(fileName);
    if (comicFileExtension(fileName) == 'epub' &&
        stem.toLowerCase().endsWith('.kepub')) {
      stem = stem.substring(0, stem.length - 6);
    }
    stem = stem.replaceAllMapped(
      _fullWidthDigits,
      (match) => String.fromCharCode(match[0]!.codeUnitAt(0) - 0xfee0),
    );
    final match = _unitNumber.firstMatch(stem);
    if (match != null) {
      final rawUnit = (match[3] ?? match[4]!).toLowerCase();
      final unit =
          const {'卷', '巻', '册', '冊'}.contains(rawUnit) ||
              rawUnit.startsWith('vol')
          ? '卷'
          : const {'话', '話', '回'}.contains(rawUnit)
          ? '话'
          : '章';
      final first = _integer(match[1] ?? match[5]!);
      final last = _integer(match[2] ?? match[6] ?? match[1] ?? match[5]!);
      if (first != null && last != null && first <= last) {
        final number = first.toString().padLeft(2, '0');
        return RemoteComicVolumeName(
          series: _series(stem.substring(0, match.start)),
          title: first == last
              ? '第$number$unit'
              : '第$number–${last.toString().padLeft(2, '0')}$unit',
          unit: unit,
          first: first,
          last: last,
        );
      }
    }
    final serial = _serial.firstMatch(stem);
    return RemoteComicVolumeName(
      series: serial == null ? '' : _series(serial[1]!),
      title: stem,
      unit: '',
      first: serial == null ? null : int.tryParse(serial[2]!),
      last: serial == null ? null : int.tryParse(serial[3] ?? serial[2]!),
    );
  }

  static String _series(String value) {
    var result = value.trim().replaceFirst(_seriesSuffix, '');
    if (result.length > 1 &&
        (result.startsWith('[') && result.endsWith(']') ||
            result.startsWith('【') && result.endsWith('】'))) {
      result = result.substring(1, result.length - 1).trim();
    }
    return result;
  }

  static int? _integer(String value) {
    final number = int.tryParse(value);
    if (number != null) return number;
    const digits = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '兩': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const units = {'十': 10, '百': 100, '千': 1000};
    if (!value.runes.any(
      (rune) => units.containsKey(String.fromCharCode(rune)),
    )) {
      return int.tryParse(
        [
          for (final rune in value.runes) digits[String.fromCharCode(rune)],
        ].join(),
      );
    }
    var total = 0;
    var digit = 0;
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (digits.containsKey(char)) {
        digit = digits[char]!;
      } else if (units.containsKey(char)) {
        total += (digit == 0 ? 1 : digit) * units[char]!;
        digit = 0;
      } else {
        return null;
      }
    }
    return total + digit;
  }
}

final _editionDirectoryPattern = RegExp(
  r'(?:^|[^a-z])(?:epub|pdf|cbz|zip)(?:[^a-z]|$)|(?:台|臺|日|港|汉化|漢化|扫描|掃描|电子|電子|彩色|黑白|重制|重製|典藏|珍藏)版',
  caseSensitive: false,
);

bool isRemoteComicEditionDirectory(String name) =>
    _editionDirectoryPattern.hasMatch(name);

final _seriesKeyPattern = RegExp(r'[\s\[\]【】_—–-]+');

String remoteComicSeriesKey(String title) =>
    title.toLowerCase().replaceAll(_seriesKeyPattern, '');

void sortRemoteComicVolumes(List<RemoteComicVolume> volumes) {
  final names = {
    for (final volume in volumes)
      volume.id: RemoteComicVolumeName.parse(volume.archive.path),
  };
  volumes.sort((a, b) {
    final edition = compareComicFileNames(a.edition, b.edition);
    if (edition != 0) return edition;
    final left = names[a.id]!;
    final right = names[b.id]!;
    const units = {'卷': 0, '': 0, '话': 1, '章': 2};
    if (left.numbered && right.numbered) {
      final unit = units[left.unit]!.compareTo(units[right.unit]!);
      if (unit != 0) return unit;
      final number = left.first!.compareTo(right.first!);
      if (number != 0) return number;
    }
    return compareComicFileNames(a.archive.path, b.archive.path);
  });
}

/// Duplicate volumes are alternate editions, never extra consecutive volumes.
List<RemoteComicVolume> separateRemoteComicEditions(
  List<RemoteComicVolume> volumes,
) {
  final identities = <String>{};
  var duplicates = false;
  for (final volume in volumes) {
    if (!identities.add(
      '${volume.edition}:${RemoteComicVolumeName.parse(volume.id).identity}',
    )) {
      duplicates = true;
    }
  }
  if (!duplicates) {
    sortRemoteComicVolumes(volumes);
    return volumes;
  }
  final groups = <String, List<Set<String>>>{};
  final result = <RemoteComicVolume>[];
  for (final volume in volumes) {
    final format = comicFileExtension(volume.id).toUpperCase();
    final base = volume.edition.isEmpty ? format : volume.edition;
    final bins = groups.putIfAbsent(base, () => []);
    final identity = RemoteComicVolumeName.parse(volume.id).identity;
    var bin = bins.indexWhere((identities) => !identities.contains(identity));
    if (bin < 0) {
      bin = bins.length;
      bins.add({});
    }
    bins[bin].add(identity);
    result.add(
      RemoteComicVolume(
        archive: volume.archive,
        title: volume.title,
        edition: bin == 0 ? base : '$base (${bin + 1})',
      ),
    );
  }
  sortRemoteComicVolumes(result);
  return result;
}
