import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

/// Browser shared by library (multi-select) and single-target sync/backup UI.
class RemoteDirectoryPicker extends StatefulWidget {
  const RemoteDirectoryPicker({
    super.key,
    required this.store,
    this.initialDirectories = const [],
    this.multiSelect = false,
    this.disposeStore = false,
    this.onDisposeStore,
  });
  final RemoteFileStore store;
  final List<String> initialDirectories;
  final bool multiSelect;
  final bool disposeStore;
  final void Function(RemoteFileStore store)? onDisposeStore;
  @override
  State<RemoteDirectoryPicker> createState() => _RemoteDirectoryPickerState();
}

class _RemoteDirectoryPickerState extends State<RemoteDirectoryPicker> {
  var _directory = '/';
  late final List<String> _selected = normalizeRemoteDirectories(
    widget.multiSelect
        ? widget.initialDirectories
        : widget.initialDirectories.take(1),
  );
  late Future<List<RemoteEntry>> _entries;
  @override
  void initState() {
    super.initState();
    _entries = widget.store.list(_directory);
  }

  @override
  void dispose() {
    if (widget.disposeStore) {
      widget.store.cancelAll();
      widget.onDisposeStore?.call(widget.store);
    }
    super.dispose();
  }

  void _open(String path, {bool refresh = false}) => setState(() {
    _directory = normalizeRemoteDirectory(path);
    _entries = widget.store.list(_directory, refresh: refresh);
  });
  void _select(String path) => setState(() {
    if (_selected.contains(path)) {
      _selected.remove(path);
    } else {
      if (!widget.multiSelect) _selected.clear();
      _selected.add(path);
    }
  });

  Widget _folderTile(String path, String name, {bool current = false}) {
    final normalizedPath = normalizeRemoteDirectory(path);
    final selected = _selected.contains(normalizedPath);
    return ListTile(
      leading: Icon(current ? Icons.folder_open : Icons.folder_outlined),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: current
          ? Text(normalizedPath == '/' ? 'Root directory'.tl : normalizedPath)
          : null,
      selected: selected,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primaryContainer.withValues(alpha: 0.35),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!current) const Icon(Icons.chevron_right),
          Checkbox(value: selected, onChanged: (_) => _select(normalizedPath)),
        ],
      ),
      onTap: current
          ? () => _select(normalizedPath)
          : () => _open(normalizedPath),
    );
  }

  Widget _folderState({
    required IconData icon,
    required Color color,
    required String message,
    VoidCallback? retry,
  }) => SliverFillRemaining(
    hasScrollBody: false,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 36),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
            if (retry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: actionButtonStyle,
                onPressed: retry,
                icon: const Icon(Icons.refresh),
                label: Text('Retry'.tl),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Appbar(title: Text('Select Remote Directory'.tl)),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              'Current path: @path'.tlParams({'path': _directory}),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const Divider(height: 1),
          _folderTile(_directory, 'Current folder'.tl, current: true),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<RemoteEntry>>(
              future: _entries,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final colors = Theme.of(context).colorScheme;
                final directories =
                    snapshot.data
                        ?.where((entry) => entry.isDirectory)
                        .toList() ??
                    const <RemoteEntry>[];
                return CustomScrollView(
                  slivers: [
                    if (_directory != '/')
                      SliverToBoxAdapter(
                        child: ListTile(
                          leading: const Icon(Icons.arrow_upward),
                          title: Text('Parent directory'.tl),
                          onTap: () {
                            final parts = _directory.split('/')
                              ..removeWhere((item) => item.isEmpty);
                            parts.removeLast();
                            _open(parts.isEmpty ? '/' : '/${parts.join('/')}/');
                          },
                        ),
                      ),
                    if (snapshot.hasError)
                      _folderState(
                        icon: Icons.error_outline,
                        color: colors.error,
                        message: '${snapshot.error}',
                        retry: () => _open(_directory, refresh: true),
                      )
                    else if (directories.isEmpty)
                      _folderState(
                        icon: Icons.folder_outlined,
                        color: colors.onSurfaceVariant,
                        message: 'No subfolders'.tl,
                      )
                    else
                      SliverList.builder(
                        itemCount: directories.length,
                        itemBuilder: (context, index) {
                          final entry = directories[index];
                          return _folderTile(entry.path, entry.name);
                        },
                      ),
                  ],
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '@count folders selected'.tlParams({
                      'count': _selected.length,
                    }),
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  style: actionButtonStyle,
                  onPressed: !widget.multiSelect && _selected.isEmpty
                      ? null
                      : () =>
                            Navigator.pop(context, List<String>.of(_selected)),
                  child: Text('Done'.tl),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
