import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/button.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalManager manager;
  LocalComic comic(String id, String title) => LocalComic(
    id: id,
    title: title,
    subtitle: '',
    tags: const [],
    directory: id,
    chapters: null,
    cover: 'cover.png',
    comicType: ComicType.local,
    downloadedChapters: const [],
    createdAt: DateTime(2026),
  );
  setUp(() async {
    root = Directory.systemTemp.createTempSync('local-selection-');
    App.dataPath = App.cachePath = root.path;
    final library = Directory('${root.path}/library')..createSync();
    File('${root.path}/local_path').writeAsStringSync(library.path);
    LocalManager.debugSkipComicSourceInit = true;
    manager = LocalManager();
    await manager.init();
    for (final item in [comic('1', 'Visible'), comic('2', 'Blocked')]) {
      final dir = Directory('${library.path}/${item.id}')..createSync();
      File('${dir.path}/cover.png').writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
        ),
      );
      await manager.add(item);
    }
    appdata.settings['blockedWords'] = ['Blocked'];
    appdata.settings['showFavoriteStatusOnTile'] = false;
    appdata.settings['showHistoryStatusOnTile'] = false;
    appdata.settings['comicDisplayMode'] = 'brief';
  });
  tearDown(() async {
    await manager.pendingDownloadTaskWrites;
    LocalManager.resetForTesting();
    LocalManager.debugSkipComicSourceInit = false;
    appdata.settings['blockedWords'] = <String>[];
    root.deleteSync(recursive: true);
  });

  testWidgets(
    'selection stays limited to visible identities across refresh and filtering',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const LocalComicsPage(),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LocalComicsPage));
      state.selectAll();
      await tester.pump();
      expect((state.selectedComics as Map).keys.map((item) => item.id), ['1']);
      state.invertSelection();
      expect(state.selectedComics, isEmpty);
      state.selectAll();
      await manager.add(comic('1', 'Updated'));
      await tester.pump();
      expect((state.selectedComics as Map).keys.single.title, 'Updated');
      appdata.settings['blockedWords'] = ['Blocked', 'Updated'];
      await tester.pump();
      expect(state.selectedComics, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a refreshed selection invalidates an already-open delete confirmation',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const LocalComicsPage(),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LocalComicsPage));
      state.selectAll();
      final menu = state.buildMultiSelectMenu() as MenuButton;
      menu.entries.first.onClick();
      await tester.pumpAndSettle();
      await manager.add(comic('1', 'Updated'));
      await tester.pump();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(manager.find('1', ComicType.local), isNotNull);
      expect(Directory('${manager.path}/1').existsSync(), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
