import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'remote_directory_picker.dart';
import 'storage_accounts_page.dart';

class RemoteLocationFields extends StatefulWidget {
  const RemoteLocationFields({
    super.key,
    required this.accountId,
    required this.directories,
    required this.onChanged,
    this.multiSelect = false,
    this.accountLocked = false,
    this.allowNone = false,
    this.accounts,
  });

  final String? accountId;
  final List<String> directories;
  final void Function(StorageAccount? account, List<String> directories)
  onChanged;
  final bool multiSelect;
  final bool accountLocked;
  final bool allowNone;
  final RemoteStorageAccounts? accounts;

  @override
  State<RemoteLocationFields> createState() => _RemoteLocationFieldsState();
}

class _RemoteLocationFieldsState extends State<RemoteLocationFields> {
  RemoteStorageAccounts get _storage =>
      widget.accounts ?? RemoteStorageAccounts.instance;
  var _adding = false;

  Future<void> _addAccount() async {
    setState(() => _adding = true);
    try {
      final account = await showStorageAccountEditor(
        context,
        accounts: _storage,
      );
      if (mounted && account != null) widget.onChanged(account, const []);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.accountId == null
        ? null
        : _storage.account(widget.accountId!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(labelText: 'Cloud Storage Account'.tl),
          child: widget.accountLocked
              ? Text(account?.name ?? 'Account unavailable'.tl)
              : DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: account?.id ?? (widget.allowNone ? '' : null),
                    hint: Text('Select an account'.tl),
                    items: [
                      if (widget.allowNone)
                        DropdownMenuItem(
                          value: '',
                          child: Text('Not Configured'.tl),
                        ),
                      for (final value in _storage.accounts)
                        DropdownMenuItem(
                          value: value.id,
                          child: Text(value.name),
                        ),
                      DropdownMenuItem(
                        value: '__add_account__',
                        child: Text('Add Cloud Storage Account'.tl),
                      ),
                    ],
                    onChanged: _adding
                        ? null
                        : (value) {
                            if (value == '__add_account__') {
                              _addAccount();
                            } else if (value != widget.accountId) {
                              widget.onChanged(
                                value == null || value.isEmpty
                                    ? null
                                    : _storage.account(value),
                                const [],
                              );
                            }
                          },
                  ),
                ),
        ),
        if (account?.statusMessage != null)
          Text(
            account!.statusMessage!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined),
          title: Text(
            widget.multiSelect
                ? 'Recognition Directories'.tl
                : 'Remote Directory'.tl,
          ),
          subtitle: Text(
            widget.directories.isEmpty
                ? 'None selected'.tl
                : widget.directories.join('\n'),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: account == null || _adding
              ? null
              : () async {
                  final store = _storage.storeFor(account.id);
                  final selected = await Navigator.of(context)
                      .push<List<String>>(
                        MaterialPageRoute(
                          builder: (_) => RemoteDirectoryPicker(
                            store: store,
                            initialDirectories: widget.directories,
                            multiSelect: widget.multiSelect,
                            disposeStore: true,
                            onDisposeStore: _storage.release,
                          ),
                        ),
                      );
                  if (mounted && selected != null) {
                    widget.onChanged(account, selected);
                  }
                },
        ),
      ],
    );
  }
}
