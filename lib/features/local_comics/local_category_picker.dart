import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/menu.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

import 'local.dart';

Future<int?> showLocalCategoryPicker(
  BuildContext context, {
  required int selectedCategory,
  bool moving = false,
}) => showDialog<int>(
  context: context,
  builder: (context) =>
      _LocalCategoryPicker(selectedCategory: selectedCategory, moving: moving),
);

class _LocalCategoryPicker extends StatefulWidget {
  const _LocalCategoryPicker({
    required this.selectedCategory,
    required this.moving,
  });

  final int selectedCategory;
  final bool moving;

  @override
  State<_LocalCategoryPicker> createState() => _LocalCategoryPickerState();
}

class _LocalCategoryPickerState extends State<_LocalCategoryPicker> {
  final _manager = LocalManager();
  String _query = '';

  Future<int?> _editCategory([LocalComicCategory? category]) {
    var name = category?.name ?? '';
    String? error;
    return showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void save() {
            if (name.trim().isEmpty) {
              setDialogState(() => error = 'Cannot be empty'.tl);
              return;
            }
            final id = category == null
                ? _manager.createComicCategory(name)
                : _manager.renameComicCategory(category.id, name)
                ? category.id
                : null;
            if (id == null) {
              setDialogState(
                () => error = 'A category with this name already exists'.tl,
              );
            } else {
              context.pop(id);
            }
          }

          return ContentDialog(
            title: category == null ? 'New category'.tl : 'Rename category'.tl,
            content: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextFormField(
                initialValue: name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Name'.tl,
                  errorText: error,
                ),
                onChanged: (value) {
                  name = value;
                  if (error != null) setDialogState(() => error = null);
                },
                onFieldSubmitted: (_) => save(),
              ),
            ),
            actions: [FilledButton(onPressed: save, child: Text('Confirm'.tl))],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: widget.moving ? 'Move to category'.tl : 'Categories'.tl,
      content: ListenableBuilder(
        listenable: _manager,
        builder: (context, child) {
          final choices = <LocalComicCategory>[
            if (!widget.moving)
              (id: LocalManager.allCategories, name: 'All Comics'.tl),
            (id: LocalManager.uncategorized, name: 'Uncategorized'.tl),
            ..._manager.comicCategories,
          ].where((category) => category.name.toLowerCase().contains(_query));
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search categories'.tl,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                ),
              ),
              if (choices.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No categories found'.tl),
                ),
              for (final category in choices)
                ListTile(
                  leading: Icon(
                    category.id == widget.selectedCategory && !widget.moving
                        ? Icons.check
                        : Icons.folder_outlined,
                  ),
                  title: Text(category.name),
                  selected:
                      category.id == widget.selectedCategory && !widget.moving,
                  onTap: () => context.pop(category.id),
                  trailing:
                      category.id > LocalManager.uncategorized && !widget.moving
                      ? MenuButton(
                          entries: [
                            MenuEntry(
                              icon: Icons.edit_outlined,
                              text: 'Rename category'.tl,
                              onClick: () => _editCategory(category),
                            ),
                            MenuEntry(
                              icon: Icons.delete_outline,
                              text: 'Delete category'.tl,
                              onClick: () => showConfirmDialog(
                                context: context,
                                title: 'Delete category'.tl,
                                content:
                                    'Comics will move to Uncategorized.'.tl,
                                onConfirm: () =>
                                    _manager.deleteComicCategory(category.id),
                                confirmText: 'Delete',
                              ),
                            ),
                          ],
                        )
                      : null,
                ),
            ],
          );
        },
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            final categoryId = await _editCategory();
            if (context.mounted && categoryId != null) context.pop(categoryId);
          },
          icon: const Icon(Icons.create_new_folder_outlined),
          label: Text('New category'.tl),
        ),
      ],
    );
  }
}
