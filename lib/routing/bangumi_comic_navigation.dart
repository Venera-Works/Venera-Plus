import 'package:flutter/material.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/components/side_bar.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

ComicType _typeOf(Comic comic) => switch (comic) {
  FavoriteItem() => comic.type,
  History() => comic.type,
  LocalComic() => comic.comicType,
  _ => ComicType.fromKey(comic.sourceKey),
};

/// The current collection's members are kept intact, including their types.
Future<Comic?> selectBangumiComicSource(
  BuildContext context,
  Comic comic, {
  bool alwaysChoose = false,
  bool allowUnavailable = false,
}) async {
  if (comic is! BangumiComicGroup) return comic;
  final members = comic.members;
  if (members.length == 1) return members.single;
  Comic? latestComic;
  DateTime? latestTime;
  for (final member in members) {
    final type = _typeOf(member);
    final available = ComicSource.find(member.sourceKey) != null ||
        LocalManager().find(member.id, type) != null;
    if (!available) continue;
    final time = HistoryManager().find(member.id, type)?.time;
    if (time != null && (latestTime == null || time.isAfter(latestTime))) {
      latestComic = member;
      latestTime = time;
    }
  }
  if (!alwaysChoose && latestComic != null) return latestComic;
  return Navigator.of(context).push<Comic>(
    SideBarRoute<Comic>(
      Builder(builder: (context) => PopUpWidgetScaffold(
        title: 'Choose comic source'.tl,
        body: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(comic.title, style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final member in members)
              _sourceTile(context, member, latestComic, allowUnavailable),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Each source keeps its own reading position'.tl),
            ),
          ],
        ),
      )),
      width: 500,
    ),
  );
}

Widget _sourceTile(BuildContext context, Comic comic, Comic? latestComic, bool allowUnavailable) {
  final type = _typeOf(comic);
  final source = ComicSource.find(comic.sourceKey);
  final local = LocalManager().find(comic.id, type);
  final history = HistoryManager().find(comic.id, type);
  final available = source != null || local != null;
  final name = comic.sourceKey == 'local' ? 'Local'.tl : source?.name ?? comic.sourceKey;
  return ListTile(
    key: ValueKey('comic-source:${comic.sourceKey}:${comic.id}'),
    enabled: available || allowUnavailable,
    leading: Icon(local == null ? Icons.public : Icons.download_done),
    title: Text(name),
    subtitle: Text([
      comic.title,
      if (history != null) history.progressDescription(showTotals: true),
      if (identical(comic, latestComic)) 'Last read source'.tl,
      if (local != null) 'Downloaded'.tl,
      if (LocalFavoritesManager().hasNewUpdate(comic.id, type)) 'New update'.tl,
      if (!available) 'Source unavailable'.tl,
    ].join('\n')),
    onTap: available || allowUnavailable ? () => Navigator.of(context).pop(comic) : null,
  );
}

Future<void> openBangumiComic(
  BuildContext context,
  Comic comic, {
  required bool read,
  int? heroID,
  bool chooseSource = false,
}) async {
  final selected = await selectBangumiComicSource(
    context, comic, alwaysChoose: chooseSource,
  );
  if (selected == null || !context.mounted) return;
  final hasHistory = HistoryManager().find(selected.id, _typeOf(selected)) != null;
  final newSource = comic is BangumiComicGroup && comic.members.length > 1 && !hasHistory;
  if (read && !newSource || selected.sourceKey == 'local') {
    context.to(() => ReaderWithLoading(id: selected.id, sourceKey: selected.sourceKey));
  } else {
    context.to(() => ComicPage(
      id: selected.id,
      sourceKey: selected.sourceKey,
      cover: selected.cover,
      title: selected.title,
      heroID: heroID,
    ));
  }
}

/// Used from an existing source's detail page to discover its other bindings.
BangumiComicGroup<Comic>? bangumiGroupForComic(Comic comic) {
  final service = BangumiService();
  final binding = service.bindingFor(comic.sourceKey, comic.id);
  if (binding == null) return null;
  final favorites = {
    for (final item in LocalFavoritesManager().getAllComics())
      (item.sourceKey, item.id): item,
  };
  final members = <Comic>[comic];
  for (final other in service.bindingsForSubject(binding.subjectId)) {
    if (other.sourceKey == comic.sourceKey && other.comicId == comic.id) continue;
    final type = ComicType.fromKey(other.sourceKey);
    members.add(favorites[(other.sourceKey, other.comicId)] ??
        HistoryManager().find(other.comicId, type) ??
        LocalManager().find(other.comicId, type) ??
        Comic(other.subjectTitle, other.coverUrl, other.comicId, null, null, '', other.sourceKey, null, null));
  }
  return BangumiComicGroup<Comic>(
    groupKey: 'bangumi:${binding.subjectId}',
    members: members,
    representative: comic,
    binding: binding,
  );
}
