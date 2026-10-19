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

class _MemoryImageLoader {
  _MemoryImageLoader(int width, int height)
    : bytes = img.encodePng(img.Image(width: width, height: height));

  final Uint8List bytes;
  final waits = <int, Completer<void>>{};
  final _started = <int, Completer<void>>{};
  final targets = <ComicImageLoadTarget?>[];
  int loads = 0;

  Future<void> started(int request) =>
      (_started[request] ??= Completer<void>()).future;

  void install() {
    ImageDownloader.debugLoadComicImageUnwrapped =
        (imageKey, sourceKey, cid, eid, {target}) async* {
          final request = ++loads;
          targets.add(target);
          (_started[request] ??= Completer<void>()).complete();
          await waits[request]?.future;
          yield ImageDownloadProgress(
            currentBytes: bytes.length,
            totalBytes: bytes.length,
            imageBytes: bytes,
            diskCacheKey: ImageDownloader.getComicImageCacheKey(
              imageKey,
              sourceKey,
              cid,
              eid,
              target: target,
            ),
          );
        };
  }
}

ReaderImageProvider _provider(ComicImageLoadTarget target) =>
    ReaderImageProvider(
      'memory-image',
      'source',
      'comic',
      'chapter',
      1,
      chapter: 1,
      enableResize: true,
      target: target,
    );

Future<Size> _decodedSize(ReaderImageProvider provider) async {
  final ready = Completer<Size>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, synchronous) {
    if (!ready.isCompleted) {
      ready.complete(
        Size(info.image.width.toDouble(), info.image.height.toDouble()),
      );
    }
    info.dispose();
  }, onError: ready.completeError);
  stream.addListener(listener);
  try {
    return await ready.future;
  } finally {
    stream.removeListener(listener);
  }
}

