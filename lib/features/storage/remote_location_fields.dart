import 'package:flutter/material.dart';
import 'package:venera_plus/foundation/context.dart';
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
    this.accountErrorText,
    this.directoryErrorText,
  });

  final String? accountId;
  final List<String> directories;
  final void Function(StorageAccount? account, List<String> directories)
  onChanged;
  final bool multiSelect;
  final bool accountLocked;
  final bool allowNone;
  final RemoteStorageAccounts? accounts;
  final String? accountErrorText;
  final String? directoryErrorText;

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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final errorStyle = theme.textTheme.bodySmall?.copyWith(color: colors.error);
    final accountError = widget.accountErrorText;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(10));
    final account = widget.accountId == null
        ? null
        : _storage.account(widget.accountId!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            // 描边与下拉按钮同宽，浮动标签仍使用输入框的默认左侧位置。
            Positioned.fill(
              child: InputDecorator(
                expands: true,
                decoration: InputDecoration(
                  labelText: 'Cloud Storage Account'.tl,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  border: border,
                  enabledBorder: accountError == null
                      ? null
                      : border.copyWith(
                          borderSide: BorderSide(color: colors.error),
                        ),
                  floatingLabelStyle: accountError == null
                      ? null
                      : TextStyle(color: colors.error),
                ),
                child: const SizedBox.shrink(),
              ),
            ),
            if (widget.accountLocked)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(account?.name ?? 'Account unavailable'.tl),
              )
            else
              ButtonTheme(
                alignedDropdown: true,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    isDense: true,
                    borderRadius: BorderRadius.circular(12),
                    dropdownColor: colors.surfaceContainerHigh,
                    menuMaxHeight: 320,
                    padding: const EdgeInsetsDirectional.fromSTEB(0, 6, 8, 6),
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
                          child: Text(
                            value.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      DropdownMenuItem(
                        value: '__add_account__',
                        child: Row(
                          children: [
                            Icon(Icons.add, size: 18, color: colors.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Add Cloud Storage Account'.tl,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: colors.primary),
                              ),
                            ),
                          ],
                        ),
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
          ],
        ),
        if (accountError != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, top: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(accountError, style: errorStyle),
            ),
          ),
        if (account?.statusMessage case final message?) ...[
          const SizedBox(height: 8),
          Text(message.tl, style: errorStyle),
        ],
        const SizedBox(height: 12),
        Material(
          color: colors.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: widget.directoryErrorText == null
                  ? colors.outlineVariant
                  : colors.error,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
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
            trailing: const Icon(Icons.arrow_right),
            enabled: account != null && !_adding,
            onTap: account == null || _adding
                ? null
                : () async {
                    final store = _storage.storeFor(account.id);
                    final selected = await context.to<List<String>>(
                      () => RemoteDirectoryPicker(
                        store: store,
                        initialDirectories: widget.directories,
                        multiSelect: widget.multiSelect,
                        disposeStore: true,
                        onDisposeStore: _storage.release,
                      ),
                    );
                    if (mounted && selected != null) {
                      widget.onChanged(account, selected);
                    }
                  },
          ),
        ),
        if (widget.directoryErrorText case final error?) ...[
          const SizedBox(height: 8),
          Text(error, style: errorStyle),
        ],
      ],
    );
  }
}
