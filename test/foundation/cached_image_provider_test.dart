import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/image_provider/cached_image.dart';
import 'package:venera_plus/network/app_dio.dart' show CancelToken;
import 'package:venera_plus/network/images.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cached image provider limits concurrent thumbnail loads', () async {
    var active = 0;
    var maxActive = 0;
    final started = <Completer<void>>[];
    final release = <Completer<void>>[];

    final tasks = List.generate(11, (index) {
      final startedCompleter = Completer<void>();
      final releaseCompleter = Completer<void>();
      started.add(startedCompleter);
      release.add(releaseCompleter);

      return CachedImageProvider.debugRunWithThumbnailSlot(() async {
        active++;
        if (active > maxActive) {
          maxActive = active;
        }
        startedCompleter.complete();
        await releaseCompleter.future;
        active--;
        return index;
      });
    });

    await Future.wait(
      started
          .take(9)
          .map(
            (completer) => completer.future.timeout(const Duration(seconds: 1)),
          ),
    );
    await pumpEventQueue();

    expect(started[9].isCompleted, isFalse);
    expect(maxActive, 9);
    expect(CachedImageProvider.loadingCount, 9);

    release[0].complete();
    await started[9].future.timeout(const Duration(seconds: 1));

    expect(maxActive, 9);

    for (final completer in release.skip(1)) {
      completer.complete();
    }

    expect(await Future.wait(tasks), List.generate(11, (index) => index));
    expect(active, 0);
    expect(CachedImageProvider.loadingCount, 0);
  });

  test('queued thumbnail load checks stop before running task', () async {
    final release = List.generate(9, (_) => Completer<void>());
    final holders = release.map((completer) {
      return CachedImageProvider.debugRunWithThumbnailSlot(() async {
        await completer.future;
      });
    }).toList();
    await pumpEventQueue();

    var ran = false;
    final queued = CachedImageProvider.debugRunWithThumbnailSlot(
      () async {
        ran = true;
      },
      checkStop: () {
        throw StateError('stopped');
      },
    );
    await pumpEventQueue();

    expect(ran, isFalse);

    release.first.complete();
    await expectLater(queued, throwsA(isA<StateError>()));
    expect(ran, isFalse);

    for (final completer in release.skip(1)) {
      completer.complete();
    }
    await Future.wait(holders);

    expect(CachedImageProvider.loadingCount, 0);
  });

  test(
    'cancelling active thumbnail providers unblocks a disk-cached cover',
    () async {
      final directory = await Directory.systemTemp.createTemp('cover-queue-');
      App.dataPath = directory.path;
      App.cachePath = directory.path;
      CacheManager.debugDisableInitialScan = true;
      final previousErrorHandler = FlutterError.onError;
      final errors = <FlutterErrorDetails>[];
      FlutterError.onError = errors.add;
      final started = List.generate(9, (_) => Completer<CancelToken>());
      final release = List.generate(9, (_) => Completer<Uint8List>());
      final holders = <(ImageStreamCompleter, ImageStreamListener)>[];
      final chunkEvents = StreamController<ImageChunkEvent>.broadcast();
      var fallbackCalls = 0;
      const cachedUrl = 'https://example.invalid/cached-cover.png';

      ImageDownloader.configureSourceImageLoading(
        thumbnailLoadingConfig: (source, url) {
          final index = int.parse(Uri.parse(url).pathSegments.last);
          Future<Uint8List> loadBytes(CancelToken token) {
            started[index].complete(token);
            return release[index].future;
          }

          return {'loadBytes': loadBytes};
        },
      );

      try {
        await CacheManager().writeCache('$cachedUrl@probe', [8, 9]);
        for (var index = 0; index < 9; index++) {
          final provider = CachedImageProvider(
            'https://example.invalid/$index',
            sourceKey: 'probe',
            fallback: () {
              fallbackCalls++;
              return Uint8List.fromList([1]);
            },
          );
          final completer = provider.loadImage(
            provider,
            (buffer, {getTargetSize}) =>
                throw StateError('Cancelled covers must not be decoded'),
          );
          final listener = ImageStreamListener((image, synchronous) {
            image.dispose();
            fail('Cancelled covers must not produce an image');
          });
          completer.addListener(listener);
          holders.add((completer, listener));
        }
        final tokens = await Future.wait(
          started.map((item) => item.future),
        ).timeout(const Duration(seconds: 5));
        var cachedFinished = false;
        final cached = const CachedImageProvider(cachedUrl, sourceKey: 'probe')
            .load(chunkEvents, () {})
            .then((bytes) {
              cachedFinished = true;
              return bytes;
            });
        await pumpEventQueue();
        expect(cachedFinished, isFalse);
        expect(CachedImageProvider.loadingCount, 9);

        for (final (completer, listener) in holders) {
          completer.removeListener(listener);
        }
        holders.clear();

        expect(await cached.timeout(const Duration(seconds: 5)), [8, 9]);
        await pumpEventQueue();
        expect(tokens.every((token) => token.isCancelled), isTrue);
        expect(release.every((item) => !item.isCompleted), isTrue);
        expect(CachedImageProvider.loadingCount, 0);
        expect(fallbackCalls, 0);
        expect(errors, hasLength(9));
        expect(
          errors.every(
            (error) => error.exception.toString().contains(
              '_ImageLoadingStopException',
            ),
          ),
          isTrue,
        );
      } finally {
        for (final (completer, listener) in holders) {
          completer.removeListener(listener);
        }
        for (final item in release) {
          if (!item.isCompleted) item.complete(Uint8List.fromList([1]));
        }
        await pumpEventQueue();
        await chunkEvents.close();
        ImageDownloader.debugResetSourceImageLoading();
        await ImageDownloader.debugFlushImageCacheWrites();
        await CacheManager.resetForTesting();
        FlutterError.onError = previousErrorHandler;
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cached image provider uses fallback after primary load fails',
    () async {
      final chunkEvents = StreamController<ImageChunkEvent>.broadcast();
      addTearDown(chunkEvents.close);

      final provider = CachedImageProvider(
        'file://missing-cover.jpg',
        fallback: () => Uint8List.fromList([1, 2, 3]),
      );

      final data = await provider.load(chunkEvents, () {});

      expect(data, [1, 2, 3]);
    },
  );
}
