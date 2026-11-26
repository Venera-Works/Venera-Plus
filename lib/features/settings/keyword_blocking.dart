import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/keyword_filter.dart';
import 'package:venera_plus/foundation/keyword_settings_store.dart';
import 'package:venera_plus/foundation/translations.dart';

String keywordModeLabel(KeywordMatchMode mode) => switch (mode) {
  KeywordMatchMode.contains => 'Contains text'.tl,
  KeywordMatchMode.word => 'Whole word'.tl,
  KeywordMatchMode.tag => 'Exact tag'.tl,
};

String keywordRuleSummary(KeywordRule rule) =>
    '${keywordModeLabel(rule.mode)} · ${rule.caseSensitive ? 'Case sensitive'.tl : 'Ignore case'.tl}';

class KeywordMatchPreview extends StatelessWidget {
  const KeywordMatchPreview({super.key, required this.match});
  final KeywordMatch match;
  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(text: match.text.substring(0, match.start)),
        TextSpan(
          text: match.text.substring(match.start, match.end),
          style: TextStyle(
            backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            color: Theme.of(context).colorScheme.onTertiaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
        TextSpan(text: match.text.substring(match.end)),
      ],
    ),
  );
}

Future<void> showKeywordRuleEditor(
  BuildContext context, {
  required BlockedKeywordList target,
  KeywordRule? rule,
  KeywordSettingsStore? store,
}) => showDialog<void>(
  context: context,
  animationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (_) =>
      KeywordRuleEditor(target: target, initialRule: rule, store: store),
);

class KeywordBlockingSettings extends StatefulWidget {
  const KeywordBlockingSettings({super.key, this.comments = false, this.store});
  final bool comments;
  final KeywordSettingsStore? store;
  @override
  State<KeywordBlockingSettings> createState() =>
      _KeywordBlockingSettingsState();
}

