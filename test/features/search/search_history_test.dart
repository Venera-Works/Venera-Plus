import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/search_history.dart';

void main() {
  test('search identity distinguishes exact source and option tuples', () {
    final entries = [
      SearchHistoryEntry(keyword: 'same', sourceKey: 'a', options: ['x', 'y']),
      SearchHistoryEntry(keyword: 'same', sourceKey: 'b', options: ['x', 'y']),
      SearchHistoryEntry(keyword: 'same', sourceKey: 'a', options: ['y', 'x']),
      SearchHistoryEntry(keyword: 'same', sourceKey: 'a', options: ['x,y']),
      SearchHistoryEntry(
        keyword: 'same',
        sourceKey: 'a',
        options: ['x\u0000y'],
      ),
    ];
    expect(
      entries.map((entry) => entry.identity).toSet(),
      hasLength(entries.length),
    );
    expect(entries.first.copyWith(page: 8).identity, entries.first.identity);
  });

  test(
    'options are immutable snapshots and optional source names round trip',
    () {
      final options = ['first'];
      final entry = SearchHistoryEntry(
        keyword: 'term',
        sourceKey: 'source',
        options: options,
        page: 3,
      );
      options[0] = 'changed';
      expect(entry.options, ['first']);
      expect(() => entry.options.add('changed'), throwsUnsupportedError);
      final restored = SearchHistoryEntry.fromJson(entry.toJson());
      expect(restored.identity, entry.identity);
      expect(restored.page, 3);
      expect(restored.sourceName, isNull);
      final named = SearchHistoryEntry(
        keyword: 'term',
        sourceKey: 'source',
        sourceName: 'Source',
      );
      expect(SearchHistoryEntry.fromJson(named.toJson()).sourceName, 'Source');
    },
  );

  test(
    'invalid JSON types and invalid page numbers fail with FormatException',
    () {
      final valid = SearchHistoryEntry(
        keyword: 'term',
        sourceKey: 'source',
      ).toJson();
      for (final field in {
        'keyword': [null, 1, '', '  '],
        'sourceKey': [null, true, ''],
        'sourceName': [1, false, <String>[]],
        'options': [
          null,
          'option',
          <Object>['a', 1],
        ],
        'page': [null, 0, -1, 1.0, '2', false],
      }.entries) {
        for (final value in field.value) {
          expect(
            () => SearchHistoryEntry.fromJson({...valid, field.key: value}),
            throwsFormatException,
            reason: '${field.key}: $value',
          );
        }
      }
    },
  );
}
