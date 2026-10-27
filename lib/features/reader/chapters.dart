import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/scroll.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';
import 'package:venera_plus/foundation/widget_utils.dart';

class ReaderChaptersView extends StatefulWidget {
  const ReaderChaptersView(this.reader, {super.key});

  final ReaderState reader;

  @override
  State<ReaderChaptersView> createState() => ReaderChaptersViewState();
}

class ReaderChaptersViewState extends State<ReaderChaptersView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _scrollControllers = <String, ScrollController>{};
  late List<ImageFavorite> _bookmarks;
  String? _selectedGroup;
  bool desc = false;
  bool _openingDownload = false;
  int _activeTab = 0;

  ComicChapters? get chapters => widget.reader.widget.chapters;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_onTabChanged);
    var start = 0;
    if (chapters?.isGrouped == true) {
      for (final group in chapters!.groups) {
        final count = chapters!.getGroup(group).length;
        if (widget.reader.chapter > start &&
            widget.reader.chapter <= start + count) {
          _selectedGroup = group;
          break;
        }
        start += count;
      }
      _selectedGroup ??= chapters!.groups.firstOrNull;
    }
    _readBookmarks();
    ImageFavoriteManager().addListener(_onBookmarksChanged);
    LocalManager().addListener(_onLocalChanged);
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(_onBookmarksChanged);
    LocalManager().removeListener(_onLocalChanged);
    _tabs.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onTabChanged() {
    if (_activeTab != _tabs.index) setState(() => _activeTab = _tabs.index);
  }

  void _readBookmarks() {
    _bookmarks =
        ImageFavoriteManager()
            .find(widget.reader.cid, widget.reader.type.sourceKey)
            ?.bookmarks
            .toList() ??
        [];
  }

  void _onBookmarksChanged() {
    setState(_readBookmarks);
  }

  void _onLocalChanged() => setState(() {});

  Future<void> _download() async {
    final reader = widget.reader;
    final source = ComicSource.find(reader.type.sourceKey);
    if (source == null || _openingDownload) return;
    setState(() => _openingDownload = true);
    try {
      final result = await source.loadComicInfoForReading(reader.cid);
      if (!mounted) return;
      setState(() => _openingDownload = false);
      if (result.error) {
        context.showMessage(message: result.errorMessage ?? 'Error'.tl);
        return;
      }
      await downloadComicChapters(context, result.data);
    } catch (error, stackTrace) {
      Log.error('Reader download', error, stackTrace);
      if (mounted) context.showMessage(message: error.toString());
    } finally {
      if (mounted && _openingDownload) {
        setState(() => _openingDownload = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canDownload =
        ComicSource.find(widget.reader.type.sourceKey)?.loadComicPages != null;
    return Scaffold(
      appBar: Appbar(
        style: AppbarStyle.shadow,
        title: TabBar(
          controller: _tabs,
          dividerColor: Colors.transparent,
          labelColor: context.colorScheme.primary,
          unselectedLabelColor: context.colorScheme.onSurfaceVariant,
          indicatorColor: context.colorScheme.primary,
          indicatorWeight: 3,
          labelPadding: const EdgeInsets.symmetric(horizontal: 4),
          labelStyle: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          tabs: [
            Tab(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Chapters'.tl),
              ),
            ),
            Tab(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Bookmarks'.tl),
              ),
            ),
          ],
        ),
        actions: [
          Visibility(
            visible: _activeTab == 0,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: IconButton(
              tooltip: desc ? 'Descending'.tl : 'Ascending'.tl,
              onPressed: () => setState(() => desc = !desc),
              icon: Icon(
                desc ? Icons.arrow_downward : Icons.arrow_upward,
                size: 18,
              ),
            ),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildChapters(), _buildBookmarks()],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: canDownload && _activeTab == 0
          ? FloatingActionButton(
              tooltip: 'Download'.tl,
              onPressed: _openingDownload ? null : _download,
              child: _openingDownload
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
            )
          : null,
    );
  }

  Widget _buildChapters() {
    final all = chapters?.isGrouped == true
        ? [
            for (final group in chapters!.groups)
              ...chapters!.getGroup(group).entries,
          ]
        : chapters?.allChapters.entries.toList() ??
              <MapEntry<String, String>>[];
    var groupStart = 0;
    if (chapters?.isGrouped == true) {
      for (final group in chapters!.groups) {
        if (group == _selectedGroup) break;
        groupStart += chapters!.getGroup(group).length;
      }
    }
    final entries = chapters?.isGrouped == true && _selectedGroup != null
        ? chapters!.getGroup(_selectedGroup!).entries.toList()
        : all;
    final groupKey = _selectedGroup ?? '';
    final controller = _scrollControllers.putIfAbsent(groupKey, () {
      final current = widget.reader.chapter - groupStart - 1;
      return ScrollController(
        initialScrollOffset: ((current - 1) * 48.0).clamp(0, double.infinity),
      );
    });
    final downloaded =
        LocalManager()
            .find(widget.reader.cid, widget.reader.type)
            ?.downloadedChapters ??
        [];
    return Column(
      children: [
        if (chapters?.isGrouped == true)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                for (final group in chapters!.groups)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(group),
                      selected: group == _selectedGroup,
                      onSelected: (_) => setState(() => _selectedGroup = group),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: SmoothCustomScrollView(
            key: PageStorageKey('reader-chapters-$groupKey'),
            controller: controller,
            slivers: [
              if (chapters == null)
                SliverToBoxAdapter(
                  child: _ChapterListTile(
                    title: 'Full comic'.tl,
                    isActive: true,
                    isDownloaded:
                        widget.reader.type == ComicType.local ||
                        downloaded.isNotEmpty,
                    onTap: () {
                      widget.reader.toPage(
                        1,
                        source: ReadingNavigationSource.userSeek,
                      );
                      context.pop();
                    },
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final entry =
                        entries[desc ? entries.length - 1 - index : index];
                    final chapter =
                        groupStart +
                        (desc ? entries.length - 1 - index : index) +
                        1;
                    return _ChapterListTile(
                      title: entry.value,
                      isActive: widget.reader.chapter == chapter,
                      isDownloaded: downloaded.contains(entry.key),
                      onTap: () {
                        widget.reader.toChapter(
                          chapter,
                          source: ReadingNavigationSource.userSeek,
                        );
                        context.pop();
                      },
                    );
                  }, childCount: entries.length),
                ),
              SliverPadding(
                padding: EdgeInsets.only(bottom: 96 + context.padding.bottom),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBookmarks() {
    if (_bookmarks.isEmpty) return Center(child: Text('No bookmarks'.tl));
    return GridView.builder(
      key: const PageStorageKey('reader-bookmarks'),
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + context.padding.bottom),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.65,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _bookmarks.length,
      itemBuilder: (context, index) {
        final bookmark = _bookmarks[index];
        return Material(
          color: context.colorScheme.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              if (widget.reader.goToBookmark(bookmark)) {
                context.pop();
              } else {
                context.showMessage(message: 'Chapter not found'.tl);
              }
            },
            child: Column(
              children: [
                Expanded(
                  child: Image(
                    image: ResizeImage.resizeIfNeeded(
                      (180 * MediaQuery.devicePixelRatioOf(context)).round(),
                      null,
                      ImageFavoritesProvider(bookmark),
                    ),
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      Text(
                        bookmark.epName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'P${bookmark.page}',
                        style: TextStyle(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ChapterListTile extends StatelessWidget {
  const _ChapterListTile({
    required this.title,
    required this.isActive,
    required this.isDownloaded,
    required this.onTap,
  });

  final String title;

  final bool isActive;

  final bool isDownloaded;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClickInkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isActive
                  ? context.colorScheme.primary
                  : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isActive
                    ? ts.withColor(context.colorScheme.primary).bold.s16
                    : ts.s16,
              ),
            ),
            if (isDownloaded)
              Icon(
                Icons.download_done_rounded,
                color: context.colorScheme.secondary,
              ),
          ],
        ),
      ),
    );
  }
}
