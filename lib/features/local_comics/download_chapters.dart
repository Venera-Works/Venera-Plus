import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/side_bar.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/local_comics/download.dart';
import 'package:venera_plus/features/local_comics/local.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

typedef _ChapterOption = ({String id, String title, String? group});

Future<void> downloadComicChapters(
  BuildContext context,
  ComicDetails comic,
) async {
  final source = ComicSource.find(comic.sourceKey);
  if (source == null || source.loadComicPages == null) return;
  if (LocalManager().isDownloading(comic.id, comic.comicType)) {
    context.showMessage(message: "The comic is downloading".tl);
    return;
  }
  final chapters = comic.chapters;
  if (chapters == null &&
      LocalManager().isDownloaded(comic.id, comic.comicType, 0)) {
    context.showMessage(message: "The comic is downloaded".tl);
    return;
  }
  if (chapters == null) {
    LocalManager().addTask(
      ImagesDownloadTask(source: source, comicId: comic.id, comic: comic),
    );
  } else {
    List<String>? selected;
    final options = <_ChapterOption>[
      if (chapters.isGrouped)
        for (final group in chapters.groups)
          for (final entry in chapters.getGroup(group).entries)
            (id: entry.key, title: entry.value, group: group)
      else
        for (final entry in chapters.allChapters.entries)
          (id: entry.key, title: entry.value, group: null),
    ];
    final localComic = LocalManager().find(comic.id, comic.comicType);
    await showSideBar(
      context,
      _SelectDownloadChapter(
        chapters: options,
        showGroups: chapters.groupCount > 1,
        finishSelect: (ids) => selected = ids,
        downloaded: localComic?.downloadedChapters.toSet() ?? const {},
      ),
    );
    if (selected == null || selected!.isEmpty || !context.mounted) return;
    LocalManager().addTask(
      ImagesDownloadTask(
        source: source,
        comicId: comic.id,
        comic: comic,
        chapters: selected,
      ),
    );
  }
  context.showMessage(message: "Download started".tl);
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter({
    required this.chapters,
    required this.showGroups,
    required this.finishSelect,
    required this.downloaded,
  });

  final List<_ChapterOption> chapters;
  final bool showGroups;
  final void Function(List<String>) finishSelect;
  final Set<String> downloaded;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  final selected = <String>{};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.chapters.length,
              itemBuilder: (context, i) {
                final chapter = widget.chapters[i];
                final downloaded = widget.downloaded.contains(chapter.id);
                return CheckboxListTile(
                  title: Text(chapter.title),
                  subtitle: widget.showGroups ? Text(chapter.group!) : null,
                  value: downloaded || selected.contains(chapter.id),
                  onChanged: downloaded
                      ? null
                      : (checked) {
                          setState(() {
                            if (checked == true) {
                              selected.add(chapter.id);
                            } else {
                              selected.remove(chapter.id);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      widget.finishSelect(
                        {
                          for (final chapter in widget.chapters)
                            if (!widget.downloaded.contains(chapter.id))
                              chapter.id,
                        }.toList(),
                      );
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(selected.toList());
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}
