import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/appbar.dart';
import 'package:venera_plus/components/layout.dart';
import 'package:venera_plus/features/comic_details/chapters.dart';
import 'package:venera_plus/features/comic_source/models.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Object? previousReverse;
  setUp(() {
    previousReverse = appdata.settings['reverseChapterOrder'];
    appdata.settings['reverseChapterOrder'] = false;
  });
  tearDown(() {
    appdata.settings['reverseChapterOrder'] = previousReverse;
  });

  test(
    'chapter display metadata survives cached JSON without changing titles',
    () {
      final details = ComicDetails.fromJson({
        ..._detailsJson(),
        'chapterPageCounts': {
          'a': 12,
          'zero': 0,
          'negative': -1,
          'text': '4',
          'fraction': 2.5,
          5: 8,
        },
        'chapterGroups': {'a': '第01卷', 'invalid': 2, 5: 'invalid'},
      });
      expect(details.chapterPageCounts, {'a': 12});
      expect(details.chapterGroups, {'a': '第01卷'});

      final restored = ComicDetails.fromJson(
        jsonDecode(jsonEncode(details.toJson())) as Map<String, dynamic>,
      );
      expect(restored.chapterPageCounts, {'a': 12});
      expect(restored.chapterGroups, {'a': '第01卷'});
      expect(restored.chapters!.isGrouped, isFalse);
      expect(restored.chapters!.ids, ['a', 'b', 'c', 'd']);
      expect(restored.chapters!['a'], '第01卷/第01话');
      expect(restored.chapters!['c'], '第02卷/第01话');
    },
  );

  test(
    'old details and absent or invalid chapter metadata default to empty',
    () {
      final oldDetails = ComicDetails.fromJson(_detailsJson());
      expect(oldDetails.chapterPageCounts, isEmpty);
      expect(oldDetails.chapterGroups, isEmpty);
      for (final value in [null, 'invalid', <Object>[]]) {
        final details = ComicDetails.fromJson({
          ..._detailsJson(),
          'chapterPageCounts': value,
          'chapterGroups': value,
        });
        expect(details.chapterPageCounts, isEmpty);
        expect(details.chapterGroups, isEmpty);
      }
    },
  );

  testWidgets(
    'flat chapter titles show page counts below without large text overflow',
    (tester) async {
      final selections = <(int, int?)>[];
      const title = '第01话：保留完整章节名称';
      await _pumpChapters(
        tester,
        chapters: const ComicChapters({'a': title, 'b': '第02话'}),
        pageCounts: const {'a': 12, 'b': 8},
        textScale: 2,
        readChapter: (ep, group) => selections.add((ep, group)),
      );

      expect(find.text(title), findsOneWidget);
      expect(find.text(_pages(12)), findsOneWidget);
      expect(find.text(_pages(8)), findsOneWidget);
      expect(
        tester.getRect(find.text(_pages(12))).top,
        greaterThan(tester.getRect(find.text(title)).bottom),
      );
      await tester.tap(find.text(title));
      expect(selections, [(1, null)]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ordinary flat sources keep their original title and 48 height', (
    tester,
  ) async {
    final selections = <(int, int?)>[];
    await _pumpChapters(
      tester,
      chapters: const ComicChapters({
        'a': 'Original title',
        'b': 'Other chapter',
      }),
      readChapter: (ep, group) => selections.add((ep, group)),
    );

    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedHeight).itemHeight,
      48,
    );
    expect(find.byType(AppTabBar), findsNothing);
    expect(find.text('Original title'), findsOneWidget);
    expect(find.textContaining('${"Pages".tl}:'), findsNothing);
    await tester.tap(find.text('Other chapter'));
    expect(selections, [(2, null)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'display groups keep flat history and map selections to global indices',
    (tester) async {
      final selections = <(int, int?)>[];
      final details = ComicDetails.fromJson(_detailsJson());
      final history = History.fromModel(model: details, ep: 3, page: 4);
      final chapters = details.chapters!;
      await _pumpChapters(
        tester,
        chapters: chapters,
        pageCounts: const {'a': 11, 'b': 12, 'c': 21, 'd': 22},
        chapterGroups: const {
          'a': '第01卷',
          'b': '第01卷',
          'c': '第02卷',
          'd': '第02卷',
        },
        history: history,
        readChapter: (ep, group) => selections.add((ep, group)),
      );

      final tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
      expect(tabs.controller!.length, 2);
      expect(tabs.controller!.index, 1);
      expect(find.text('第01卷'), findsOneWidget);
      expect(find.text('第02卷'), findsOneWidget);
      expect(find.text('第01话'), findsOneWidget);
      expect(find.text('第02卷/第01话'), findsNothing);
      expect(find.text(_pages(21)), findsOneWidget);
      await tester.tap(find.text('第01话'));
      expect(selections, [(3, null)]);

      await tester.tap(find.text('第01卷'));
      await tester.pumpAndSettle();
      expect(find.text(_pages(11)), findsOneWidget);
      await tester.tap(find.text('第02话'));
      expect(selections, [(3, null), (2, null)]);
      expect(chapters.isGrouped, isFalse);
      expect(chapters.ids, ['a', 'b', 'c', 'd']);
      expect(chapters['c'], '第02卷/第01话');
      expect(history.ep, 3);
      expect(history.group, isNull);
      expect(history.page, 4);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('display groups trim only matching group prefixes', (
    tester,
  ) async {
    await _pumpChapters(
      tester,
      chapters: const ComicChapters({'a': 'Metadata title/kept intact'}),
      chapterGroups: const {'a': 'Volume'},
    );
    expect(find.text('Volume'), findsOneWidget);
    expect(find.text('Metadata title/kept intact'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing grouped sources keep group-local episode callbacks', (
    tester,
  ) async {
    final selections = <(int, int?)>[];
    await _pumpChapters(
      tester,
      chapters: const ComicChapters.grouped({
        'Source A': {'a1': 'A1', 'a2': 'A2'},
        'Source B': {'b1': 'Source B/B1'},
        'Source C': {'c1': 'C1', 'c2': 'C2'},
      }),
      pageCounts: const {'b1': 17},
      chapterGroups: const {'b1': 'Ignored display metadata'},
      history: _history(ep: 1, group: 2),
      readChapter: (ep, group) => selections.add((ep, group)),
    );
    final tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
    expect(tabs.controller!.length, 3);
    expect(tabs.controller!.index, 1);
    expect(find.text('Ignored display metadata'), findsNothing);
    expect(find.text('Source B/B1'), findsOneWidget);
    expect(find.text(_pages(17)), findsOneWidget);
    await tester.tap(find.text('Source B/B1'));
    expect(selections, [(1, 2)]);
    await tester.tap(find.text('Source C'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('C2'));
    expect(selections, [(1, 2), (2, 3)]);
    expect(tester.takeException(), isNull);
  });

  for (final (savedGroup, selectedIndex) in [(0, 0), (99, 1)]) {
    testWidgets('out-of-range history group $savedGroup selects a valid tab', (
      tester,
    ) async {
      await _pumpChapters(
        tester,
        chapters: const ComicChapters.grouped({
          'A': {'a1': 'A1', 'a2': 'A2'},
          'B': {'b1': 'B1'},
        }),
        history: _history(ep: 1, group: savedGroup),
      );
      final tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
      expect(tabs.controller!.length, 2);
      expect(tabs.controller!.index, selectedIndex);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'async grouped updates retain a valid tab and clamp removed tabs',
    (tester) async {
      const initial = {
        'A': {'a1': 'A1', 'a2': 'A2'},
        'B': {'b1': 'B1'},
        'C': {'c1': 'C1'},
      };
      await _pumpChapters(
        tester,
        chapters: const ComicChapters.grouped(initial),
        history: _history(ep: 1, group: 2),
      );
      await _pumpChapters(
        tester,
        chapters: const ComicChapters.grouped({
          ...initial,
          'D': {'d1': 'D1'},
        }),
      );
      var tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
      expect(tabs.controller!.length, 4);
      expect(tabs.controller!.index, 1);
      expect(find.text('B1'), findsOneWidget);

      await tester.tap(find.text('D'));
      await tester.pumpAndSettle();
      expect(find.text('D1'), findsOneWidget);
      await _pumpChapters(
        tester,
        chapters: const ComicChapters.grouped({
          'A': {'a1': 'A1', 'a2': 'A2'},
          'B': {'b1': 'B1'},
        }),
      );
      tabs = tester.widget<AppTabBar>(find.byType(AppTabBar));
      expect(tabs.controller!.length, 2);
      expect(tabs.controller!.index, 1);
      expect(find.text('B1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

String _pages(int count) => '${"Pages".tl}: $count';

Map<String, dynamic> _detailsJson() => {
  'title': 'Archive',
  'cover': '',
  'tags': <String, List<String>>{},
  'sourceKey': 'archive-test',
  'comicId': 'archive',
  'chapters': {
    'a': '第01卷/第01话',
    'b': '第01卷/第02话',
    'c': '第02卷/第01话',
    'd': '第02卷/第02话',
  },
};

History _history({required int ep, int? group}) => History.fromModel(
  model: ComicDetails.fromJson(_detailsJson()),
  ep: ep,
  page: 1,
  group: group,
);

Future<void> _pumpChapters(
  WidgetTester tester, {
  required ComicChapters chapters,
  Map<String, int> pageCounts = const {},
  Map<String, String> chapterGroups = const {},
  History? history,
  void Function(int, int?)? readChapter,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            ComicChaptersView(
              chapters: chapters,
              pageCounts: pageCounts,
              chapterGroups: chapterGroups,
              history: history,
              readChapter: readChapter ?? (_, _) {},
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
