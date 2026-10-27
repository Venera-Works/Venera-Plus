import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';

void main() {
  late Directory temporary;
  late LocalManager manager;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('venera-local-bookmarks-');
    App.dataPath = temporary.path;
    App.cachePath = temporary.path;
    Log.isMuted = true;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
  });

  tearDown(() {
    LocalManager.resetForTesting();
    Log.isMuted = false;
    temporary.deleteSync(recursive: true);
  });

  Future<void> add({bool grouped = true, String directory = 'book'}) async {
    final images = Directory(
      '${manager.path}/$directory${grouped ? '/chapter-id' : ''}',
    )..createSync(recursive: true);
    File('${images.path}/1.jpg').writeAsBytesSync([11]);
    File('${images.path}/2.jpg').writeAsBytesSync([22]);
    await manager.add(
      LocalComic(
        id: 'book-id',
        title: 'Imported comic',
        subtitle: '',
        tags: [],
        directory: directory,
        chapters: grouped
            ? const ComicChapters({'chapter-id': 'Chapter'})
            : null,
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: grouped ? ['chapter-id'] : [],
        createdAt: DateTime(2026),
      ),
    );
  }

  ImageFavorite bookmark({int page = 1, String eid = 'chapter-id'}) =>
      ImageFavorite(
        page,
        'file://obsolete-location/$page.jpg',
        false,
        eid,
        'book-id',
        1,
        'local',
        'Chapter',
      );

  test(
    'local bookmarks resolve comic ID, chapter ID and one-based page',
    () async {
      await add();
      expect(await ImageFavoritesProvider(bookmark()).getImageFromLocal(), [
        11,
      ]);
      expect(
        await ImageFavoritesProvider(bookmark(page: 2)).getImageFromLocal(),
        [22],
      );
    },
  );

  test(
    'unsegmented imported comics can display their bookmarked pages',
    () async {
      await add(grouped: false);
      final provider = ImageFavoritesProvider(bookmark(page: 2, eid: '0'));
      expect(await provider.load(null, null), [22]);
    },
  );

  test(
    'local bookmark follows the library location after files move',
    () async {
      await add();
      final provider = ImageFavoritesProvider(bookmark(page: 2));
      expect(await provider.getImageFromLocal(), [22]);
      Directory('${manager.path}/book').renameSync('${manager.path}/moved');
      await add(directory: 'moved');
      expect(await provider.getImageFromLocal(), [22]);
    },
  );

  test(
    'unavailable local pages fail without falling back to a comic source',
    () async {
      await add();
      final provider = ImageFavoritesProvider(bookmark(page: 3));
      await expectLater(
        provider.load(null, null),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
