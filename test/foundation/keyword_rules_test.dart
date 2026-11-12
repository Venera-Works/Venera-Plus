import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/keyword_filter.dart';

void main() {
  bool title(KeywordRule rule, String text) =>
      KeywordFilter.rules([rule]).comicMatch(title: text, description: '') !=
      null;

  test(
    'whole words use Unicode letters numbers and combining marks as boundaries',
    () {
      const rule = KeywordRule('BL', mode: KeywordMatchMode.word);
      for (final value in [
        '[BL] stories',
        'artist.bl.part01.zip',
        'BL_stories',
        'BL-story',
      ]) {
        expect(title(rule, value), isTrue, reason: value);
      }
      for (final value in [
        'black',
        'BL漫画',
        '漫画BL',
        'BL2',
        'éBL',
        'BL\u0301',
        '𐐀BL',
      ]) {
        expect(title(rule, value), isFalse, reason: value);
      }
      expect(
        title(const KeywordRule('校园', mode: KeywordMatchMode.word), '校园恋爱故事'),
        isFalse,
      );
      expect(title(const KeywordRule('校园'), '校园恋爱故事'), isTrue);
    },
  );

  test('metacharacters stay literal in all text modes', () {
    for (final mode in [KeywordMatchMode.contains, KeywordMatchMode.word]) {
      for (final word in ['a.b', '[BL]', 'a+b', r'a\b', '(a*)']) {
        final rule = KeywordRule(word, mode: mode);
        expect(title(rule, ' $word '), isTrue);
      }
      expect(title(KeywordRule('a.b', mode: mode), ' axb '), isFalse);
    }
  });

  test('tags require entire tag or the legacy first namespace segment', () {
    for (final mode in KeywordMatchMode.values) {
      final filter = KeywordFilter.rules([KeywordRule('bl', mode: mode)]);
      for (final tag in ['BL', 'genre:BL', 'genre:BL:other']) {
        final match = filter.comicMatch(
          title: '',
          description: '',
          tags: [tag],
        );
        expect(match?.field, KeywordMatchField.tag);
        expect(match!.text.substring(match.start, match.end), 'BL');
      }
      for (final tag in ['black', 'BL stories', 'genre:other:BL']) {
        expect(
          filter.comicMatch(title: '', description: '', tags: [tag]),
          isNull,
        );
      }
    }
    expect(
      title(const KeywordRule('BL', mode: KeywordMatchMode.tag), 'BL'),
      isFalse,
    );
  });

  test(
    'legacy comics retain case and comments retain lowercase substring behavior',
    () {
      final comics = KeywordFilter.fromSettings({
        'blockedWords': ['bl'],
      });
      expect(comics.comicMatch(title: 'BL', description: ''), isNull);
      expect(comics.comicMatch(title: 'black', description: ''), isNotNull);
      expect(
        comics.comicMatch(title: '', description: '', tags: ['BL']),
        isNull,
      );
      final comments = KeywordFilter.fromSettings({
        'blockedCommentWords': ['BL'],
      }, comments: true);
      expect(comments.blocksComment('black'), isTrue);
      expect(comments.rules.single.isLegacy, isTrue);
      expect(KeywordRule.read('BL', null), const KeywordRule.legacy('BL'));
      expect(KeywordRule.suggested('BL').mode, KeywordMatchMode.word);
      expect(KeywordRule.suggested('BL', tag: true).mode, KeywordMatchMode.tag);
    },
  );

  test(
    'first match carries original text and actual field for explanations',
    () {
      final filter = KeywordFilter.rules([
        const KeywordRule('BL', mode: KeywordMatchMode.word),
        const KeywordRule('story'),
      ]);
      final match = filter.comicMatch(
        title: 'story',
        subtitle: 'A bl story',
        description: '',
      )!;
      expect(match.rule.keyword, 'BL');
      expect(match.field, KeywordMatchField.subtitle);
      expect(match.text.substring(match.start, match.end), 'bl');
    },
  );

  test('rule codec rejects malformed settings and comment tag mode', () {
    for (final value in [
      null,
      [],
      {'a': {}},
      {
        'a': {'mode': 'regex', 'caseSensitive': false},
      },
      {
        'a': {'mode': 'word', 'caseSensitive': 'false'},
      },
    ]) {
      expect(() => validateKeywordRuleOptions(value), throwsFormatException);
    }
    expect(
      () => validateKeywordRuleOptions({
        'a': {'mode': 'tag', 'caseSensitive': false},
      }, comments: true),
      throwsFormatException,
    );
    final rule = KeywordRule.read('a.b', {
      'mode': 'word',
      'caseSensitive': true,
    });
    expect(rule.storageOptions, {'mode': 'word', 'caseSensitive': true});
  });
}
