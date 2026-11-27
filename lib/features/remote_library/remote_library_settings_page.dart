import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/message.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/storage/storage.dart';
import 'package:venera_plus/features/remote_library/remote_library_engine.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

final _storage = RemoteStorageAccounts.instance;

bool _isPageTitleUsedElsewhere(String title, RemoteLibrary? library) =>
    _storage.libraries.any(
      (item) => item.id != library?.id && item.name == title,
    ) ||
    ComicSourceManager().all().any(
      (source) =>
          source.key != library?.sourceKey &&
          source.explorePages.any((page) => page.title == title),
    );

List<String> _explorePages() =>
    (appdata.settings['explore_pages'] as List? ?? const [])
        .whereType<String>()
        .toList();

void _updatePageVisibility(RemoteLibrary library, RemoteLibrary? previous) {
  final pages = _explorePages();
  if (previous == null) {
    if (!pages.contains(library.name)) pages.add(library.name);
    appdata.settings['explore_pages'] = pages;
    return;
  }
  if (previous.name == library.name || !pages.contains(previous.name)) return;
  final index = pages.indexOf(previous.name);
  final oldTitleIsShared = _isPageTitleUsedElsewhere(previous.name, previous);
  final newTitleIsEnabled = pages.contains(library.name);
  if (!newTitleIsEnabled) {
    if (oldTitleIsShared) {
      pages.insert(index, library.name);
    } else {
      pages[index] = library.name;
    }
  } else if (!oldTitleIsShared) {
    pages.removeAt(index);
  }
  appdata.settings['explore_pages'] = pages;
}

void _removePageVisibility(RemoteLibrary library) {
  for (final setting in ['searchSources', 'disabledLibrarySearchSources']) {
    final keys = appdata.settings[setting] as List?;
    if (keys != null && keys.contains(library.sourceKey)) {
      appdata.settings[setting] = keys
          .where((key) => key != library.sourceKey)
          .toList();
    }
  }
  if (_isPageTitleUsedElsewhere(library.name, library)) return;
  final pages = _explorePages()..removeWhere((item) => item == library.name);
  appdata.settings['explore_pages'] = pages;
}

Future<void> showRemoteLibraryEditor(
  BuildContext context, {
  RemoteLibrary? initial,
  String? initialAccountId,
}) async {
  var name = initial?.name ?? '';
  final existingAccount = initial == null
      ? null
      : _storage.account(initial.accountId);
  final needsRebinding = initial != null && existingAccount == null;
  var accountLocked = existingAccount != null;
  StorageAccount? account =
      existingAccount ??
      (initial == null
          ? _storage.account(initialAccountId ?? '') ??
                _storage.accounts.firstOrNull
          : null);
  var directories = initial?.directories ?? const <String>[];
  var autoRefresh =
      initial?.autoRefresh ?? RemoteLibrary.defaultAutoRefresh(account);
  var autoRefreshChosen = initial != null;
  var refreshIntervalMinutes = initial?.refreshIntervalMinutes ?? 360;
  var showValidation = false;
  String? nameError() {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Cannot be empty'.tl;
    if (trimmed != initial?.name &&
        _isPageTitleUsedElsewhere(trimmed, initial)) {
      return 'Choose a unique name for this library.'.tl;
    }
    return null;
  }

  const intervals = {
    15: 'Every 15 minutes',
    60: 'Every hour',
    360: 'Every 6 hours',
    1440: 'Every day',
  };
  final result = await showDialog<RemoteLibrary>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => ContentDialog(
        title: initial == null
            ? 'Add Comic Library'.tl
            : 'Edit Comic Library'.tl,
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                initialValue: name,
                onChanged: (value) {
                  name = value;
                  if (showValidation) setDialogState(() {});
                },
                decoration: InputDecoration(
                  labelText: 'Name'.tl,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  errorText: showValidation ? nameError() : null,
                ),
              ),
              const SizedBox(height: 12),
              RemoteLocationFields(
                accountId: account?.id,
                directories: directories,
                multiSelect: true,
                accountLocked: accountLocked,
                accountErrorText: account != null
                    ? null
                    : needsRebinding
                    ? 'The original cloud storage account is missing. Select an account and choose the folders again.'
                          .tl
                    : showValidation
                    ? 'Select an account'.tl
                    : null,
                directoryErrorText: showValidation && directories.isEmpty
                    ? 'Choose Folder'.tl
                    : null,
                onChanged: (value, selected) => setDialogState(() {
                  account = value;
                  directories = selected;
                  if (!autoRefreshChosen) {
                    autoRefresh = RemoteLibrary.defaultAutoRefresh(value);
                  }
                }),
              ),
              if (accountLocked)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    style: actionButtonStyle,
                    onPressed: () =>
                        setDialogState(() => accountLocked = false),
                    child: Text('Rebind account'.tl),
                  ),
                ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Automatic library updates'.tl),
                value: autoRefresh,
                onChanged: (value) => setDialogState(() {
                  autoRefresh = value;
                  autoRefreshChosen = true;
                }),
              ),
              if (autoRefresh) ...[
                const SizedBox(height: 12),
                ButtonTheme(
                  alignedDropdown: true,
                  child: DropdownButtonFormField<int>(
                    isExpanded: true,
                    isDense: true,
                    initialValue: refreshIntervalMinutes,
                    borderRadius: BorderRadius.circular(12),
                    dropdownColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHigh,
                    menuMaxHeight: 320,
                    decoration: InputDecoration(
                      labelText: 'Update interval'.tl,
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    items: [
                      for (final interval in intervals.entries)
                        DropdownMenuItem(
                          value: interval.key,
                          child: Text(interval.value.tl),
                        ),
                      if (!intervals.containsKey(refreshIntervalMinutes))
                        DropdownMenuItem(
                          value: refreshIntervalMinutes,
                          child: Text(
                            '@minutes min'.tlParams({
                              'minutes': '$refreshIntervalMinutes',
                            }),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => refreshIntervalMinutes = value);
                      }
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            style: actionButtonStyle,
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'.tl),
          ),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () {
              final trimmed = name.trim();
              final selectedAccount = account;
              if (nameError() != null ||
                  directories.isEmpty ||
                  selectedAccount == null) {
                setDialogState(() => showValidation = true);
                return;
              }
              final library = initial == null
                  ? RemoteComicLibraryRegistry.create(
                      accountId: selectedAccount.id,
                      directories: directories,
                      name: trimmed,
                    ).copyWith(
                      autoRefresh: autoRefresh,
                      refreshIntervalMinutes: refreshIntervalMinutes,
                    )
                  : RemoteLibrary(
                      id: initial.id,
                      sourceKey: initial.sourceKey,
                      accountId: selectedAccount.id,
                      name: trimmed,
                      directories: directories,
                      autoRefresh: autoRefresh,
                      refreshIntervalMinutes: refreshIntervalMinutes,
                    );
              Navigator.pop(context, library);
            },
            child: Text('Save'.tl),
          ),
        ],
      ),
    ),
  );
  if (result == null) return;
  _updatePageVisibility(result, initial);
  await _storage.saveLibrary(result);
}

