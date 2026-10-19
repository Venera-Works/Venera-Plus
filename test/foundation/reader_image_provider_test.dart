import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:flutter/painting.dart';
import 'package:venera_plus/network/images.dart';

void main() {
  test('reader image processing waits for future result', () async {
    final cancelSignal = Completer<void>();
    final bytes = Uint8List.fromList([1, 2, 3]);
    var canceled = false;

    final result = await debugWaitForReaderImageProcessingResult(
      Future<Uint8List>.value(bytes),
      () {
        canceled = true;
      },
      () {},
      cancelSignal: cancelSignal.future,
    );

    expect(result, same(bytes));
    expect(canceled, isFalse);
  });

  test('reader image processing cancels through stop signal', () async {
    final image = Completer<Uint8List>();
    final cancelSignal = Completer<void>();
    var canceled = false;
    var checkedStop = false;

    final result = debugWaitForReaderImageProcessingResult(
      image.future,
      () {
        canceled = true;
      },
      () {
        checkedStop = true;
        throw StateError('stopped');
      },
      cancelSignal: cancelSignal.future,
    );

    cancelSignal.complete();

    await expectLater(result, throwsA(isA<StateError>()));
    expect(canceled, isTrue);
    expect(checkedStop, isTrue);
  });

  test('reader image processing keeps null result as empty bytes', () async {
    final cancelSignal = Completer<void>();

    final result = await debugWaitForReaderImageProcessingResult(
      Future<void>.value(),
      () {},
      () {},
      cancelSignal: cancelSignal.future,
    );

    expect(result, isA<Uint8List>());
    expect(result, isEmpty);
  });

  test('reader image processing propagates future errors', () async {
    final cancelSignal = Completer<void>();
    var canceled = false;

    final result = debugWaitForReaderImageProcessingResult(
      Future<Uint8List>.error(StateError('failed')),
      () {
        canceled = true;
      },
      () {},
      cancelSignal: cancelSignal.future,
    );

    await expectLater(result, throwsA(isA<StateError>()));
    expect(canceled, isFalse);
  });

  group('ReaderImageProvider identity & target contract', () {
    tearDown(() {
      ImageDownloader.debugLoadComicImageUnwrapped = null;
      ImageDownloader.cancelAllLoadingImages();
    });

    test(
      'ReaderImageProvider equality, hashCode, key, and diskCacheKey reflect target',
      () {
        final target1 = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.contain,
        );
        final target2 = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.contain,
        );
        final target3 = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.fitWidth,
        );
        final targetSplit = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
          devicePixelRatio: 2.0,
          fit: ComicImageTargetFit.contain,
          splitWideImage: true,
        );
        final targetDiffDpr = ComicImageLoadTarget(
          logicalWidth: 400,
          logicalHeight: 600,
          devicePixelRatio: 1.0,
          fit: ComicImageTargetFit.contain,
          splitWideImage: false,
        );
        final provider1 = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: target1,
        );
        final provider2 = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: target2,
        );
        final provider3 = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: target3,
        );
        final providerSplit = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: targetSplit,
        );
        final providerDiffDpr = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          target: targetDiffDpr,
        );
        const providerNull = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
        );

        expect(provider1, equals(provider2));
        expect(provider1.hashCode, equals(provider2.hashCode));
        expect(provider1.key, equals(provider2.key));
        expect(provider1.diskCacheKey, equals(provider2.diskCacheKey));

        expect(provider1, isNot(equals(provider3)));
        expect(provider1.key, isNot(equals(provider3.key)));
        expect(provider1.diskCacheKey, isNot(equals(provider3.diskCacheKey)));

        expect(provider1, isNot(equals(providerSplit)));
        expect(provider1.key, isNot(equals(providerSplit.key)));
        expect(
          provider1.diskCacheKey,
          isNot(equals(providerSplit.diskCacheKey)),
        );

        expect(provider1, isNot(equals(providerDiffDpr)));
        expect(provider1.key, isNot(equals(providerDiffDpr.key)));
        expect(
          provider1.diskCacheKey,
          isNot(equals(providerDiffDpr.diskCacheKey)),
        );
        expect(provider1, isNot(equals(providerNull)));
        expect(provider1.key, isNot(equals(providerNull.key)));
        expect(
          provider1.diskCacheKey,
          isNot(equals(providerNull.diskCacheKey)),
        );

        expect(
          provider1.key,
          'img-1@source-1@comic-1@chapter-1@false@${target1.cacheIdentity}',
        );
        expect(providerNull.key, 'img-1@source-1@comic-1@chapter-1@false');
        expect(
          provider1.diskCacheKey,
          'img-1@source-1@comic-1@chapter-1@${target1.cacheIdentity}',
        );
        expect(providerNull.diskCacheKey, 'img-1@source-1@comic-1@chapter-1');

        expect(provider1.key, contains('splitfalse'));
        expect(providerSplit.key, contains('splittrue'));
        expect(provider1.diskCacheKey, contains('splitfalse'));
        expect(providerSplit.diskCacheKey, contains('splittrue'));

        expect(target1.physicalWidth, equals(targetDiffDpr.physicalWidth));
        expect(target1.physicalHeight, equals(targetDiffDpr.physicalHeight));
        expect(provider1.key, contains('dpr2.0'));
        expect(providerDiffDpr.key, contains('dpr1.0'));
        expect(provider1.diskCacheKey, contains('dpr2.0'));
        expect(providerDiffDpr.diskCacheKey, contains('dpr1.0'));
      },
    );

    test(
      'decode identity uses effective pixels and preserves the base key',
      () {
        final target = ComicImageLoadTarget(
          logicalWidth: 200,
          logicalHeight: 300,
        );
        final base = ReaderImageProvider(
          'img-1',
          'source-1',
          'comic-1',
          'chapter-1',
          1,
          chapter: 2,
          enableResize: true,
          target: target,
        );
        final key = base.key;
        final hashCode = base.hashCode;
        const sourceSize = Size(800, 1200);
        final zoomed = base.withDecodeScale(2, sourceSize);
        expect(zoomed.key, '$key@decode400x600');
        expect(zoomed, isNot(base));
        expect(zoomed.diskCacheKey, base.diskCacheKey);
        expect(zoomed.imageKey, base.imageKey);
        expect(zoomed.sourceKey, base.sourceKey);
        expect(zoomed.cid, base.cid);
        expect(zoomed.eid, base.eid);
        expect(zoomed.page, base.page);
        expect(zoomed.chapter, base.chapter);
        expect(zoomed.enableResize, base.enableResize);
        expect(zoomed.target, same(target));
        expect(zoomed.withDecodeScale(1, sourceSize), same(base));
        expect(base.withDecodeScale(1, sourceSize), same(base));

        final capped = base.withDecodeScale(4, sourceSize);
        expect(capped.key, '$key@decode800x1200');
        for (final scale in [5.0, 10.0]) {
          final next = base.withDecodeScale(scale, sourceSize);
          expect(next, capped);
          expect(next.hashCode, capped.hashCode);
        }
        expect(base.key, key);
        expect(base.hashCode, hashCode);
        expect(
          key,
          'img-1@source-1@comic-1@chapter-1@true@${target.cacheIdentity}',
        );
      },
    );

    test('optional pixel budget is immutable memory identity only', () {
      final target = ComicImageLoadTarget(logicalWidth: 20, logicalHeight: 30);
      ReaderImageProvider provider({int? budget}) => ReaderImageProvider(
        'img',
        'source',
        'comic',
        'chapter',
        1,
        enableResize: true,
        target: target,
        maxDecodePixels: budget ?? ReaderImageProvider.defaultMaxDecodePixels,
      );
      final standard = provider();
      final limited = provider(budget: 1000);
      final equal = provider(budget: 1000);
      final different = provider(budget: 1001);
      final key = limited.key;
      final hashCode = limited.hashCode;
      expect(key, '${standard.key}@pixels1000');
      expect(limited, equal);
      expect(limited.hashCode, equal.hashCode);
      expect(limited, isNot(different));
      expect(limited.diskCacheKey, standard.diskCacheKey);
      expect(limited.target, same(target));
      const source = Size(80, 120);
      final zoomed = limited.withDecodeScale(2, source);
      expect(zoomed.key, '$key@decode25x38');
      expect(zoomed.maxDecodePixels, 1000);
      expect(zoomed.withDecodeScale(1, source), same(limited));
      for (final scale in [3.0, 4.0, 10.0]) {
        expect(limited.withDecodeScale(scale, source), zoomed);
      }
      expect(limited.key, key);
      expect(limited.hashCode, hashCode);
    });

    test(
      'default budget caps large decoded variants without allocating them',
      () {
        final provider = ReaderImageProvider(
          'img',
          'source',
          'comic',
          'chapter',
          1,
          enableResize: true,
          target: ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
        );
        const source = Size(40000, 60000);
        final capped = provider.withDecodeScale(100, source);
        final dimensions = RegExp(
          r'@decode(\d+)x(\d+)$',
        ).firstMatch(capped.key)!;
        final width = int.parse(dimensions.group(1)!);
        final height = int.parse(dimensions.group(2)!);
        expect(ReaderImageProvider.defaultMaxDecodePixels, 16 * 1024 * 1024);
        expect(width * height, lessThanOrEqualTo(provider.maxDecodePixels));
        expect(width, greaterThan(0));
        expect(height, greaterThan(0));
        expect(provider.withDecodeScale(1000, source), capped);
      },
    );

    test('small images and equal rounded pixels reuse the base provider', () {
      final base = ReaderImageProvider(
        'img-1',
        'source-1',
        'comic-1',
        'chapter-1',
        1,
        enableResize: true,
        target: ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
      );
      for (final scale in [4.0, 5.0, 10.0]) {
        expect(base.withDecodeScale(scale, const Size(100, 150)), same(base));
      }
      final rounded = ReaderImageProvider(
        'img-2',
        'source-1',
        'comic-1',
        'chapter-1',
        2,
        enableResize: true,
        target: ComicImageLoadTarget(logicalWidth: 2, logicalHeight: 3),
      );
      expect(rounded.withDecodeScale(1.1, const Size(3, 4)), same(rounded));
    });

    test('noninteger source cap merges the first capped level and higher', () {
      final base = ReaderImageProvider(
        'img-1',
        null,
        'comic-1',
        'chapter-1',
        1,
        enableResize: true,
        target: ComicImageLoadTarget(logicalWidth: 200, logicalHeight: 300),
      );
      const sourceSize = Size(750, 1100);
      expect(
        base.withDecodeScale(3, sourceSize).key,
        '${base.key}@decode600x880',
      );
      final capped = base.withDecodeScale(3.75, sourceSize);
      expect(capped.key, '${base.key}@decode750x1100');
      for (final scale in [4.0, 5.0, 10.0]) {
        expect(base.withDecodeScale(scale, sourceSize), capped);
      }
    });

    for (final (name, target, sourceSize, dimensions) in [
      (
        'fitWidth',
        ComicImageLoadTarget(
          logicalWidth: 200,
          fit: ComicImageTargetFit.fitWidth,
        ),
        const Size(600, 3600),
        '400x2400',
      ),
      (
        'fitHeight',
        ComicImageLoadTarget(
          logicalHeight: 200,
          fit: ComicImageTargetFit.fitHeight,
        ),
        const Size(1200, 800),
        '600x400',
      ),
      (
        'split contain',
        ComicImageLoadTarget(
          logicalWidth: 300,
          logicalHeight: 500,
          splitWideImage: true,
        ),
        const Size(1800, 900),
        '1200x600',
      ),
      (
        'split fitWidth',
        ComicImageLoadTarget(
          logicalWidth: 300,
          fit: ComicImageTargetFit.fitWidth,
          splitWideImage: true,
        ),
        const Size(1800, 900),
        '1200x600',
      ),
    ]) {
      test('$name uses the same normalization for variant identity', () {
        final base = ReaderImageProvider(
          'img-1',
          null,
          'comic-1',
          'chapter-1',
          1,
          enableResize: true,
          target: target,
        );
        final zoomed = base.withDecodeScale(2, sourceSize);
        expect(zoomed.key, '${base.key}@decode$dimensions');
        expect(zoomed.target, same(target));
        expect(zoomed.diskCacheKey, base.diskCacheKey);
      });
    }

    test(
      'ReaderImageProvider load forwards target to ImageDownloader and receives bytes',
      () async {
        final source = StreamController<ImageDownloadProgress>();
        addTearDown(() async {
          if (!source.isClosed) {
            await source.close();
          }
        });

        ComicImageLoadTarget? forwardedTarget;
        ImageDownloader.debugLoadComicImageUnwrapped =
            (imageKey, sourceKey, cid, eid, {target}) {
              forwardedTarget = target;
              return source.stream;
            };

        final target = ComicImageLoadTarget(
          logicalWidth: 150,
          logicalHeight: 250,
          fit: ComicImageTargetFit.fitHeight,
        );
        final provider = ReaderImageProvider(
          'http://example.com/test.jpg',
          'src',
          'cid',
          'eid',
          1,
          target: target,
        );

        final chunkEvents = StreamController<ImageChunkEvent>();
        final chunks = <ImageChunkEvent>[];
        chunkEvents.stream.listen(chunks.add);
        addTearDown(() async {
          if (!chunkEvents.isClosed) {
            await chunkEvents.close();
          }
        });

        final expectedBytes = Uint8List.fromList([10, 20, 30, 40]);
        final loadFuture = provider.load(chunkEvents, () {});

        await pumpEventQueue();

        expect(forwardedTarget, equals(target));

        source.add(
          ImageDownloadProgress(
            currentBytes: 4,
            totalBytes: 4,
            imageBytes: expectedBytes,
          ),
        );
        await source.close();

        final resultBytes = await loadFuture;
        expect(resultBytes, orderedEquals(expectedBytes));
        expect(chunks, hasLength(1));
        expect(chunks.first.cumulativeBytesLoaded, 4);
        expect(chunks.first.expectedTotalBytes, 4);
      },
    );
  });
}
