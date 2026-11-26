import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera_plus/components/image.dart';
import 'package:venera_plus/foundation/image_provider/base_image_provider.dart';

void main() {
  testWidgets('隐藏尚未加载的封面会取消请求，重新可见后可出图', (tester) async {
    final cover = _ControlledCover('hidden-cover');
    final cache = PaintingBinding.instance.imageCache;
    addTearDown(cover.evict);

    await tester.pumpWidget(_host(cover, visible: true));
    expect(cover.requests, hasLength(1));
    expect(cache.statusForKey(cover).pending, isTrue);

    await tester.pumpWidget(_host(cover, visible: false));
    await tester.pump();
    expect(cover.cancelledRequests, 1);
    expect(cache.statusForKey(cover).pending, isFalse);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(cover, visible: true));
    expect(cover.requests, hasLength(2));
    await _completeAndShowCover(tester, cover, width: 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已有封面的隐藏组件更换图片时等待可见再加载', (tester) async {
    final first = _ControlledCover('cover-a');
    final next = _ControlledCover('cover-b');
    addTearDown(first.evict);
    addTearDown(next.evict);

    await tester.pumpWidget(_host(first, visible: true));
    expect(first.requests, hasLength(1));
    await _completeAndShowCover(tester, first, width: 3);

    await tester.pumpWidget(_host(first, visible: false));
    await tester.pumpWidget(_host(next, visible: false));
    await tester.pump();
    expect(next.requests, isEmpty);

    await tester.pumpWidget(_host(next, visible: true));
    expect(next.requests, hasLength(1));
    await _completeAndShowCover(tester, next, width: 5);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _host(_ControlledCover cover, {required bool visible}) => Directionality(
  textDirection: TextDirection.ltr,
  child: TickerMode(
    enabled: visible,
    child: Offstage(
      offstage: !visible,
      child: Center(child: AnimatedImage(image: cover, width: 40, height: 40)),
    ),
  ),
);

Future<void> _completeAndShowCover(
  WidgetTester tester,
  _ControlledCover cover, {
  required int width,
}) async {
  cover.requests.last.complete(
    img.encodePng(img.Image(width: width, height: 2)),
  );
  final pixels = find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image?.width == width,
  );
  final elapsed = Stopwatch()..start();
  while (pixels.evaluate().isEmpty &&
      elapsed.elapsed < const Duration(seconds: 5)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(pixels, findsOneWidget);
  await tester.pumpAndSettle();
}

class _ControlledCover extends BaseImageProvider<_ControlledCover> {
  _ControlledCover(this.key);

  @override
  final String key;
  final requests = <Completer<Uint8List>>[];
  int cancelledRequests = 0;

  @override
  Future<_ControlledCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) {
    final request = Completer<Uint8List>();
    requests.add(request);
    final cancelled = BaseImageProvider.cancelSignalOf(checkStop).then((_) {
      if (!request.isCompleted) cancelledRequests++;
      checkStop();
      return request.future;
    });
    return Future.any([request.future, cancelled]);
  }
}
