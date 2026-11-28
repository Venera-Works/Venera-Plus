import 'package:flutter/material.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/remote_library/remote_library.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

enum ContentSourceSection { websites, cloudLibraries }

class ContentSourcesPage extends StatefulWidget {
  const ContentSourcesPage({
    super.key,
    this.initialAccountId,
    this.initialSection = ContentSourceSection.websites,
  });

  final String? initialAccountId;
  final ContentSourceSection initialSection;

  @override
  State<ContentSourcesPage> createState() => _ContentSourcesPageState();
}

class _ContentSourcesPageState extends State<ContentSourcesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      initialIndex: widget.initialAccountId == null
          ? widget.initialSection.index
          : ContentSourceSection.cloudLibraries.index,
      vsync: this,
    );
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

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _addSource() async {
    if (_tabController.index == 0) {
      await showAddWebsiteSource(context);
    } else {
      await showRemoteLibraryEditor(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final storage = RemoteStorageAccounts.instance;
    return Scaffold(
      appBar: Appbar(
        title: Text('Sources'.tl),
        leading: Navigator.of(context).canPop()
            ? null
            : AppbarLeadingScope.maybeOf(context) ?? const SizedBox(),
        actions: [
          TextButton.icon(
            style: actionButtonStyle,
            key: const Key('add-content-source'),
            onPressed: _addSource,
            icon: const Icon(Icons.add),
            label: Text('Add'.tl),
          ),
        ],
      ),
      body: Column(
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([
              ComicSourceManager(),
              storage,
              appdata.settings,
            ]),
            builder: (context, _) {
              final websiteCount = ComicSource.all()
                  .where((source) => source.filePath.isNotEmpty)
                  .length;
              return Material(
                child: AppTabBar(
                  key: const PageStorageKey('content_sources_tabs'),
                  controller: _tabController,
                  tabs: [
                    Tab(text: '${'Website Sources'.tl} · $websiteCount'),
                    Tab(
                      text:
                          '${'Cloud Comic Libraries'.tl} · ${storage.libraries.length}',
                    ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                SmoothCustomScrollView(
                  key: PageStorageKey('content_sources_websites'),
                  slivers: [
                    ComicSourcesSliverList(),
                    SliverPadding(padding: EdgeInsets.only(bottom: 16)),
                  ],
                ),
                SmoothCustomScrollView(
                  key: PageStorageKey('content_sources_remote_libraries'),
                  slivers: [
                    RemoteLibrariesSliver(),
                    SliverPadding(padding: EdgeInsets.only(bottom: 16)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
