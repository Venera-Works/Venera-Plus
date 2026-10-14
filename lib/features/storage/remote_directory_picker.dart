import 'package:flutter/material.dart';
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
    widget.initialDirectories,
  );
  Future<List<RemoteEntry>>? _entries;
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

  void _open(String path) => setState(() {
    _directory = normalizeRemoteDirectory(path);
    _entries = widget.store.list(_directory);
  });
  void _select() {
    if (widget.multiSelect) {
      setState(() {
        if (_selected.contains(_directory)) {
          _selected.remove(_directory);
        } else {
          _selected.add(_directory);
        }
      });
    } else {
      Navigator.pop(context, [_directory]);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Select Remote Directory'.tl),
      actions: [
        if (widget.multiSelect)
          TextButton(
            onPressed: () => Navigator.pop(context, _selected),
            child: Text('Done'.tl),
          ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: _select,
      child: Icon(
        widget.multiSelect && _selected.contains(_directory)
            ? Icons.remove
            : Icons.check,
      ),
    ),
    body: FutureBuilder<List<RemoteEntry>>(
      future: _entries,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          children: [
            if (_directory != '/')
              ListTile(
                leading: const Icon(Icons.arrow_upward),
                title: Text('..'),
                onTap: () {
                  final parts = _directory.split('/')
                    ..removeWhere((item) => item.isEmpty);
                  parts.removeLast();
                  _open(parts.isEmpty ? '/' : '/${parts.join('/')}/');
                },
              ),
            for (final entry in snapshot.data!.where(
              (item) => item.isDirectory,
            ))
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(entry.name),
                onTap: () => _open(entry.path),
              ),
          ],
        );
      },
    ),
  );
}
