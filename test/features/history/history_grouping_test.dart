import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/comic_type.dart';

const _sourceA = 'history_group_source_a';
const _sourceB = 'history_group_source_b';

void main() {
  late Directory directory;
  late HistoryManager? previousHistory;
  late Map<String, dynamic> previousSettings;
  late _HistoryManager manager;
  late History older;
  late History latest;
  late History single;

  setUpAll(() async {
    directory = Directory.systemTemp.createTempSync('history-grouping-');
    App.dataPath = App.cachePath = directory.path;
    LocalManager.debugSkipComicSourceInit = true;
    await LocalManager().init();
  });

  tearDownAll(() async {
    LocalManager.resetForTesting();
    await directory.delete(recursive: true);
  });

  setUp(() {
    previousHistory = HistoryManager.cache;
    previousSettings = {
      for (final key in [
        'bangumiBindings',
        'comicDisplayMode',
        'language',
        'blockedWords',
        'showDetailedReadingProgress',
      ])
        key: appdata.settings[key],
    };
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['language'] = 'en-US';
    appdata.settings['blockedWords'] = <String>[];
    ComicSourceManager().add(_source(_sourceA, 'Source A'));
    ComicSourceManager().add(_source(_sourceB, 'Source B'));
    older = _history('older', _sourceA, 10, ep: 12, page: 30);
    latest = _history('latest', _sourceB, 30, ep: 2, page: 4);
    single = _history('single', 'local', 20);
    manager = _HistoryManager([older, single, latest]);
    HistoryManager.cache = manager;
    _bind([older, latest]);
    configureComicWidgets();
  });

  tearDown(() {
    configureComicWidgets();
    HistoryManager.cache = previousHistory;
    manager.dispose();
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    ComicSourceManager().remove(_sourceA);
    ComicSourceManager().remove(_sourceB);
  });

  testWidgets(
    'histories retain each source title and position despite shared bindings',
    (tester) async {
      await tester.pumpWidget(_host());
      expect(_grid(tester).comics, [latest, single, older]);
      expect(_grid(tester).comics.map((comic) => comic.title), [
        'Title latest',
        'Title single',
        'Title older',
      ]);
      expect(older.resumePosition, const ReadingPosition(ep: 12, page: 30));
      expect(latest.resumePosition, const ReadingPosition(ep: 2, page: 4));
      expect(manager.records, hasLength(3));
    },
  );

  testWidgets(
    'removing one history leaves other sources for the same work intact',
    (tester) async {
      await tester.pumpWidget(_host());
      _menu(tester, 'Remove');
      await tester.pump();
      expect(manager.deleted, [ComicID(latest.type, latest.id)]);
      expect(_grid(tester).comics, [single, older]);
    },
  );

  testWidgets('refresh updates the selected source without a source selector', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    _menu(tester, 'Refresh Info');
    await tester.pump();
    expect(manager.refreshed, [latest]);
    expect(older.resumePosition, const ReadingPosition(ep: 12, page: 30));
  });

  testWidgets('blocked sources stay outside batch selection', (tester) async {
    appdata.settings['blockedWords'] = ['Title latest'];
    await tester.pumpWidget(_host());
    await tester.tap(find.byTooltip('Multi-Select'));
    await tester.pump();
    await tester.tap(find.byTooltip('Select All'));
    await tester.pump();
    expect(_grid(tester).selections!.keys, unorderedEquals([single, older]));
    await tester.tap(find.byTooltip('Delete'));
    await tester.pump();
    expect(manager.records, [latest]);
  });
  testWidgets('inactive progress updates refresh once when visible', (
    tester,
  ) async {
    var active = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return HistoryPage(isActive: active);
          },
        ),
      ),
    );
    expect(manager.queries, 1);
    update(() => active = false);
    await tester.pump();
    appdata.settings['bangumiBindings'] = <String, dynamic>{};
    manager.changed();
    manager.changed();
    await tester.pump();
    expect(manager.queries, 1);

    update(() => active = true);
    await tester.pump();
    expect(manager.queries, 2);
    expect(_grid(tester).comics, hasLength(3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'normal tap opens latest source details and Continue resumes it',
    (tester) async {
      final observer = _Routes();
      await tester.pumpWidget(_host(observer: observer));
      var grid = _grid(tester);
      grid.onTap!(grid.comics.first, 17);
      await tester.idle();
      var route = observer.latest as AppPageRoute;
      final details =
          route.builder(tester.element(find.byType(HistoryPage))) as ComicPage;
      expect(details.id, latest.id);
      expect(details.sourceKey, _sourceB);
      expect(details.heroID, 17);
      App.rootNavigatorKey.currentState!.removeRoute(route);
      await tester.pumpAndSettle();

      _menu(tester, 'Continue');
      await tester.idle();
      route = observer.latest as AppPageRoute;
      final reader =
          route.builder(tester.element(find.byType(HistoryPage)))
              as ReaderWithLoading;
      expect(reader.id, latest.id);
      expect(reader.sourceKey, _sourceB);
      expect(reader.initialEp, isNull);
      expect(reader.initialPage, isNull);
      expect(reader.initialNavigationSource, ReadingNavigationSource.restore);
      App.rootNavigatorKey.currentState!.removeRoute(route);
      await tester.pumpAndSettle();
      expect(manager.records, [older, single, latest]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Widget _host({_Routes? observer}) => MaterialApp(
  navigatorKey: App.rootNavigatorKey,
  navigatorObservers: [if (observer != null) observer],
  home: const HistoryPage(),
);

SliverGridComics _grid(WidgetTester tester) =>
    tester.widget(find.byType(SliverGridComics));

void _menu(WidgetTester tester, String text) {
  final grid = _grid(tester);
  grid.menuBuilder!(grid.comics.first)
      .singleWhere((entry) => entry.text == text)
      .onClick();
}

History _history(
  String id,
  String source,
  int time, {
  int ep = 1,
  int page = 1,
}) => History.fromMap({
  'id': id,
  'type': ComicType.fromKey(source).value,
  'title': 'Title $id',
  'time': time,
  'ep': ep,
  'page': page,
});

void _bind(List<History> records) {
  appdata.settings['bangumiBindings'] = {
    for (final record in records)
      bangumiBindingKey(record.sourceKey, record.id): {
        'sourceKey': record.sourceKey,
        'comicId': record.id,
        'subjectId': 42,
        'subjectTitle': 'Work 42',
      },
  };
}

class _HistoryManager extends HistoryManager {
  _HistoryManager(this.records) : super.create();

  final List<History> records;
  final deleted = <ComicID>[];
  final refreshed = <History>[];
  int queries = 0;

  @override
  List<History> getAll() {
    queries++;
    return List.of(records)..sort((a, b) => b.time.compareTo(a.time));
  }

  @override
  History? find(String id, ComicType type) {
    for (final record in records) {
      if (record.id == id && record.type == type) return record;
    }
    return null;
  }

  @override
  void batchDeleteHistories(List<ComicID> histories) {
    deleted.addAll(histories);
    records.removeWhere(
      (record) => histories.contains(ComicID(record.type, record.id)),
    );
    notifyListeners();
  }

  @override
  void remove(String id, ComicType type) =>
      batchDeleteHistories([ComicID(type, id)]);

  @override
  Future<bool> refreshHistoryInfo(
    History history, {
    Future<void> Function(Duration duration)? retryDelay,
  }) async {
    refreshed.add(history);
    return true;
  }

  void changed() => notifyListeners();
}

class _Routes extends NavigatorObserver {
  Route<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      latest = route;
}

ComicSource _source(String key, String name) => ComicSource(
  name,
  key,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'test.js',
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
