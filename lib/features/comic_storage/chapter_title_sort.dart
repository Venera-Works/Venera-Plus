import 'comic_file_rules.dart';

/// 按章节编号稳定排序，编号相同的项目保留传入顺序。
List<T> sortedChapterEntries<T>(
  Iterable<T> entries, {
  required String Function(T entry) titleOf,
  bool descending = false,
}) {
  final keyed = [
    for (final (index, entry) in entries.indexed)
      (index: index, entry: entry, key: _ChapterTitleKey(titleOf(entry))),
  ];
  keyed.sort((left, right) {
    final order = left.key.compareTo(right.key);
    if (order == 0) return left.index.compareTo(right.index);
    return descending ? -order : order;
  });
  return [for (final item in keyed) item.entry];
}

const _digits = {
  '零': '0',
  '〇': '0',
  '一': '1',
  '二': '2',
  '两': '2',
  '兩': '2',
  '三': '3',
  '四': '4',
  '五': '5',
  '六': '6',
  '七': '7',
  '八': '8',
  '九': '9',
};
const _units = {'十': 10, '百': 100, '千': 1000, '万': 10000, '萬': 10000};
const _digitCharacters = '零〇一二两兩三四五六七八九';
const _integer = '[0-9]+|[$_digitCharacters十百千万萬]+';
const _number = '(?:$_integer)(?:[.点點](?:[0-9]+|[$_digitCharacters]+))?';
const _volumeUnits = {'卷', '巻', '册', '冊', '部'};

final _chapterMarker = RegExp(
  '(?:第|全)?\\s*($_number)(?:\\s*[-~〜至]\\s*$_number)?\\s*([卷巻册冊部话話章回集篇])'
  '|\\b(volume|vol\\.?|chapter|chap\\.?|ch\\.?|episode|ep\\.?)\\s*#?\\s*($_number)(?![a-z0-9])'
  '|(?:^|(?<=[\\s/]))[卷巻]\\s*($_number)',
);
final _leadingNumber = RegExp('^($_number)(?=\\s|[.、:_\\-—(]|\$)');
final _extraChapter = RegExp(
  r'^(?:番外|外传|外傳|特别篇|特別篇|特典|extra\b|special\b|omake\b)',
);
final _fullWidthAscii = RegExp(r'[！-～]');
final _decimalSeparator = RegExp(r'[.点點]');

String _normalize(String title) => title
    .replaceAllMapped(
      _fullWidthAscii,
      (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0),
    )
    .replaceAll('\u3000', ' ')
    .trim()
    .toLowerCase();

class _ChapterTitleKey implements Comparable<_ChapterTitleKey> {
  _ChapterTitleKey(String title) : text = _normalize(title) {
    if (_extraChapter.hasMatch(text)) return;
    final markers = _chapterMarker.allMatches(text).iterator;
    if (!markers.moveNext()) {
      final leading = _leadingNumber.firstMatch(text);
      if (leading != null) numbers.add(_ChapterNumber.parse(leading.group(1)!));
      return;
    }
    final first = markers.current;
    numbers.add(_markerNumber(first));
    if (_isVolume(first)) {
      while (markers.moveNext()) {
        final marker = markers.current;
        if (_isVolume(marker)) continue;
        numbers.add(_markerNumber(marker));
        break;
      }
    }
  }

  final String text;
  final numbers = <_ChapterNumber>[];

  static _ChapterNumber _markerNumber(Match marker) => _ChapterNumber.parse(
    (marker.group(1) ?? marker.group(4) ?? marker.group(5))!,
  );

  static bool _isVolume(Match marker) =>
      _volumeUnits.contains(marker.group(2)) ||
      marker.group(3)?.startsWith('vol') == true ||
      marker.group(5) != null;

  @override
  int compareTo(_ChapterTitleKey other) {
    if (numbers.isEmpty || other.numbers.isEmpty) {
      if (numbers.isEmpty != other.numbers.isEmpty) {
        return numbers.isEmpty ? 1 : -1;
      }
      return compareComicFileNames(text, other.text);
    }
    for (var i = 0; i < numbers.length && i < other.numbers.length; i++) {
      final order = numbers[i].compareTo(other.numbers[i]);
      if (order != 0) return order;
    }
    return numbers.length.compareTo(other.numbers.length);
  }
}

class _ChapterNumber implements Comparable<_ChapterNumber> {
  const _ChapterNumber(this.whole, this.fraction);

  final BigInt whole;
  final String fraction;

  factory _ChapterNumber.parse(String value) {
    final parts = value.split(_decimalSeparator);
    final whole = parts.first;
    final fraction = parts.length == 1 ? '' : _decimalDigits(parts.last);
    if (!whole.split('').any(_units.containsKey)) {
      return _ChapterNumber(BigInt.parse(_decimalDigits(whole)), fraction);
    }

    var total = 0;
    var section = 0;
    int? digit;
    for (final character in whole.split('')) {
      final unit = _units[character];
      if (unit == null) {
        digit = int.parse(_digits[character]!);
      } else if (unit == 10000) {
        total += (section + (digit ?? 0)) * unit;
        section = 0;
        digit = null;
      } else {
        section += (digit ?? 1) * unit;
        digit = null;
      }
    }
    return _ChapterNumber(
      BigInt.from(total + section + (digit ?? 0)),
      fraction,
    );
  }

  static String _decimalDigits(String value) => value
      .split('')
      .map((character) => _digits[character] ?? character)
      .join();

  @override
  int compareTo(_ChapterNumber other) {
    final order = whole.compareTo(other.whole);
    if (order != 0) return order;
    final length = fraction.length > other.fraction.length
        ? fraction.length
        : other.fraction.length;
    return fraction
        .padRight(length, '0')
        .compareTo(other.fraction.padRight(length, '0'));
  }
}
