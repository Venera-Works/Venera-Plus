import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/scroll.dart';

const _listKey = Key('refresh-test-list');

Widget _refreshTestApp({
  required Future<void> Function() onRefresh,
  Widget? child,
}) {
  return MaterialApp(
    home: Scaffold(
      body: AppRefreshIndicator(
        onRefresh: onRefresh,
        child:
            child ??
            ListView.builder(
              key: _listKey,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 30,
              itemExtent: 48,
              itemBuilder: (context, index) => Text('Item $index'),
            ),
      ),
    ),
  );
}

void _sendVerticalWheel(
  WidgetTester tester,
  Offset position, {
  required double deltaY,
}) {
  tester.binding.handlePointerEvent(
    PointerHoverEvent(
      pointer: 20,
      device: 20,
      position: position,
      kind: PointerDeviceKind.mouse,
    ),
  );
  tester.binding.handlePointerEvent(
    PointerScrollEvent(
      device: 20,
      position: position,
      scrollDelta: Offset(0, deltaY),
      kind: PointerDeviceKind.mouse,
    ),
  );
}

void main() {
  testWidgets('wheel pulls refresh once per idle-separated burst', (
    tester,
  ) async {
    final refreshes = <Completer<void>>[];
    var refreshCount = 0;

    await tester.pumpWidget(
      _refreshTestApp(
        onRefresh: () {
          refreshCount++;
          final refresh = Completer<void>();
          refreshes.add(refresh);
          return refresh.future;
        },
      ),
    );
    await tester.pump();

    final position = tester.getCenter(find.byKey(_listKey));
    _sendVerticalWheel(tester, position, deltaY: -24);
    await tester.pump();
    expect(refreshCount, 0);
    expect(find.byType(RefreshProgressIndicator), findsNothing);

    _sendVerticalWheel(tester, position, deltaY: -40);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(refreshCount, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);

    _sendVerticalWheel(tester, position, deltaY: -100);
    await tester.pump(const Duration(milliseconds: 100));
    expect(refreshCount, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);

    refreshes.first.complete();
    await tester.pump(const Duration(milliseconds: 200));

    // A continuing burst stays latched after refresh completion.
    _sendVerticalWheel(tester, position, deltaY: -100);
    await tester.pump();
    expect(refreshCount, 1);

    // An idle gap ends the burst and permits a genuinely new refresh.
    await tester.pump(const Duration(milliseconds: 401));
    _sendVerticalWheel(tester, position, deltaY: -80);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(refreshCount, 2);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);

    refreshes.last.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('upward wheel away from the top only scrolls the list', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      _refreshTestApp(
        onRefresh: () async {
          refreshCount++;
        },
      ),
    );
    await tester.pump();

    await tester.drag(find.byKey(_listKey), const Offset(0, -240));
    await tester.pumpAndSettle();
    final position = tester.getCenter(find.byKey(_listKey));
    _sendVerticalWheel(tester, position, deltaY: -80);
    await tester.pump();

    expect(refreshCount, 0);
  });

  testWidgets('horizontal wheel does not trigger refresh', (tester) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      _refreshTestApp(
        onRefresh: () async {
          refreshCount++;
        },
      ),
    );
    await tester.pump();

    _sendVerticalWheel(
      tester,
      tester.getCenter(find.byKey(_listKey)),
      deltaY: 0,
    );
    tester.binding.handlePointerEvent(
      PointerHoverEvent(
        pointer: 21,
        device: 21,
        position: tester.getCenter(find.byKey(_listKey)),
        kind: PointerDeviceKind.mouse,
      ),
    );
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        device: 21,
        position: tester.getCenter(find.byKey(_listKey)),
        scrollDelta: const Offset(-100, 0),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();

    expect(refreshCount, 0);
  });

  testWidgets('vertical wheel over a nested list does not refresh the page', (
    tester,
  ) async {
    final innerController = ScrollController();
    var refreshCount = 0;
    final nestedList = ListView.builder(
      key: const Key('nested-refresh-list'),
      controller: innerController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: 20,
      itemExtent: 32,
      itemBuilder: (context, index) => Text('Nested $index'),
    );

    await tester.pumpWidget(
      _refreshTestApp(
        onRefresh: () async {
          refreshCount++;
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: 180, child: nestedList),
            const SizedBox(height: 800),
          ],
        ),
      ),
    );
    await tester.pump();
    innerController.jumpTo(100);
    await tester.pump();

    _sendVerticalWheel(
      tester,
      tester.getCenter(find.byKey(const Key('nested-refresh-list'))),
      deltaY: -80,
    );
    await tester.pump();

    expect(refreshCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    innerController.dispose();
  });

  testWidgets('mouse drag down at the top triggers one refresh', (
    tester,
  ) async {
    final refresh = Completer<void>();
    var refreshCount = 0;
    await tester.pumpWidget(
      _refreshTestApp(
        onRefresh: () {
          refreshCount++;
          return refresh.future;
        },
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_listKey)),
      pointer: 22,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveBy(const Offset(0, 90));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(refreshCount, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);

    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(refreshCount, 1);

    await gesture.up();
    refresh.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('trackpad pan gestures reset between completed pulls', (
    tester,
  ) async {
    final refreshes = <Completer<void>>[];
    var refreshCount = 0;
    await tester.pumpWidget(
      _refreshTestApp(
        onRefresh: () {
          refreshCount++;
          final refresh = Completer<void>();
          refreshes.add(refresh);
          return refresh.future;
        },
      ),
    );
    await tester.pump();

    final position = tester.getCenter(find.byKey(_listKey));
    void sendPan(int pointer) {
      tester.binding.handlePointerEvent(
        PointerPanZoomStartEvent(pointer: pointer, position: position),
      );
      tester.binding.handlePointerEvent(
        PointerPanZoomUpdateEvent(
          pointer: pointer,
          position: position,
          pan: const Offset(0, 80),
          panDelta: const Offset(0, 80),
        ),
      );
    }

    void endPan(int pointer) {
      tester.binding.handlePointerEvent(
        PointerPanZoomEndEvent(pointer: pointer, position: position),
      );
    }

    sendPan(30);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(refreshCount, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    endPan(30);

    refreshes.first.complete();
    await tester.pumpAndSettle();

    sendPan(31);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(refreshCount, 2);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    endPan(31);

    refreshes.last.complete();
    await tester.pumpAndSettle();
  });
  testWidgets('touch pull-to-refresh remains available', (tester) async {
    final refresh = Completer<void>();
    var refreshCount = 0;
    await tester.pumpWidget(
      _refreshTestApp(
        onRefresh: () {
          refreshCount++;
          return refresh.future;
        },
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(_listKey)),
    );
    await gesture.moveBy(const Offset(0, 300));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(refreshCount, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);

    refresh.complete();
    await tester.pumpAndSettle();
  });
}
