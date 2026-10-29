import 'package:flutter/material.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';

Future<void> openComic(
  BuildContext context,
  Comic comic, {
  required bool read,
  int? heroID,
}) async {
  final type = switch (comic) {
    FavoriteItem() => comic.type,
    History() => comic.type,
    LocalComic() => comic.comicType,
    _ => ComicType.fromKey(comic.sourceKey),
  };
  if (ComicSource.find(comic.sourceKey) == null) {
    final local = LocalManager().find(comic.id, type);
    if (local != null) {
      local.read();
      return;
    }
  }
  if (read || comic.sourceKey == 'local') {
    await context.to(
      () => ReaderWithLoading(id: comic.id, sourceKey: comic.sourceKey),
    );
  } else {
    await context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
        heroID: heroID,
      ),
    );
  }
}
