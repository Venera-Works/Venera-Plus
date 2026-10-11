import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:image/image.dart' as img;
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/components/window_frame.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_details/thumbnails.dart';
import 'package:venera_plus/features/favorites/favorites_manager.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/features/sync/data_sync.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/sync_records.dart';

const _testRoundId = '00000000-0000-4000-8000-000000000001';

void main() {
  test(
    'read-only comic info namespaces exclude searchable author and tag fields',
    () {
      expect(isReadOnlyComicInfoNamespaceForTesting('views'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('浏览量'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('last update'), isTrue);
      expect(isReadOnlyComicInfoNamespaceForTesting('作者'), isFalse);
      expect(isReadOnlyComicInfoNamespaceForTesting('标签'), isFalse);

      expect(isReadOnlyComicInfoNamespaceForTesting('artist'), isFalse);
      expect(isReadOnlyComicInfoNamespaceForTesting('language'), isFalse);

      expect(isAuthorNamespace('author'), isTrue);
      expect(isAuthorNamespace('artist'), isTrue);
      expect(isAuthorNamespace('language'), isFalse);
    },
  );
  for (final grouped in [false, true]) {
    testWidgets(
      grouped
          ? 'details page continues to imported grouped history'
          : 'details page continues to imported flat history',
      (tester) async {
        final fixture = await _createFixture(tester, grouped: grouped);
        if (!grouped) {
          fixture.histories.addHistory(
            fixture.makeHistory(ep: 1, page: 1, group: null),
          );
        }
        await tester.pumpWidget(fixture.page);
        await _waitForText(tester, grouped ? 'Read' : 'P1');
        if (grouped) {
          expect(find.text('Continue'), findsNothing);
        }

        final targetEp = grouped ? 1 : 2;
        final targetPage = grouped ? 1 : 3;
        final targetGroup = grouped ? 2 : null;
        fixture.histories.applySyncRecords(
          _syncRecords(
            fixture,
            ep: targetEp,
            page: targetPage,
            group: targetGroup,
            reread: grouped,
          ),
        );
        await tester.pump();
        expect(find.textContaining('P$targetPage'), findsOneWidget);
        if (grouped) {
          expect(find.textContaining('Group Two Chapter A'), findsOneWidget);
        }
        expect(find.text('Continue'), findsOneWidget);

        await tester.tap(find.text('Continue'));
        final reader = await _waitForReaderRoute(tester);
        final expectedChapter = grouped ? 3 : 2;
        expect(reader.chapter, expectedChapter);
        expect(reader.pageValue, targetPage);
        expect(reader.history!.ep, targetEp);
        expect(reader.history!.page, targetPage);
        expect(reader.history!.group, targetGroup);
        expect(reader.history!.resumePosition?.ep, targetEp);
        expect(reader.history!.resumePosition?.page, targetPage);
        expect(reader.history!.resumePosition?.group, targetGroup);

        await _waitForReader(tester, reader, targetPage);
        expect(reader.images, fixture.imageUrls);
        expect(_visibleReaderPage(targetPage), findsWidgets);
        expect(fixture.requestedChapterIds.last, grouped ? 'g2a' : 'c2');

        await tester.pump(const Duration(seconds: 2));
        await _pumpAsyncWork(tester, fixture.histories.waitForAsyncWrites());
        final persistedRecords = await _pumpAsyncWork(
          tester,
          fixture.histories.exportSyncRecords(),
        );
        final persistedHistoryRecord =
            persistedRecords[syncRecordKey('history', [
              fixture.comicId,
              fixture.type.value,
            ])]!;
        expect(persistedHistoryRecord.containsKey('progress'), isFalse);
        final persistedProgress = ReadingProgress.fromJson(
          persistedHistoryRecord['readingProgress'],
        );
        expect(persistedProgress.resumePosition?.ep, targetEp);
        expect(persistedProgress.resumePosition?.page, targetPage);
        expect(persistedProgress.resumePosition?.group, targetGroup);
        if (grouped) {
          expect(persistedProgress.activeRoundId, _testRoundId);
          expect(persistedProgress.maximumPositions.single.page, 3);
        }
      },
      skip: !_sqliteAvailable(),
    );
  }

  testWidgets(
    'explicit chapter and thumbnail selections do not inherit synced group progress',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: true);
      fixture.histories.addHistory(
        fixture.makeHistory(ep: 1, page: 1, group: 1),
      );
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'P1');

      void importCurrentPosition() {
        fixture.histories.applySyncRecords(
          _syncRecords(fixture, ep: 1, page: 4, group: 2),
        );
      }

      importCurrentPosition();
      await tester.pump();
      expect(find.textContaining('P4'), findsOneWidget);

      final chapter = find.text('Group One Chapter B');
      await _scrollUntilVisible(tester, chapter);
      await tester.tap(chapter);
      final selectedChapterReader = await _waitForReaderRoute(tester);
      expect(selectedChapterReader.chapter, 2);
      expect(selectedChapterReader.pageValue, 1);
      await _waitForReader(tester, selectedChapterReader, 1);
      expect(fixture.requestedChapterIds.last, 'g1b');
      expect(_visibleReaderPage(1), findsWidgets);

      await _popReader(tester, fixture);
      final groupTwoTab = find.text('Group Two').first;
      await _scrollUntilVisible(tester, groupTwoTab);
      await tester.tap(groupTwoTab);
      await tester.pumpAndSettle();
      final groupTwoChapter = find.text('Group Two Chapter B');
      await _scrollUntilVisible(tester, groupTwoChapter);
      await tester.tap(groupTwoChapter);
      final selectedGroupTwoReader = await _waitForReaderRoute(tester);
      expect(selectedGroupTwoReader.chapter, 4);
      expect(selectedGroupTwoReader.pageValue, 1);
      await _waitForReader(tester, selectedGroupTwoReader, 1);
      expect(fixture.requestedChapterIds.last, 'g2b');
      expect(_visibleReaderPage(1), findsWidgets);

      await _popReader(tester, fixture);
      importCurrentPosition();
      await tester.pump();

      final preview = find.byType(ComicThumbnails);
      await _scrollUntilVisible(tester, preview);
      final secondThumbnail = find
          .descendant(of: preview, matching: find.byType(ClickInkWell))
          .at(1);
      await tester.ensureVisible(secondThumbnail);
      await tester.tap(secondThumbnail);
      final selectedPageReader = await _waitForReaderRoute(tester);
      expect(selectedPageReader.chapter, 1);
      expect(selectedPageReader.pageValue, 2);
      await _waitForReader(tester, selectedPageReader, 2);
      expect(fixture.requestedChapterIds.last, 'g1a');
      expect(_visibleReaderPage(2), findsWidgets);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );
  testWidgets(
    'Read starts at the beginning when the comic has no saved history',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Read');
      expect(find.text('Continue'), findsNothing);

      await tester.tap(find.text('Read'));
      final reader = await _waitForReaderRoute(tester);
      expect(reader.chapter, 1);
      expect(reader.pageValue, 1);
      await _waitForReader(tester, reader, 1);
      expect(fixture.requestedChapterIds.last, 'c1');
      expect(_visibleReaderPage(1), findsWidgets);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'layout changes retain the visible source image without rereading',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      fixture.histories.applySyncRecords(
        _syncRecords(fixture, ep: 2, page: 2, group: null),
      );
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await _waitForReader(tester, reader, 2);
      expect(_visibleReaderPage(2), findsWidgets);

      appdata.settings['showSingleImageOnFirstPage'] = false;
      appdata.settings['readerScreenPicNumberForPortrait'] = 2;
      appdata.settings['readerScreenPicNumberForLandscape'] = 2;
      reader.update();
      await tester.pumpAndSettle();
      appdata.settings['showSingleImageOnFirstPage'] = true;
      reader.update();
      await tester.pumpAndSettle();
      appdata.settings['readerScreenPicNumberForPortrait'] = 1;
      appdata.settings['readerScreenPicNumberForLandscape'] = 1;
      reader.update();
      await tester.pumpAndSettle();
      await _waitForReader(tester, reader, 2);
      expect(_visibleReaderPage(2), findsWidgets);
      final records = await _pumpAsyncWork(
        tester,
        fixture.histories.exportSyncRecords(),
      );
      final state = ReadingProgress.fromJson(
        records[syncRecordKey('history', [
          fixture.comicId,
          fixture.type.value,
        ])]!['readingProgress'],
      );
      expect(state.maximumPositions.single.page, 2);
      expect(state.resumePosition?.page, 2);
      expect(state.activeRoundId, isNull);
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );

  testWidgets(
    'unmapped progress prompts for a real chapter selection before reading',
    (tester) async {
      final fixture = await _createFixture(tester, grouped: false);
      final records = _syncRecords(fixture, ep: 2, page: 2, group: null);
      final key = syncRecordKey('history', [
        fixture.comicId,
        fixture.type.value,
      ]);
      final known = ReadingProgress.fromJson(records[key]!['readingProgress']);
      final unresolved = known.merge(
        ReadingProgress.seed(
          const ReadingPosition(ep: 2, page: 4, chapterId: 'removed-chapter'),
        ),
      );
      expect(unresolved.hasOrderConflict, isTrue);
      records[key]!['readingProgress'] = unresolved.toJson();
      fixture.histories.applySyncRecords(records);
      await tester.pumpWidget(fixture.page);
      await _waitForText(tester, 'Continue');
      await tester.tap(find.text('Continue'));
      final reader = await _waitForReaderRoute(tester);
      await _waitForText(
        tester,
        'Saved reading position is ambiguous. Select a chapter to continue.',
      );
      expect(fixture.requestedChapterIds, isEmpty);
      await tester.tap(find.text(fixture.details.chapters!.allChapters['c2']!));
      await _waitForReader(tester, reader, 1);
      expect(fixture.requestedChapterIds.last, 'c2');
      expect(_visibleReaderPage(1), findsWidgets);
      expect(
        fixture.histories
            .find(fixture.comicId, fixture.type)!
            .readingProgress!
            .maximumPositions
            .any((position) => position.chapterId == 'removed-chapter'),
        isTrue,
      );
      await _popReader(tester, fixture);
    },
    skip: !_sqliteAvailable(),
  );
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.close();
    return true;
  } catch (_) {
    return false;
  }
}

