import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_details/comic_details.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/features/local_comics/local_comics.dart';
import 'package:venera_plus/features/reader/reader.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/app_page_route.dart';
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
    configureComicWidgets(
      identityResolver: (comic) => comic is BangumiComicGroup
          ? comic.groupKey
          : (comic.sourceKey, comic.id),
    );
  });

  tearDown(() {
    configureComicWidgets();
    HistoryManager.cache = previousHistory;
    manager.dispose();
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
    ComicSourceManager().remove(_sourceA);
    ComicSourceManager().remove(_sourceB);
  });

  testWidgets('groups all history by work and keeps source records intact', (
    tester,
  ) async {
    final unknown = _history('unknown', 'missing', 5);
    manager.records.add(unknown);
    await tester.pumpWidget(_host());

    final grid = _grid(tester);
    final groups = grid.comics.cast<BangumiComicGroup<History>>();
    expect(groups, hasLength(3));
    expect(groups.first.subjectId, 42);
    expect(groups.first.members, [latest, older]);
    expect(groups.first.representative, same(latest));
    expect(groups.first.description, latest.description);
    expect(groups.skip(1).map((group) => group.members.single), [
      single,
      unknown,
    ]);
    expect(grid.badgeBuilder!(groups.first), '2 sources');
    expect(grid.badgeBuilder!(groups[1]), 'Local');
    expect(grid.badgeBuilder!(groups[2]), unknown.sourceKey);
    expect(manager.records, [older, single, latest, unknown]);
    expect(older.resumePosition, const ReadingPosition(ep: 12, page: 30));
    expect(latest.resumePosition, const ReadingPosition(ep: 2, page: 4));
    expect(manager.deleted, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'selection counts works and deleting a work expands its sources',
    (tester) async {
      await tester.pumpWidget(_host());
      await tester.tap(find.byTooltip('Multi-Select'));
      await tester.pump();
      await tester.tap(find.byTooltip('Select All'));
      await tester.pump();
      expect(_grid(tester).selections, hasLength(2));

      await tester.tap(find.byTooltip('Deselect'));
      await tester.pump();
      expect(_grid(tester).selections, isEmpty);
      final grid = _grid(tester);
      grid.onTap!(grid.comics.last, 0);
      await tester.pump();
      await tester.tap(find.byTooltip('Invert Selection'));
      await tester.pump();
      expect(_grid(tester).selections!.keys.single, _grid(tester).comics.first);

      await tester.tap(find.byTooltip('Delete'));
      await tester.pump();
      expect(
        manager.deleted,
        unorderedEquals([
          ComicID(older.type, older.id),
          ComicID(latest.type, latest.id),
        ]),
      );
      expect(manager.records, [single]);
      expect(_grid(tester).comics, hasLength(1));
      expect(find.byTooltip('Multi-Select'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('blocked works stay outside selection without querying history', (
    tester,
  ) async {
    appdata.settings['blockedWords'] = ['Work 42'];
    await tester.pumpWidget(_host());
    final queries = manager.queries;
    expect(_grid(tester).comics, hasLength(1));
    await tester.tap(find.byTooltip('Multi-Select'));
    await tester.pump();
    await tester.tap(find.byTooltip('Select All'));
    await tester.pump();
    expect(_grid(tester).selections!.keys.single, _grid(tester).comics.single);

    await tester.tap(find.byTooltip('Invert Selection'));
    await tester.pump();
    expect(_grid(tester).selections, isEmpty);
    await tester.tap(find.byTooltip('Invert Selection'));
    await tester.pump();
    expect(_grid(tester).selections, hasLength(1));

    appdata.settings['blockedWords'] = <String>[];
    await tester.pump();
    expect(_grid(tester).comics, hasLength(2));
    expect(_grid(tester).selections, hasLength(1));
    await tester.tap(find.byTooltip('Select All'));
    await tester.pump();
    expect(_grid(tester).selections, hasLength(2));
    appdata.settings['blockedWords'] = ['Work 42'];
    await tester.pump();
    expect(_grid(tester).comics, hasLength(1));
    expect(_grid(tester).selections!.keys.single, _grid(tester).comics.single);
    expect(manager.queries, queries);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pump();
    expect(manager.deleted, [ComicID(single.type, single.id)]);
    expect(manager.records, [older, latest]);
    expect(find.byType(SliverGridComics), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('work menu removes every source without affecting other works', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    _menu(tester, 'Remove work history');
    await tester.pump();
    expect(manager.deleted, hasLength(2));
    expect(manager.records, [single]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'source removal can delete unavailable history by its real type',
    (tester) async {
      final unavailable = _history('removed-source', 'missing', 40);
      manager.records.add(unavailable);
      _bind([older, latest, unavailable]);
      await tester.pumpWidget(_host());
      _menu(tester, 'Remove source history');
      await tester.pumpAndSettle();

      final source = find.byKey(
        ValueKey('comic-source:${unavailable.sourceKey}:${unavailable.id}'),
      );
      expect(tester.widget<ListTile>(source).enabled, isTrue);
      await tester.tap(source);
      await tester.pumpAndSettle();

      expect(manager.deleted, [ComicID(unavailable.type, unavailable.id)]);
      expect(manager.records, [older, single, latest]);
      expect(
        (_grid(tester).comics.first as BangumiComicGroup).members,
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('refresh chooses one source and keeps each saved position', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    _menu(tester, 'Refresh Info');
    await tester.pumpAndSettle();
    expect(manager.refreshed, isEmpty);
    await tester.tap(
      find.byKey(ValueKey('comic-source:$_sourceA:${older.id}')),
    );
    await tester.pumpAndSettle();

    expect(manager.refreshed, [older]);
    expect(older.resumePosition, const ReadingPosition(ep: 12, page: 30));
    expect(latest.resumePosition, const ReadingPosition(ep: 2, page: 4));
    expect(manager.deleted, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('binding changes regroup and clear selections immediately', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.byTooltip('Multi-Select'));
    await tester.pump();
    await tester.tap(find.byTooltip('Select All'));
    await tester.pump();
    final queries = manager.queries;

    appdata.settings['showDetailedReadingProgress'] = true;
    await tester.pump();
    expect(manager.queries, queries);
    appdata.settings['showDetailedReadingProgress'] = false;
    appdata.settings['bangumiBindings'] = <String, dynamic>{};
    await tester.pump();

    expect(_grid(tester).comics, hasLength(3));
    expect(_grid(tester).selections, isEmpty);
    expect(find.byTooltip('Multi-Select'), findsOneWidget);
    expect(manager.deleted, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'inactive binding and progress updates refresh once when visible',
    (tester) async {
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
    },
  );

  testWidgets('new group members clear selection before batch deletion', (
    tester,
  ) async {
    final incoming = _history('incoming', _sourceA, 40);
    _bind([older, latest, incoming]);
    await tester.pumpWidget(_host());
    await tester.tap(find.byTooltip('Multi-Select'));
    await tester.pump();
    final grid = _grid(tester);
    grid.onTap!(grid.comics.first, 0);
    await tester.pump();
    manager.records.add(incoming);
    manager.changed();
    await tester.pump();

    expect(_grid(tester).selections, isEmpty);
    expect(find.byTooltip('Multi-Select'), findsOneWidget);
    expect(manager.deleted, isEmpty);
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

  testWidgets('source switching resumes the explicitly chosen source', (
    tester,
  ) async {
    final observer = _Routes();
    await tester.pumpWidget(_host(observer: observer));
    _menu(tester, 'Choose comic source');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('comic-source:$_sourceA:${older.id}')),
    );
    await tester.idle();
    final route = observer.latest as AppPageRoute;
    final reader =
        route.builder(tester.element(find.byType(HistoryPage)))
            as ReaderWithLoading;
    expect(reader.id, older.id);
    expect(reader.sourceKey, _sourceA);
    expect(reader.initialEp, isNull);
    expect(reader.initialPage, isNull);
    App.rootNavigatorKey.currentState!.removeRoute(route);
    await tester.pumpAndSettle();
    expect(older.resumePosition, const ReadingPosition(ep: 12, page: 30));
    expect(latest.resumePosition, const ReadingPosition(ep: 2, page: 4));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
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
