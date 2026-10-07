import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/settings/settings.dart';
import 'package:venera_plus/features/sync/sync.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/translations.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(800, 360)]) {
    for (final brightness in Brightness.values) {
      testWidgets('sync fields support $size, $brightness and large text', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previous = appdata.settings['language'];
        appdata.settings['language'] = 'zh-CN';
        addTearDown(() => appdata.settings['language'] = previous);
        await AppTranslation.init();
        var direction = SyncDirection.bidirectional;
        var timing = SyncTiming.manual;
        var minutes = 30;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: StatefulBuilder(
                    builder: (context, setState) => DataSyncScheduleFields(
                      direction: direction,
                      timing: timing,
                      minutes: minutes,
                      onDirectionChanged: (value) =>
                          setState(() => direction = value),
                      onTimingChanged: (value) =>
                          setState(() => timing = value),
                      onIntervalChanged: (value) =>
                          setState(() => minutes = value),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.byType(DropdownButton<int>), findsNothing);
        expect(find.byType(DropdownButton<SyncDirection>), findsOneWidget);
        expect(find.byType(DropdownButton<SyncTiming>), findsOneWidget);

        await tester.tap(find.byType(DropdownButton<SyncTiming>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('定时').last);
        await tester.pumpAndSettle();
        expect(timing, SyncTiming.scheduled);
        expect(find.byType(DropdownButton<int>), findsOneWidget);
        await tester.ensureVisible(find.byType(DropdownButton<int>));
        await tester.tap(find.byType(DropdownButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text('@minutes min'.tlParams({'minutes': 60})).last,
        );
        await tester.pumpAndSettle();
        expect(minutes, 60);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
