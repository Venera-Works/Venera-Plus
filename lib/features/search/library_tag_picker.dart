import 'package:flutter/material.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';
import 'package:venera_plus/foundation/translations.dart';

import 'library_search_query.dart';

Future<Set<String>?> showLibraryTagPicker(
  BuildContext context, {
  required Iterable<String> availableTags,
  required Set<String> selectedTags,
}) => showPopUpWidget<Set<String>?>(
  context,
  _LibraryTagPicker(availableTags: availableTags, selectedTags: selectedTags),
);

class _LibraryTagPicker extends StatefulWidget {
  const _LibraryTagPicker({
    required this.availableTags,
    required this.selectedTags,
  });

  final Iterable<String> availableTags;
  final Set<String> selectedTags;

  @override
  State<_LibraryTagPicker> createState() => _LibraryTagPickerState();
}

class _LibraryTagPickerState extends State<_LibraryTagPicker> {
  late final _labels = {
    for (final tag in [...widget.availableTags, ...widget.selectedTags])
      sqliteNoCaseKey(tag): tag,
  };
  late final _selected = {
    for (final tag in widget.selectedTags) sqliteNoCaseKey(tag),
  };
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final typed = libraryTagLabel(_query);
    final typedKey = typed == null ? null : sqliteNoCaseKey(typed);
    final labels = [
      if (typed != null && !_labels.containsKey(typedKey)) typed,
      for (final entry in _labels.entries)
        if (entry.value.toLowerCase().contains(query) || entry.key == typedKey)
          entry.value,
    ];
    return PopUpWidgetScaffold(
      title: 'Filter by tags'.tl,
      tailing: [
        TextButton(
          onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
          child: Text('Clear'.tl),
        ),
        TextButton(
          onPressed: () => Navigator.of(
            context,
            rootNavigator: true,
          ).pop({for (final key in _selected) _labels[key]!}),
          child: Text('Done'.tl),
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: 'Search tags'.tl,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: labels.isEmpty
                ? Center(child: Text('No tags found'.tl))
                : ListView.builder(
                    itemCount: labels.length,
                    itemBuilder: (context, index) {
                      final label = labels[index];
                      final key = sqliteNoCaseKey(label);
                      return CheckboxListTile(
                        title: Text(label),
                        value: _selected.contains(key),
                        onChanged: (checked) => setState(() {
                          if (checked == true) {
                            _labels[key] = label;
                            _selected.add(key);
                          } else {
                            _selected.remove(key);
                          }
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
