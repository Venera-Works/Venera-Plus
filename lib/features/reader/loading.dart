import 'package:flutter/material.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/res.dart';

class ReaderWithLoading extends StatefulWidget {
  const ReaderWithLoading({
    super.key,
    required this.id,
    required this.sourceKey,
    this.initialEp,
    this.initialPage,
    this.initialNavigationSource = ReadingNavigationSource.restore,
  });

  final String id;

  final String sourceKey;

  final int? initialEp;

  final int? initialPage;

  final ReadingNavigationSource initialNavigationSource;

  @override
  State<ReaderWithLoading> createState() => _ReaderWithLoadingState();
}

class _ReaderWithLoadingState
    extends LoadingState<ReaderWithLoading, ReaderProps> {
  @override
  Widget buildContent(BuildContext context, ReaderProps data) {
    final hasExplicitTarget =
        widget.initialEp != null || widget.initialPage != null;
    return Reader(
      type: data.type,
      cid: data.cid,
      name: data.name,
      chapters: data.chapters,
      history: data.history,
      initialChapter: hasExplicitTarget ? widget.initialEp ?? 1 : null,
      initialPage: hasExplicitTarget ? widget.initialPage ?? 1 : null,
      initialNavigationSource: widget.initialNavigationSource,
      author: data.author,
      tags: data.tags,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    final manager = HistoryManager();
    final hasExplicitTarget =
        widget.initialEp != null || widget.initialPage != null;
    // ReaderState resolves progress in the background for explicit targets.
    var history = manager.find(widget.id, ComicType.fromKey(widget.sourceKey));
    final comicSource = ComicSource.find(widget.sourceKey);
    if (comicSource == null) {
      final localComic = LocalManager().find(
        widget.id,
        ComicType.fromKey(widget.sourceKey),
      );
      if (localComic == null) {
        return Res.error("comic not found");
      }
      history ??= History.fromModel(model: localComic, ep: 0, page: 0);
      if (!hasExplicitTarget) {
        final catalog = readingCatalogFromComicChapters(localComic.chapters);
        if (catalog != null) {
          try {
            history = await manager.resolveReadingProgressCatalog(
              history,
              catalog,
            );
          } catch (error) {
            return Res.error(error.toString());
          }
        }
      }
      return Res(
        ReaderProps(
          type: ComicType.fromKey(widget.sourceKey),
          cid: widget.id,
          name: localComic.title,
          chapters: localComic.chapters,
          history: history,
          author: localComic.subtitle,
          tags: localComic.tags,
        ),
      );
    }
    final comic = await comicSource.loadComicInfo!(widget.id);
    if (comic.error) {
      return Res.fromErrorRes(comic);
    }
    history =
        manager.find(widget.id, ComicType.fromKey(widget.sourceKey)) ??
        History.fromModel(model: comic.data, ep: 0, page: 0);
    if (!hasExplicitTarget) {
      final catalog = readingCatalogFromComicChapters(comic.data.chapters);
      if (catalog != null) {
        try {
          history = await manager.resolveReadingProgressCatalog(
            history,
            catalog,
          );
        } catch (error) {
          return Res.error(error.toString());
        }
      }
    }
    return Res(
      ReaderProps(
        type: ComicType.fromKey(widget.sourceKey),
        cid: widget.id,
        name: comic.data.title,
        chapters: comic.data.chapters,
        history: history,
        author: comic.data.findAuthor() ?? "",
        tags: comic.data.plainTags,
      ),
    );
  }
}

class ReaderProps {
  final ComicType type;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  final History history;

  final String author;

  final List<String> tags;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
  });
}
