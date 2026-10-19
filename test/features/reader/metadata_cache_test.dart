import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/chapter_loader.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/res.dart';

const _key = 'reader_metadata_test';
const _chapters = ComicChapters({'first': 'First', 'second': 'Second'});

void main() {
  late Directory directory;
  late ComicSource source;
  var infoCalls = 0;
  var pageCalls = 0;
  var offline = false;
  var failPages = false;
  var emptyPages = false;
  var revision = 1;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('reader-metadata-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    CacheManager.debugDisableInitialScan = true;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    await LocalManager().init();
    infoCalls = pageCalls = 0;
    offline = failPages = emptyPages = false;
    revision = 1;
    source = ComicSource(
      'Test',
      _key,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      (id) async {
        infoCalls++;
        if (offline) return const Res.error('offline');
        return Res(
          ComicDetails.fromJson({
            'title': 'Book $revision',
            'subtitle': 'Subtitle',
            'cover': 'https://example.invalid/cover.jpg',
            'tags': {
              'author': ['Author'],
            },
            'chapters': _chapters.toJson(),
            'sourceKey': _key,
            'comicId': id,
            'maxPage': 20,
            'updateTime': 'revision-$revision',
          }),
        );
      },
      null,
      (id, chapter) async {
        pageCalls++;
        if (offline || failPages) return const Res.error('offline');
        return Res(
          emptyPages
              ? <String>[]
              : ['https://example.invalid/$id/$chapter/$revision.jpg'],
        );
      },
      null,
      null,
      'test.js',
      'https://example.invalid/source.js',
      '1.0.0',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
    ComicSourceManager().add(source);
  });

  tearDown(() async {
    ComicSourceManager().remove(_key);
    LocalManager.resetForTesting();
    await CacheManager.resetForTesting();
    directory.deleteSync(recursive: true);
  });

  Future<List<String>> load({
    int chapter = 1,
    ComicChapters chapters = _chapters,
    bool refresh = false,
  }) => loadReaderChapterImages(
    comicId: 'book',
    type: ComicType.fromKey(_key),
    chapter: chapter,
    chapters: chapters,
    forceRefresh: refresh,
  );

  Future<void> reopenCache() async {
    await CacheManager.resetForTesting();
    CacheManager.debugDisableInitialScan = true;
  }

  test(
    'reopening uses persisted details and pages before source requests',
    () async {
      final initial = await source.loadComicInfoForReading('book');
      final pages = await load(chapters: initial.data.chapters!);
      await reopenCache();
      offline = true;

      final reopened = await source.loadComicInfoForReading('book');
      expect(reopened.data.title, 'Book 1');
      expect(reopened.data.subTitle, 'Subtitle');
      expect(reopened.data.maxPage, 20);
      expect(reopened.data.findAuthor(), 'Author');
      expect(await load(chapters: reopened.data.chapters!), pages);
      expect(infoCalls, 1);
      expect(pageCalls, 1);
    },
  );

  test('unchanged fresh details keep page lists across reopenings', () async {
    await source.loadComicInfoForReading('book');
    final pages = await load();
    for (var opening = 0; opening < 2; opening++) {
      await reopenCache();
      expect(
        (await source.loadComicInfoForReading('book', refresh: true)).success,
        isTrue,
      );
      expect(await load(), pages);
    }
    expect(infoCalls, 3);
    expect(pageCalls, 1);
  });

  test(
    'fresh details invalidate page lists even when chapter IDs stay the same',
    () async {
      await source.loadComicInfoForReading('book');
      await load();
      revision = 2;
      final refreshed = await source.loadComicInfoForReading(
        'book',
        refresh: true,
      );
      expect(refreshed.data.title, 'Book 2');
      expect(await load(), ['https://example.invalid/book/first/2.jpg']);
      await reopenCache();
      expect(
        (await source.loadComicInfoForReading('book')).data.title,
        'Book 2',
      );
      expect(await load(), ['https://example.invalid/book/first/2.jpg']);
      expect(infoCalls, 2);
      expect(pageCalls, 2);
    },
  );

  test(
    'page retry refreshes expired addresses and replaces the cached list',
    () async {
      await load();
      revision = 2;
      expect(await load(refresh: true), [
        'https://example.invalid/book/first/2.jpg',
      ]);
      await reopenCache();
      expect(await load(), ['https://example.invalid/book/first/2.jpg']);
      expect(pageCalls, 2);
    },
  );

  test(
    'page cache follows chapter IDs after reordering and isolates books',
    () async {
      final first = await load();
      expect(await load(chapter: 2), [
        'https://example.invalid/book/second/1.jpg',
      ]);
      expect(
        await load(
          chapter: 2,
          chapters: const ComicChapters({'second': 'Second', 'first': 'First'}),
        ),
        first,
      );
      expect((await source.loadComicPagesForReading('other', 'first')).data, [
        'https://example.invalid/other/first/1.jpg',
      ]);
      expect(pageCalls, 3);
    },
  );

  test(
    'account and source settings changes do not reuse another context',
    () async {
      await source.loadComicInfoForReading('book');
      await load();
      source.data['settings'] = {'language': 'zh'};
      await source.loadComicInfoForReading('book');
      await load();
      source.data['account'] = ['another', 'password'];
      await source.loadComicInfoForReading('book');
      await load();
      expect(infoCalls, 3);
      expect(pageCalls, 3);
    },
  );

  test(
    'failures and empty lists are not saved as usable reading metadata',
    () async {
      offline = true;
      expect((await source.loadComicInfoForReading('book')).error, isTrue);
      offline = false;
      expect((await source.loadComicInfoForReading('book')).success, isTrue);
      failPages = true;
      await expectLater(load(), throwsA('offline'));
      failPages = false;
      emptyPages = true;
      expect(await load(), isEmpty);
      emptyPages = false;
      expect(await load(), isNotEmpty);
      expect(await load(), isNotEmpty);
      expect(infoCalls, 2);
      expect(pageCalls, 3);
    },
  );
}