Future<_ComicDetailsFixture> _createFixture(
  WidgetTester tester, {
  required bool grouped,
}) async {
  final previousSettings =
      jsonDecode(jsonEncode(appdata.toJson()['settings']))
          as Map<String, dynamic>;
  final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
  final previousHistory = HistoryManager.cache;
  final previousFavorites = LocalFavoritesManager.cache;
  final previousDataPath = _currentAppPath(cache: false);
  final previousCachePath = _currentAppPath(cache: true);
  final previousLogMuted = Log.isMuted;
  final previousDisableWindowCloseHandler =
      DataSync.debugDisableWindowCloseHandler;
  final temporary = Directory.systemTemp.createTempSync(
    'comic-details-history-',
  );
  final sourceKey =
      'comic_details_history_${DateTime.now().microsecondsSinceEpoch}';
  final comicId = grouped ? 'grouped-comic' : 'flat-comic';
  final imageBytes = img.encodePng(img.Image(width: 100, height: 160));
  final imageUrls = <String>[];
  for (var page = 1; page <= 4; page++) {
    final imageFile = File('${temporary.path}/page-$page.png')
      ..writeAsBytesSync(imageBytes);
    imageUrls.add('file://${imageFile.path}');
  }
  final chapterData = grouped
      ? <String, dynamic>{
          'Group One': {
            'g1a': 'Group One Chapter A',
            'g1b': 'Group One Chapter B',
          },
          'Group Two': {
            'g2a': 'Group Two Chapter A',
            'g2b': 'Group Two Chapter B',
          },
        }
      : <String, dynamic>{'c1': 'Chapter One', 'c2': 'Chapter Two'};
  final details = ComicDetails.fromJson({
    'title': 'Fixture Comic',
    'subtitle': 'Fixture Author',
    'cover': imageUrls.first,
    'description': '',
    'tags': <String, dynamic>{},
    'chapters': chapterData,
    'thumbnails': imageUrls,
    'sourceKey': sourceKey,
    'comicId': comicId,
    'maxPage': 4,
  });
  final requestedChapterIds = <String>[];
  final source = _comicSource(
    sourceKey: sourceKey,
    details: details,
    imageUrls: imageUrls,
    requestedChapterIds: requestedChapterIds,
  );
  ComicSourceManager().add(source);

  App.dataPath = temporary.path;
  App.cachePath = temporary.path;
  final settings = appdata.settings;
  settings['webdav'] = <String>[];
  appdata.implicitData
    ..clear()
    ..addAll({
      'webdavSyncDirection': 'bidirectional',
      'webdavSyncTiming': 'manual',
    });
  settings['language'] = 'en-US';
  settings['readerMode'] = 'galleryLeftToRight';
  settings['autoReaderMode'] = false;
  settings['readerScreenPicNumberForPortrait'] = 1;
  settings['readerScreenPicNumberForLandscape'] = 1;
  settings['comicSpecificSettings'] = <String, Map<String, dynamic>>{};
  settings['deviceSpecificSettings'] = <String, dynamic>{};
  settings['enableCustomImageProcessing'] = false;
  settings['enableClockAndBatteryInfoInReader'] = false;
  settings['showPageNumberInReader'] = false;
  settings['showSystemStatusBar'] = false;
  settings['historyRetentionDays'] = 0;
  settings['reverseChapterOrder'] = false;
  Log.isMuted = true;
  DataSync.resetForTesting();
  DataSync.debugDisableWindowCloseHandler = true;
  LocalFavoritesManager.cache = _TestFavorites();
  HistoryManager.cache = null;
  LocalManager.resetForTesting();
  LocalManager.debugSkipComicSourceInit = true;

  final histories = HistoryManager();
  await tester.runAsync(() async {
    final comicsDirectory = Directory('${temporary.path}/comics')
      ..createSync(recursive: true);
    File(
      '${temporary.path}/local_path',
    ).writeAsStringSync(comicsDirectory.path);
    await histories.init();
    await LocalManager().init();
  });
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter_memory_info'),
    (call) async => 1 << 30,
  );
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (call) async {
      if (call.method == 'isMaximized') return false;
      throw MissingPluginException('Unexpected window call: ${call.method}');
    },
  );

  final fixture = _ComicDetailsFixture(
    sourceKey: sourceKey,
    comicId: comicId,
    details: details,
    histories: histories,
    imageUrls: imageUrls,
    requestedChapterIds: requestedChapterIds,
  );
  addTearDown(() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _pumpAsyncWork(tester, histories.flushReadingProgress());
      final sync = DataSync.instance;
      if (sync != null) {
        await _pumpAsyncWork(tester, sync.flushPendingChanges());
      }
    } finally {
      ComicSourceManager().remove(sourceKey);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter_memory_info'),
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
      LocalManager.resetForTesting();
      try {
        histories.close();
      } catch (_) {}
      DataSync.resetForTesting();
      HistoryManager.cache = previousHistory;
      LocalFavoritesManager.cache = previousFavorites;
      DataSync.debugDisableWindowCloseHandler =
          previousDisableWindowCloseHandler;
      Log.isMuted = previousLogMuted;
      (appdata.toJson()['settings'] as Map)
        ..clear()
        ..addAll(previousSettings);
      App.dataPath = previousDataPath ?? Directory.systemTemp.path;
      App.cachePath = previousCachePath ?? Directory.systemTemp.path;
      appdata.implicitData
        ..clear()
        ..addAll(previousImplicit);
      if (temporary.existsSync()) {
        temporary.deleteSync(recursive: true);
      }
    }
  });
  return fixture;
}

