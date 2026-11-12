enum KeywordMatchMode { contains, word, tag }

/// Options accompany the original word lists without rewriting legacy rules.
class KeywordRule {
  const KeywordRule(
    this.keyword, {
    this.mode = KeywordMatchMode.contains,
    this.caseSensitive = false,
  }) : isLegacy = false;

  const KeywordRule.legacy(this.keyword, {this.caseSensitive = true})
    : mode = KeywordMatchMode.contains,
      isLegacy = true;

  factory KeywordRule.suggested(String keyword, {bool tag = false}) =>
      KeywordRule(
        keyword,
        mode: tag
            ? KeywordMatchMode.tag
            : isShortAbbreviation(keyword)
            ? KeywordMatchMode.word
            : KeywordMatchMode.contains,
      );

  static final _shortAbbreviation = RegExp(r'^[a-zA-Z]{1,3}$');
  static bool isShortAbbreviation(String value) =>
      _shortAbbreviation.hasMatch(value.trim());

  factory KeywordRule.read(
    String keyword,
    Object? options, {
    bool comments = false,
  }) {
    if (options == null) {
      return KeywordRule.legacy(keyword, caseSensitive: !comments);
    }
    if (options is! Map || options['caseSensitive'] is! bool) {
      throw const FormatException('Invalid keyword rule');
    }
    final mode = switch (options['mode']) {
      'contains' => KeywordMatchMode.contains,
      'word' => KeywordMatchMode.word,
      'tag' when !comments => KeywordMatchMode.tag,
      _ => throw const FormatException('Invalid keyword rule mode'),
    };
    return KeywordRule(
      keyword,
      mode: mode,
      caseSensitive: options['caseSensitive'] as bool,
    );
  }

  final String keyword;
  final KeywordMatchMode mode;
  final bool caseSensitive;
  final bool isLegacy;

  Map<String, dynamic>? get storageOptions =>
      isLegacy ? null : {'mode': mode.name, 'caseSensitive': caseSensitive};

  @override
  bool operator ==(Object other) =>
      other is KeywordRule &&
      keyword == other.keyword &&
      mode == other.mode &&
      caseSensitive == other.caseSensitive &&
      isLegacy == other.isLegacy;
  @override
  int get hashCode => Object.hash(keyword, mode, caseSensitive, isLegacy);
}

/// Validate imported rule maps before mutating live settings.
Map<String, Map<String, dynamic>> validateKeywordRuleOptions(
  Object? value, {
  bool comments = false,
}) {
  if (value is! Map) {
    throw const FormatException('Keyword rules must be an object');
  }
  final result = <String, Map<String, dynamic>>{};
  for (final entry in value.entries) {
    final key = entry.key;
    final options = entry.value;
    if (key is! String ||
        options is! Map ||
        options['caseSensitive'] is! bool ||
        !['contains', 'word', if (!comments) 'tag'].contains(options['mode'])) {
      throw const FormatException('Invalid keyword rule');
    }
    result[key] = {
      'mode': options['mode'],
      'caseSensitive': options['caseSensitive'],
    };
  }
  return result;
}

enum KeywordMatchField { title, subtitle, description, tag, comment }

class KeywordMatch {
  const KeywordMatch({
    required this.rule,
    required this.field,
    required this.text,
    required this.start,
    required this.end,
  });
  final KeywordRule rule;
  final KeywordMatchField field;
  final String text;
  final int start;
  final int end;
}
