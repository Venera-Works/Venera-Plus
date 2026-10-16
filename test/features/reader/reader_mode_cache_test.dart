import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera_plus/features/reader/images.dart';
import 'package:venera_plus/features/reader/reader_page.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/images.dart';

class _ResponseCallback extends JSInvokable {
  _ResponseCallback(this.bytes);

  final Uint8List? bytes;
  int destroyCount = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) =>
      bytes ?? (throw StateError('Image response processing failed'));

  @override
  void destroy() => destroyCount++;
}

Future<Object?> _resolveImage(ReaderImageProvider provider) async {
  final result = Completer<Object?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (image, synchronous) {
      image.dispose();
      if (!result.isCompleted) result.complete();
    },
    onError: (Object error, StackTrace? stack) {
      if (!result.isCompleted) result.complete(error);
    },
  );
  stream.addListener(listener);
  try {
    return await result.future.timeout(const Duration(seconds: 5));
  } finally {
    stream.removeListener(listener);
    await provider.evict();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('reader-mode-cache-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    CacheManager.debugDisableInitialScan = true;
  });

  tearDown(() {
    ImageDownloader.cancelAllLoadingImages();
    ImageDownloader.debugResetSourceImageLoading();
    CacheManager.resetForTesting();
    directory.deleteSync(recursive: true);
  });

  ComicImageLoadTarget targetForMode(ReaderMode mode) =>
      calculateReaderImageTarget(
        mode: mode,
        viewportSize: const Size(800, 600),
        devicePixelRatio: 2,
        page: 1,
        totalImages: 10,
      );

  final galleryTarget = targetForMode(ReaderMode.galleryLeftToRight);
  final flowTarget = targetForMode(ReaderMode.continuousTopToBottom);

  test(
    'reopened decoded image skips source configuration and download',
    () async {
      var configs = 0;
      var downloads = 0;
      var restarted = false;
      final callbacks = <_ResponseCallback>[];
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (source, image, comic, chapter, {target}) {
          configs++;
          if (restarted) {
            throw StateError('Source is unavailable after restart');
          }
          final callback = _ResponseCallback(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
            ),
          );
          callbacks.add(callback);
          return {
            'url': 'https://example.invalid/image.png?token=$configs',
            'onResponse': callback,
          };
        },
      );
      ImageDownloader.debugComicImageTransport = (url, config) {
        downloads++;
        return Uint8List.fromList([0]);
      };
      ReaderImageProvider provider() => ReaderImageProvider(
        'stable-image',
        'source',
        'comic',
        'chapter',
        1,
        target: galleryTarget,
      );

      expect(await _resolveImage(provider()), isNull);
      ImageDownloader.cancelAllLoadingImages();
      CacheManager.resetForTesting();
      // Include the real startup scan, while retaining only the disk files.
      await CacheManager().debugInitialScanTask;
      restarted = true;
      expect(await _resolveImage(provider()), isNull);
      expect(configs, 1);
      expect(downloads, 1);
      expect(callbacks.single.destroyCount, 1);
    },
  );

  test('reader modes reuse a completed identical image request', () async {
    var requests = 0;
    ImageDownloader.debugComicImageTransport = (url, configs) {
      requests++;
      return Uint8List.fromList([1, 2, 3]);
    };
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (source, image, comic, chapter, {target}) => {
        'url': 'https://example.invalid/image.png',
        'headers': target == galleryTarget
            ? {'Referer': 'https://example.invalid', 'X-Image': 'original'}
            : {'X-Image': 'original', 'Referer': 'https://example.invalid'},
      },
    );

    for (final mode in [
      ReaderMode.galleryLeftToRight,
      ReaderMode.continuousTopToBottom,
      ReaderMode.waterfallTopToBottom,
      ReaderMode.galleryLeftToRight,
    ]) {
      final bytes = await ImageDownloader.loadComicImageBytes(
        'image',
        'source',
        'comic',
        'chapter',
        target: targetForMode(mode),
      );
      expect(bytes, [1, 2, 3]);
    }
    expect(requests, 1);
  });

  test('target-dependent requests keep separate cached bytes', () async {
    for (final (field, first, second) in <(String, Object, Object)>[
      ('url', 'https://example.invalid/single', 'https://example.invalid/flow'),
      ('headers', {'X-Variant': 'single'}, {'X-Variant': 'flow'}),
      ('method', 'GET', 'POST'),
      ('data', {'variant': 'single'}, {'variant': 'flow'}),
      ('data', Stream.value([1]), Stream.value([2])),
    ]) {
      var requests = 0;
      ImageDownloader.debugComicImageTransport = (url, configs) =>
          Uint8List.fromList([++requests]);
      ImageDownloader.configureSourceImageLoading(
        comicImageLoadingConfig: (source, image, comic, chapter, {target}) => {
          field: target == galleryTarget ? first : second,
        },
      );
      for (final (target, expected) in [
        (galleryTarget, 1),
        (flowTarget, 2),
        (galleryTarget, 1),
      ]) {
        final bytes = await ImageDownloader.loadComicImageBytes(
          'image-$field-${first.runtimeType}',
          'source',
          'comic',
          'chapter',
          target: target,
        );
        expect(bytes, [expected]);
      }
      expect(requests, 2);
    }
  });

  test('response callbacks retain target-specific image processing', () async {
    var requests = 0;
    final callbacks = <_ResponseCallback>[];
    ImageDownloader.debugComicImageTransport = (url, configs) {
      requests++;
      return Uint8List.fromList([0]);
    };
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (source, image, comic, chapter, {target}) {
        final callback = _ResponseCallback(
          Uint8List.fromList([target == galleryTarget ? 1 : 2]),
        );
        callbacks.add(callback);
        return {'onResponse': callback};
      },
    );
    for (final (target, expected) in [
      (galleryTarget, 1),
      (flowTarget, 2),
      (galleryTarget, 1),
    ]) {
      final bytes = await ImageDownloader.loadComicImageBytes(
        'https://example.invalid/image.png',
        'source',
        'comic',
        'chapter',
        target: target,
      );
      expect(bytes, [expected]);
    }
    expect(requests, 1);
    expect(callbacks, hasLength(3));
    expect(callbacks.map((callback) => callback.destroyCount), [1, 1, 1]);
  });

  test('response failure discards the raw download before retry', () async {
    var requests = 0;
    final callbacks = <_ResponseCallback>[];
    ImageDownloader.debugComicImageTransport = (url, configs) {
      requests++;
      return Uint8List.fromList([0]);
    };
    ImageDownloader.configureSourceImageLoading(
      comicImageLoadingConfig: (source, image, comic, chapter, {target}) {
        final callback = _ResponseCallback(
          callbacks.isEmpty ? null : Uint8List.fromList([1]),
        );
        callbacks.add(callback);
        return {'onResponse': callback};
      },
    );
    Future<Uint8List> load() => ImageDownloader.loadComicImageBytes(
      'https://example.invalid/image.png',
      'source',
      'comic',
      'chapter',
      target: galleryTarget,
    );

    await expectLater(load(), throwsStateError);
    expect(await load(), [1]);
    expect(requests, 2);
    expect(callbacks.map((callback) => callback.destroyCount), [1, 1]);
  });

  test(
    'decode failure evicts the resolved download cache before retry',
    () async {
      final previousLogMuted = Log.isMuted;
      Log.isMuted = true;
      addTearDown(() => Log.isMuted = previousLogMuted);
      var requests = 0;
      ImageDownloader.debugComicImageTransport = (url, configs) {
        requests++;
        return requests == 1
            ? Uint8List.fromList([1, 2, 3])
            : base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
              );
      };
      final provider = ReaderImageProvider(
        'https://example.invalid/image.png',
        null,
        'comic',
        'chapter',
        1,
        target: galleryTarget,
      );

      final processedCacheKey = provider.diskCacheKey;
      expect(await _resolveImage(provider), isNotNull);
      expect(await CacheManager().findCache(provider.diskCacheKey), isNull);
      expect(await CacheManager().findCache(processedCacheKey), isNull);
      expect(await _resolveImage(provider), isNull);
      expect(requests, 2);
    },
  );
}
