import 'package:venera_plus/features/bangumi/bangumi_models.dart';
import 'package:venera_plus/features/comic_storage/comic_storage.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart'
    show RemoteComicVolumeName;
import 'package:venera_plus/foundation/opencc.dart';

class BangumiMetadataName {
  BangumiMetadataName(
    this.title, {
    this.authors = const [],
    this.needsCorroboration = false,
  }) : key = BangumiMetadataHints.normalize(title),
       chineseKey = BangumiMetadataHints.chineseKey(title),
       issue = BangumiMetadataHints.issueOf(title);

  final String title;
  final List<String> authors;
  final bool needsCorroboration;
  final String key;
  final String chineseKey;
  final String? issue;
}

class BangumiMetadataHints {
  BangumiMetadataHints._({
    required this.names,
    required this.members,
    required this.authors,
    required this.keywords,
    required this.isMagazine,
  });

  final List<BangumiMetadataName> names;
  final List<List<BangumiMetadataName>> members;
  final List<String> authors;
  final List<String> keywords;
  final bool isMagazine;

  static final _labeledNoise = RegExp(
    r'\s*(?:语言|語言|language|版本|version|汉化者|漢化者|汉化组|漢化組)'
    r'\s*[:：]?\s*(?:\[([^\[\]]+)\]|【([^【】]+)】)\s*$',
    caseSensitive: false,
  );
  static final _labeledAuthor = RegExp(
    r'\s*(?:作者|著者|原作|作画|作畫|漫画|漫畫|脚本|剧本|劇本|繪者|绘者|author|writer|artist)'
    r'\s*(?:(?:[:：]\s*)?(?:\[([^\[\]]+)\]|【([^【】]+)】)|'
    r'[:：]\s*([^【】\[\]]+))\s*$',
    caseSensitive: false,
  );
  static final _leadingBracket = RegExp(
    r'^(?:\[([^\[\]]+)\]|【([^【】]+)】|\(([^()]+)\))\s*',
  );
  static final _trailingBracket = RegExp(
    r'\s*(?:\[([^\[\]]+)\]|【([^【】]+)】|\(([^()]+)\))\s*$',
  );
  static final _noise = RegExp(
    r'^(?:chinese|中文|中国翻訳|中國翻譯|中国翻译|漢化|汉化|翻訳|翻譯|翻译|'
    r'无修正|無修正|dl版|digital|完结|已完结|完結|已完結|'
    r'全\d+(?:卷|巻|册|冊)|kindle(?:版)?|高清(?:版)?|日文(?:版)?|日本語|'
    r'台版|臺版|台湾版|台灣版|典藏版|珍藏版|重制版|重製版|'
    r'成年コミック|成人漫画|成人漫畫|雑誌|雜誌|杂志|漫画|漫畫|'
    r'(?:19|20)\d{2}(?:年)?(?:重制|重製|重制版|重製版|新版|修订版|修訂版)?)$',
    caseSensitive: false,
  );
  static final _magazine = RegExp(r'雑誌|雜誌|杂志');
  static final _issue = RegExp(
    r'((?:19|20)\d{2})\s*年\s*(0?[1-9]|1[0-2])\s*月\s*[号號]',
  );
  static final _catalogPrefix = RegExp(
    r'^(?:[a-z]|\d+)[\s_-]+(.+)$',
    caseSensitive: false,
  );
  static final _creatorPrefix = RegExp(
    r'^(?:\[([^\[\]]+)\]|【([^【】]+)】)\s*(.+)$',
  );
  static final _pageSuffix = RegExp(
    r'(?:[_ -]+p(?:age)?\d+)?[_ -]+img\d+$|[_ -]+p(?:age)?\d+$',
    caseSensitive: false,
  );
  static final _generic = RegExp(
    r'^(?:(?:\d+[_ -]*)?(?:img|image|page|p|vol)[_. -]*\d*|\d+|'
    r'(?:全|第)?\d+[卷巻册冊话話章回]|images?|cover|'
    r'(?:【(?:漫画|漫畫)】)?(?:epub|pdf|cbz|zip)(?:格式|版)?|'
    r'(?:pixiv)?fanbox)$',
    caseSensitive: false,
  );
  static final _kana = RegExp(r'[\u3040-\u30ff]');
  static final _punctuation = RegExp(
    r'''[\s\u3000·・:：!！?？,，.。\-—_~～/／\\|｜「」『』【】\[\]()（）'"“”‘’]+''',
  );

