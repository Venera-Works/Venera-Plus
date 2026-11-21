import 'package:flutter/material.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sqlite_connection.dart';
import 'package:venera_plus/foundation/translations.dart';

import 'library_search_query.dart';

class LibrarySearchTagFilter extends StatefulWidget {
  const LibrarySearchTagFilter({
    super.key,
    required this.loadTags,
    required this.selected,
    required this.onChanged,
  });

  final Future<Res<List<String>>> Function() loadTags;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  State<LibrarySearchTagFilter> createState() => _LibrarySearchTagFilterState();
}

class _LibrarySearchTagFilterState extends State<LibrarySearchTagFilter> {
  bool _picking = false;

  Future<void> _pickTags() async {
    setState(() => _picking = true);
    try {
      final result = await widget.loadTags();
      if (!mounted) return;
      if (result.error) {
        context.showMessage(message: result.errorMessage!.tl);
        return;
      }
      final tags = await showLibraryTagPicker(
        context,
        availableTags: result.data,
        selectedTags: widget.selected.toSet(),
      );
      if (mounted && tags != null) widget.onChanged(tags.toList());
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.filter_alt_outlined),
    title: Text('Filter by tags'.tl),
    subtitle: widget.selected.isEmpty
        ? null
        : Text(widget.selected.join(' · ')),
    trailing: const Icon(Icons.arrow_right),
    onTap: _picking ? null : _pickTags,
  );
}

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
