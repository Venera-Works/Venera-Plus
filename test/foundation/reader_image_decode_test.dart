import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:venera_plus/features/reader/comic_image.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/network/images.dart';

import '../widget_test_io.dart';

class _MemoryReaderImage extends ReaderImageProvider {
  _MemoryReaderImage(
    this.bytes, {
    required ComicImageLoadTarget target,
    double decodeScale = 1,
    this.zoomReady,
  }) : super(
         'memory-image',
         null,
         'comic',
         'chapter',
         1,
         chapter: 1,
         enableResize: true,
         target: target,
         decodeScale: decodeScale,
       );

  final Uint8List bytes;
  final Future<void>? zoomReady;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    if (decodeScale > 1) await zoomReady;
    checkStop();
    return bytes;
  }

  @override
  ReaderImageProvider withDecodeScale(double scale) => _MemoryReaderImage(
    bytes,
    target: target!,
    decodeScale: scale,
    zoomReady: zoomReady,
  );
}

Future<Size> _decodedSize(ReaderImageProvider provider) async {
  final ready = Completer<Size>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, synchronous) {
    ready.complete(
      Size(info.image.width.toDouble(), info.image.height.toDouble()),
    );
    info.dispose();
  }, onError: ready.completeError);
  stream.addListener(listener);
  try {
    return await ready.future;
  } finally {
    stream.removeListener(listener);
    await provider.evict();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicImage.clear();
  });

  for (final (name, width, height, target, expected) in [
    (
      'gallery uses physical viewport pixels',
      800,
      1200,
      ComicImageLoadTarget(
        logicalWidth: 200,
        logicalHeight: 300,
        devicePixelRatio: 2,
      ),
      const Size(400, 600),
    ),
    (
      'contain respects the limiting viewport dimension',
      800,
      1200,
      ComicImageLoadTarget(logicalWidth: 300, logicalHeight: 300),
      const Size(200, 300),
    ),
    (
      'long images are decoded to the display width',
      600,
      3600,
      ComicImageLoadTarget(
        logicalWidth: 200,
        fit: ComicImageTargetFit.fitWidth,
      ),
      const Size(200, 1200),
    ),
    (
      'horizontal flow is decoded to the display height',
      1200,
      800,
      ComicImageLoadTarget(
        logicalHeight: 200,
        fit: ComicImageTargetFit.fitHeight,
      ),
      const Size(300, 200),
    ),
    (
      'split images retain enough pixels for each visual half',
      1200,
      600,
      ComicImageLoadTarget(
        logicalWidth: 300,
        logicalHeight: 500,
        splitWideImage: true,
      ),
      const Size(600, 300),
    ),
    (
      'split flow retains the display width of each half',
      1200,
      600,
      ComicImageLoadTarget(
        logicalWidth: 300,
        fit: ComicImageTargetFit.fitWidth,
        splitWideImage: true,
      ),
      const Size(600, 300),
    ),
    (
      'small images are never enlarged during decoding',
      100,
      150,
      ComicImageLoadTarget(logicalWidth: 300, logicalHeight: 500),
      const Size(100, 150),
    ),
  ]) {
    test(name, () async {
      final bytes = img.encodePng(img.Image(width: width, height: height));
      final provider = _MemoryReaderImage(bytes, target: target);
      expect(await _decodedSize(provider), expected);
    });
  }

  test(
    'zoom has a separate memory entry and shares the encoded cache',
    () async {
      final provider = _MemoryReaderImage(
        img.encodePng(img.Image(width: 800, height: 1200)),
        target: ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
      );
      final zoomed = provider.withDecodeScale(2);
      expect(zoomed, isNot(provider));
      expect(zoomed.key, isNot(provider.key));
      expect(zoomed.diskCacheKey, provider.diskCacheKey);
      expect(zoomed.target, same(provider.target));
      expect(await _decodedSize(zoomed), const Size(400, 600));
      expect(
        await _decodedSize(provider.withDecodeScale(10)),
        const Size(800, 1200),
      );
    },
  );

  testWidgets('zoom upgrades pixels without blanking or changing the layout', (
    tester,
  ) async {
    final zoomReady = Completer<void>();
    final controller = PhotoViewController(initialScale: 1)
      ..getInitialScale = () => 1;
    final provider = _MemoryReaderImage(
      img.encodePng(img.Image(width: 800, height: 1200)),
      target: ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
      zoomReady: zoomReady.future,
    );
    var imageReady = Completer<Size>();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: 300,
            child: ComicImage(
              image: provider,
              zoomController: controller,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.contain,
              onImageSize: (size) {
                if (!imageReady.isCompleted) imageReady.complete(size);
              },
            ),
          ),
        ),
      ),
    );
    Size? decoded;
    await runWidgetIo(tester, () async {
      decoded = await imageReady.future;
    });
    expect(decoded, const Size(200, 300));
    await tester.pump();
    final original = tester.widget<RawImage>(find.byType(RawImage)).image;
    final layout = tester.getSize(find.byType(ComicImage));

    imageReady = Completer<Size>();
    controller.scale = 1.75;
    await tester.pump();
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );
    zoomReady.complete();
    await runWidgetIo(tester, () async {
      decoded = await imageReady.future;
    });
    expect(decoded, const Size(400, 600));
    await tester.pump();
    expect(tester.getSize(find.byType(ComicImage)), layout);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 400);

    imageReady = Completer<Size>();
    controller.scale = 1;
    await runWidgetIo(tester, () async {
      decoded = await imageReady.future;
    });
    expect(decoded, const Size(200, 300));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