Future<void> _waitForPixels(WidgetTester tester, Size expected) {
  return runWidgetIo(tester, () async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      final images = tester.widgetList<RawImage>(find.byType(RawImage));
      if (images.any(
        (raw) =>
            raw.image?.width == expected.width &&
            raw.image?.height == expected.height,
      )) {
        return;
      }
      if (stopwatch.elapsed > const Duration(seconds: 8)) {
        throw TestFailure('No painted image with pixels $expected.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}

Widget _galleryImage(
  ReaderImageProvider provider,
  PhotoViewController controller, {
  ValueChanged<Size>? onImageSize,
}) => MaterialApp(
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
        onImageSize: onImageSize,
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    ImageDownloader.debugLoadComicImageUnwrapped = null;
    ImageDownloader.cancelAllLoadingImages();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    ComicImage.clear();
  });

  for (final (name, width, height, target, expected, zoomedSize) in [
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
      const Size(800, 1200),
    ),
    (
      'contain respects the limiting viewport dimension',
      800,
      1200,
      ComicImageLoadTarget(logicalWidth: 300, logicalHeight: 300),
      const Size(200, 300),
      const Size(400, 600),
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
      const Size(400, 2400),
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
      const Size(600, 400),
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
      const Size(1200, 600),
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
      const Size(1200, 600),
    ),
    (
      'small images are never enlarged during decoding',
      100,
      150,
      ComicImageLoadTarget(logicalWidth: 300, logicalHeight: 500),
      const Size(100, 150),
      const Size(100, 150),
    ),
  ]) {
    test(name, () async {
      final loader = _MemoryImageLoader(width, height)..install();
      final provider = _provider(target);
      final key = provider.key;
      final hashCode = provider.hashCode;
      expect(await _decodedSize(provider), expected);
      final stream = provider.resolve(ImageConfiguration.empty);
      expect(
        ReaderImageProvider.sourceSizeOf(stream.completer),
        Size(width.toDouble(), height.toDouble()),
      );
      expect(provider.key, key);
      expect(provider.hashCode, hashCode);
      expect(loader.loads, 1);
      final zoomed = provider.withDecodeScale(
        2,
        Size(width.toDouble(), height.toDouble()),
      );
      expect(await _decodedSize(zoomed), zoomedSize);
      expect(loader.loads, zoomed == provider ? 1 : 2);
      expect(provider.key, key);
      expect(provider.hashCode, hashCode);
    });
  }

  for (final (name, width, height, baseSize, expectedLoads) in [
    ('integer source cap', 800, 1200, const Size(200, 300), 2),
    ('noninteger source cap', 750, 1100, const Size(200, 293), 2),
    ('small source already at base', 100, 150, const Size(100, 150), 1),
  ]) {
    test('$name reuses effective pixels at scales 4, 5 and 10', () async {
      final loader = _MemoryImageLoader(width, height)..install();
      final provider = _provider(
        ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
      );
      final sourceSize = Size(width.toDouble(), height.toDouble());
      expect(await _decodedSize(provider), baseSize);
      ImageStreamCompleter? capped;
      for (final scale in [4.0, 5.0, 10.0]) {
        final zoomed = provider.withDecodeScale(scale, sourceSize);
        expect(zoomed.diskCacheKey, provider.diskCacheKey);
        expect(zoomed.target, same(provider.target));
        expect(await _decodedSize(zoomed), sourceSize);
        final stream = zoomed.resolve(ImageConfiguration.empty);
        capped ??= stream.completer;
        expect(stream.completer, same(capped));
      }
      expect(loader.loads, expectedLoads);
      expect(
        provider.withDecodeScale(10, sourceSize).withDecodeScale(1, sourceSize),
        same(provider),
      );
      expect(await _decodedSize(provider), baseSize);
      expect(loader.loads, expectedLoads);
    });
  }

  testWidgets('precache metadata is shared by a new equal provider', (
    tester,
  ) async {
    final loader = _MemoryImageLoader(800, 1200)..install();
    final target = ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300);
    final precachedProvider = _provider(target);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final future = precacheImage(
      precachedProvider,
      tester.element(find.byType(SizedBox).first),
    );
    await runWidgetIo(tester, () => future);
    await tester.pump();
    final originalStream = precachedProvider.resolve(ImageConfiguration.empty);

    final provider = _provider(target);
    expect(provider, precachedProvider);
    expect(identical(provider, precachedProvider), isFalse);
    final key = provider.key;
    final hashCode = provider.hashCode;
    final newStream = provider.resolve(ImageConfiguration.empty);
    expect(newStream.completer, same(originalStream.completer));
    expect(
      ReaderImageProvider.sourceSizeOf(newStream.completer),
      const Size(800, 1200),
    );

    final controller = PhotoViewController(initialScale: 2)
      ..getInitialScale = () => 1;
    final reported = <Size>[];
    await tester.pumpWidget(
      _galleryImage(provider, controller, onImageSize: reported.add),
    );
    await _waitForPixels(tester, const Size(400, 600));
    expect(loader.loads, 2);
    expect(provider.key, key);
    expect(provider.hashCode, hashCode);
    expect(reported, [const Size(200, 300)]);
    expect(ComicImage.getCachedImageSize(provider), const Size(200, 300));
    controller.scale = 1;
    await _waitForPixels(tester, const Size(200, 300));
    expect(loader.loads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('cold zoom uses latest demand and ignores a late upgrade frame', (
    tester,
  ) async {
    final baseReady = Completer<void>();
    final zoomReady = Completer<void>();
    final loader = _MemoryImageLoader(800, 1200)
      ..waits[1] = baseReady
      ..waits[2] = zoomReady
      ..install();
    final provider = _provider(
      ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
    );
    final controller = PhotoViewController(initialScale: 2)
      ..getInitialScale = () => 1;
    final reported = <Size>[];
    await tester.pumpWidget(
      _galleryImage(provider, controller, onImageSize: reported.add),
    );
    await runWidgetIo(tester, () => loader.started(1));
    controller.scale = 6;
    await tester.pump();
    expect(loader.loads, 1);
    baseReady.complete();
    await runWidgetIo(tester, () => loader.started(2));
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 200);
    expect(reported, [const Size(200, 300)]);

    final lateFrame = _decodedSize(
      provider.withDecodeScale(6, const Size(800, 1200)),
    );
    controller.scale = 1;
    await tester.pump();
    zoomReady.complete();
    Size? latePixels;
    await runWidgetIo(tester, () async {
      latePixels = await lateFrame;
    });
    expect(latePixels, const Size(800, 1200));
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 200);
    expect(loader.loads, 2);
    controller.scale = 6;
    await _waitForPixels(tester, const Size(800, 1200));
    expect(loader.loads, 2);
    expect(reported, [const Size(200, 300)]);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('cold zoom returning to one never starts an upgrade', (
    tester,
  ) async {
    final baseReady = Completer<void>();
    final loader = _MemoryImageLoader(800, 1200)
      ..waits[1] = baseReady
      ..install();
    final provider = _provider(
      ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
    );
    final controller = PhotoViewController(initialScale: 2)
      ..getInitialScale = () => 1;
    await tester.pumpWidget(_galleryImage(provider, controller));
    await runWidgetIo(tester, () => loader.started(1));
    controller.scale = 6;
    await tester.pump();
    controller.scale = 1;
    await tester.pump();
    expect(loader.loads, 1);
    baseReady.complete();
    await _waitForPixels(tester, const Size(200, 300));
    await tester.pump();
    expect(loader.loads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('zoom waits without blanking or moving rounded flow layout', (
    tester,
  ) async {
    final zoomReady = Completer<void>();
    final loader = _MemoryImageLoader(803, 1207)
      ..waits[2] = zoomReady
      ..install();
    final provider = _provider(
      ComicImageLoadTarget(
        logicalWidth: 200,
        fit: ComicImageTargetFit.fitWidth,
      ),
    );
    final controller = PhotoViewController(initialScale: 1)
      ..getInitialScale = () => 1;
    final reported = <Size>[];
    const following = ValueKey('following');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: 500,
            child: ListView(
              children: [
                ComicImage(
                  image: provider,
                  zoomController: controller,
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                  onImageSize: reported.add,
                ),
                const SizedBox(key: following, height: 20),
              ],
            ),
          ),
        ),
      ),
    );
    await _waitForPixels(tester, const Size(200, 301));
    final original = tester.widget<RawImage>(find.byType(RawImage)).image;
    final layout = tester.getSize(find.byType(ComicImage));
    final followingPosition = tester.getTopLeft(find.byKey(following));
    controller.scale = 1.75;
    await runWidgetIo(tester, () => loader.started(2));
    await tester.pump();
    expect(
      tester.widget<RawImage>(find.byType(RawImage)).image,
      same(original),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    zoomReady.complete();
    await _waitForPixels(tester, const Size(400, 601));
    expect(tester.getSize(find.byType(ComicImage)), layout);
    expect(tester.getTopLeft(find.byKey(following)), followingPosition);
    expect(ComicImage.getCachedImageSize(provider), const Size(200, 301));
    expect(reported, [const Size(200, 301)]);
    controller.scale = 1;
    await _waitForPixels(tester, const Size(200, 301));
    expect(tester.getTopLeft(find.byKey(following)), followingPosition);
    expect(loader.loads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final (name, sourceSize, target, basePixels, zoomPixels, horizontal) in [
    (
      'fitHeight',
      const Size(1207, 803),
      ComicImageLoadTarget(
        logicalHeight: 200,
        fit: ComicImageTargetFit.fitHeight,
      ),
      const Size(301, 200),
      const Size(601, 400),
      true,
    ),
    (
      'split fitWidth',
      const Size(1207, 801),
      ComicImageLoadTarget(
        logicalWidth: 100,
        fit: ComicImageTargetFit.fitWidth,
        splitWideImage: true,
      ),
      const Size(200, 133),
      const Size(400, 265),
      false,
    ),
  ]) {
    testWidgets('$name keeps rounded layout when real pixels change', (
      tester,
    ) async {
      final loader = _MemoryImageLoader(
        sourceSize.width.toInt(),
        sourceSize.height.toInt(),
      )..install();
      final provider = _provider(target);
      final controller = PhotoViewController(initialScale: 1)
        ..getInitialScale = () => 1;
      final reported = <Size>[];
      const following = ValueKey('following');
      final image = ComicImage(
        image: provider,
        zoomController: controller,
        width: horizontal ? null : double.infinity,
        height: horizontal ? double.infinity : null,
        splitWideImage: target.splitWideImage,
        fit: horizontal ? BoxFit.fitHeight : BoxFit.fitWidth,
        onImageSize: reported.add,
      );
      final children = [
        image,
        const SizedBox(key: following, width: 20, height: 20),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: horizontal ? 500 : 100,
              height: horizontal ? 200 : 500,
              child: SingleChildScrollView(
                scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
                child: horizontal
                    ? Row(children: children)
                    : Column(children: children),
              ),
            ),
          ),
        ),
      );
      Size? decodedPixels;
      await runWidgetIo(tester, () async {
        decodedPixels = await _decodedSize(provider);
      });
      expect(decodedPixels, basePixels);
      await tester.pump();
      final layout = tester.getSize(find.byType(ComicImage));
      final followingPosition = tester.getTopLeft(find.byKey(following));
      final paint = find.descendant(
        of: find.byType(ComicImage),
        matching: find.byType(CustomPaint),
      );
      final originalPainter = horizontal
          ? null
          : tester.widget<CustomPaint>(paint).painter;
      controller.scale = 1.75;
      await tester.pump();
      await runWidgetIo(tester, () async {
        decodedPixels = await _decodedSize(
          provider.withDecodeScale(2, sourceSize),
        );
      });
      expect(decodedPixels, zoomPixels);
      await tester.pump();
      expect(loader.loads, 2);
      expect(tester.getSize(find.byType(ComicImage)), layout);
      expect(tester.getTopLeft(find.byKey(following)), followingPosition);
      expect(ComicImage.getCachedImageSize(provider), basePixels);
      expect(reported, [basePixels]);
      if (horizontal) {
        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image!.width, zoomPixels.width);
        expect(raw.image!.height, zoomPixels.height);
      } else {
        expect(
          tester.widget<CustomPaint>(paint).painter,
          isNot(same(originalPainter)),
        );
        expect(find.byType(RawImage), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets('target and controller changes discard a pending base callback', (
    tester,
  ) async {
    final oldReady = Completer<void>();
    final loader = _MemoryImageLoader(800, 1200)
      ..waits[1] = oldReady
      ..install();
    final original = _provider(
      ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
    );
    final replacement = _provider(
      ComicImageLoadTarget(logicalWidth: 100, logicalHeight: 150),
    );
    final oldController = PhotoViewController(initialScale: 6)
      ..getInitialScale = () => 1;
    final controller = PhotoViewController(initialScale: 1)
      ..getInitialScale = () => 1;
    final reported = <Size>[];
    await tester.pumpWidget(
      _galleryImage(original, oldController, onImageSize: reported.add),
    );
    await runWidgetIo(tester, () => loader.started(1));
    final lateFrame = _decodedSize(original);
    await tester.pumpWidget(
      _galleryImage(replacement, controller, onImageSize: reported.add),
    );
    await _waitForPixels(tester, const Size(100, 150));
    oldReady.complete();
    Size? latePixels;
    await runWidgetIo(tester, () async {
      latePixels = await lateFrame;
    });
    expect(latePixels, const Size(200, 300));
    await tester.pump();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 100);
    expect(reported, [const Size(100, 150)]);
    expect(loader.loads, 2);
    expect(ComicImage.getCachedImageSize(replacement), const Size(100, 150));
    await tester.pumpWidget(const SizedBox.shrink());
    oldController.dispose();
    controller.dispose();
  });
}
