import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/favorites/favorites.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

void main() {
  late HistoryManager? previousHistory;
  late LocalFavoritesManager? previousFavorites;
  late DataSync? previousSync;

  setUp(() {
    previousHistory = HistoryManager.cache;
    previousFavorites = LocalFavoritesManager.cache;
    previousSync = DataSync.instance;
    HistoryManager.cache = _EmptyHistory();
    LocalFavoritesManager.cache = _EmptyFavorites();
    DataSync.instance = _EmptySync();
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
  });

  tearDown(() {
    configureReaderChapterCompletedHandler(null);
    HistoryManager.cache = previousHistory;
    LocalFavoritesManager.cache = previousFavorites;
    DataSync.instance = previousSync;
  });

  const editions = ComicChapters.grouped({
    'EPUB': {'epub-1': '第01卷', 'epub-2': '第02卷'},
    'PDF': {'pdf-1': '第01卷', 'pdf-2': '第02卷'},
  });

  Future<_TestReaderState> openReader(
    WidgetTester tester, {
    ComicChapters chapters = editions,
    int initialChapter = 1,
  }) async {
    final key = GlobalKey<_TestReaderState>();
    await tester.pumpWidget(
      MaterialApp(
        home: _TestReader(
          key: key,
          chapters: chapters,
          initialChapter: initialChapter,
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    await tester.pump(const Duration(milliseconds: 200));
    return key.currentState!;
  }

  testWidgets('native editions retain their own first and last volume', (
    tester,
  ) async {
    final reader = await openReader(tester);
    for (var chapter = 1; chapter <= 4; chapter++) {
      reader.chapter = chapter;
      expect(reader.isFirstChapterOfGroup, chapter == 1 || chapter == 3);
      expect(reader.isLastChapterOfGroup, chapter == 2 || chapter == 4);
    }
  });

  testWidgets('next volume stays in the EPUB edition at its end', (
    tester,
  ) async {
    final reader = await openReader(tester);
    expect(reader.toNextChapter(), isTrue);
    expect(reader.chapter, 2);
    // Complete the new volume load: the boundary must stop navigation even
    // when the reader is ready to accept another navigation command.
    reader.isLoading = false;
    expect(reader.toNextChapter(), isFalse);
    expect(reader.chapter, 2);
  });

  testWidgets('previous volume stays in the PDF edition at its start', (
    tester,
  ) async {
    final reader = await openReader(tester, initialChapter: 4);
    expect(reader.toPrevChapter(), isTrue);
    expect(reader.chapter, 3);
    reader.isLoading = false;
    expect(reader.toPrevChapter(), isFalse);
    expect(reader.chapter, 3);
  });

  testWidgets('explicit selection can switch editions in either direction', (
    tester,
  ) async {
    final reader = await openReader(tester, initialChapter: 2);
    expect(reader.toChapter(3), isTrue);
    expect(reader.chapter, 3);
    reader.isLoading = false;
    expect(reader.toChapter(1), isTrue);
    expect(reader.chapter, 1);
  });

  testWidgets('flat chapter lists keep their complete reading sequence', (
    tester,
  ) async {
    final reader = await openReader(
      tester,
      chapters: const ComicChapters({
        'one': '第01卷',
        'two': '第02卷',
        'three': '第03卷',
      }),
    );
    expect(reader.toPrevChapter(), isFalse);
    expect(reader.toNextChapter(), isTrue);
    expect(reader.chapter, 2);
    reader.isLoading = false;
    expect(reader.toNextChapter(), isTrue);
    expect(reader.chapter, 3);
    reader.isLoading = false;
    expect(reader.toNextChapter(), isFalse);
  });
}

class _TestReader extends Reader {
  _TestReader({super.key, required super.chapters, super.initialChapter})
    : super(
        type: ComicType.local,
        cid: 'editions-comic',
        author: '',
        tags: const [],
        name: 'Edition comic',
        history: History.fromMap({
          'id': 'editions-comic',
          'type': ComicType.local.value,
          'time': 0,
          'title': 'Edition comic',
          'ep': initialChapter ?? 1,
          'page': 1,
        }),
      );

  @override
  ReaderState createState() => _TestReaderState();
}

class _TestReaderState extends ReaderState {
  @override
  void setImageCacheSize() {}
  @override
  void initReaderWindow() {}
  @override
  void disposeReaderWindow() {}
  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}

class _EmptyHistory extends HistoryManager {
  _EmptyHistory() : super.create();
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

class _EmptyFavorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  void onRead(String id, ComicType type) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptySync implements DataSync {
  @override
  void onDataChanged() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
