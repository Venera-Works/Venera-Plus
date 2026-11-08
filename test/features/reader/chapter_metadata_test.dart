import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/reader/scaffold.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

void main() {
  late Map<String, dynamic> previousSettings;
  late HistoryManager? previousHistory;
  late LocalFavoritesManager? previousFavorites;
  late DataSync? previousSync;
  const settingKeys = [
    'comicSpecificSettings',
    'deviceSpecificSettings',
    'readerMode',
    'enableTurnPageByVolumeKey',
    'enableClockAndBatteryInfoInReader',
    'showPageNumberInReader',
    'showSystemStatusBar',
    'quickCollectImage',
    'readerScreenPicNumberForLandscape',
    'readerScreenPicNumberForPortrait',
    'language',
  ];

  setUp(() {
    previousSettings = {
      for (final key in settingKeys) key: appdata.settings[key],
    };
    previousHistory = HistoryManager.cache;
    previousFavorites = LocalFavoritesManager.cache;
    previousSync = DataSync.instance;
    HistoryManager.cache = _History();
    LocalFavoritesManager.cache = _Favorites();
    DataSync.instance = _Sync();
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['readerMode'] = 'galleryLeftToRight';
    appdata.settings['enableTurnPageByVolumeKey'] = false;
    appdata.settings['enableClockAndBatteryInfoInReader'] = false;
    appdata.settings['showPageNumberInReader'] = true;
    appdata.settings['showSystemStatusBar'] = true;
    appdata.settings['quickCollectImage'] = 'No';
    appdata.settings['readerScreenPicNumberForLandscape'] = 1;
    appdata.settings['readerScreenPicNumberForPortrait'] = 1;
    appdata.settings['language'] = 'en-US';
  });

  tearDown(() {
    configureReaderChapterCompletedHandler(null);
    HistoryManager.cache = previousHistory;
    LocalFavoritesManager.cache = previousFavorites;
    DataSync.instance = previousSync;
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
  });

  for (final grouped in [false, true]) {
    testWidgets('chapter metadata stays indexed in source order ($grouped)', (
      tester,
    ) async {
      final chapters = grouped
          ? _CountingChapters.grouped({
              'Volume Z': {'duplicate': 'Z start', 'chapter-9': 'Z end'},
              'Empty': {},
              'Volume A': {'duplicate': 'A start', 'chapter-1': 'A end'},
            })
          : _CountingChapters({'z': 'Z start', 'a': 'A start', 'm': 'M end'});
      final expectedIDs = grouped
          ? ['duplicate', 'chapter-9', 'duplicate', 'chapter-1']
          : ['z', 'a', 'm'];
      final expectedTitles = grouped
          ? ['Z start', 'Z end', 'A start', 'A end']
          : ['Z start', 'A start', 'M end'];
      final events = <ReaderChapterCompletedEvent>[];
      configureReaderChapterCompletedHandler(events.add);
      final readerKey = GlobalKey<_MetadataReaderState>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: _MetadataReader(key: readerKey, chapters: chapters),
          ),
        );
        await tester.pump();
        final reader = readerKey.currentState!;
        final scaffold = tester.state<ReaderScaffoldState>(
          find.byType(ReaderScaffold),
        );
        scaffold.openOrClose();
        await tester.pumpAndSettle();
        expect(chapters.titleReads, expectedTitles.length);
        final initialReads = chapters.readCounts;

        for (var index = 0; index < expectedIDs.length; index++) {
          reader.selectChapter(index + 1);
          await tester.pump();
          expect(reader.eid, expectedIDs[index]);
          expect(reader.chapterTitle, expectedTitles[index]);
          expect(reader.maxChapter, expectedIDs.length);
          expect(find.text(expectedTitles[index]), findsOneWidget);
          expect(find.text('${expectedTitles[index]} : 1/1'), findsNWidgets(2));
          if (grouped) {
            expect(reader.readingChapter!.group, index < 2 ? 1 : 3);
            expect(reader.readingChapter!.ep, index % 2 + 1);
            expect(
              reader.readingChapter!.groupId,
              index < 2 ? 'Volume Z' : 'Volume A',
            );
          }
          for (var page = 0; page < 100; page++) {
            expect(reader.eid, expectedIDs[index]);
            expect(reader.chapterTitle, expectedTitles[index]);
            scaffold.updatePage();
          }
          await tester.pump();
        }
        expect(chapters.readCounts, initialReads);

        reader.images = ['first', 'second'];
        reader.pageValue = 2;
        reader.onReaderContentReady();
        await tester.pump();
        expect(events, hasLength(1));
        expect(events.single.chapterKey, expectedIDs.last);
        expect(events.single.chapterTitle, expectedTitles.last);
        expect(chapters.readCounts, initialReads);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    });
  }

  testWidgets(
    'finishing the final new chapter keeps another new chapter pending',
    (tester) async {
      final chapters = _CountingChapters({
        'old': 'Old',
        'new-one': 'New One',
        'new-two': 'New Two',
      });
      final snapshot = ComicUpdateSnapshot.fromChapters(chapters.toJson());
      var updates = ComicUpdateState.empty()
          .observe(ComicUpdateSnapshot.fromChapters({'old': 'Old'}))
          .state
          .observe(snapshot)
          .state;
      configureReaderChapterCompletedHandler((event) {
        updates = updates.acknowledgeSnapshot(
          event.updateSnapshot!,
          chapterId: event.chapterKey,
          groupId: event.groupId,
          isLastChapter: event.isLastChapter,
        );
      });
      final key = GlobalKey<_MetadataReaderState>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: _MetadataReader(
              key: key,
              chapters: chapters,
              updateSnapshot: snapshot,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(updates.hasNewUpdate, isTrue);
        final reader = key.currentState!;
        reader.selectChapter(3);
        await tester.pump();
        reader.images = ['first', 'second'];
        reader.pageValue = 2;
        reader.onReaderContentReady();
        await tester.pump();
        expect(updates.hasNewUpdate, isTrue);
        reader.selectChapter(2);
        await tester.pump();
        reader.images = ['first', 'second'];
        reader.pageValue = 2;
        reader.onReaderContentReady();
        await tester.pump();
        expect(updates.hasNewUpdate, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );

  testWidgets(
    'a comic without chapters confirms its loaded page version at the last page',
    (tester) async {
      final snapshot = ComicUpdateSnapshot.fromChapters(null, maxPage: 2);
      var updates = ComicUpdateState.empty()
          .observe(ComicUpdateSnapshot.fromChapters(null, maxPage: 1))
          .state
          .observe(snapshot)
          .state;
      configureReaderChapterCompletedHandler((event) {
        updates = updates.acknowledgeSnapshot(
          event.updateSnapshot!,
          chapterId: event.chapterKey,
          isLastChapter: event.isLastChapter,
        );
      });
      final key = GlobalKey<_MetadataReaderState>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: _MetadataReader(
              key: key,
              chapters: null,
              updateSnapshot: snapshot,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(updates.hasNewUpdate, isTrue);
        final reader = key.currentState!;
        reader.images = ['first', 'second'];
        reader.pageValue = 1;
        reader.onReaderContentReady();
        await tester.pump();
        expect(updates.hasNewUpdate, isTrue);
        reader.pageValue = 2;
        reader.notifyChapterCompletedIfNeeded();
        await tester.pump();
        expect(updates.hasNewUpdate, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );

  for (final hasChapters in [false, true]) {
    testWidgets(
      'shorter loaded content cannot confirm newer pages ($hasChapters)',
      (tester) async {
        final catalog = hasChapters ? {'one': 'One'} : null;
        final snapshot = ComicUpdateSnapshot.fromChapters(
          catalog,
          maxPage: hasChapters ? null : 2,
          chapterPageCounts: hasChapters ? {'one': 2} : const {},
        );
        var updates = const ComicUpdateState.empty()
            .observe(
              ComicUpdateSnapshot.fromChapters(
                catalog,
                maxPage: hasChapters ? null : 1,
                chapterPageCounts: hasChapters ? {'one': 1} : const {},
              ),
            )
            .state
            .observe(snapshot)
            .state;
        configureReaderChapterCompletedHandler((event) {
          updates = updates.acknowledgeSnapshot(
            event.updateSnapshot!,
            chapterId: event.chapterKey,
            isLastChapter: event.isLastChapter,
          );
        });
        final key = GlobalKey<_MetadataReaderState>();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: _MetadataReader(
                key: key,
                chapters: hasChapters ? ComicChapters(catalog!) : null,
                updateSnapshot: snapshot,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          final reader = key.currentState!;
          reader.images = ['old'];
          reader.pageValue = 1;
          reader.onReaderContentReady();
          await tester.pump();
          expect(updates.hasNewUpdate, isTrue);
          reader.images = ['old', 'new'];
          reader.pageValue = 2;
          reader.notifyChapterCompletedIfNeeded();
          await tester.pump();
          expect(updates.hasNewUpdate, isFalse);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
        }
      },
    );
  }

  for (final chapters in [
    null,
    _CountingChapters({}),
    _CountingChapters.grouped({}),
  ]) {
    testWidgets(
      'chapter metadata preserves empty fallback (${chapters?.isGrouped})',
      (tester) async {
        final readerKey = GlobalKey<_MetadataReaderState>();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: _MetadataReader(key: readerKey, chapters: chapters),
            ),
          );
          await tester.pump();
          final reader = readerKey.currentState!;
          expect(reader.eid, '0');
          expect(reader.chapterTitle, isNull);
          expect(reader.readingChapter, isNull);
          expect(reader.maxChapter, chapters == null ? 1 : 0);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
        }
      },
    );
  }
}

class _CountingChapters extends ComicChapters {
  _CountingChapters(Map<String, String> chapters) : super(chapters);
  _CountingChapters.grouped(Map<String, Map<String, String>> chapters)
    : super.grouped(chapters);

  int idReads = 0;
  int titleReads = 0;
  int lengthReads = 0;
  int groupReads = 0;

  (int, int, int, int) get readCounts =>
      (idReads, titleReads, lengthReads, groupReads);

  @override
  Iterable<String> get ids sync* {
    for (final id in super.ids) {
      idReads++;
      yield id;
    }
  }

  @override
  Iterable<String> get titles sync* {
    for (final title in super.titles) {
      titleReads++;
      yield title;
    }
  }

  @override
  int get length {
    lengthReads++;
    return super.length;
  }

  @override
  Map<String, String> getGroup(String group) {
    groupReads++;
    return super.getGroup(group);
  }
}

class _MetadataReader extends Reader {
  _MetadataReader({
    required super.key,
    required super.chapters,
    super.updateSnapshot,
  }) : super(
         type: ComicType.local,
         cid: 'book',
         name: 'Book',
         author: '',
         tags: const [],
         initialChapter: 1,
         history: History.fromMap({
           'id': 'book',
           'type': 0,
           'time': 1000,
           'title': 'Book',
           'ep': 1,
           'page': 1,
         }),
       );

  @override
  ReaderState createState() => _MetadataReaderState();
}

class _MetadataReaderState extends ReaderState {
  void selectChapter(int value) => setState(() => chapter = value);

  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SizedBox.expand(
      child: ReaderScaffold(child: const SizedBox.expand()),
    ),
  );
}

class _History extends HistoryManager {
  _History() : super.create();

  @override
  Database get imageFavoritesDatabase => _EmptyDatabase();

  @override
  Future<History> resolveReadingProgressCatalog(
    History fallback,
    ReadingCatalog catalog,
  ) async => fallback;

  @override
  Future<void> addReadDuration(History history, Duration duration) async {}

  @override
  Future<void> flushReadingProgress({String? id, ComicType? type}) async {}
}

class _EmptyDatabase implements Database {
  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
      ResultSet(const [], null, const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Favorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  void onRead(String id, ComicType type) {}

  @override
  void acknowledgeChapter(
    String id,
    ComicType type,
    ComicUpdateSnapshot snapshot, {
    required String chapterId,
    String? groupId,
    required bool isLastChapter,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync implements DataSync {
  @override
  void onDataChanged() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
