import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/foundation/reader_diagnostics.dart';

FrameTiming _frame(int ui, int raster) => FrameTiming(
  vsyncStart: 0,
  buildStart: 0,
  buildFinish: ui,
  rasterStart: ui,
  rasterFinish: ui + raster,
  rasterFinishWallTime: ui + raster,
);

Future<void> _drawFrame() async {
  SchedulerBinding.instance.handleBeginFrame(Duration.zero);
  SchedulerBinding.instance.handleDrawFrame();
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReaderDiagnostics diagnostics;
  late int now, attaches, detaches, clockReads;
  TimingsCallback? frames;
  void start({String version = '1.18.2-rc.4+240'}) => diagnostics.start(
    mode: ReaderDiagnosticMode.continuous,
    processingEnabled: false,
    appVersion: version,
    refreshRate: 120,
  );
  Map<String, dynamic> report() =>
      jsonDecode(diagnostics.exportJson()) as Map<String, dynamic>;
  setUp(() {
    now = attaches = detaches = clockReads = 0;
    frames = null;
    diagnostics = ReaderDiagnostics(
      nowMicros: () {
        clockReads++;
        return now;
      },
      attachTimings: (callback) {
        attaches++;
        frames = callback;
      },
      detachTimings: (callback) {
        expectSync(callback, frames);
        detaches++;
      },
    );
  });
  tearDown(() => diagnostics.dispose());

  test('disabled capture registers no callbacks and reads no clock', () {
    expect(
      diagnostics.beginImageSpan(42, ReaderDiagnosticStage.localRead),
      isNull,
    );
    diagnostics.recordCache(42, pending: false, keepAlive: false, live: false);
    expect(diagnostics.hasCapture, isFalse);
    expect(attaches, 0);
    expect(detaches, 0);
    expect(clockReads, 0);
  });

  test(
    'spans use session-local image numbers and elapsed waits, not private keys',
    () {
      start();
      final span = diagnostics.beginImageSpan(
        987654321,
        ReaderDiagnosticStage.localRead,
      )!;
      now = 2300;
      span.finish(bytes: 512);
      span.finish(bytes: 999);
      diagnostics.recordCache(
        987654321,
        pending: false,
        keepAlive: true,
        live: true,
      );
      frames!([_frame(6000, 6000), _frame(9000, 1000)]);
      diagnostics.stop(ReaderDiagnosticStop.review);
      final data = report();
      final events = data['imageEvents'] as List;
      expect(events, hasLength(2));
      expect(events[0]['image'], 1);
      expect(events[0]['waitUs'], 2300);
      expect(events[0]['bytes'], 512);
      expect(events[1]['image'], 1);
      expect(data['retainedFrameSamples']['overBudget'], 1);
      expect(data['retainedFrameSamples']['frameBudgetUs'], 8333);
      expect(data['configuration']['appVersion'], '1.18.2-rc.4+240');
      expect(diagnostics.exportJson(), isNot(contains('987654321')));
      expect(detaches, 1);
      expect(data['inFlightStagesAtStop'], 0);
    },
  );

  testWidgets('capture times out once and unregisters the frame callback', (
    tester,
  ) async {
    start();
    await tester.pump(const Duration(seconds: 44));
    expect(diagnostics.isRecording, isTrue);
    now = const Duration(seconds: 45).inMicroseconds;
    await tester.pump(const Duration(seconds: 1));
    expect(diagnostics.isRecording, isFalse);
    expect(report()['stopReason'], 'timeout');
    expect(report()['durationUs'], 45000000);
    expect(detaches, 1);
    frames!([_frame(99999, 99999)]);
    expect(report()['retainedFrameSamples']['ui']['count'], 0);
    await tester.pump(const Duration(seconds: 60));
    expect(detaches, 1);
  });

  test(
    'late work cannot append to a stopped, cleared or replacement capture',
    () {
      start();
      final old = diagnostics.beginImageSpan(
        1,
        ReaderDiagnosticStage.codecInitWait,
      )!;
      diagnostics.stop(ReaderDiagnosticStop.background);
      expect(report()['inFlightStagesAtStop'], 1);
      old.finish();
      expect(report()['imageEvents'], isEmpty);
      start();
      old.finish();
      expect(report()['imageEvents'], isEmpty);
      final pending = diagnostics.beginImageSpan(
        2,
        ReaderDiagnosticStage.firstDecodeWait,
      )!;
      diagnostics.clear();
      pending.finish();
      expect(diagnostics.hasCapture, isFalse);
      expect(report()['imageEvents'], isEmpty);
      expect(detaches, 2);
    },
  );

  test(
    'deadline rejects late samples even before a delayed timer callback',
    () {
      start();
      now = const Duration(seconds: 46).inMicroseconds;
      expect(
        diagnostics.beginImageSpan(1, ReaderDiagnosticStage.localRead),
        isNull,
      );
      expect(diagnostics.isRecording, isFalse);
      expect(report()['durationUs'], 45000000);
      expect(report()['stopReason'], 'timeout');
    },
  );

  test(
    'event, frame and identity buffers are bounded and truncation is explicit',
    () {
      diagnostics.dispose();
      diagnostics = ReaderDiagnostics(
        maxEvents: 3,
        maxFrames: 2,
        maxImages: 2,
        nowMicros: () => now,
        attachTimings: (callback) => frames = callback,
        detachTimings: (_) {},
      );
      start(version: 'https://private.example/account');
      for (var i = 0; i < 5; i++) {
        diagnostics.recordCache(
          i % 2,
          pending: false,
          keepAlive: false,
          live: false,
        );
      }
      diagnostics.recordCache(3, pending: false, keepAlive: false, live: false);
      frames!([_frame(1, 1), _frame(2, 2), _frame(3, 3)]);
      diagnostics.stop(ReaderDiagnosticStop.review);
      final data = report();
      expect(data['imageEvents'], hasLength(3));
      expect(data['droppedEvents'], 2);
      expect(data['droppedFrames'], 1);
      expect(data['ignoredImageLookups'], 1);
      expect(data['retainedFrameSamples']['ui']['count'], 2);
      expect(data['configuration']['appVersion'], 'unknown');
      expect(diagnostics.exportJson(), isNot(contains('private.example')));
    },
  );

  testWidgets('a deadline detected during image build defers UI notification', (
    tester,
  ) async {
    start();
    now = const Duration(seconds: 46).inMicroseconds;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            ListenableBuilder(
              listenable: diagnostics,
              builder: (_, _) => Text('${diagnostics.isRecording}'),
            ),
            Builder(
              builder: (_) {
                diagnostics.recordCache(
                  1,
                  pending: false,
                  keepAlive: false,
                  live: false,
                );
                return const SizedBox();
              },
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(diagnostics.isRecording, isFalse);
    expect(find.text('false'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(detaches, 1);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'a full capture stays copyable and explicitly counts omitted details',
    () {
      start();
      for (var i = 0; i < diagnostics.maxEvents; i++) {
        diagnostics
            .beginImageSpan(1, ReaderDiagnosticStage.firstDecodeWait)!
            .finish(
              bytes: 0x7fffffffffffffff,
              width: 0x7fffffffffffffff,
              height: 0x7fffffffffffffff,
            );
        now += 100;
      }
      frames!(
        List.generate(diagnostics.maxFrames, (_) => _frame(50000, 50000)),
      );
      diagnostics.stop(ReaderDiagnosticStop.review);
      final encoded = diagnostics.exportJson();
      final data = jsonDecode(encoded) as Map<String, dynamic>;
      expect(
        encoded.length,
        lessThanOrEqualTo(ReaderDiagnostics.maxReportCharacters),
      );
      expect(data['retainedEventCount'], diagnostics.maxEvents);
      expect(data['omittedEventsForCopy'], greaterThan(0));
      expect(
        (data['imageEvents'] as List).length +
            (data['omittedEventsForCopy'] as int),
        diagnostics.maxEvents,
      );
      expect(
        data['retainedStageSamples']['firstDecodeWait']['count'],
        diagnostics.maxEvents,
      );
      expect(data['droppedEvents'], 0);
      expect(
        data['retainedFrameSamples']['ui']['count'],
        diagnostics.maxFrames,
      );
      expect(data['retainedFrameSamples']['slowest'], hasLength(40));
      expect(
        diagnostics.exportJson(),
        encoded,
        reason: 'preview must not prune retained samples',
      );
      start(version: '1.2.3-${'private' * 100}');
      expect(report()['configuration']['appVersion'], 'unknown');
    },
  );

  test('capture follows the reader zone across asynchronous work', () async {
    expect(ReaderDiagnostics.current, isNull);
    await diagnostics.run(() async {
      await Future<void>.value();
      expect(ReaderDiagnostics.current, same(diagnostics));
    });
    expect(ReaderDiagnostics.current, isNull);
  });

  test(
    'actual local provider records read and decoding without private data',
    () async {
      final root = Directory.systemTemp.createTempSync('reader-diagnostics-');
      final file = File('${root.path}/private-comic.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
          ),
        );
      final previous = appdata.settings['enableCustomImageProcessing'];
      appdata.settings['enableCustomImageProcessing'] = false;
      final provider = ReaderImageProvider(
        'file://${file.path}',
        'private-source',
        'private-title',
        'private-chapter',
        1,
      );
      start();
      final stream = diagnostics.run(
        () => provider.resolve(ImageConfiguration.empty),
      );
      final ready = Completer<void>();
      final listener = ImageStreamListener(
        (image, _) {
          image.dispose();
          if (!ready.isCompleted) ready.complete();
        },
        onError: (Object error, StackTrace? stack) {
          if (!ready.isCompleted) ready.completeError(error, stack);
        },
      );
      stream.addListener(listener);
      try {
        for (var i = 0; i < 80 && !ready.isCompleted; i++) {
          await pumpEventQueue();
          await _drawFrame();
        }
        await ready.future.timeout(const Duration(seconds: 5));
        diagnostics.stop(ReaderDiagnosticStop.review);
        final events = report()['imageEvents'] as List;
        expect(
          events.map((event) => event['stage']),
          containsAll(['localRead', 'codecInitWait', 'firstDecodeWait']),
        );
        expect(events.every((event) => event['success'] == true), isTrue);
        expect(diagnostics.exportJson(), isNot(contains('private-')));
        start();
        final cachedReady = Completer<void>();
        final cached = diagnostics.run(
          () => provider.resolve(ImageConfiguration.empty),
        );
        final cachedListener = ImageStreamListener((image, _) {
          image.dispose();
          if (!cachedReady.isCompleted) cachedReady.complete();
        });
        cached.addListener(cachedListener);
        await cachedReady.future;
        cached.removeListener(cachedListener);
        diagnostics.stop(ReaderDiagnosticStop.review);
        expect(
          report()['imageEvents'],
          isEmpty,
          reason: 'decoded cache hits do not repeat IO or decoding',
        );
      } finally {
        stream.removeListener(listener);
        await provider.evict();
        await _drawFrame();
        appdata.settings['enableCustomImageProcessing'] = previous;
        root.deleteSync(recursive: true);
      }
    },
  );
}