  factory BangumiMetadataHints.parse(
    String title, {
    String? directoryTitle,
    Iterable<String> fileNames = const [],
    Iterable<String> authors = const [],
  }) {
    final names = <BangumiMetadataName>[];
    final members = <List<BangumiMetadataName>>[];
    final memberKeys = <String>{};
    final explicitAuthors = <String>{
      for (final author in authors) ..._authorNames(author),
    };
    final primary = _parseName(title, explicitAuthors: explicitAuthors);
    names.addAll(primary);
    if (directoryTitle != null && directoryTitle != title) {
      names.addAll(
        _parseName(
          directoryTitle,
          explicitAuthors: explicitAuthors,
          needsCorroboration: true,
        ),
      );
    }
    for (final fileName in fileNames) {
      if (isNamedComicCover(fileName)) continue;
      final parsed = _parseName(fileName, isFile: true);
      if (parsed.isEmpty) continue;
      final key = parsed
          .map((name) => '${name.chineseKey}:${name.authors.join(',')}')
          .join('|');
      if (!memberKeys.add(key)) continue;
      if (parsed.any((name) => !name.needsCorroboration)) members.add(parsed);
      names.addAll(parsed);
    }
    final keywords = <String>[];
    final keywordKeys = <String>{};
    void addKeyword(String value) {
      if (keywords.length == 3) return;
      final key = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
      if (key.isNotEmpty && keywordKeys.add(key)) keywords.add(value);
    }

    void addVariant(String value) {
      if (_kana.hasMatch(value)) return;
      final simplified = OpenCC.traditionalToSimplified(value);
      addKeyword(
        simplified == value
            ? OpenCC.simplifiedToTraditional(value)
            : simplified,
      );
    }

    if (primary.isNotEmpty) {
      addKeyword(primary.first.title);
      addVariant(primary.first.title);
    }
    for (final member in members) {
      addKeyword(member.first.title);
    }
    for (final name in names) {
      addKeyword(name.title);
      addVariant(name.title);
    }
    return BangumiMetadataHints._(
      names: names,
      members: members,
      authors: explicitAuthors.toList(growable: false),
      keywords: keywords,
      isMagazine:
          _magazine.hasMatch(title) || names.any((name) => name.issue != null),
    );
  }

  bool matches(BangumiMetadataName name, BangumiSubject subject) {
    if (subject.platform != null &&
        subject.platform != '漫画' &&
        !(isMagazine && const {'杂志', '雜誌', '雑誌'}.contains(subject.platform))) {
      return false;
    }
    if (isMagazine && name.issue == null) return false;
    bool equal(String value, {bool chinese = false}) {
      if (value.isEmpty) return false;
      if (name.issue != null && issueOf(value) != name.issue) return false;
      return normalize(value) == name.key ||
          (chinese &&
              !_kana.hasMatch(value) &&
              chineseKey(value) == name.chineseKey);
    }

    return equal(subject.title, chinese: subject.nameCn.isNotEmpty) ||
        equal(subject.originalTitle) ||
        equal(subject.nameCn, chinese: true) ||
        subject.aliases.any((alias) => equal(alias, chinese: true));
  }

