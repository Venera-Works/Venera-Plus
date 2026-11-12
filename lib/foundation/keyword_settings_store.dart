import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'keyword_rule.dart';

export 'keyword_rule.dart';

enum BlockedKeywordList {
  comics('blockedWords', 'blockedWordRules'),
  comments('blockedCommentWords', 'blockedCommentWordRules');

  const BlockedKeywordList(this.key, this.rulesKey);
  final String key;
  final String rulesKey;
}

enum KeywordRuleSaveResult { saved, duplicate, changed }

final keywordSettings = KeywordSettingsStore(
  readSettings: () => {
    for (final target in BlockedKeywordList.values) ...{
      target.key: appdata.settings[target.key],
      target.rulesKey: appdata.settings[target.rulesKey],
    },
  },
  writeSettings: (target, words, rules) => appdata.settings.setKeywordSettings(
    target.key,
    words,
    target.rulesKey,
    rules,
  ),
  persist: () => appdata.saveData(),
);

/// The queue belongs to the settings, not any dialog. Admitted changes finish
/// after disposal. Retrying persists the latest state, never a stale editor.
class KeywordSettingsStore extends ChangeNotifier {
  KeywordSettingsStore({
    required this.readSettings,
    required this.writeSettings,
    required this.persist,
  });
  final Map<String, dynamic> Function() readSettings;
  final void Function(BlockedKeywordList, List<String>, Map<String, dynamic>)
  writeSettings;
  final Future<void> Function() persist;
  Future<void> _tail = Future.value();
  Object? error;
  int pending = 0;

  List<KeywordRule> rules(BlockedKeywordList target) {
    final settings = readSettings();
    final options = settings[target.rulesKey] as Map? ?? const {};
    return [
      for (final word in settings[target.key] as List? ?? const [])
        KeywordRule.read(
          word as String,
          options[word],
          comments: target == BlockedKeywordList.comments,
        ),
    ];
  }

  KeywordRule? ruleFor(BlockedKeywordList target, String word) =>
      rules(target).where((rule) => rule.keyword == word).firstOrNull;

  Future<T> _enqueue<T>(T Function() change) {
    final completion = Completer<T>();
    pending++;
    notifyListeners();
    _tail = _tail.then((_) async {
      try {
        final result = change();
        if (result != KeywordRuleSaveResult.changed &&
            result != KeywordRuleSaveResult.duplicate &&
            result != false) {
          await persist();
          error = null;
        }
        completion.complete(result);
      } catch (failure, stack) {
        error = failure;
        completion.completeError(failure, stack);
      } finally {
        pending--;
        notifyListeners();
      }
    });
    return completion.future;
  }

  Future<void> retry() => _enqueue(() {});

  void _write(BlockedKeywordList target, List<KeywordRule> rules) {
    writeSettings(
      target,
      [for (final rule in rules) rule.keyword],
      {
        for (final rule in rules)
          if (rule.storageOptions != null) rule.keyword: rule.storageOptions,
      },
    );
  }

  void _validate(BlockedKeywordList target, KeywordRule rule) {
    if (rule.keyword.trim().isEmpty ||
        (target == BlockedKeywordList.comments &&
            rule.mode == KeywordMatchMode.tag)) {
      throw ArgumentError('Invalid keyword rule');
    }
  }

  Future<KeywordRuleSaveResult> saveRule(
    BlockedKeywordList target,
    KeywordRule rule, {
    KeywordRule? replacing,
  }) {
    _validate(target, rule);
    return _enqueue(() {
      final current = rules(target);
      final previous = current
          .where((item) => item.keyword == replacing?.keyword)
          .firstOrNull;
      final existing = current
          .where((item) => item.keyword == rule.keyword)
          .firstOrNull;
      if (replacing != null && previous != replacing) {
        return KeywordRuleSaveResult.changed;
      }
      if (existing != null && rule.keyword != replacing?.keyword) {
        return KeywordRuleSaveResult.duplicate;
      }
      _write(target, [
        for (final item in current)
          item.keyword == replacing?.keyword ? rule : item,
        if (replacing == null) rule,
      ]);
      return KeywordRuleSaveResult.saved;
    });
  }

  Future<bool> removeRule(BlockedKeywordList target, KeywordRule expected) =>
      _enqueue(() {
        final current = rules(target);
        final previous = current
            .where((item) => item.keyword == expected.keyword)
            .firstOrNull;
        if (previous == null) return true;
        if (previous != expected) return false;
        _write(
          target,
          current.where((item) => item.keyword != expected.keyword).toList(),
        );
        return true;
      });

  Future<void> blockRules(
    BlockedKeywordList target,
    Iterable<KeywordRule> selection,
  ) {
    final selected = List<KeywordRule>.of(selection);
    for (final rule in selected) {
      _validate(target, rule);
    }
    return _enqueue(() {
      final current = rules(target);
      final words = current.map((rule) => rule.keyword).toSet();
      _write(target, [
        ...current,
        for (final rule in selected)
          if (words.add(rule.keyword)) rule,
      ]);
    });
  }
}
