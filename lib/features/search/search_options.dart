import 'dart:convert';

import 'package:venera_plus/features/comic_source/comic_source.dart';

List<String> defaultSearchOptions(List<SearchOptions> definitions) => [
  for (final option in definitions)
    option.type == 'multi-select'
        ? _multiSelectDefault(option)
        : option.defaultValue,
];

String _multiSelectDefault(SearchOptions option) {
  final value = option.defaultValue;
  try {
    final decoded = jsonDecode(value);
    if (decoded is List &&
        decoded.every(
          (key) => key is String && option.options.containsKey(key),
        )) {
      return value;
    }
  } on FormatException {
    // Sources may express a single default key instead of a JSON array.
  }
  return jsonEncode(option.options.containsKey(value) ? [value] : <String>[]);
}

/// Returns null when any saved value no longer belongs to its source option.
List<String>? validatedSearchOptions(
  List<SearchOptions> definitions,
  List<String> values,
) {
  if (definitions.length != values.length) return null;
  for (var i = 0; i < definitions.length; i++) {
    final definition = definitions[i];
    final value = values[i];
    if (definition.type == 'multi-select') {
      try {
        final decoded = jsonDecode(value);
        if (decoded is! List ||
            decoded.any(
              (key) => key is! String || !definition.options.containsKey(key),
            )) {
          return null;
        }
      } on FormatException {
        return null;
      }
    } else if (!definition.options.containsKey(value)) {
      return null;
    }
  }
  return List<String>.of(values);
}

List<String> searchOptionLabels(
  List<SearchOptions> definitions,
  List<String> values,
  String sourceKey,
) {
  final valid = validatedSearchOptions(definitions, values);
  if (valid == null) return values;
  return [
    for (var i = 0; i < definitions.length; i++)
      '${definitions[i].label.ts(sourceKey)}: ${definitions[i].type == 'multi-select' ? (jsonDecode(values[i]) as List).map((key) => definitions[i].options[key]!.ts(sourceKey)).join(', ') : definitions[i].options[values[i]]!.ts(sourceKey)}',
  ];
}
