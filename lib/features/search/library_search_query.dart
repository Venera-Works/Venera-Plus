import 'package:venera_plus/features/comic_source/comic_source.dart'
    show comicAuthorNamespaces, isAuthorNamespace;

const _tagNamespaces = {
  'tag',
  'tags',
  'genre',
  'genres',
  'category',
  'categories',
  '标签',
  '標籤',
  '题材',
  '題材',
  '类别',
  '類別',
  '分类',
  '分類',
  '类型',
  '類型',
};

String? libraryTagLabel(String tag) {
  var value = tag.trim();
  final colon = value.indexOf(':');
  if (colon > 0) {
    final namespace = value.substring(0, colon).trim().toLowerCase();
    if (isAuthorNamespace(namespace)) return null;
    if (_tagNamespaces.contains(namespace)) {
      value = value.substring(colon + 1).trim();
    }
  }
  return value.isEmpty ? null : value;
}

/// SQL 参数是库表的列名。用户输入通过 [librarySearchFilter] 的绑定参数传入。
String libraryTagSql(String valueColumn) {
  final colon = 'instr($valueColumn, \':\')';
  final namespace = 'lower(trim(substr($valueColumn, 1, $colon - 1)))';
  final authors = comicAuthorNamespaces.map((name) => "'$name'").join(', ');
  final namespaces = _tagNamespaces.map((name) => "'$name'").join(', ');
  return '''NULLIF(CASE
    WHEN $colon = 0 THEN trim($valueColumn)
    WHEN $namespace IN ($authors) THEN NULL
    WHEN $namespace IN ($namespaces)
      THEN trim(substr($valueColumn, $colon + 1))
    ELSE trim($valueColumn)
  END, '')''';
}

({String sql, List<Object?> parameters}) librarySearchFilter({
  required String titleColumn,
  required String authorColumn,
  required String tagsColumn,
  String keyword = '',
  Iterable<String> tags = const [],
}) {
  final sql = StringBuffer();
  final parameters = <Object?>[];
  final text = keyword.trim();
  if (text.isNotEmpty) {
    // instr 将 % 和 _ 当作普通字符，也不会误匹配 JSON 的标点及转义。
    sql.write(''' AND (instr(lower($titleColumn), lower(?)) > 0
      OR instr(lower($authorColumn), lower(?)) > 0
      OR EXISTS (SELECT 1 FROM json_each($tagsColumn) AS item
        WHERE instr(lower(item.value), lower(?)) > 0))''');
    parameters.addAll([text, text, text]);
  }
  for (final tag in tags) {
    final value = tag.trim();
    if (value.isEmpty) continue;
    sql.write(''' AND EXISTS (SELECT 1 FROM json_each($tagsColumn) AS item
      WHERE ${libraryTagSql('item.value')} = ? COLLATE NOCASE)''');
    parameters.add(value);
  }
  return (sql: sql.toString(), parameters: parameters);
}