  static List<BangumiMetadataName> _parseName(
    String value, {
    bool isFile = false,
    bool needsCorroboration = false,
    Set<String>? explicitAuthors,
  }) {
    var remaining = width(value).trim();
    if (isFile) {
      final image = isComicImageFileName(remaining);
      if (!image &&
          !const {
            'zip',
            'cbz',
            'epub',
            'pdf',
          }.contains(comicFileExtension(remaining))) {
        return const [];
      }
      remaining = comicFileStem(remaining);
      if (remaining.toLowerCase().endsWith('.kepub')) {
        remaining = remaining.substring(0, remaining.length - 6);
      }
      final withoutPage = remaining.replaceFirst(_pageSuffix, '');
      final hasPageSuffix = withoutPage != remaining;
      remaining = withoutPage;
      final volume = RemoteComicVolumeName.parse('$remaining.cbz');
      if (image &&
          !hasPageSuffix &&
          !volume.numbered &&
          !_leadingBracket.hasMatch(remaining)) {
        return const [];
      }
      if (volume.numbered &&
          volume.unit.isEmpty &&
          !_leadingBracket.hasMatch(remaining)) {
        needsCorroboration = true;
      }
      if (volume.series.isNotEmpty) remaining = volume.series;
    }
    final labeledAuthors = <String>{};
    while (true) {
      final before = remaining;
      final noise = _labeledNoise.firstMatch(remaining);
      if (noise != null) {
        remaining = remaining.substring(0, noise.start).trimRight();
      }
      final author = _labeledAuthor.firstMatch(remaining);
      if (author != null) {
        labeledAuthors.addAll(
          _authorNames(author[1] ?? author[2] ?? author[3]!),
        );
        remaining = remaining.substring(0, author.start).trimRight();
      }
      for (final pattern in [_leadingBracket, _trailingBracket]) {
        final bracket = pattern.firstMatch(remaining);
        if (bracket == null) continue;
        final marker = bracket[1] ?? bracket[2] ?? bracket[3]!;
        if (!_noise.hasMatch(marker.replaceAll(RegExp(r'\s+'), ''))) continue;
        remaining = remaining
            .replaceRange(bracket.start, bracket.end, '')
            .trim();
      }
      if (before == remaining) break;
    }
    remaining = remaining
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'[\s\-—_·|｜,，;；]+$'), '')
        .trim();
    if (remaining.isEmpty || _generic.hasMatch(remaining)) return const [];
    explicitAuthors?.addAll(labeledAuthors);
    final result = <BangumiMetadataName>[];
    void add(
      String title, {
      List<String> creator = const [],
      bool corroboration = false,
    }) {
      title = title.trim();
      final bracket = _leadingBracket.firstMatch(title);
      if (bracket != null && bracket.end == title.length) {
        title = bracket[1] ?? bracket[2] ?? bracket[3]!;
      }
      if (title.isEmpty || _generic.hasMatch(title)) return;
      result.add(
        BangumiMetadataName(
          title,
          authors: [...labeledAuthors, ...creator],
          needsCorroboration: corroboration || needsCorroboration,
        ),
      );
    }

    var candidate = remaining;
    final catalog = _catalogPrefix.firstMatch(candidate);
    if (catalog != null) candidate = catalog[1]!;
    final creator = _creatorPrefix.firstMatch(candidate);
    if (creator != null) {
      final creatorName = creator[1] ?? creator[2]!;
      add(creator[3]!, creator: _authorNames(creatorName));
      if (_generic.hasMatch(creator[3]!.trim())) return const [];
    }
    if (catalog != null) add(candidate, corroboration: true);
    add(remaining);
    return result;
  }

  static List<String> _authorNames(String value) => value
      .split(RegExp(r'\s*[,，、;；]\s*'))
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList(growable: false);

  static String width(String value) => String.fromCharCodes(
    value.runes.map((rune) {
      if (rune == 0x3000) return 0x20;
      return rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune;
    }),
  );

  static String? issueOf(String value) {
    final issue = _issue.firstMatch(width(value));
    return issue == null ? null : '${issue[1]}:${int.parse(issue[2]!)}';
  }

  static String normalize(String value) => width(value)
      .replaceAllMapped(
        _issue,
        (match) => '${match[1]}年${int.parse(match[2]!)}月号',
      )
      .toLowerCase()
      .replaceAll(_punctuation, '');

  static String chineseKey(String value) => normalize(
    _kana.hasMatch(value) ? value : OpenCC.traditionalToSimplified(value),
  );
}