class RemoteLibrariesSliver extends StatefulWidget {
  const RemoteLibrariesSliver({super.key});

  @override
  State<RemoteLibrariesSliver> createState() => _RemoteLibrariesSliverState();
}

class _RemoteLibrariesSliverState extends State<RemoteLibrariesSliver> {
  final _refreshing = <String>{};
  final _refreshErrors = <String, String>{};

  Future<void> _refresh(
    String libraryId,
    RemoteLibraryEngine engine, {
    required bool deep,
  }) async {
    if (_refreshing.contains(libraryId) || engine.syncStatus.value.isSyncing) {
      return;
    }
    setState(() {
      _refreshing.add(libraryId);
      _refreshErrors.remove(libraryId);
    });
    try {
      final result = await engine.synchronize(force: true, deep: deep);
      if (result.error && engine.syncStatus.value.errorMessage == null) {
        _refreshErrors[libraryId] = result.errorMessage ?? 'Failed';
      }
    } finally {
      _refreshing.remove(libraryId);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_storage, ComicSourceManager()]),
      builder: (context, _) {
        final libraries = _storage.libraries;
        if (libraries.isEmpty) {
          final theme = Theme.of(context);
          final color = theme.colorScheme.onSurfaceVariant;
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_outlined, size: 40, color: color),
                    const SizedBox(height: 12),
                    Text(
                      'No Cloud Comic Libraries'.tl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Add a cloud comic library to browse comics from your cloud storage.'
                          .tl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return SliverList.builder(
          itemCount: libraries.length,
          itemBuilder: (context, index) {
            final library = libraries[index];
            final account = _storage.account(library.accountId);
            final engine = RemoteLibraryEngines.find(library.sourceKey);
            Widget buildTile(BuildContext context) {
              final status = engine?.syncStatus.value;
              final refreshing =
                  (status?.isSyncing ?? false) ||
                  _refreshing.contains(library.id);
              final failures = engine?.failedRoots ?? const <String, String>{};
              final error = status?.errorMessage ?? _refreshErrors[library.id];
              return ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(library.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${account?.name ?? library.accountId}\n${library.directories.join('\n')}',
                    ),
                    if (refreshing) ...[
                      const SizedBox(height: 4),
                      const LinearProgressIndicator(),
                      Text(engine?.statusMessage ?? 'Syncing Data'.tl),
                    ] else if (error != null || failures.isNotEmpty)
                      Text(
                        [
                          if (failures.isNotEmpty) engine!.statusMessage!,
                          if (error != null) error.tl,
                        ].join('\n'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
                isThreeLine:
                    library.directories.length > 1 ||
                    refreshing ||
                    error != null ||
                    failures.isNotEmpty,
                onTap: () => showRemoteLibraryEditor(context, initial: library),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Refresh'.tl,
                      icon: const Icon(Icons.refresh),
                      onPressed: engine == null || refreshing
                          ? null
                          : () => _refresh(library.id, engine, deep: false),
                    ),
                    IconButton(
                      tooltip: 'Full refresh'.tl,
                      icon: const Icon(Icons.sync),
                      onPressed: engine == null || refreshing
                          ? null
                          : () => _refresh(library.id, engine, deep: true),
                    ),
                    IconButton(
                      tooltip: 'Delete'.tl,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => showConfirmDialog(
                        context: context,
                        title: 'Delete'.tl,
                        content: library.name,
                        confirmText: 'Delete',
                        btnColor: Theme.of(context).colorScheme.error,
                        onConfirm: () async {
                          _removePageVisibility(library);
                          await _storage.removeLibrary(library.id);
                        },
                      ),
                    ),
                  ],
                ),
              );
            }

            return engine == null
                ? buildTile(context)
                : ListenableBuilder(
                    key: ValueKey(library.id),
                    listenable: engine.syncStatus,
                    builder: (context, _) => buildTile(context),
                  );
          },
        );
      },
    );
  }
}
