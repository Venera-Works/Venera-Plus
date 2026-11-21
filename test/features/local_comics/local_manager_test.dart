import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import '../../support/sqlite.dart';

const _testComicType = ComicType(9001);

LocalComic _localComic(
  String id, {
  String subtitle = 'Author',
  List<String> tags = const ['tag'],
  ComicType comicType = _testComicType,
}) {
  return LocalComic(
    id: id,
    title: 'Local $id',
    subtitle: subtitle,
    tags: tags,
    directory: id,
    chapters: null,
    cover: 'cover.jpg',
    comicType: comicType,
    downloadedChapters: const [],
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  test(
    '移除漫画源后保留本地漫画身份并支持标识往返',
    () async {
      final root = Directory.systemTemp.createTempSync('venera-local-source-');
      addTearDown(() {
        LocalManager.resetForTesting();
        configureComicTypeSourceKeyResolver();
        root.deleteSync(recursive: true);
      });
      App.dataPath = App.cachePath = root.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      var sourceAvailable = true;
      ComicType.configureSourceKeyResolver(
        (value) => value == _testComicType.value && sourceAvailable
            ? 'removed_source'
            : null,
      );
      var manager = LocalManager();
      await manager.init();
      final comic = _localComic('downloaded');
      await manager.add(comic);
      expect(comic.sourceKey, 'removed_source');

      sourceAvailable = false;
      final missingKey = comic.sourceKey;
      expect(missingKey, 'Unknown:${_testComicType.value}');
      expect(ComicType.fromKey(missingKey), _testComicType);
      expect(comic.toJson()['sourceKey'], missingKey);
      expect(ComicType.fromKey('local'), ComicType.local);
      expect(
        ComicType.fromKey('Unknown:invalid').value,
        'Unknown:invalid'.hashCode,
      );

      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      manager = LocalManager();
      await manager.init();
      final restored = manager.find(comic.id, ComicType.fromKey(missingKey));
      expect(restored, isNotNull);
      expect(restored!.comicType, comic.comicType);
      expect(restored.directory, comic.directory);

      sourceAvailable = true;
      expect(restored.sourceKey, 'removed_source');
      expect(manager.getComics(LocalSortType.name), hasLength(1));
    },
    skip: isSqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'getImages filters non-images and sorts numeric page names',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-local-data-');
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-local-cache-',
      );
      addTearDown(() {
        LocalManager.resetForTesting();
        if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
        if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();
      await manager.init();

      final comic = _localComic('pages');
      final directory = Directory(
        '${manager.path}${Platform.pathSeparator}pages',
      )..createSync(recursive: true);
      File(
        '${directory.path}${Platform.pathSeparator}cover.jpg',
      ).writeAsBytesSync([1]);
      File(
        '${directory.path}${Platform.pathSeparator}10.JPG',
      ).writeAsBytesSync([1]);
      File(
        '${directory.path}${Platform.pathSeparator}2.jpg',
      ).writeAsBytesSync([1]);
      File(
        '${directory.path}${Platform.pathSeparator}3.avif',
      ).writeAsBytesSync([1]);
      File(
        '${directory.path}${Platform.pathSeparator}metadata.json',
      ).writeAsStringSync('{}');
      File(
        '${directory.path}${Platform.pathSeparator}.hidden.png',
      ).writeAsBytesSync([1]);
      await manager.add(comic);

      final images = await manager.getImages(comic.id, comic.comicType, 1);

      expect(images.map((image) => image.split(RegExp(r'[/\\]')).last), [
        '2.jpg',
        '3.avif',
        '10.JPG',
      ]);
    },
    skip: isSqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  test(
    'single local comic deletes notify once',
    () async {
      final dataDir = Directory.systemTemp.createTempSync('venera-local-data-');
      final cacheDir = Directory.systemTemp.createTempSync(
        'venera-local-cache-',
      );
      addTearDown(() {
        LocalManager.resetForTesting();
        if (dataDir.existsSync()) {
          dataDir.deleteSync(recursive: true);
        }
        if (cacheDir.existsSync()) {
          cacheDir.deleteSync(recursive: true);
        }
      });

      App.dataPath = dataDir.path;
      App.cachePath = cacheDir.path;
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;

      final manager = LocalManager();
      await manager.init();

      var notifyCount = 0;
      var isDeleting = false;
      void listener() {
        if (isDeleting) {
          notifyCount++;
        }
      }

      manager.addListener(listener);

      final first = _localComic('first');
      await manager.add(first);
      isDeleting = true;
      manager.removeComic(first);
      isDeleting = false;

      expect(notifyCount, 1);
      expect(manager.find(first.id, first.comicType), isNull);

      final second = _localComic('second');
      await manager.add(second);
      notifyCount = 0;
      isDeleting = true;
      manager.deleteComic(second, false);
      isDeleting = false;

      expect(notifyCount, 1);
      expect(manager.find(second.id, second.comicType), isNull);
    },
    skip: isSqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
  test(
    'unavailable SAF storage keeps the configured library instead of switching roots',
    () async {
      final root = Directory.systemTemp.createTempSync('venera-local-saf-');
      addTearDown(() {
        LocalManager.resetForTesting();
        root.deleteSync(recursive: true);
      });
      App.dataPath = App.cachePath = root.path;
      const savedPath = 'android://primary%3AManga';
      final pathFile = File('${root.path}/local_path')
        ..writeAsStringSync(savedPath);
      LocalManager.resetForTesting();
      LocalManager.debugSkipComicSourceInit = true;
      final manager = LocalManager();

      await IOOverrides.runWithIOOverrides(manager.init, _UnavailableSafIO());

      expect(manager.path, savedPath);
      expect(pathFile.readAsStringSync(), savedPath);
      expect(manager.directory.path, savedPath);
    },
    skip: isSqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );

  group(
    '本地书库分类与搜索',
    () {
      late LocalManager manager;

      setUp(() async {
        final root = Directory.systemTemp.createTempSync(
          'venera-local-library-',
        );
        addTearDown(() {
          LocalManager.resetForTesting();
          root.deleteSync(recursive: true);
        });
        App.dataPath = App.cachePath = root.path;
        final library = Directory('${root.path}/library')..createSync();
        File('${root.path}/local_path').writeAsStringSync(library.path);
        LocalManager.resetForTesting();
        LocalManager.debugSkipComicSourceInit = true;
        manager = LocalManager();
        await manager.init();
      });

      test('删掉分类后漫画回到未分类且保留文件', () async {
        final comic = _localComic('downloaded');
        final page = File('${manager.path}/${comic.directory}/1.png')
          ..createSync(recursive: true);
        await manager.add(comic);
        final category = manager.createComicCategory('待阅读')!;
        manager.moveComicsToCategory([comic], category);

        await manager.add(comic);
        expect(manager.search('', categoryId: category).single.id, comic.id);

        manager.deleteComicCategory(category);
        expect(manager.comicCategories, isEmpty);
        expect(
          manager.search('', categoryId: LocalManager.uncategorized).single.id,
          comic.id,
        );
        expect(page.existsSync(), isTrue);
      });

      test('标签要求完整匹配并能与作者搜索组合', () async {
        await manager.add(
          _localComic('first', subtitle: '', tags: ['标签:悬疑', '校园', '作者:朝仓']),
        );
        await manager.add(
          _localComic('partial', subtitle: '朝仓', tags: ['轻悬疑', '校园']),
        );
        await manager.add(_localComic('other', subtitle: '朝仓', tags: ['悬疑']));

        expect(
          manager.search('朝仓', tags: ['悬疑', '校园']).map((comic) => comic.id),
          ['first'],
        );
        expect(
          manager.availableTags(LocalManager.allCategories),
          unorderedEquals(['悬疑', '校园', '轻悬疑']),
        );
      });

      test('重复刮削替换上次的 Bangumi 标签并保留导入元数据', () async {
        final comic = _localComic(
          'imported',
          comicType: ComicType.local,
          subtitle: '原作者',
          tags: ['原标签', '校园'],
        );
        await manager.add(comic);
        manager.updateImportedMetadata(
          comic.id,
          tags: ['校园', '旧标签'],
          author: '作者甲',
        );
        expect(manager.find(comic.id, comic.comicType)!.tags, [
          '原标签',
          '校园',
          '旧标签',
        ]);

        manager.updateImportedMetadata(comic.id, tags: ['新标签'], author: '作者乙');
        final updated = manager.find(comic.id, comic.comicType)!;
        expect(updated.tags, ['原标签', '校园', '新标签']);
        expect(updated.subtitle, '原作者');
      });
    },
    skip: isSqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}

final class _UnavailableSafIO extends IOOverrides {
  @override
  Directory createDirectory(String path) => path.startsWith('android://')
      ? _UnavailableSafDirectory(path)
      : super.createDirectory(path);

  @override
  File createFile(String path) => path.startsWith('android://')
      ? _UnavailableSafFile(path)
      : super.createFile(path);
}

class _UnavailableSafDirectory extends Fake implements Directory {
  _UnavailableSafDirectory(this.path);

  @override
  final String path;

  @override
  bool existsSync() => false;
}

class _UnavailableSafFile extends Fake implements File {
  _UnavailableSafFile(this.path);

  @override
  final String path;

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    throw FileSystemException('Provider is offline', path);
  }
}