String? _currentAppPath({required bool cache}) {
  try {
    return cache ? App.cachePath : App.dataPath;
  } catch (_) {
    return null;
  }
}

ComicSource _comicSource({
  required String sourceKey,
  required ComicDetails details,
  required List<String> imageUrls,
  required List<String> requestedChapterIds,
}) => ComicSource(
  'Comic details test source',
  sourceKey,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  (id) async => Res(details),
  (id, next) async => const Res(<String>[]),
  (id, ep) async {
    requestedChapterIds.add(ep!);
    return Res(imageUrls);
  },
  null,
  null,
  '',
  '',
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

class _ComicDetailsFixture {
  const _ComicDetailsFixture({
    required this.sourceKey,
    required this.comicId,
    required this.details,
    required this.histories,
    required this.imageUrls,
    required this.requestedChapterIds,
  });

  final String sourceKey;
  final String comicId;
  final ComicDetails details;
  final HistoryManager histories;
  final List<String> imageUrls;
  final List<String> requestedChapterIds;
  ComicType get type => ComicType.fromKey(sourceKey);

  History makeHistory({required int ep, required int page, int? group}) =>
      History.fromModel(
        model: details,
        ep: ep,
        page: page,
        group: group,
        readChapters: <String>{},
      );

  ReadingCatalog get readingCatalog {
    final chapters = details.chapters!;
    final entries = <ReadingChapter>[];
    if (chapters.isGrouped) {
      for (var groupIndex = 0; groupIndex < chapters.groupCount; groupIndex++) {
        final group = chapters.getGroupByIndex(groupIndex);
        final groupId = chapters.groups.elementAt(groupIndex);
        var ep = 1;
        for (final id in group.keys) {
          entries.add(
            ReadingChapter(
              id: id,
              ep: ep++,
              group: groupIndex + 1,
              groupId: groupId,
            ),
          );
        }
      }
    } else {
      var ep = 1;
      for (final id in chapters.allChapters.keys) {
        entries.add(ReadingChapter(id: id, ep: ep++));
      }
    }
    return ReadingCatalog(entries);
  }

  Widget get page => MaterialApp(
    navigatorKey: App.rootNavigatorKey,
    builder: (context, child) => WindowFrame(child!),
    home: ComicPage(id: comicId, sourceKey: sourceKey),
  );
}

SyncRecords _syncRecords(
  _ComicDetailsFixture fixture, {
  required int ep,
  required int page,
  required int? group,
  bool reread = false,
}) {
  final typeValue = fixture.type.value;
  final chapterKey = group == null ? '$ep' : '$group-$ep';
  final catalog = fixture.readingCatalog;
  var readingProgress = ReadingProgress.seed(
    ReadingPosition(ep: ep, page: reread ? 3 : page, group: group),
    time: 1700000000000,
    catalog: catalog,
  );
  if (reread) {
    readingProgress = readingProgress.record(
      ReadingPosition(ep: ep, page: page, group: group),
      source: ReadingNavigationSource.userBackward,
      newRoundId: _testRoundId,
      catalog: catalog,
    );
  }
  final metadata = <String, Object?>{
    'title': fixture.details.title,
    'subtitle': fixture.details.subTitle ?? '',
    'cover': fixture.details.cover,
    'maxPage': 4,
    'readDurationMs': 0,
  };
  final records = <String, Map<String, Object?>>{
    syncRecordKey('history', [fixture.comicId, typeValue]): {
      ...metadata,
      'readingProgress': readingProgress.toJson(),
    },
    syncRecordKey('historyChapter', [fixture.comicId, typeValue, chapterKey]): {
      'comicId': fixture.comicId,
      'typeValue': typeValue,
      'chapter': chapterKey,
      'title': fixture.details.title,
      'subtitle': fixture.details.subTitle ?? '',
      'cover': fixture.details.cover,
      'maxPage': 4,
    },
  };
  return records;
}

Future<void> _waitForText(WidgetTester tester, String text) async {
  final target = find.textContaining(text);
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (target.evaluate().isNotEmpty) return;
  }
  expect(target, findsOneWidget);
}

