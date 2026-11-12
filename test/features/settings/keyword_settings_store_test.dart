import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/keyword_settings_store.dart';

void main() {
  late Map<String, dynamic> settings;
  late KeywordSettingsStore store;
  late Future<void> Function() save;
  var writes = 0;
  setUp(() {
    settings = {
      'blockedWords': <String>[],
      'blockedWordRules': <String, dynamic>{},
    };
    writes = 0;
    save = () async {};
    store = KeywordSettingsStore(
      readSettings: () => settings,
      writeSettings: (target, words, rules) {
        writes++;
        settings[target.key] = words;
        settings[target.rulesKey] = rules;
      },
      persist: () => save(),
    );
  });

  test(
    'words and options are one queued mutation and accepted work survives owner disposal',
    () async {
      final barrier = Completer<void>();
      save = () => barrier.future;
      final first = store.saveRule(
        BlockedKeywordList.comics,
        const KeywordRule('BL', mode: KeywordMatchMode.word),
      );
      final second = store.blockRules(BlockedKeywordList.comics, [
        const KeywordRule('tag', mode: KeywordMatchMode.tag),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(settings['blockedWords'], ['BL']);
      expect(settings['blockedWordRules'], {
        'BL': {'mode': 'word', 'caseSensitive': false},
      });
      barrier.complete();
      await Future.wait([first, second]);
      expect(settings['blockedWords'], ['BL', 'tag']);
      expect(writes, 2);
    },
  );

  test(
    'failed persistence can retry latest state without replaying an outdated mutation',
    () async {
      save = () async {
        throw StateError('disk full');
      };
      await expectLater(
        store.saveRule(BlockedKeywordList.comics, const KeywordRule('BL')),
        throwsStateError,
      );
      expect(store.error, isNotNull);
      expect(store.rules(BlockedKeywordList.comics).single.keyword, 'BL');
      save = () async {};
      await store.blockRules(BlockedKeywordList.comics, [
        const KeywordRule('new'),
      ]);
      await store.retry();
      expect(store.error, isNull);
      expect(settings['blockedWords'], ['BL', 'new']);
      expect(writes, 2);
    },
  );

  test('stale editors cannot overwrite changed or deleted rules', () async {
    const original = KeywordRule('BL');
    await store.saveRule(BlockedKeywordList.comics, original);
    const updated = KeywordRule('BL', mode: KeywordMatchMode.word);
    expect(
      await store.saveRule(
        BlockedKeywordList.comics,
        updated,
        replacing: original,
      ),
      KeywordRuleSaveResult.saved,
    );
    expect(
      await store.saveRule(
        BlockedKeywordList.comics,
        const KeywordRule('renamed'),
        replacing: original,
      ),
      KeywordRuleSaveResult.changed,
    );
    expect(store.rules(BlockedKeywordList.comics), [updated]);
    expect(
      await store.removeRule(BlockedKeywordList.comics, original),
      isFalse,
    );
    expect(await store.removeRule(BlockedKeywordList.comics, updated), isTrue);
    expect(
      await store.saveRule(
        BlockedKeywordList.comics,
        updated,
        replacing: updated,
      ),
      KeywordRuleSaveResult.changed,
    );
    expect(settings['blockedWords'], isEmpty);
  });

  test(
    'quick block preserves existing rule options and legacy case policy',
    () async {
      settings['blockedWords'] = ['BL'];
      await store.blockRules(BlockedKeywordList.comics, [
        KeywordRule.suggested('BL', tag: true),
        KeywordRule.suggested('new', tag: true),
      ]);
      expect(
        store.ruleFor(BlockedKeywordList.comics, 'BL'),
        const KeywordRule.legacy('BL'),
      );
      expect(
        store.ruleFor(BlockedKeywordList.comics, 'new')?.mode,
        KeywordMatchMode.tag,
      );
    },
  );

  test(
    'saving unmodified legacy rules does not opt them into modern folding',
    () async {
      settings['blockedWords'] = [' BL '];
      final rule = store.rules(BlockedKeywordList.comics).single;
      expect(
        await store.saveRule(BlockedKeywordList.comics, rule, replacing: rule),
        KeywordRuleSaveResult.saved,
      );
      expect(settings['blockedWords'], [' BL ']);
      expect(settings['blockedWordRules'], isEmpty);
    },
  );
}
