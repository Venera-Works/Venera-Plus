import 'dart:convert';

/// A search query and the last result page actually viewed.
class SearchHistoryEntry {
  SearchHistoryEntry({
    required this.keyword,
    required this.sourceKey,
    this.sourceName,
    List<String> options = const [],
    this.page = 1,
  }) : options = List.unmodifiable(options) {
    if (keyword.trim().isEmpty || sourceKey.isEmpty || page < 1) {
      throw const FormatException('Invalid search history entry');
    }
  }

  static const aggregatedSourceKey = '_aggregated_';

  final String keyword;
  final String sourceKey;
  final String? sourceName;
  final List<String> options;
  final int page;

  String get identity => jsonEncode([keyword, sourceKey, options]);

  SearchHistoryEntry copyWith({int? page}) => SearchHistoryEntry(
    keyword: keyword,
    sourceKey: sourceKey,
    sourceName: sourceName,
    options: options,
    page: page ?? this.page,
  );

  Map<String, dynamic> toJson() => {
    'keyword': keyword,
    'sourceKey': sourceKey,
    if (sourceName != null) 'sourceName': sourceName,
    'options': options,
    'page': page,
  };

  factory SearchHistoryEntry.fromJson(Map<String, dynamic> json) {
    final keyword = json['keyword'];
    final sourceKey = json['sourceKey'];
    final sourceName = json['sourceName'];
    final options = json['options'];
    final page = json['page'];
    if (keyword is! String ||
        sourceKey is! String ||
        (sourceName != null && sourceName is! String) ||
        options is! List ||
        options.any((value) => value is! String) ||
        page is! int ||
        page < 1) {
      throw const FormatException('Invalid search history entry');
    }
    return SearchHistoryEntry(
      keyword: keyword,
      sourceKey: sourceKey,
      sourceName: sourceName as String?,
      options: List<String>.from(options),
      page: page,
    );
  }
}
