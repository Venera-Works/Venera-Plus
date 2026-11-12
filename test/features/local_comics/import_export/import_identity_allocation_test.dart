import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/local_comics/import_export/import_export.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';

LocalComic _comic(String id, String title) => LocalComic(
  id: id,
  title: title,
  subtitle: '',
  tags: const [],
  directory: title,
  chapters: null,
  cover: 'cover.jpg',
  comicType: ComicType.local,
  downloadedChapters: const [],
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late LocalManager manager;
  late String favoritesPath;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('venera-import-identity-');
    App.dataPath = root.path;
    App.cachePath = (Directory('${root.path}/cache')..createSync()).path;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
    favoritesPath = '${root.path}/local_favorite.db';
  });

  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    root.deleteSync(recursive: true);
  });

  void storeFavorite(Database database, String folder, String id, int type) {
    final table = quoteSqlIdentifier(folder);
    database.execute(
      'CREATE TABLE IF NOT EXISTS $table (id TEXT, type INTEGER, name TEXT);',
    );
    database.execute('INSERT INTO $table VALUES (?, ?, ?);', [
      id,
      type,
      'Original $id',
    ]);
  }

  test(
    'imports avoid persisted identities in every folder without a UI index',
    () async {
      final favorites = sqlite3.open(favoritesPath);
      try {
        storeFavorite(favorites, 'Migrated', '1', ComicType.local.value);
        storeFavorite(favorites, 'Other "folder"', '80', ComicType.local.value);
        storeFavorite(favorites, 'Other "folder"', '900', 17);
        favorites.execute('CREATE TABLE folder_metadata (folder_id TEXT);');
      } finally {
        favorites.close();
      }
      final originalFavorites = File(favoritesPath).readAsBytesSync();
      await manager.add(_comic('7', 'Existing'));

      await const ImportComic().registerComic(_comic('0', 'Fresh A'));
      await const ImportComic().registerComic(_comic('0', 'Fresh B'));

      expect(manager.find('81', ComicType.local)?.title, 'Fresh A');
      expect(manager.find('82', ComicType.local)?.title, 'Fresh B');
      expect(manager.find('7', ComicType.local)?.title, 'Existing');
      expect(manager.find('1', ComicType.local), isNull);
      expect(manager.find('80', ComicType.local), isNull);
      expect(File(favoritesPath).readAsBytesSync(), originalFavorites);

      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      manager = LocalManager();
      await manager.init();
      expect(manager.find('81', ComicType.local)?.title, 'Fresh A');
      expect(manager.find('82', ComicType.local)?.title, 'Fresh B');
    },
  );

  test(
    'allocation reads the favorites beside its own open local database',
    () async {
      final favorites = sqlite3.open(favoritesPath);
      try {
        storeFavorite(favorites, 'Migrated', '12', ComicType.local.value);
      } finally {
        favorites.close();
      }
      final replacement = Directory('${root.path}/replacement')..createSync();
      App.dataPath = replacement.path;

      expect(manager.findValidId(ComicType.local), '13');
      expect(replacement.listSync(), isEmpty);
    },
  );

  test('large migrated IDs cannot overflow and reuse an existing identity', () {
    final favorites = sqlite3.open(favoritesPath);
    try {
      storeFavorite(
        favorites,
        'Migrated',
        '9223372036854775808',
        ComicType.local.value,
      );
      storeFavorite(
        favorites,
        'Migrated',
        'not-a-number',
        ComicType.local.value,
      );
    } finally {
      favorites.close();
    }

    expect(manager.findValidId(ComicType.local), '9223372036854775809');
  });

  test(
    'unreadable favorites stop registration before the local record is written',
    () async {
      final brokenBytes = [0, 1, 2, 3, 4];
      File(favoritesPath).writeAsBytesSync(brokenBytes);
      await manager.add(_comic('5', 'Existing'));

      await expectLater(
        const ImportComic().registerComic(_comic('0', 'Fresh')),
        throwsA(isA<SqliteException>()),
      );

      expect(manager.findByName('Fresh'), isNull);
      expect(manager.find('5', ComicType.local)?.title, 'Existing');
      expect(File(favoritesPath).readAsBytesSync(), brokenBytes);
    },
  );

  test(
    'a directory at the favorites path cannot be treated as an empty store',
    () async {
      Directory(favoritesPath).createSync();

      await expectLater(
        const ImportComic().registerComic(_comic('0', 'Fresh')),
        throwsA(isA<FileSystemException>()),
      );

      expect(manager.findByName('Fresh'), isNull);
      expect(Directory(favoritesPath).listSync(), isEmpty);
    },
  );
}