class _KeywordBlockingSettingsState extends State<KeywordBlockingSettings> {
  KeywordSettingsStore get store => widget.store ?? keywordSettings;
  BlockedKeywordList get target =>
      widget.comments ? BlockedKeywordList.comments : BlockedKeywordList.comics;
  String? _error;
  @override
  void initState() {
    super.initState();
    store.addListener(_refresh);
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    store.removeListener(_refresh);
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _delete(KeywordRule rule) async {
    try {
      final removed = await store.removeRule(target, rule);
      if (mounted) {
        setState(() {
          _error = removed
              ? null
              : 'The rule changed. Close and reopen the editor.'.tl;
        });
      }
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = store.rules(target);
    final secondaryColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return PopUpWidgetScaffold(
      title:
          (widget.comments
                  ? 'Comment keyword blocking'
                  : 'Comic keyword blocking')
              .tl,
      tailing: [
        TextButton.icon(
          style: actionButtonStyle,
          onPressed: () =>
              showKeywordRuleEditor(context, target: target, store: store),
          icon: const Icon(Icons.add),
          label: Text('Add'.tl),
        ),
      ],
      body: Column(
        children: [
          if (store.error != null)
            ListTile(
              title: Text('Failed to save keyword rules'.tl),
              trailing: TextButton(
                style: actionButtonStyle,
                onPressed: store.pending == 0
                    ? () async {
                        try {
                          await store.retry();
                        } catch (_) {
                          /* The store retains the error for retry. */
                        }
                      }
                    : null,
                child: Text('Retry'.tl),
              ),
            ),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
          Expanded(
            child: rules.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.filter_alt_outlined,
                            size: 40,
                            color: secondaryColor,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No keywords are blocked here. Add a rule to filter by keyword.'
                                .tl,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: secondaryColor),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: rules.length,
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      return ListTile(
                        title: Text(
                          rule.keyword.isEmpty
                              ? 'Empty keyword'.tl
                              : rule.keyword,
                        ),
                        subtitle: Text(keywordRuleSummary(rule)),
                        onTap: () => showKeywordRuleEditor(
                          context,
                          target: target,
                          rule: rule,
                          store: store,
                        ),
                        trailing: IconButton(
                          tooltip: 'Delete'.tl,
                          icon: const Icon(Icons.close),
                          onPressed: () => _delete(rule),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class KeywordRuleEditor extends StatefulWidget {
  const KeywordRuleEditor({
    super.key,
    required this.target,
    this.initialRule,
    this.store,
  });
  final BlockedKeywordList target;
  final KeywordRule? initialRule;
  final KeywordSettingsStore? store;
  @override
  State<KeywordRuleEditor> createState() => _KeywordRuleEditorState();
}

class _KeywordRuleEditorState extends State<KeywordRuleEditor> {
  KeywordSettingsStore get store => widget.store ?? keywordSettings;
  late final _word = TextEditingController(text: widget.initialRule?.keyword);
  final _sample = TextEditingController();
  late KeywordMatchMode _mode =
      widget.initialRule?.mode ?? KeywordMatchMode.contains;
  late bool _sensitive = widget.initialRule?.caseSensitive ?? false;
  bool _chosen = false;
  bool _preview = false;
  bool _saving = false;
  bool _failed = false;
  bool _stale = false;
  String? _error;
  TextStyle? get _hintStyle {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  bool get comments => widget.target == BlockedKeywordList.comments;
  KeywordRule get candidate {
    final original = widget.initialRule;
    final word = _word.text == original?.keyword
        ? _word.text
        : _word.text.trim();
    return original?.isLegacy == true &&
            _mode == original!.mode &&
            _sensitive == original.caseSensitive
        ? KeywordRule.legacy(word, caseSensitive: _sensitive)
        : KeywordRule(word, mode: _mode, caseSensitive: _sensitive);
  }

  Future<void> _save() async {
    if (_saving || _stale) return;
    final rule = candidate;
    if (rule.keyword.trim().isEmpty) {
      setState(() {
        _error = 'Keyword cannot be blank'.tl;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      KeywordRuleSaveResult result;
      if (_failed) {
        await store.retry();
        result = store.ruleFor(widget.target, rule.keyword) == rule
            ? KeywordRuleSaveResult.saved
            : KeywordRuleSaveResult.changed;
      } else {
        result = await store.saveRule(
          widget.target,
          rule,
          replacing: widget.initialRule,
        );
      }
      if (!mounted) return;
      if (result == KeywordRuleSaveResult.saved) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _stale = result == KeywordRuleSaveResult.changed;
        _error = _stale
            ? 'The rule changed. Close and reopen the editor.'.tl
            : 'Keyword already exists'.tl;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _error = 'Failed to save keyword rules'.tl;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Widget _samplePreview() {
    final filter = KeywordFilter.rules([candidate]);
    final sample = _sample.text;
    final match = candidate.keyword.trim().isEmpty
        ? null
        : comments
        ? filter.commentMatch(sample)
        : filter.comicMatch(
            title: _mode == KeywordMatchMode.tag ? '' : sample,
            description: '',
            tags: _mode == KeywordMatchMode.tag ? [sample] : const [],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('keyword-rule-sample'),
          controller: _sample,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            labelText:
                (comments
                        ? 'Sample comment'
                        : _mode == KeywordMatchMode.tag
                        ? 'Sample tag'
                        : 'Sample title')
                    .tl,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        if (sample.isNotEmpty && candidate.keyword.trim().isNotEmpty) ...[
          Text((match == null ? 'Will stay visible' : 'Will be hidden').tl),
          if (match != null) KeywordMatchPreview(match: match),
        ] else
          Text('Enter sample text to check this rule.'.tl, style: _hintStyle),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ContentDialog(
    title: (widget.initialRule == null ? 'Add keyword' : 'Edit keyword').tl,
    content: Container(
      width: 480,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('keyword-rule-word'),
            controller: _word,
            enabled: !_saving && !_failed && !_stale,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Keyword'.tl,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onSubmitted: (_) => _save(),
            onChanged: (_) => setState(() {
              _error = null;
              if (widget.initialRule == null && !_chosen) {
                _mode = KeywordRule.suggested(_word.text).mode;
              }
            }),
          ),
          const SizedBox(height: 16),
          ButtonTheme(
            alignedDropdown: true,
            child: DropdownButtonFormField<KeywordMatchMode>(
              initialValue: _mode,
              key: ValueKey(_mode),
              isExpanded: true,
              isDense: true,
              borderRadius: BorderRadius.circular(12),
              dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
              menuMaxHeight: 320,
              decoration: InputDecoration(
                labelText: 'Match mode'.tl,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              items: [
                for (final mode in KeywordMatchMode.values)
                  if (!comments || mode != KeywordMatchMode.tag)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(keywordModeLabel(mode)),
                    ),
              ],
              onChanged: _saving || _failed || _stale
                  ? null
                  : (mode) => setState(() {
                      _mode = mode!;
                      _chosen = true;
                    }),
            ),
          ),
          if (widget.initialRule == null &&
              KeywordRule.isShortAbbreviation(_word.text))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Whole word is recommended for short abbreviations.'.tl,
                style: _hintStyle,
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Ignore case'.tl),
            value: !_sensitive,
            onChanged: _saving || _failed || _stale
                ? null
                : (value) => setState(() {
                    _sensitive = !value;
                  }),
          ),
          Text(
            'Keywords are literal text, not regular expressions.'.tl,
            style: _hintStyle,
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              style: actionButtonStyle,
              onPressed: () => setState(() {
                _preview = !_preview;
              }),
              child: Text('Try matching'.tl),
            ),
          ),
          if (_preview) _samplePreview(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        style: actionButtonStyle,
        onPressed: () => Navigator.of(context).pop(),
        child: Text('Close'.tl),
      ),
      FilledButton(
        style: actionButtonStyle,
        onPressed: _saving || _stale ? null : _save,
        child: Text(
          (_saving
                  ? 'Saving'
                  : _failed
                  ? 'Retry'
                  : widget.initialRule == null
                  ? 'Add'
                  : 'Save')
              .tl,
        ),
      ),
    ],
  );
  @override
  void dispose() {
    _word.dispose();
    _sample.dispose();
    super.dispose();
  }
}
