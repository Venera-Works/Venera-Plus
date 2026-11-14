import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/navigation_bar.dart';
import 'package:venera_plus/foundation/app_page_route.dart';

const _flightKey = ValueKey('cover-flight');

Widget _page({bool detail = false}) => Material(
  child: Align(
    alignment: detail ? Alignment.topRight : Alignment.bottomLeft,
    child: Hero(
      tag: 'cover',
      transitionOnUserGestures: true,
      flightShuttleBuilder: (_, _, _, _, _) =>
          const ColoredBox(key: _flightKey, color: Colors.orange),
      child: SizedBox(
        width: detail ? 144 : 80,
        height: detail ? 200 : 110,
        child: ColoredBox(color: detail ? Colors.green : Colors.blue),
      ),
    ),
  ),
);

class _Harness {
  final navigation = ValueNotifier(GlobalKey<NavigatorState>());
  final rebuild = ValueNotifier(0);
  final observer = NaviObserver();

  NavigatorState get navigator => navigation.value.currentState!;

  HeroController get hero =>
      HeroControllerScope.of(navigation.value.currentContext!);

  Future<void> mount(WidgetTester tester) async {
    addTearDown(navigation.dispose);
    addTearDown(rebuild.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: Listenable.merge([navigation, rebuild]),
          builder: (_, _) => NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Library',
                icon: Icons.book,
                activeIcon: Icons.book,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) => _page(),
            observer: observer,
            navigatorKey: navigation.value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void push() {
    navigator.push<void>(
      AppPageRoute<void>(builder: (_) => _page(detail: true)),
    );
  }
}

void main() {
  testWidgets('cover flight finishes after the navigation layout rebuilds', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    final original = harness.hero;
    harness.push();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byKey(_flightKey), findsOneWidget);
    harness.rebuild.value++;
    await tester.pump();
    expect(harness.hero, same(original));
    await tester.pumpAndSettle();
    expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
    harness.navigator.pop();
    await tester.pumpAndSettle();
    expect(harness.observer.routes, hasLength(1));
    expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled back gesture clears its cover after a rebuild', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    harness.push();
    await tester.pumpAndSettle();
    harness.navigator.didStartUserGesture();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(_flightKey), findsOneWidget);
    harness.rebuild.value++;
    await tester.pump();
    harness.navigator.didStopUserGesture();
    await tester.pumpAndSettle();
    expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
    expect(harness.observer.routes, hasLength(2));
    harness.navigator.pop();
    await tester.pumpAndSettle();
    expect(harness.observer.routes, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('replacing a navigator releases an active cover flight', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.mount(tester);
    harness.push();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    final original = harness.hero;
    harness.navigation.value = GlobalKey<NavigatorState>();
    await tester.pumpAndSettle();
    expect(harness.hero.navigator, same(harness.navigator));
    expect(original.navigator, isNull);
    expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
    harness.push();
    await tester.pumpAndSettle();
    harness.navigator.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byKey(_flightKey, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
