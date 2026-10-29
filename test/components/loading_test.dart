import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/components/loading.dart';
import 'package:venera_plus/foundation/res.dart';

void main() {
  for (final retry in [false, true]) {
    testWidgets(
      'loading ignores post-load completion after disposal (retry=$retry)',
      (tester) async {
        final dataLoaded = Completer<void>();
        var waitForDataLoaded = !retry;
        var onDataLoadedCalls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: _LoadingPage(
              loadData: () async => const Res('ready'),
              onDataLoaded: () async {
                onDataLoadedCalls++;
                if (waitForDataLoaded) await dataLoaded.future;
              },
            ),
          ),
        );
        await tester.pump();
        if (retry) {
          expect(find.text('ready'), findsOneWidget);
          waitForDataLoaded = true;
          await tester.tap(find.text('Retry'));
          await tester.pump();
        }
        expect(onDataLoadedCalls, retry ? 2 : 1);

        await tester.pumpWidget(const SizedBox.shrink());
        dataLoaded.complete();
        await tester.pump();

        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final success in [false, true]) {
    testWidgets('retry ignores a result after disposal (success=$success)', (
      tester,
    ) async {
      final result = Completer<Res<String>>();
      var loadCalls = 0;
      var onDataLoadedCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: _LoadingPage(
            loadData: () {
              loadCalls++;
              return loadCalls == 1
                  ? Future.value(const Res('ready'))
                  : result.future;
            },
            onDataLoaded: () async => onDataLoadedCalls++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(loadCalls, 2);

      await tester.pumpWidget(const SizedBox.shrink());
      result.complete(success ? const Res('done') : const Res.error('failed'));
      await tester.pump();

      expect(onDataLoadedCalls, 1);
      expect(loadCalls, 2);
      expect(tester.takeException(), isNull);
    });
  }
}

class _LoadingPage extends StatefulWidget {
  const _LoadingPage({required this.loadData, required this.onDataLoaded});

  final Future<Res<String>> Function() loadData;
  final Future<void> Function() onDataLoaded;

  @override
  State<_LoadingPage> createState() => _LoadingPageState();
}

class _LoadingPageState extends LoadingState<_LoadingPage, String> {
  @override
  Future<Res<String>> loadData() => widget.loadData();

  @override
  Future<void> onDataLoaded() => widget.onDataLoaded();

  @override
  Widget buildContent(BuildContext context, String data) => Column(
    children: [
      Text(data),
      TextButton(onPressed: retry, child: const Text('Retry')),
    ],
  );
}
