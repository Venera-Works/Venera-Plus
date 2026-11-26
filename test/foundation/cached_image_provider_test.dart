import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

  group('封面加载调度', () {
    const remoteSource = 'remote_library_1';
    const timeout = Duration(seconds: 5);
    late Directory directory;
    late StreamController<ImageChunkEvent> chunkEvents;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('thumbnail-slots-');
      App.dataPath = App.cachePath = directory.path;
      CacheManager.debugDisableInitialScan = true;
      chunkEvents = StreamController<ImageChunkEvent>.broadcast();
    });

    tearDown(() async {
      await chunkEvents.close();
      ImageDownloader.debugResetSourceImageLoading();
      await CacheManager.resetForTesting();
      await directory.delete(recursive: true);
    });

    test('单个云端库只占用三个槽位，普通来源和本地封面可以返回', () async {
      final release = Completer<Uint8List>();
      final threeStarted = Completer<void>();
      var slowStarts = 0;
      final ordinaryBytes = Uint8List.fromList([4, 5, 6]);
      final localBytes = img.encodePng(img.Image(width: 2, height: 2));
      final file = await File(
        '${directory.path}/local.png',
      ).writeAsBytes(localBytes);
      ImageDownloader.configureSourceImageLoading(
        thumbnailLoadingConfig: (source, _) => {
          'loadBytes': (CancelToken _) async {
            if (source != remoteSource) return ordinaryBytes;
            if (++slowStarts == 3) threeStarted.complete();
            return release.future;
          },
        },
      );

      final pending = List.generate(6, (index) {
        return CachedImageProvider(
          'https://example.invalid/slow-$index.png',
          sourceKey: remoteSource,
        ).load(chunkEvents, () {});
      });
      try {
        await threeStarted.future.timeout(timeout);
        expect(CachedImageProvider.loadingCount, 3);

        final otherCovers = await Future.wait([
          const CachedImageProvider(
            'https://example.invalid/ordinary.png',
            sourceKey: 'probe',
          ).load(chunkEvents, () {}),
          CachedImageProvider('file://${file.path}').load(chunkEvents, () {}),
        ]).timeout(timeout);

        expect(otherCovers, [ordinaryBytes, localBytes]);
        expect(release.isCompleted, isFalse);
        expect(slowStarts, 3);
        expect(CachedImageProvider.loadingCount, 3);
      } finally {
        release.complete(Uint8List.fromList([1, 2, 3]));
        await Future.wait(pending);
      }
    });

    test('同库三个槽位都忙时命中磁盘缓存仍直接返回', () async {
      final release = Completer<Uint8List>();
      final threeStarted = Completer<void>();
      final resolvedUrls = <String>[];
      const cached = CachedImageProvider(
        'https://example.invalid/cached.png',
        sourceKey: remoteSource,
        cid: 'comic',
      );
      await CacheManager().writeCache('${cached.url}@$remoteSource@comic', [
        8,
        9,
      ]);
      ImageDownloader.configureSourceImageLoading(
        thumbnailLoadingConfig: (_, url) {
          resolvedUrls.add(url);
          if (resolvedUrls.length == 3) threeStarted.complete();
          return {'loadBytes': (CancelToken _) => release.future};
        },
      );

      final pending = List.generate(3, (index) {
        return CachedImageProvider(
          'https://example.invalid/stalled-$index.png',
          sourceKey: remoteSource,
        ).load(chunkEvents, () {});
      });
      try {
        await threeStarted.future.timeout(timeout);
        expect(CachedImageProvider.loadingCount, 3);
        expect(await cached.load(chunkEvents, () {}).timeout(timeout), [8, 9]);
        expect(resolvedUrls, hasLength(3));
        expect(resolvedUrls, isNot(contains(cached.url)));
        expect(release.isCompleted, isFalse);
        expect(CachedImageProvider.loadingCount, 3);
      } finally {
        release.complete(Uint8List.fromList([1, 2, 3]));
        await Future.wait(pending);
      }
    });

    test('取消全局队列中的第十张封面时无需等待槽位释放', () async {
      final release = Completer<void>();
      final holders = List.generate(9, (_) {
        return CachedImageProvider.debugRunWithThumbnailSlot(
          () => release.future,
        );
      });
      final stopped = Completer<FlutterErrorDetails>();
      final previousErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        if (!stopped.isCompleted) stopped.complete(details);
      };
      const provider = CachedImageProvider(
        'https://example.invalid/queued.png',
        sourceKey: 'probe',
      );
      final listener = ImageStreamListener((image, _) {
        image.dispose();
        fail('排队后取消的封面不应出图');
      });
      ImageStreamCompleter? listening;
      try {
        await pumpEventQueue();
        expect(CachedImageProvider.loadingCount, 9);
        final stream = provider.loadImage(
          provider,
          (_, {getTargetSize}) => throw StateError('取消的封面不应解码'),
        );
        stream.addListener(listener);
        listening = stream;
        await pumpEventQueue();
        expect(stopped.isCompleted, isFalse);
        expect(CacheManager.instance, isNull);

        // 移除直接加载流的最后一个监听器，触发生产代码的取消信号。
        stream.removeListener(listener);
        listening = null;
        final error = await stopped.future.timeout(timeout);
        expect(
          error.exceptionAsString(),
          contains('_ImageLoadingStopException'),
        );
        expect(release.isCompleted, isFalse);
        expect(CachedImageProvider.loadingCount, 9);
        expect(CacheManager.instance, isNull);
      } finally {
        listening?.removeListener(listener);
        release.complete();
        await Future.wait(holders);
        await pumpEventQueue();
        FlutterError.onError = previousErrorHandler;
      }
      expect(CacheManager.instance, isNull);
    });
  });
}
