import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/gesture.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/search/search.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/context.dart';
import 'package:venera_plus/foundation/res.dart';
import 'package:venera_plus/foundation/search_history.dart';

import '../../widget_test_io.dart';

void main() {
  late Directory directory;
  late Map<String, dynamic> previousSettings;
  late List<String> previousKeywords;
  late List<SearchHistoryEntry> previousEntries;
  late String? previousDataPath;
  late String? previousCachePath;
  final installed = <String>[];
  final messages = <String>[];

  setUp(() {
    previousDataPath = _path();
    previousCachePath = _path(cache: true);
    directory = Directory.systemTemp.createTempSync('search-history-widget-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    previousSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
    previousKeywords = appdata.fullSearchHistory;
    previousEntries = List.of(appdata.searchHistoryEntries);
    appdata.setFullSearchHistory([]);
    appdata.searchHistoryEntries.clear();
    appdata.settings['language'] = 'en-US';
    appdata.settings['comicListDisplayMode'] = 'paging';
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['comicTileScale'] = 1.0;
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['blockedWordRules'] = <String, dynamic>{};
    appdata.settings['searchSources'] = <String>[];
    appdata.settings['searchShortcuts'] = <Map<String, dynamic>>[];
    appdata.settings['defaultSearchTarget'] = '';
    appdata.settings['autoAddLanguageFilter'] = 'none';
    appdata.settings['searchHistoryDisplayMode'] = 'detailed';
    messages.clear();
    configureComicWidgets();
    registerShowMessageHandler((_, message) => messages.add(message));
  });

  tearDown(() {
    for (final key in installed) {
      ComicSourceManager().remove(key);
    }
    installed.clear();
    configureComicWidgets();
    registerShowMessageHandler((_, _) {});
    appdata.setFullSearchHistory(previousKeywords);
    appdata.searchHistoryEntries
      ..clear()
      ..addAll(previousEntries);
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    App.dataPath = previousDataPath ?? Directory.systemTemp.path;
    App.cachePath = previousCachePath ?? Directory.systemTemp.path;
    directory.deleteSync(recursive: true);
  });

  ComicSource install(String key, SearchPageData data) {
    final source = _source(key, data);
    ComicSourceManager().add(source);
    installed.add(key);
    appdata.settings['searchSources'] = List<String>.of(installed);
    return source;
  }

  Future<void> mount(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(body: page),
      ),
    );
    await _frames(tester);
  }

  void testSearchPage(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await runWidgetIo(tester, () => appdata.saveData(false));
      }
    });
  }

  testSearchPage('same keyword keeps independent source and option records', (
    tester,
  ) async {
    final seen = <(String, String, int, List<String>)>[];
    SearchPageData data(String key) =>
        SearchPageData(_options(), (word, page, options) async {
          seen.add((key, word, page, List.of(options)));
          return Res(_comics(key, page), subData: 1);
        }, null);
    install('alpha', data('alpha'));
    install('beta', data('beta'));
    for (final query in [('alpha', 'a'), ('alpha', 'b'), ('beta', 'a')]) {
      await mount(
        tester,
        SearchResultPage(
          key: UniqueKey(),
          text: 'same',
          sourceKey: query.$1,
          options: [query.$2],
        ),
      );
    }
    expect(seen.map((query) => (query.$1, query.$4.single)), [
      ('alpha', 'a'),
      ('alpha', 'b'),
      ('beta', 'a'),
    ]);
    expect(appdata.searchHistoryEntries, hasLength(3));
    expect(
      appdata.searchHistoryEntries.map((entry) => entry.identity).toSet(),
      hasLength(3),
    );
    expect(appdata.searchHistory, ['same']);
    await mount(tester, const SearchPage());
    await tester.scrollUntilVisible(
      find.text('Search History'),
      250,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    await _frames(tester);
    expect(find.text('same'), findsNWidgets(3));
    expect(find.text('Order: First'), findsWidgets);
    expect(find.text('Order: Second'), findsWidgets);
  });

  testSearchPage(
    'detailed history restores its actual page and preserves comic tap consumers',
    (tester) async {
      final requested = <int>[];
      final taps = <Comic>[];
      install(
        'alpha',
        SearchPageData(_options(), (word, page, options) async {
          requested.add(page);
          return Res(_comics('alpha', page), subData: 8);
        }, null),
      );
      final entry = SearchHistoryEntry(
        keyword: 'resume',
        sourceKey: 'alpha',
        options: ['b'],
        page: 4,
      );
      appdata.searchHistoryEntries.add(entry);
      appdata.setFullSearchHistory(['resume']);
      await mount(tester, const SearchPage());
      await tester.scrollUntilVisible(
        find.text('Page 4'),
        250,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.tap(find.text('Page 4'));
      await _frames(tester);
      expect(requested, [4]);
      expect(find.text('Page 4 / 8'), findsWidgets);
      expect(find.text('alpha page 4 comic 0'), findsOneWidget);
      expect(appdata.searchHistoryEntries.first.page, 4);
      App.rootNavigatorKey.currentState!.pop();
      await _frames(tester);

      await mount(
        tester,
        SearchResultPage(
          key: UniqueKey(),
          text: 'resume',
          sourceKey: 'alpha',
          historyEntry: entry,
          onComicTap: taps.add,
        ),
      );
      await tester.tap(find.text('alpha page 4 comic 0'));
      expect(taps.single.id, '4-0');
    },
  );

  testSearchPage(
    'continuous preloading keeps the visible page and scrolling back rewrites it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      appdata.settings['comicListDisplayMode'] = 'continuous';
      final second = Completer<Res<List<Comic>>>();
      final requested = <int>[];
      install(
        'alpha',
        SearchPageData(const [], (word, page, options) {
          requested.add(page);
          if (page == 2) return second.future;
          return Future.value(Res(_comics('alpha', 1, count: 12), subData: 2));
        }, null),
      );
      await mount(
        tester,
        const SearchResultPage(text: 'visible', sourceKey: 'alpha'),
      );
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await _frames(tester);
      expect(requested, contains(2));
      scroll.jumpTo(0);
      await _frames(tester);
      second.complete(Res(_comics('alpha', 2, count: 12), subData: 2));
      await _frames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(appdata.searchHistoryEntries.first.page, 1);
      await tester.scrollUntilVisible(
        find.text('alpha page 2 comic 0'),
        350,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await _frames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(appdata.searchHistoryEntries.first.page, 2);
      scroll.jumpTo(0);
      await _frames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(appdata.searchHistoryEntries.first.page, 1);
    },
  );

  testSearchPage(
    'cursor restoration shows progress and cancellation rejects stale results and requests',
    (tester) async {
      final pending = <Completer<Res<List<Comic>>>>[];
      final requested = <(String, String?)>[];
      install(
        'cursor',
        SearchPageData(const [], null, (word, next, options) {
          requested.add((word, next));
          final completer = Completer<Res<List<Comic>>>();
          pending.add(completer);
          return completer.future;
        }),
      );
      await mount(
        tester,
        SearchResultPage(
          text: 'old',
          sourceKey: 'cursor',
          historyEntry: SearchHistoryEntry(
            keyword: 'old',
            sourceKey: 'cursor',
            page: 4,
          ),
        ),
      );
      expect(find.text('Restoring search page 0 / 4'), findsOneWidget);
      pending[0].complete(Res(_comics('cursor', 1), subData: 'next-2'));
      await _frames(tester);
      expect(requested, [('old', null), ('old', 'next-2')]);
      expect(find.text('Restoring search page 1 / 4'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(find.text('Search restoration cancelled'), findsOneWidget);
      pending[1].complete(Res(_comics('cursor', 2), subData: 'next-3'));
      await _frames(tester);
      expect(requested, hasLength(2));
      expect(find.text('cursor page 2 comic 0'), findsNothing);

      await tester.enterText(find.byType(TextField).first, 'new');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _frames(tester);
      expect(requested.last, ('new', null));
      pending[2].complete(Res(_comics('cursor', 1), subData: null));
      await _frames(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(appdata.searchHistoryEntries.first.keyword, 'new');
      expect(appdata.searchHistoryEntries.first.page, 1);
      expect(
        appdata.searchHistoryEntries
            .firstWhere((entry) => entry.keyword == 'old')
            .page,
        4,
      );
    },
  );

  testSearchPage(
    'replacing a query invalidates a cursor restoration before its response arrives',
    (tester) async {
      final old = Completer<Res<List<Comic>>>();
      final requested = <(String, String?)>[];
      install(
        'cursor',
        SearchPageData(const [], null, (word, next, options) {
          requested.add((word, next));
          return word == 'old'
              ? old.future
              : Future.value(Res(_comics('cursor', 1), subData: null));
        }),
      );
      await mount(
        tester,
        SearchResultPage(
          text: 'old',
          sourceKey: 'cursor',
          historyEntry: SearchHistoryEntry(
            keyword: 'old',
            sourceKey: 'cursor',
            page: 3,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'new');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _frames(tester);
      old.complete(Res(_comics('cursor', 9), subData: 'stale-next'));
      await _frames(tester);
      expect(requested, [('old', null), ('new', null)]);
      expect(find.text('cursor page 9 comic 0'), findsNothing);
      expect(appdata.searchHistoryEntries.first.keyword, 'new');
    },
  );

  testSearchPage('leaving during cursor restoration prevents another request', (
    tester,
  ) async {
    final response = Completer<Res<List<Comic>>>();
    final requested = <String?>[];
    install(
      'cursor',
      SearchPageData(const [], null, (word, next, options) {
        requested.add(next);
        return response.future;
      }),
    );
    await mount(tester, const Scaffold(body: Text('home')));
    unawaited(
      App.rootNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => SearchResultPage(
            text: 'leave',
            sourceKey: 'cursor',
            historyEntry: SearchHistoryEntry(
              keyword: 'leave',
              sourceKey: 'cursor',
              page: 4,
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
    App.rootNavigatorKey.currentState!.pop();
    response.complete(Res(_comics('cursor', 1), subData: 'must-not-load'));
    await _frames(tester);
    expect(requested, [null]);
    expect(find.text('home'), findsOneWidget);
  });

  testSearchPage('cursor restoration reaches the requested page in order', (
    tester,
  ) async {
    appdata.settings['comicListDisplayMode'] = 'continuous';
    final requested = <String?>[];
    install(
      'cursor',
      SearchPageData(const [], null, (word, next, options) async {
        requested.add(next);
        final page = next == null ? 1 : int.parse(next);
        return Res(
          _comics('cursor', page, count: page == 3 ? 1 : 8),
          subData: page == 3 ? null : '${page + 1}',
        );
      }),
    );
    await mount(
      tester,
      SearchResultPage(
        text: 'restore',
        sourceKey: 'cursor',
        historyEntry: SearchHistoryEntry(
          keyword: 'restore',
          sourceKey: 'cursor',
          page: 3,
        ),
      ),
    );
    await _frames(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(requested, [null, '2', '3']);
    final tile = find.text('cursor page 3 comic 0');
    expect(tile.hitTestable(), findsOneWidget);
    expect(appdata.searchHistoryEntries.first.page, 3);
  });

  testSearchPage(
    'deleted source asks for a replacement and resets source options and page',
    (tester) async {
      final requested = <(int, List<String>)>[];
      install(
        'replacement',
        SearchPageData(_options(), (word, page, options) async {
          requested.add((page, List.of(options)));
          return Res(_comics('replacement', page), subData: 1);
        }, null),
      );
      appdata.searchHistoryEntries.add(
        SearchHistoryEntry(
          keyword: 'missing',
          sourceKey: 'deleted',
          sourceName: 'Old source',
          options: ['gone'],
          page: 9,
        ),
      );
      await mount(tester, const SearchPage());
      await tester.scrollUntilVisible(
        find.text('Page 9'),
        250,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.tap(find.text('Page 9'));
      await _frames(tester);
      expect(
        find.text('This search source is unavailable. Choose another source.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(SimpleDialogOption, 'replacement'));
      await _frames(tester);
      expect(requested.map((query) => query.$1), [1]);
      expect(requested.single.$2, ['a']);
      expect(appdata.searchHistoryEntries.first.sourceKey, 'replacement');
      expect(appdata.searchHistoryEntries.first.page, 1);
    },
  );

  testSearchPage(
    'aggregated searches and entering one source keep separate records',
    (tester) async {
      install(
        'alpha',
        SearchPageData(
          const [],
          (word, page, options) async =>
              Res(_comics('alpha', page), subData: 1),
          null,
        ),
      );
      await mount(tester, const AggregatedSearchPage(keyword: 'shared'));
      expect(
        appdata.searchHistoryEntries.single.sourceKey,
        SearchHistoryEntry.aggregatedSourceKey,
      );
      await tester.tap(find.text('alpha'));
      await _frames(tester);
      expect(find.byType(SearchResultPage), findsOneWidget);
      expect(appdata.searchHistoryEntries.map((entry) => entry.sourceKey), [
        'alpha',
        SearchHistoryEntry.aggregatedSourceKey,
      ]);
      expect(appdata.searchHistory, ['shared']);
    },
  );

  testSearchPage(
    'multi-select history validates each saved key rather than the option count',
    (tester) async {
      final requested = <(int, List<String>)>[];
      final definitions = [
        SearchOptions(
          LinkedHashMap.of({'a': 'First', 'b': 'Second'}),
          'Tags',
          'multi-select',
          '["a"]',
        ),
      ];
      install(
        'alpha',
        SearchPageData(definitions, (word, page, options) async {
          requested.add((page, List.of(options)));
          return Res(_comics('alpha', page), subData: 1);
        }, null),
      );
      await mount(
        tester,
        SearchResultPage(
          text: 'changed',
          sourceKey: 'alpha',
          historyEntry: SearchHistoryEntry(
            keyword: 'changed',
            sourceKey: 'alpha',
            options: ['["removed"]'],
            page: 7,
          ),
        ),
      );
      expect(requested.map((query) => query.$1), [1]);
      expect(requested.single.$2, ['["a"]']);
      expect(
        messages,
        contains(
          'Search options have changed. Using current defaults from page 1.',
        ),
      );
    },
  );

  testSearchPage(
    'same-length changed filter values fall back and explain page one',
    (tester) async {
      final requested = <(int, List<String>)>[];
      install(
        'alpha',
        SearchPageData(_options(), (word, page, options) async {
          requested.add((page, List.of(options)));
          return Res(_comics('alpha', page), subData: 1);
        }, null),
      );
      await mount(
        tester,
        SearchResultPage(
          text: 'changed',
          sourceKey: 'alpha',
          historyEntry: SearchHistoryEntry(
            keyword: 'changed',
            sourceKey: 'alpha',
            options: ['deleted-value'],
            page: 7,
          ),
        ),
      );
      expect(requested.map((query) => query.$1), [1]);
      expect(requested.single.$2, ['a']);
      expect(
        messages,
        contains(
          'Search options have changed. Using current defaults from page 1.',
        ),
      );
      expect(appdata.searchHistoryEntries.first.page, 1);
    },
  );

  testSearchPage(
    'mode switches retain both histories on a narrow screen and keep legacy words usable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requested = <String>[];
      install(
        'alpha',
        SearchPageData(const [], (word, page, options) async {
          requested.add(word);
          return Res(_comics('alpha', page), subData: 1);
        }, null),
      );
      appdata.setFullSearchHistory(['legacy-only']);
      appdata.searchHistoryEntries.add(
        SearchHistoryEntry(keyword: 'detailed', sourceKey: 'alpha', page: 4),
      );
      await mount(tester, const SearchPage());
      await tester.scrollUntilVisible(
        find.text('Search History'),
        250,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.tap(find.byTooltip('Switch to keyword search history'));
      await _frames(tester);
      expect(find.text('legacy-only'), findsOneWidget);
      expect(appdata.searchHistoryEntries.single.keyword, 'detailed');
      expect(appdata.settings['searchHistoryDisplayMode'], 'keywords');
      await tester.tap(find.byTooltip('Switch to detailed search history'));
      await _frames(tester);
      expect(find.text('detailed'), findsOneWidget);
      expect(appdata.searchHistory, ['legacy-only']);
      expect(appdata.searchHistoryEntries.single.page, 4);
      late Map<String, dynamic> saved;
      await runWidgetIo(tester, () async {
        await appdata.saveData(false);
        saved =
            jsonDecode(
                  await File('${directory.path}/appdata.json').readAsString(),
                )
                as Map<String, dynamic>;
      });
      expect(
        (saved['settings'] as Map)['searchHistoryDisplayMode'],
        'detailed',
      );
      expect(saved['searchHistory'], ['legacy-only']);
      expect((saved['searchHistoryEntries'] as List).single['page'], 4);
      expect(tester.takeException(), isNull);
      appdata.searchHistoryEntries.clear();
      await mount(tester, SearchPage(key: UniqueKey()));
      await tester.scrollUntilVisible(
        find.text('legacy-only'),
        250,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      await tester.tap(find.text('legacy-only'));
      await _frames(tester);
      expect(requested, ['legacy-only']);
    },
  );

  testSearchPage(
    'copy, delete and clear operate on the selected history mode',
    (tester) async {
      install(
        'alpha',
        SearchPageData(
          const [],
          (word, page, options) async =>
              Res(_comics('alpha', page), subData: 1),
          null,
        ),
      );
      appdata.setFullSearchHistory(['legacy']);
      appdata.searchHistoryEntries.addAll([
        SearchHistoryEntry(keyword: 'one', sourceKey: 'alpha'),
        SearchHistoryEntry(keyword: 'two', sourceKey: 'alpha'),
      ]);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await mount(tester, const SearchPage());
      await tester.scrollUntilVisible(
        find.text('one'),
        250,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      final row = find.ancestor(
        of: find.text('one'),
        matching: find.byType(ClickInkWell),
      );
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await _frames(tester);
      await tester.tap(find.text('Copy'));
      await _frames(tester);
      expect(clipboard, 'one');
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await _frames(tester);
      await tester.tap(find.text('Delete'));
      await _frames(tester);
      expect(appdata.searchHistoryEntries.map((entry) => entry.keyword), [
        'two',
      ]);
      expect(appdata.searchHistory, ['legacy']);
      await runWidgetIo(tester, () => appdata.saveData(false));
      await _frames(tester);
      expect(find.text('one'), findsNothing);
      await tester.tap(find.byTooltip('Clear').last);
      await _frames(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await _frames(tester);
      expect(appdata.searchHistoryEntries, isEmpty);
      expect(appdata.searchHistory, ['legacy']);
    },
  );

  testSearchPage(
    'empty source queries remain usable without creating invalid history',
    (tester) async {
      final requested = <String>[];
      install(
        'alpha',
        SearchPageData(const [], (word, page, options) async {
          requested.add(word);
          return const Res(<Comic>[], subData: 1);
        }, null),
      );
      await mount(tester, const SearchResultPage(text: '', sourceKey: 'alpha'));
      expect(requested, ['']);
      expect(appdata.searchHistoryEntries, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

List<SearchOptions> _options() => [
  SearchOptions(
    LinkedHashMap.of({'a': 'First', 'b': 'Second'}),
    'Order',
    'select',
    'a',
  ),
];

List<Comic> _comics(String key, int page, {int count = 8}) => [
  for (var index = 0; index < count; index++)
    Comic(
      '$key page $page comic $index',
      '',
      '$page-$index',
      null,
      null,
      '',
      key,
      null,
      null,
    ),
];

// Uses the same concrete, network-free source fixture as runtime_sources_test.
ComicSource _source(String key, SearchPageData data) => ComicSource(
  key,
  key,
  null,
  null,
  null,
  null,
  const [],
  data,
  null,
  null,
  null,
  null,
  null,
  null,
  '',
  '',
  '',
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

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

String? _path({bool cache = false}) {
  try {
    return cache ? App.cachePath : App.dataPath;
  } catch (_) {
    return null;
  }
}
