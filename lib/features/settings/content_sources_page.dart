import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/webdav_library/webdav_library.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

import 'setting_components.dart';

class ContentSourcesPage extends StatefulWidget {
  const ContentSourcesPage({super.key, this.initialAccountId});

  final String? initialAccountId;

  @override
  State<ContentSourcesPage> createState() => _ContentSourcesPageState();
}

class _ContentSourcesPageState extends State<ContentSourcesPage> {
  @override
  void initState() {
    super.initState();
    if (widget.initialAccountId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showRemoteLibraryEditor(
            context,
            initialAccountId: widget.initialAccountId,
          );
        }
      });
    }
  }

  Future<void> _addSource() async {
    final isRemoteLibrary = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Add Content Source'.tl),
        children: [
          SimpleDialogOption(
            key: const Key('add-website-source'),
            onPressed: () => Navigator.pop(context, false),
            child: ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: Text('Website Source'.tl),
              subtitle: Text('Install from a repository, link or file.'.tl),
            ),
          ),
          SimpleDialogOption(
            key: const Key('add-remote-library'),
            onPressed: () => Navigator.pop(context, true),
            child: ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text('Remote Comic Library'.tl),
              subtitle: Text(
                'Choose a cloud account and comic directories.'.tl,
              ),
            ),
          ),
        ],
      ),
    );
    if (isRemoteLibrary == null || !mounted) return;
    if (isRemoteLibrary) {
      await showRemoteLibraryEditor(context);
    } else {
      await showAddWebsiteSource(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final storage = RemoteStorageAccounts.instance;
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([
          ComicSourceManager(),
          storage,
          appdata.settings,
        ]),
        builder: (context, _) {
          final websiteCount = ComicSource.all()
              .where((source) => source.filePath.isNotEmpty)
              .length;
          return SmoothCustomScrollView(
            slivers: [
              SliverAppbar(
                title: Text('Content Sources'.tl),
                actions: [
                  TextButton.icon(
                    key: const Key('add-content-source'),
                    onPressed: _addSource,
                    icon: const Icon(Icons.add),
                    label: Text('Add'.tl),
                  ),
                ],
              ),
              SettingPartTitle(
                title: '${'Website Sources'.tl} · $websiteCount',
                icon: Icons.extension_outlined,
              ),
              const ComicSourcesSliverList(),
              SettingPartTitle(
                title:
                    '${'Remote Comic Libraries'.tl} · ${storage.libraries.length}',
                icon: Icons.folder_open_outlined,
              ),
              const RemoteLibrariesSliver(),
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 16,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
