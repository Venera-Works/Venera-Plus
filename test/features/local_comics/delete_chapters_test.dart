import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/models.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/comic_type.dart';
import 'package:venera_plus/foundation/translations.dart';

LocalComic _createComic({
  required String id,
  required ComicChapters chapters,
  required List<String> downloadedChapters,
  Map<String, IncompleteChapter> incompleteChapters = const {},
}) {
  return LocalComic(
    id: id,
    title: 'Comic $id',
    subtitle: 'Author',
    tags: const ['tag'],
    directory: id,
    chapters: chapters,
    cover: 'cover.jpg',
    comicType: ComicType.local,
    downloadedChapters: downloadedChapters,
    incompleteChapters: incompleteChapters,
    createdAt: DateTime(2026, 1, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late LocalManager manager;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('venera-delete-chapters-');
    App.dataPath = App.cachePath = root.path;
    final library = Directory('${root.path}/library')..createSync();
    File('${root.path}/local_path').writeAsStringSync(library.path);
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
  });

  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = false;
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'delete pop window renders downloaded and incomplete chapters in original order and deletes incomplete chapter state while preserving others',
    (tester) async {
      const chapters = ComicChapters({
        'ch1': 'Chapter 1',
        'ch2': 'Chapter 2',
        'ch3': 'Chapter 3',
        'ch4': 'Chapter 4',
      });
      final comic = _createComic(
        id: 'mixed_comic',
        chapters: chapters,
        downloadedChapters: ['ch1', 'ch4'],
        incompleteChapters: {
          'ch2': IncompleteChapter(pageCount: 10, missing: [2, 5]),
        },
      );

      final comicDir = Directory('${manager.path}/${comic.directory}')
        ..createSync(recursive: true);
      Directory('${comicDir.path}/ch1').createSync(recursive: true);
      Directory('${comicDir.path}/ch2').createSync(recursive: true);
      Directory('${comicDir.path}/ch4').createSync(recursive: true);

      await manager.add(comic);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDeleteChaptersPopWindow(context, comic),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Chapter 2'), findsOneWidget);
      expect(find.text('Chapter 4'), findsOneWidget);
      expect(find.text('Chapter 3'), findsNothing);

      expect(
        tester.getRect(find.text('Chapter 1')).top,
        lessThan(tester.getRect(find.text('Chapter 2')).top),
      );
      expect(
        tester.getRect(find.text('Chapter 2')).top,
        lessThan(tester.getRect(find.text('Chapter 4')).top),
      );

      await tester.tap(find.text('Chapter 2'));
      await tester.pump();

      await tester.tap(find.text('Submit'.tl));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final updated = manager.find(comic.id, comic.comicType);
      expect(updated, isNotNull);
      expect(updated!.downloadedChapters, ['ch1', 'ch4']);
      expect(updated.incompleteChapters.containsKey('ch2'), isFalse);
      expect(updated.incompleteChapters.isEmpty, isTrue);

      expect(Directory('${comicDir.path}/ch2').existsSync(), isFalse);
      expect(Directory('${comicDir.path}/ch1').existsSync(), isTrue);
      expect(Directory('${comicDir.path}/ch4').existsSync(), isTrue);
    },
  );

  testWidgets(
    'delete pop window renders and deletes when comic contains only incomplete chapters',
    (tester) async {
      const chapters = ComicChapters({'ch1': 'Chapter 1', 'ch2': 'Chapter 2'});
      final comic = _createComic(
        id: 'incomplete_only',
        chapters: chapters,
        downloadedChapters: [],
        incompleteChapters: {
          'ch2': IncompleteChapter(pageCount: 5, missing: [1]),
        },
      );

      final comicDir = Directory('${manager.path}/${comic.directory}')
        ..createSync(recursive: true);
      Directory('${comicDir.path}/ch2').createSync(recursive: true);

      await manager.add(comic);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDeleteChaptersPopWindow(context, comic),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Chapter 2'), findsOneWidget);
      expect(find.text('Chapter 1'), findsNothing);

      await tester.tap(find.text('Chapter 2'));
      await tester.pump();
      await tester.tap(find.text('Submit'.tl));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      final deleted = manager.find(comic.id, comic.comicType);
      expect(deleted, isNull);
      expect(Directory('${comicDir.path}/ch2').existsSync(), isFalse);
    },
  );

  testWidgets(
    'delete pop window deduplicates overlapping chapters and preserves comic order',
    (tester) async {
      const chapters = ComicChapters({
        'c1': 'First',
        'c2': 'Second',
        'c3': 'Third',
        'c4': 'Fourth',
      });
      final comic = _createComic(
        id: 'dedup_order',
        chapters: chapters,
        downloadedChapters: ['c3', 'c1'],
        incompleteChapters: {
          'c1': IncompleteChapter(pageCount: 8, missing: [3]),
          'c2': IncompleteChapter(pageCount: 6, missing: [2]),
        },
      );

      await manager.add(comic);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDeleteChaptersPopWindow(context, comic),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('Third'), findsOneWidget);
      expect(find.text('Fourth'), findsNothing);

      expect(
        tester.getRect(find.text('First')).top,
        lessThan(tester.getRect(find.text('Second')).top),
      );
      expect(
        tester.getRect(find.text('Second')).top,
        lessThan(tester.getRect(find.text('Third')).top),
      );
    },
  );
}
