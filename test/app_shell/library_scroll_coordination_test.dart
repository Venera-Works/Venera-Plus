import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_shell/app_shell.dart';
import 'package:venera_plus/components/scroll.dart';

void main() {
  testWidgets('reverse touch restores the category header before its content', (
    tester,
  ) async {
    final fixtureKey = GlobalKey<_LibraryScrollFixtureState>();

    await tester.pumpWidget(_buildFixture(fixtureKey));
    await tester.pumpAndSettle();

    await tester.drag(find.text('A row 0'), const Offset(0, -36));
    await tester.pumpAndSettle();
    final nested = fixtureKey.currentState!.nestedKey.currentState!;
    expect(nested.outerController.offset, greaterThan(0));
    expect(fixtureKey.currentState!.controllers[0].offset, closeTo(0, 1));

    await tester.drag(find.text('A row 0'), const Offset(0, -220));
    await tester.pumpAndSettle();

    final outerOffsetAfterUp = nested.outerController.offset;

    final contentOffsetAfterUp = fixtureKey.currentState!.controllers[0].offset;
    expect(outerOffsetAfterUp, greaterThan(0));
    expect(contentOffsetAfterUp, greaterThan(0));

    await tester.drag(find.text('A row 3'), const Offset(0, 36));
    await tester.pumpAndSettle();

    expect(nested.outerController.offset, lessThan(outerOffsetAfterUp));
    expect(
      fixtureKey.currentState!.controllers[0].offset,
      contentOffsetAfterUp,
    );

    await tester.drag(find.text('A row 3'), const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(nested.outerController.offset, closeTo(0, 1));
    expect(
      fixtureKey.currentState!.controllers[0].offset,
      lessThan(contentOffsetAfterUp),
    );
  });

  testWidgets('reverse mouse wheel restores the header before its content', (
    tester,
  ) async {
    final fixtureKey = GlobalKey<_LibraryScrollFixtureState>();
    await tester.pumpWidget(_buildFixture(fixtureKey));
    await tester.pumpAndSettle();
    final nested = fixtureKey.currentState!.nestedKey.currentState!;

    Future<void> wheel(double delta) async {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(NestedScrollView)),
          scrollDelta: Offset(0, delta),
        ),
      );
      await tester.pumpAndSettle();
    }

    await wheel(160);
    final contentOffsetAfterUp = fixtureKey.currentState!.controllers[0].offset;
    expect(contentOffsetAfterUp, greaterThan(0));
    expect(
      nested.outerController.offset,
      nested.outerController.position.maxScrollExtent,
    );

    await wheel(-24);
    expect(
      nested.outerController.offset,
      lessThan(nested.outerController.position.maxScrollExtent),
    );
    expect(
      fixtureKey.currentState!.controllers[0].offset,
      contentOffsetAfterUp,
    );

    await wheel(-160);
    expect(nested.outerController.offset, closeTo(0, 1));
    expect(
      fixtureKey.currentState!.controllers[0].offset,
      lessThan(contentOffsetAfterUp),
    );
  });

  testWidgets(
    'scrolling the active category leaves the inactive offset intact',
    (tester) async {
      final fixtureKey = GlobalKey<_LibraryScrollFixtureState>();

      await tester.pumpWidget(_buildFixture(fixtureKey));
      await tester.pumpAndSettle();

      await tester.drag(find.text('A row 0'), const Offset(0, -220));
      await tester.pumpAndSettle();
      final inactiveOffset = fixtureKey.currentState!.controllers[0].offset;

      fixtureKey.currentState!.selectSection(1);
      await tester.pumpAndSettle();
      await tester.drag(find.text('B row 0'), const Offset(0, -180));
      await tester.pumpAndSettle();

      expect(fixtureKey.currentState!.controllers[1].offset, greaterThan(0));
      expect(fixtureKey.currentState!.controllers[0].offset, inactiveOffset);
      fixtureKey.currentState!.selectSection(0);
      await tester.pumpAndSettle();
      expect(fixtureKey.currentState!.controllers[0].offset, inactiveOffset);
    },
  );
}

Widget _buildFixture(GlobalKey<_LibraryScrollFixtureState> key) {
  return MaterialApp(
    home: Scaffold(body: _LibraryScrollFixture(key: key)),
  );
}

class _LibraryScrollFixture extends StatefulWidget {
  const _LibraryScrollFixture({super.key});

  @override
  State<_LibraryScrollFixture> createState() => _LibraryScrollFixtureState();
}

class _LibraryScrollFixtureState extends State<_LibraryScrollFixture>
    with SingleTickerProviderStateMixin {
  final nestedKey = GlobalKey<NestedScrollViewState>();
  final controllers = [ScrollController(), ScrollController()];
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );
  int activeSection = 0;

  void selectSection(int index) {
    _tabController.animateTo(index);
    setState(() {
      activeSection = index;
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NestedScrollView(
      key: nestedKey,
      floatHeaderSlivers: true,
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 80,
            child: const Center(child: Text('Category header')),
          ),
        ),
      ],
      body: Builder(
        builder: (context) {
          final nestedController = PrimaryScrollController.of(context);
          return TabBarView(
            controller: _tabController,
            children: [
              for (var index = 0; index < 2; index++)
                PrimaryScrollController.none(
                  child: KeepAliveView(
                    key: ValueKey('section_$index'),
                    isActive: activeSection == index,
                    isVisible: true,
                    child: NestedScrollScope(
                      controller: nestedController,
                      isActive: activeSection == index,
                      child: SmoothCustomScrollView(
                        controller: controllers[index],
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, row) => SizedBox(
                                height: 80,
                                child: Center(
                                  child: Text(
                                    '${index == 0 ? 'A' : 'B'} row $row',
                                  ),
                                ),
                              ),
                              childCount: 30,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
