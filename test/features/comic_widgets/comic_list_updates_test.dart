import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/res.dart';

void main() {
  late Map<String, dynamic> previousSettings;

  setUp(() {
    previousSettings = {
      for (final key in [
        'blockedWords',
        'comicDisplayMode',
        'comicListDisplayMode',
        'comicTileScale',
        'language',
      ])
        key: appdata.settings[key],
    };
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['comicListDisplayMode'] = 'continuous';
    appdata.settings['comicTileScale'] = 1.0;
    appdata.settings['language'] = 'en-US';
  });

  tearDown(() {
    previousSettings.forEach((key, value) => appdata.settings[key] = value);
  });

  testWidgets('changes during a reload trigger one final fresh reload', (
    tester,
  ) async {
    late VoidCallback notifyChanged;
    final pending = Completer<Res<List<Comic>>>();
    var calls = 0;
    var title = 'Initial';
    await tester.pumpWidget(
      _host(
        ComicList(
          loadPage: (_) async {
            calls++;
            if (calls == 2) return pending.future;
            return Res([_comic('one', title)], subData: 1);
          },
          reloadHandlerCallback: (reload) => notifyChanged = reload,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Initial'), findsOneWidget);

    notifyChanged();
    await tester.pump();
    expect(calls, 2);
    title = 'Newest';
    for (var index = 0; index < 20; index++) {
      notifyChanged();
    }
    pending.complete(Res([_comic('one', 'Stale')], subData: 1));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Stale'), findsNothing);
  });

  testWidgets('pending invalidation stops when the list is disposed', (
    tester,
  ) async {
    late VoidCallback notifyChanged;
    final pending = Completer<Res<List<Comic>>>();
    var calls = 0;
    await tester.pumpWidget(
      _host(
        ComicList(
          loadPage: (_) async {
            calls++;
            if (calls == 2) return pending.future;
            return Res([_comic('one', 'Initial')], subData: 1);
          },
          reloadHandlerCallback: (reload) => notifyChanged = reload,
        ),
      ),
    );
    await tester.pumpAndSettle();
    notifyChanged();
    await tester.pump();
    notifyChanged();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(const Res([], subData: 1));
    await tester.pump();
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('content changes preserve a queued reset request', (
    tester,
  ) async {
    final key = GlobalKey<ComicListState>();
    late VoidCallback notifyChanged;
    final pending = Completer<Res<List<Comic>>>();
    final calls = <int>[];
    await tester.pumpWidget(
      _host(
        ComicList(
          key: key,
          initialPage: 2,
          loadPage: (page) async {
            calls.add(page);
            if (calls.length == 2) return pending.future;
            return Res([_comic('book-$page', 'Book page $page')], subData: 2);
          },
          reloadHandlerCallback: (reload) => notifyChanged = reload,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, [2]);
    notifyChanged();
    await tester.pump();
    final reset = key.currentState!.reload(reset: true);
    notifyChanged();
    pending.complete(Res([_comic('old', 'Stale page')], subData: 2));
    await tester.pumpAndSettle();
    await reset;
    expect(calls.take(3), [2, 2, 1]);
    expect(find.text('Book page 1'), findsOneWidget);
  });

  testWidgets('inserting many books preserves the visible comic anchor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var comics = [
      for (var index = 0; index < 100; index++)
        _comic('$index', 'Comic $index'),
    ];
    late StateSetter update;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return CustomScrollView(
              controller: controller,
              slivers: [
                SliverGridComics(comics: comics, preserveScrollPosition: true),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.jumpTo(20 * 152 + 40);
    await tester.pumpAndSettle();
    final originalTop = tester.getTopLeft(find.text('Comic 20')).dy;
    update(() {
      comics = [
        for (var index = 0; index < 50; index++)
          _comic('new-$index', 'New $index'),
        ...comics,
      ];
    });
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Comic 20')).dy, originalTop);
    expect(controller.offset, 70 * 152 + 40);

    controller.jumpTo(130 * 152 + 40);
    await tester.pumpAndSettle();
    final topBeforeRemoval = tester.getTopLeft(find.text('Comic 80')).dy;
    update(() => comics = comics.sublist(100));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Comic 80')).dy, topBeforeRemoval);
    expect(controller.offset, 30 * 152 + 40);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Comic _comic(String id, String title) =>
    Comic(title, '', id, null, null, '', 'remote-list-test', null, null);
