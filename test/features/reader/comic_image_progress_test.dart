import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/reader/comic_image.dart';
import 'package:venera_plus/features/reader/gesture.dart';
import 'package:venera_plus/foundation/global_state.dart';

void main() {
  late ReaderGestureDetectorState gestureState;

  setUp(() {
    gestureState = ReaderGestureDetectorState();
    GlobalState.register(gestureState);
  });

  tearDown(() {
    GlobalState.unregister(gestureState);
  });

  testWidgets('同帧进度仅在下一帧提交最新值', (tester) async {
    final provider = _ControlledImageProvider();

    await tester.pumpWidget(_host(provider));
    provider.completer.emitChunk(20, 100);
    provider.completer.emitChunk(70, 100);

    expect(_reportedProgress(tester), isNull);

    await tester.pump();

    expect(_reportedProgress(tester)!.cumulativeBytesLoaded, 70);
    expect(_progressValue(tester), 0.7);
  });

  testWidgets('图片完成会取消尚未提交的进度', (tester) async {
    final provider = _ControlledImageProvider();

    await tester.pumpWidget(_host(provider));
    provider.completer.emitChunk(30, 100);
    provider.completer.emitImage(await _createTestImage());

    await tester.pump();

    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(_reportedProgress(tester), isNull);
  });

  testWidgets('替换图片源后旧进度不会覆盖新状态', (tester) async {
    final first = _ControlledImageProvider();
    final second = _ControlledImageProvider();
    final current = ValueNotifier<ImageProvider>(first);
    addTearDown(current.dispose);

    await tester.pumpWidget(
      ValueListenableBuilder<ImageProvider>(
        valueListenable: current,
        builder: (context, provider, child) => _host(provider),
      ),
    );
    first.completer.emitChunk(40, 100);
    current.value = second;

    await tester.pump();

    expect(_reportedProgress(tester), isNull);
    expect(_progressValue(tester), 0);
  });

  testWidgets('重试和卸载会丢弃旧流尚未提交的进度', (tester) async {
    final provider = _ControlledImageProvider();

    await tester.pumpWidget(_host(provider));
    provider.completer.emitError(StateError('加载失败'));
    await tester.pump();
    expect(find.textContaining('加载失败'), findsOneWidget);

    provider.completer.emitChunk(60, 100);
    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(_reportedProgress(tester), isNull);
    expect(_progressValue(tester), 0);

    provider.completer.emitChunk(80, 100);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

Widget _host(ImageProvider provider) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 100,
      height: 100,
      child: ComicImage(image: provider),
    ),
  ),
);

ImageChunkEvent? _reportedProgress(WidgetTester tester) {
  final state = tester.state<ComicImageState>(find.byType(ComicImage));
  final properties = DiagnosticPropertiesBuilder();
  state.debugFillProperties(properties);
  return (properties.properties.singleWhere(
            (property) => property.name == 'loadingProgress',
          )
          as DiagnosticsProperty<ImageChunkEvent>)
      .value;
}

double? _progressValue(WidgetTester tester) => tester
    .widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator))
    .value;

Future<ui.Image> _createTestImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawPaint(ui.Paint()..color = Colors.black);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  picture.dispose();
  return image;
}

class _ControlledImageProvider extends ImageProvider<_ControlledImageProvider> {
  _ControlledImageProvider() : completer = _ControlledImageStreamCompleter();

  final _ControlledImageStreamCompleter completer;

  @override
  Future<_ControlledImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_ControlledImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _ControlledImageProvider key,
    ImageDecoderCallback decode,
  ) => completer;
}

class _ControlledImageStreamCompleter extends ImageStreamCompleter {
  void emitChunk(int loaded, int total) {
    reportImageChunkEvent(
      ImageChunkEvent(cumulativeBytesLoaded: loaded, expectedTotalBytes: total),
    );
  }

  void emitImage(ui.Image image) => setImage(ImageInfo(image: image));

  void emitError(Object error) {
    reportError(exception: error, stack: StackTrace.empty);
  }
}
