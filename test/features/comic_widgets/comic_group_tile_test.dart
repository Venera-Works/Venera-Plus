import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/features/comic_source/comic_source.dart';
import 'package:venera_plus/features/comic_widgets/comic_widgets.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  const a = Comic(
    'First source',
    '',
    'a',
    null,
    null,
    '',
    'source-a',
    null,
    null,
  );
  const b = Comic(
    'Second source',
    '',
    'b',
    null,
    null,
    '',
    'source-b',
    null,
    null,
  );
  late Map<String, dynamic> previous;
  late List<Comic> opened;

  setUp(() {
    previous = {
      for (final key in [
        'blockedWords',
        'comicDisplayMode',
        'comicTileScale',
        'language',
      ])
        key: appdata.settings[key],
    };
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['comicTileScale'] = 1.0;
    appdata.settings['language'] = 'en-US';
    opened = [];
    configureComicWidgets(
      identityResolver: (comic) => (comic as BangumiComicGroup).groupKey,
      openDetails: (_, comic, _) => opened.add(comic),
      tileStateResolver: (_) => const ComicTileState(sourceCount: 2),
    );
  });

  tearDown(() {
    configureComicWidgets();
    previous.forEach((key, value) => appdata.settings[key] = value);
  });

  BangumiComicGroup<Comic> group(Comic representative) => BangumiComicGroup(
    groupKey: 'bangumi:42',
    members: [a, b],
    representative: representative,
  );

  testWidgets(
    'representative changes keep hero identity and default details receive the complete group',
    (tester) async {
      var comic = group(a);
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return CustomScrollView(
                  slivers: [
                    SliverGridComics(comics: [comic]),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstHero = tester.widget<ComicTile>(find.byType(ComicTile)).heroID;
      expect(find.text('2 sources'), findsOneWidget);
      await tester.tap(find.text('First source'));
      expect(opened.single, same(comic));

      rebuild(() => comic = group(b));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ComicTile>(find.byType(ComicTile)).heroID,
        firstHero,
      );
      final tileContext = tester.element(find.byType(ComicTile));
      tester
          .widget<ComicTile>(find.byType(ComicTile))
          .showMenu(const Offset(10, 10), tileContext);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(2));
      expect(opened.last, same(comic));
      expect((opened.last as BangumiComicGroup).members, [a, b]);
    },
  );
}
