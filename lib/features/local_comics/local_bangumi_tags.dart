import 'package:flutter/material.dart';
import 'package:venera_plus/components/pop_up_widget.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/translations.dart';

import 'local.dart';

Future<void> showLocalBangumiTagMatch(
  BuildContext context,
  LocalComic comic,
) async {
  final subject = await showPopUpWidget<BangumiSubject?>(
    context,
    BangumiProgressPanel(
      sourceKey: comic.sourceKey,
      comicId: comic.id,
      comicTitle: comic.title,
      chapters: comic.chapters,
      history: null,
      selectMetadataOnly: true,
    ),
  );
  if (subject == null || !context.mounted) return;
  final manager = LocalManager();
  final current = manager.find(comic.id, comic.comicType);
  if (current == null ||
      current.directory != comic.directory ||
      current.createdAt != comic.createdAt) {
    context.showMessage(message: 'This local comic has changed'.tl);
    return;
  }
  manager.updateImportedMetadata(
    comic.id,
    tags: subject.tags,
    author: subject.authors.join(', '),
  );
  context.showMessage(message: 'Local metadata updated'.tl);
}
