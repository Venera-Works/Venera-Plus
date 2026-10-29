import 'package:flutter/material.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/search/search.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/translations.dart';

Future<ComicDetails?> switchComicSource(
  BuildContext context, {
  required String id,
  required String sourceKey,
  required String title,
}) async {
  final selected = await context.to<ComicDetails>(
    () => _SourceSearchPage(title: title),
  );
  if (selected == null ||
      (selected.id == id && selected.sourceKey == sourceKey) ||
      !context.mounted) {
    return null;
  }
  try {
    await BangumiService().copyBindingToSource(
      sourceKey: sourceKey,
      comicId: id,
      targetSourceKey: selected.sourceKey,
      targetComicId: selected.id,
    );
    LocalFavoritesManager().replaceComic(
      id,
      ComicType.fromKey(sourceKey),
      FavoriteItem(
        id: selected.id,
        name: selected.title,
        coverPath: selected.cover,
        author: selected.findAuthor() ?? selected.subTitle ?? '',
        type: selected.comicType,
        tags: [
          for (final entry in selected.tags.entries)
            for (final tag in entry.value) '${entry.key}:$tag',
        ],
      ),
      updateTime: selected.findUpdateTime(),
    );
    DataSync().onDataChanged();
    return selected;
  } catch (error, stackTrace) {
    Log.error('Switch comic source', error, stackTrace);
    if (context.mounted) {
      context.showMessage(
        message: 'Failed to switch source: @e'.tlParams({'e': '$error'}),
      );
    }
    return null;
  }
}

class _SourceSearchPage extends StatefulWidget {
  const _SourceSearchPage({required this.title});

  final String title;

  @override
  State<_SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<_SourceSearchPage> {
  Future<void> _preview(Comic comic) async {
    final selected = await context.to<ComicDetails>(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        title: comic.title,
        cover: comic.cover,
        selectSource: true,
      ),
    );
    if (selected != null && mounted) {
      final navigator = Navigator.of(context);
      final route = ModalRoute.of(context);
      navigator.popUntil((candidate) => identical(candidate, route));
      navigator.pop(selected);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AggregatedSearchPage(keyword: widget.title, onComicTap: _preview),
  );
}
