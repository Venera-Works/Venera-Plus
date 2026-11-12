import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/keyword_rule.dart';
import 'package:venera_plus/foundation/search_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Map<String, dynamic> previous;

  setUp(() async {
    previous = jsonDecode(jsonEncode(appdata.toJson())) as Map<String, dynamic>;
    root = Directory.systemTemp.createTempSync('venera-search-keywords-');
    App.dataPath = App.cachePath = root.path;
    appdata.registerSyncDataRequestHandler(null);
    appdata.settings.replaceAll({});
    await appdata.syncData({
      'settings': <String, dynamic>{},
      'searchHistory': <String>[],
    });
  });

  tearDown(() async {
    appdata.registerSyncDataRequestHandler(null);
    appdata.settings.replaceAll(
      Map<String, dynamic>.from(previous['settings'] as Map),
    );
    await appdata.syncData(previous);
    root.deleteSync(recursive: true);
    App.dataPath = App.cachePath = Directory.systemTemp.path;
  });

  test(
    'query variants persist independently without displacing keyword history',
    () async {
      final keywords = List.generate(60, (index) => 'word-$index');
      appdata.setFullSearchHistory(keywords);
      appdata.settings['searchHistoryDisplayMode'] = 'keywords';
      final first = SearchHistoryEntry(
        keyword: 'word-59',
        sourceKey: 'a',
        sourceName: 'Source A',
        options: ['recent'],
        page: 8,
      );
      final second = SearchHistoryEntry(
        keyword: 'word-59',
        sourceKey: 'b',
        options: ['recent'],
        page: 3,
      );
      final third = SearchHistoryEntry(
        keyword: 'word-59',
        sourceKey: 'a',
        options: ['popular'],
        page: 12,
      );
      await appdata.recordSearchHistory(first);
      await appdata.recordSearchHistory(second);
      await appdata.recordSearchHistory(third);
      await appdata.removeSearchHistoryEntry(second.identity);
      expect(appdata.fullSearchHistory, ['word-59', ...keywords.take(59)]);

      appdata.searchHistoryEntries.clear();
      appdata.setFullSearchHistory([]);
      appdata.settings['searchHistoryDisplayMode'] = 'detailed';
      await appdata.loadDataForTesting(root.path);

      expect(appdata.searchHistoryEntries.map((entry) => entry.toJson()), [
        third.toJson(),
        first.toJson(),
      ]);
      expect(appdata.fullSearchHistory, ['word-59', ...keywords.take(59)]);
      expect(appdata.settings['searchHistoryDisplayMode'], 'keywords');
    },
  );

  test('clearing either history mode preserves the other mode', () async {
    final entry = SearchHistoryEntry(keyword: 'saved', sourceKey: 'a', page: 4);
    await appdata.recordSearchHistory(entry);
    appdata.addSearchHistory('another');
    await appdata.clearSearchHistoryEntries();
    expect(appdata.fullSearchHistory, ['another', 'saved']);

    await appdata.recordSearchHistory(entry);
    appdata.clearSearchHistory();
    await appdata.saveData(false);
    expect(appdata.fullSearchHistory, isEmpty);
    expect(appdata.searchHistoryEntries.single.toJson(), entry.toJson());
  });

  test(
    'old snapshots restore legacy behavior only for the replaced word list',
    () async {
      appdata.settings.setKeywordSettings(
        'blockedWords',
        ['bl'],
        'blockedWordRules',
        {
          'bl': {'mode': 'word', 'caseSensitive': false},
        },
      );
      appdata.settings.setKeywordSettings(
        'blockedCommentWords',
        ['spoiler'],
        'blockedCommentWordRules',
        {
          'spoiler': {'mode': 'word', 'caseSensitive': true},
        },
      );
      await appdata.recordSearchHistory(
        SearchHistoryEntry(keyword: 'current', sourceKey: 'a', page: 6),
      );

      await appdata.syncData({
        'settings': {
          'blockedWords': ['bl'],
        },
        'searchHistory': ['old search'],
      });

      final comicRule = KeywordRule.read(
        'bl',
        (appdata.settings['blockedWordRules'] as Map)['bl'],
      );
      final commentRule = KeywordRule.read(
        'spoiler',
        (appdata.settings['blockedCommentWordRules'] as Map)['spoiler'],
        comments: true,
      );
      expect(comicRule.isLegacy, isTrue);
      expect(comicRule.caseSensitive, isTrue);
      expect(commentRule.isLegacy, isFalse);
      expect(commentRule.mode, KeywordMatchMode.word);
      expect(commentRule.caseSensitive, isTrue);
      expect(appdata.searchHistoryEntries, isEmpty);
      expect(appdata.fullSearchHistory, ['old search']);

      await appdata.syncData({
        'settings': {
          'blockedCommentWords': ['spoiler'],
        },
        'searchHistory': ['old search'],
      });
      expect(
        KeywordRule.read(
          'spoiler',
          (appdata.settings['blockedCommentWordRules'] as Map)['spoiler'],
          comments: true,
        ).caseSensitive,
        isFalse,
      );
    },
  );

  test(
    'excluding a word list also excludes its options in both sync directions',
    () async {
      appdata.settings.setKeywordSettings(
        'blockedWords',
        ['local'],
        'blockedWordRules',
        {
          'local': {'mode': 'tag', 'caseSensitive': true},
        },
      );
      appdata.settings.setKeywordSettings(
        'blockedCommentWords',
        ['comment'],
        'blockedCommentWordRules',
        {
          'comment': {'mode': 'word', 'caseSensitive': false},
        },
      );
      appdata.settings['disableSyncFields'] = 'blockedWords';
      await appdata.saveData(false);
      final snapshot =
          jsonDecode(File('${root.path}/syncdata.json').readAsStringSync())
              as Map;
      final exported = snapshot['settings'] as Map;
      expect(exported.containsKey('blockedWords'), isFalse);
      expect(exported.containsKey('blockedWordRules'), isFalse);
      expect(exported['blockedCommentWordRules'], {
        'comment': {'mode': 'word', 'caseSensitive': false},
      });

      await appdata.syncData({
        'settings': {
          'blockedWords': ['remote'],
          'blockedWordRules': {
            'remote': {'mode': 'contains', 'caseSensitive': false},
          },
          'blockedCommentWords': ['updated comment'],
        },
        'searchHistory': <String>[],
      });
      expect(appdata.settings['blockedWords'], ['local']);
      expect(appdata.settings['blockedWordRules'], {
        'local': {'mode': 'tag', 'caseSensitive': true},
      });
      expect(appdata.settings['blockedCommentWords'], ['updated comment']);
      expect(appdata.settings['blockedCommentWordRules'], isEmpty);
    },
  );

  test(
    'invalid detailed history cannot partially replace live settings',
    () async {
      await appdata.recordSearchHistory(
        SearchHistoryEntry(keyword: 'current', sourceKey: 'a', page: 5),
      );
      final original = jsonEncode(appdata.toJson());
      await expectLater(
        appdata.syncData({
          'settings': {
            'blockedWords': ['new rule'],
          },
          'searchHistory': ['incoming'],
          'searchHistoryEntries': [
            {
              'keyword': 'incoming',
              'sourceKey': 'a',
              'options': <String>[],
              'page': 0,
            },
          ],
        }),
        throwsFormatException,
      );
      expect(jsonEncode(appdata.toJson()), original);
    },
  );

  test(
    'invalid new rule options are rejected before replacing either list',
    () async {
      appdata.settings.setKeywordSettings(
        'blockedWords',
        ['original'],
        'blockedWordRules',
        {
          'original': {'mode': 'tag', 'caseSensitive': true},
        },
      );
      final original = jsonEncode(appdata.toJson());
      await expectLater(
        appdata.syncData({
          'settings': {
            'blockedWords': ['new'],
            'blockedCommentWordRules': {
              'bad comment': {'mode': 'tag', 'caseSensitive': false},
            },
          },
          'searchHistory': <String>[],
        }),
        throwsFormatException,
      );
      expect(jsonEncode(appdata.toJson()), original);
    },
  );
}