// Isolate writes complete through fake-zone callbacks. Drive those callbacks
// with frames; use runAsync only to let the real I/O make progress.
Future<T> _pumpAsyncWork<T>(WidgetTester tester, Future<T> work) async {
  late T result;
  var completed = false;
  Object? error;
  StackTrace? errorStack;
  work.then<void>(
    (value) {
      result = value;
      completed = true;
    },
    onError: (Object failure, StackTrace stack) {
      error = failure;
      errorStack = stack;
      completed = true;
    },
  );
  final clock = Stopwatch()..start();
  while (!completed && clock.elapsed < const Duration(seconds: 10)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  clock.stop();
  expect(completed, isTrue, reason: 'Timed out waiting for async history work');
  if (error != null) {
    Error.throwWithStackTrace(error!, errorStack!);
  }
  return result;
}

Future<ReaderState> _waitForReaderRoute(WidgetTester tester) async {
  final reader = find.byType(Reader);
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (reader.evaluate().isNotEmpty &&
        ModalRoute.of(tester.element(reader))?.animation?.isCompleted == true) {
      return tester.state<ReaderState>(reader);
    }
  }
  expect(reader, findsOneWidget);
  fail('Reader navigation did not finish');
}

Future<void> _waitForReader(
  WidgetTester tester,
  ReaderState reader,
  int page,
) async {
  final visiblePage = _visibleReaderPage(page);
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (reader.images != null && visiblePage.evaluate().isNotEmpty) return;
  }
  expect(reader.images, isNotNull);
  expect(visiblePage, findsWidgets);
}

Finder _visibleReaderPage(int page) {
  final galleryPage = find.byWidgetPredicate((widget) {
    if (widget is! PhotoView) return false;
    final provider = widget.imageProvider;
    return provider is ReaderImageProvider && provider.page == page;
  });
  return find.descendant(
    of: galleryPage,
    matching: find.byWidgetPredicate(
      (widget) => widget is RawImage && widget.image != null,
    ),
  );
}

Future<void> _scrollUntilVisible(WidgetTester tester, Finder target) async {
  final scrollable = find
      .descendant(
        of: find.byType(CustomScrollView).first,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(target, 300, scrollable: scrollable);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pumpAndSettle();
}

Future<void> _popReader(
  WidgetTester tester,
  _ComicDetailsFixture fixture,
) async {
  App.rootNavigatorKey.currentState!.pop();
  await tester.pumpAndSettle();
  await _pumpAsyncWork(tester, fixture.histories.flushReadingProgress());
  await tester.pump();
}

class _TestFavorites extends ChangeNotifier implements LocalFavoritesManager {
  @override
  bool hasNewUpdate(String id, ComicType type, [String? folder]) => false;

  @override
  bool isExist(String id, ComicType type) => false;

  @override
  void onRead(String id, ComicType type) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
