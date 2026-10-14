import 'package:flutter/material.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/storage/remote_directory_picker.dart';
import 'package:venera_plus/features/webdav_library/webdav_library_source.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

/// Management page for independent remote comic libraries.  Account management
/// remains in Storage & Sync; this page only binds an account to recognition
/// directories and never deletes remote files or cached history.
class RemoteLibrarySettingsPage extends StatefulWidget {
  const RemoteLibrarySettingsPage({super.key});

  @override
  State<RemoteLibrarySettingsPage> createState() =>
      _RemoteLibrarySettingsPageState();
}

class _RemoteLibrarySettingsPageState extends State<RemoteLibrarySettingsPage> {
  final _storage = RemoteStorageAccounts.instance;

  bool _isPageTitleUsedElsewhere(String title, RemoteLibrary library) =>
      _storage.libraries.any(
        (item) => item.id != library.id && item.name == title,
      ) ||
      ComicSourceManager().all().any(
        (source) =>
            source.key != library.sourceKey &&
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
    if (_isPageTitleUsedElsewhere(library.name, library)) return;
    final pages = _explorePages()..removeWhere((item) => item == library.name);
    appdata.settings['explore_pages'] = pages;
  }

  Future<void> _edit(RemoteLibrary? initial) async {
    final accounts = _storage.accounts;
    if (accounts.isEmpty) return;
    var name = initial?.name ?? '';
    final existingAccount = initial == null
        ? null
        : _storage.account(initial.accountId);
    var account = existingAccount ?? accounts.first;
    var accountId = account.id;
    var directories = initial?.directories ?? const <String>[];
    var autoRefresh = initial?.autoRefresh ?? true;
    var refreshIntervalMinutes = initial?.refreshIntervalMinutes ?? 360;
    final result = await showDialog<RemoteLibrary>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            initial == null ? 'Add Comic Library'.tl : 'Edit Comic Library'.tl,
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: name,
                  onChanged: (value) => name = value,
                  decoration: InputDecoration(labelText: 'Name'.tl),
                ),
                if (initial == null)
                  DropdownButtonFormField<String>(
                    initialValue: accountId,
                    decoration: InputDecoration(
                      labelText: 'Storage Account'.tl,
                    ),
                    items: [
                      for (final value in accounts)
                        DropdownMenuItem(
                          value: value.id,
                          child: Text(value.name),
                        ),
                    ],
                    onChanged: (value) => setDialogState(() {
                      accountId = value!;
                      account = accounts.firstWhere((item) => item.id == value);
                      directories = const [];
                    }),
                  )
                else
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Storage Account'.tl,
                    ),
                    child: Text(existingAccount?.name ?? initial.accountId),
                  ),
                ListTile(
                  title: Text('Recognition Directories'.tl),
                  subtitle: Text(
                    directories.isEmpty
                        ? 'None selected'.tl
                        : directories.join('\n'),
                  ),
                  onTap:
                      (initial != null && existingAccount == null) ||
                          !account.isConfigured
                      ? null
                      : () async {
                          final store = _storage.storeFor(account.id);
                          final selected = await Navigator.of(context)
                              .push<List<String>>(
                                MaterialPageRoute(
                                  builder: (_) => RemoteDirectoryPicker(
                                    store: store,
                                    initialDirectories: directories,
                                    multiSelect: true,
                                    disposeStore: true,
                                    onDisposeStore: _storage.release,
                                  ),
                                ),
                              );
                          if (selected != null) {
                            setDialogState(() => directories = selected);
                          }
                        },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Automatic library updates'.tl),
                  value: autoRefresh,
                  onChanged: (value) =>
                      setDialogState(() => autoRefresh = value),
                ),
                if (autoRefresh)
                  DropdownButtonFormField<int>(
                    initialValue: refreshIntervalMinutes,
                    decoration: InputDecoration(
                      labelText: 'Update interval'.tl,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 15,
                        child: Text('Every 15 minutes'.tl),
                      ),
                      DropdownMenuItem(value: 60, child: Text('Every hour'.tl)),
                      DropdownMenuItem(
                        value: 360,
                        child: Text('Every 6 hours'.tl),
                      ),
                      DropdownMenuItem(
                        value: 1440,
                        child: Text('Every day'.tl),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => refreshIntervalMinutes = value);
                      }
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () {
                final trimmed = name.trim();
                if (trimmed.isEmpty || directories.isEmpty) return;
                final library = initial == null
                    ? RemoteComicLibraryRegistry.create(
                        accountId: account.id,
                        directories: directories,
                        name: trimmed,
                      ).copyWith(
                        autoRefresh: autoRefresh,
                        refreshIntervalMinutes: refreshIntervalMinutes,
                      )
                    : initial.copyWith(
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
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final libraries = _storage.libraries;
    return Scaffold(
      appBar: AppBar(title: Text('Comic Libraries'.tl)),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(null),
        child: const Icon(Icons.add),
      ),
      body: ListView.builder(
        itemCount: libraries.length,
        itemBuilder: (context, index) {
          final library = libraries[index];
          final account = _storage.account(library.accountId);
          final engine = WebDavLibraryEngines.find(library.sourceKey);
          final failures = engine?.failedRoots ?? const <String, String>{};
          return ListTile(
            title: Text(library.name),
            subtitle: Text(
              '${account?.name ?? library.accountId}\n'
              '${library.directories.join('\n')}'
              '${failures.isEmpty ? '' : '\n${'Failed'.tl}: ${failures.keys.join(', ')}'}',
            ),
            isThreeLine: library.directories.length > 1 || failures.isNotEmpty,
            onTap: () => _edit(library),
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: engine == null
                      ? null
                      : () async {
                          await engine.synchronize(force: true);
                          if (mounted) setState(() {});
                        },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    _removePageVisibility(library);
                    await _storage.removeLibrary(library.id);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
