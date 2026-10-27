import 'package:flutter/material.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/side_bar.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/local_comics/download.dart';
import 'package:venera_plus/features/local_comics/local.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

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
  if (comic.chapters == null &&
      LocalManager().isDownloaded(comic.id, comic.comicType, 0)) {
    context.showMessage(message: "The comic is downloaded".tl);
    return;
  }
  if (comic.chapters == null) {
    LocalManager().addTask(
      ImagesDownloadTask(source: source, comicId: comic.id, comic: comic),
    );
  } else {
    List<int>? selected;
    var downloaded = <int>[];
    var localComic = LocalManager().find(comic.id, comic.comicType);
    if (localComic != null) {
      for (int i = 0; i < comic.chapters!.length; i++) {
        if (localComic.downloadedChapters.contains(
          comic.chapters!.ids.elementAt(i),
        )) {
          downloaded.add(i);
        }
      }
    }
    await showSideBar(
      context,
      _SelectDownloadChapter(
        comic.chapters!.titles.toList(),
        (v) => selected = v,
        downloaded,
      ),
    );
    if (selected == null || selected!.isEmpty || !context.mounted) return;
    LocalManager().addTask(
      ImagesDownloadTask(
        source: source,
        comicId: comic.id,
        comic: comic,
        chapters: selected!.map((i) {
          return comic.chapters!.ids.elementAt(i);
        }).toList(),
      ),
    );
  }
  context.showMessage(message: "Download started".tl);
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(this.eps, this.finishSelect, this.downloadedEps);

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

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
              itemCount: widget.eps.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
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
                      var res = <int>[];
                      for (int i = 0; i < widget.eps.length; i++) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
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
                            widget.finishSelect(selected);
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
