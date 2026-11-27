import 'package:flutter/material.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/translations.dart';

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
  Widget buildLoading() => ReaderStatusFrame(child: super.buildLoading());

  @override
  Widget buildError() => ReaderStatusFrame(
    child: NetworkError(message: error!, retry: retry, withAppbar: false),
  );

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
      updateSnapshot: data.updateSnapshot,
    );
  }

  @override
  Future<Res<ReaderProps>> loadData() async {
    final type = ComicType.fromKey(widget.sourceKey);
    final comicSource = ComicSource.find(widget.sourceKey);
    Res<ComicDetails>? result;
    if (comicSource != null) {
      try {
        result = await comicSource.loadComicInfoForReading(widget.id);
      } catch (error) {
        result = Res.error(error.toString());
      }
    }

    final history = HistoryManager().find(widget.id, type);
    if (result != null && result.success) {
      final comic = result.data;
      return Res(
        ReaderProps(
          type: type,
          cid: widget.id,
          name: comic.title,
          chapters: comic.chapters,
          history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
          author: comic.findAuthor() ?? '',
          tags: comic.plainTags,
          updateSnapshot: ComicUpdateSnapshot.fromChapters(
            comic.chapters?.toJson(),
            updateTime: comic.findUpdateTime(),
            maxPage: comic.maxPage,
            chapterPageCounts: comic.chapterPageCounts,
          ),
        ),
      );
    }

    final localComic = LocalManager().find(widget.id, type);
    if (localComic == null) {
      return Res.error(result?.errorMessage ?? 'Comic not found'.tl);
    }
    return Res(
      ReaderProps(
        type: type,
        cid: widget.id,
        name: localComic.title,
        chapters: localComic.chapters,
        history:
            history ?? History.fromModel(model: localComic, ep: 0, page: 0),
        author: localComic.subtitle,
        tags: localComic.tags,
        updateSnapshot: ComicUpdateSnapshot.fromChapters(
          localComic.chapters?.toJson(),
          maxPage: localComic.maxPage,
        ),
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

  final ComicUpdateSnapshot? updateSnapshot;

  const ReaderProps({
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    required this.author,
    required this.tags,
    this.updateSnapshot,
  });
}
