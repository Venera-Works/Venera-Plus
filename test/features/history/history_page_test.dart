import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/history/history.dart';
import 'package:venera_plus/foundation/app_page_route.dart';

void main() {
  group('HistoryPage', () {
    late HistoryManager? previousHistory;
    late _HistoryManager manager;

    setUp(() {
      previousHistory = HistoryManager.cache;
      manager = _HistoryManager();
      HistoryManager.cache = manager;
    });

    tearDown(() {
      HistoryManager.cache = previousHistory;
      manager.dispose();
    });

    testWidgets(
      'inactive history tab defers and coalesces progress refreshes',
      (tester) async {
        var active = false;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return HistoryPage(isActive: active);
              },
            ),
          ),
        );
        expect(manager.queries, 0);

        for (var page = 0; page < 20; page++) {
          manager.progressChanged();
          await tester.pump();
        }
        expect(manager.queries, 0);

        update(() => active = true);
        await tester.pump();
        expect(manager.queries, 1);

        manager.progressChanged();
        await tester.pump();
        expect(manager.queries, 2);

        update(() => active = false);
        await tester.pump();
        manager.progressChanged();
        manager.progressChanged();
        await tester.pump();
        expect(manager.queries, 2);

        update(() => active = true);
        await tester.pump();
        expect(manager.queries, 3);
        update(() {});
        await tester.pump();
        expect(manager.queries, 3);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    for (final nested in [false, true]) {
      for (final deactivateWhileCovered in [false, true]) {
        testWidgets(
          'covered history route refreshes when visible (nested=$nested, inactive=$deactivateWhileCovered)',
          (tester) async {
            final navigatorKey = GlobalKey<NavigatorState>();
            var active = true;
            late StateSetter update;
            final history = StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return HistoryPage(isActive: active);
              },
            );
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navigatorKey,
                home: nested
                    ? Navigator(
                        onGenerateRoute: (settings) =>
                            AppPageRoute<void>(builder: (context) => history),
                      )
                    : history,
              ),
            );
            expect(manager.queries, 1);

            navigatorKey.currentState!.push(
              AppPageRoute<void>(
                builder: (context) => const Scaffold(body: Text('Reader')),
              ),
            );
            if (!nested) {
              // A progress event can arrive before the covered route rebuilds.
              manager.progressChanged();
            }
            expect(manager.queries, 1);
            await tester.pumpAndSettle();
            expect(
              find.byType(HistoryPage, skipOffstage: false),
              findsOneWidget,
            );

            for (var page = 0; page < 20; page++) {
              manager.progressChanged();
              await tester.pump();
            }
            expect(manager.queries, 1);

            if (deactivateWhileCovered) {
              update(() => active = false);
              await tester.pump();
            }
            navigatorKey.currentState!.pop();
            await tester.pumpAndSettle();
            expect(manager.queries, deactivateWhileCovered ? 1 : 2);

            if (deactivateWhileCovered) {
              update(() => active = true);
              await tester.pump();
              expect(manager.queries, 2);
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  });

  group('ReadingStatsSummary', () {
    testWidgets('reading stats summary keeps the tracked label on one line', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReadingStatsSummary(
              totalDuration: Duration(hours: 12, minutes: 36),
              comicCount: 18,
              mostReadTitle: 'A very long comic title used for compact layout',
            ),
          ),
        ),
      );

      final labelSize = tester.getSize(find.text('Comics tracked'));
      expect(labelSize.height, lessThan(24));
      expect(tester.takeException(), isNull);
    });
  });
}

class _HistoryManager extends HistoryManager {
  _HistoryManager() : super.create();

  int queries = 0;

  @override
  List<History> getAll() {
    queries++;
    return [];
  }

  void progressChanged() => notifyListeners();
}
