import 'package:flutter/material.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/keyword_settings_store.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'keyword_comic_filter.dart';

class KeywordHiddenNotice extends StatelessWidget {
  const KeywordHiddenNotice({
    super.key,
    required this.count,
    required this.comics,
    this.store,
  });
  final int count;
  final List<Comic> Function() comics;
  final KeywordSettingsStore? store;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Text('Hidden by keyword filters: @a comics'.tlParams({'a': count})),
    subtitle: Text('View reasons'.tl),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => showDialog<void>(
      context: context,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (_) => _KeywordHiddenDialog(comics: comics, store: store),
    ),
  );
}

class _KeywordHiddenDialog extends StatefulWidget {
  const _KeywordHiddenDialog({required this.comics, this.store});
  final List<Comic> Function() comics;
  final KeywordSettingsStore? store;
  @override
  State<_KeywordHiddenDialog> createState() => _KeywordHiddenDialogState();
}

class _KeywordHiddenDialogState extends State<_KeywordHiddenDialog> {
  @override
  void initState() {
    super.initState();
    appdata.settings.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    appdata.settings.removeListener(_refresh);
    super.dispose();
  }

  String _fieldLabel(KeywordMatchField field) => switch (field) {
    KeywordMatchField.title => 'Title'.tl,
    KeywordMatchField.subtitle => 'Subtitle'.tl,
    KeywordMatchField.description => 'Description'.tl,
    KeywordMatchField.tag => 'Tag'.tl,
    KeywordMatchField.comment => 'Comment'.tl,
  };
  @override
  Widget build(BuildContext context) {
    final filter = comicKeywordFilter();
    final hidden = <(Comic, KeywordMatch)>[];
    for (final comic in widget.comics()) {
      final match = matchComicKeyword(comic, filter: filter);
      if (match != null) hidden.add((comic, match));
    }
    return AlertDialog(
      title: Text('Keyword filter reasons'.tl),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Only comics in this list are checked. Images stay hidden.'.tl,
            ),
            const SizedBox(height: 12),
            if (hidden.isEmpty)
              Text('No comics in this list are hidden by keywords.'.tl),
            for (final (comic, match) in hidden) ...[
              if (match.field != KeywordMatchField.title) Text(comic.title),
              KeywordMatchPreview(match: match),
              Text('Matched in @a'.tlParams({'a': _fieldLabel(match.field)})),
              Text(
                'Keyword: @a'.tlParams({
                  'a': match.rule.keyword.isEmpty
                      ? 'Empty keyword'.tl
                      : match.rule.keyword,
                }),
              ),
              Text(keywordRuleSummary(match.rule)),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => showKeywordRuleEditor(
                    context,
                    target: BlockedKeywordList.comics,
                    rule: match.rule,
                    store: widget.store,
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text('Edit rule'.tl),
                ),
              ),
              const Divider(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Close'.tl),
        ),
      ],
    );
  }
}
