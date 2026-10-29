import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
    configureComicWidgets(openDetails: (_, comic, _) => opened.add(comic));
  });

  tearDown(() {
    configureComicWidgets();
    previous.forEach((key, value) => appdata.settings[key] = value);
  });

  testWidgets(
    'source changes replace tile identity and open the selected source',
    (tester) async {
      var comic = a;
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
      await tester.tap(find.text('First source'));
      expect(opened.single, same(comic));

      rebuild(() => comic = b);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ComicTile>(find.byType(ComicTile)).heroID,
        isNot(firstHero),
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
      expect(opened.last.sourceKey, 'source-b');
    },
  );
}
