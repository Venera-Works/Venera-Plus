import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/app_shell/app_shell.dart';

void main() {
  group('KeepAliveView behavioral isolation', () {
    testWidgets(
      'Active text field loses focus on deactivation and cannot request focus while hidden',
      (tester) async {
        final focusNode = FocusNode();
        bool active = true;
        late StateSetter toggleSetter;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  toggleSetter = setState;
                  return KeepAliveView(
                    isActive: active,
                    child: TextField(
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        hintText: 'Search input',
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );

        // Focus the text field while active
        focusNode.requestFocus();
        await tester.pump();
        expect(focusNode.hasFocus, isTrue);

        // Deactivate directly via captured StateSetter (no button tap)
        toggleSetter(() {
          active = false;
        });
        await tester.pump();

        // Focus must be cleared from the hidden descendant
        expect(focusNode.hasFocus, isFalse);

        // Attempting to request focus while inactive must fail
        focusNode.requestFocus();
        await tester.pump();
        expect(focusNode.hasFocus, isFalse);
        // Unmount before disposing focus node
        await tester.pumpWidget(const SizedBox.shrink());
        focusNode.dispose();
      },
    );

    testWidgets(
      'Navigation with duplicate hero tags across active and inactive views succeeds, transitions and returns',
      (tester) async {
        BuildContext? scaffoldContext;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  scaffoldContext = context;
                  return Stack(
                    children: [
                      KeepAliveView(
                        isActive: true,
                        child: Hero(
                          tag: 'shared-comic-cover',
                          child: const Text('Hero Active'),
                        ),
                      ),
                      KeepAliveView(
                        isActive: false,
                        child: Hero(
                          tag: 'shared-comic-cover',
                          child: const Text('Hero Inactive'),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );

        // Verify active hero text is on screen and inactive hero is retained-but-hidden
        expect(find.text('Hero Active'), findsOneWidget);
        expect(find.text('Hero Inactive'), findsNothing);
        expect(find.text('Hero Inactive', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Push target route with the same hero tag
        Navigator.of(scaffoldContext!).push(
          MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Hero(
                tag: 'shared-comic-cover',
                child: const Text('Hero Target'),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );

        // Verify target route rendered without duplicate hero exception
        expect(find.text('Hero Target'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Pop back to root
        Navigator.of(scaffoldContext!).pop();
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );

        // Returned safely to active view while inactive view remains retained-but-hidden
        expect(find.text('Hero Active'), findsOneWidget);
        expect(find.text('Hero Target'), findsNothing);
        expect(find.text('Hero Inactive'), findsNothing);
        expect(find.text('Hero Inactive', skipOffstage: false), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
