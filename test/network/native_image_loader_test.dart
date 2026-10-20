import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/network/images.dart';

class _ResponseCallback extends JSInvokable {
  _ResponseCallback(this.callback);

  final dynamic Function(List args) callback;
  int destroyCount = 0;

  @override
  dynamic invoke(List args, [dynamic thisVal]) => callback(args);

  @override
  void destroy() => destroyCount++;
}

bool _sqliteAvailable() {
  try {
    final db = sqlite3.openInMemory();
    db.close();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'native image bytes loading',
    () {
      late Directory directory;

      setUp(() {
        directory = Directory.systemTemp.createTempSync('native-image-loader-');
        App.dataPath = directory.path;
        App.cachePath = directory.path;
        CacheManager.debugDisableInitialScan = true;
      });

      tearDown(() async {
        ImageDownloader.cancelAllLoadingImages();
        await ImageDownloader.debugFlushImageCacheWrites();
        ImageDownloader.debugResetSourceImageLoading();
        await CacheManager.resetForTesting();
        directory.deleteSync(recursive: true);
      });

      test(
        'comic loader reuses stable raw cache before response processing',
        () async {
          var loaderCalls = 0;
          var resolverCalls = 0;
          final callbacks = <_ResponseCallback>[];
          final tokens = <CancelToken>[];
          ImageDownloader.debugComicImageTransport = (_, _) =>
              throw StateError('Native loading must bypass URL transport');
          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig: (source, image, comic, chapter, {target}) {
              resolverCalls++;
              final response = _ResponseCallback((args) {
                expect(args.single, [1, 2, 3]);
                return Uint8List.fromList([resolverCalls]);
              });
              callbacks.add(response);
              Future<Uint8List> loadBytes(CancelToken cancelToken) async {
                loaderCalls++;
                tokens.add(cancelToken);
                return Uint8List.fromList([1, 2, 3]);
              }

              return {
                'url': 'https://example.invalid/temporary?token=$resolverCalls',
                'data': Object(),
                'loadBytes': loadBytes,
                'onResponse': response,
              };
            },
          );

          Future<Uint8List> load({
            String comic = 'comic',
            ComicImageLoadTarget? target,
          }) => ImageDownloader.loadComicImageBytes(
            'stable-entry',
            'cloud',
            comic,
            'chapter',
            target: target,
          );
          expect(await load(), [1]);
          expect(await load(), [2]);
          expect(loaderCalls, 1);
          expect(resolverCalls, 2);
          expect(callbacks.map((callback) => callback.destroyCount), [1, 1]);
          expect(tokens.single.isCancelled, isFalse);

          expect(await load(comic: 'another-comic'), [3]);
          expect(await load(target: ComicImageLoadTarget(logicalWidth: 100)), [
            4,
          ]);
          expect(loaderCalls, 3);
        },
      );

      test(
        'preloaded native image skips both resolver and loader on reopen',
        () async {
          var resolverCalls = 0;
          var loaderCalls = 0;
          final png = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
          );
          Future<Uint8List> loadBytes(CancelToken _) async {
            loaderCalls++;
            return png;
          }

          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig: (source, image, comic, chapter, {target}) {
              resolverCalls++;
              return {'loadBytes': loadBytes};
            },
          );
          final target = ComicImageLoadTarget(logicalWidth: 100);
          await ImageDownloader.preloadComicImage(
            'preloaded-entry',
            'cloud',
            'comic',
            'chapter',
            target: target,
          );
          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig:
                (source, image, comic, chapter, {target}) => throw StateError(
                  'A cached image must not resolve its source',
                ),
          );

          expect(
            await ImageDownloader.loadComicImageBytes(
              'preloaded-entry',
              'cloud',
              'comic',
              'chapter',
              target: target,
            ),
            png,
          );
          expect(resolverCalls, 1);
          expect(loaderCalls, 1);
        },
      );

      test(
        'native response callback runs before image modification and failures evict raw bytes',
        () async {
          var loaderCalls = 0;
          final responseError = StateError('response processing failed first');
          final callbacks = <_ResponseCallback>[];
          Future<Uint8List> loadBytes(CancelToken _) async {
            loaderCalls++;
            return Uint8List.fromList([1, 2, 3]);
          }

          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig: (source, image, comic, chapter, {target}) {
              final response = _ResponseCallback((_) => throw responseError);
              callbacks.add(response);
              return {
                'loadBytes': loadBytes,
                'onResponse': response,
                'modifyImage': 'function modifyImage(image) { return image; }',
              };
            },
          );
          for (var attempt = 0; attempt < 2; attempt++) {
            await expectLater(
              ImageDownloader.loadComicImageBytes(
                'processing-entry',
                'cloud',
                'comic',
                'chapter',
              ),
              throwsA(same(responseError)),
            );
          }
          expect(loaderCalls, 2);
          expect(callbacks.map((callback) => callback.destroyCount), [1, 1]);
        },
      );

      test(
        'native thumbnail caches processed bytes and does not resolve cover URLs',
        () async {
          var resolverCalls = 0;
          var loaderCalls = 0;
          final tokens = <CancelToken>[];
          final response = _ResponseCallback((args) {
            expect(args.single, [1, 2, 3]);
            return Uint8List.fromList([3, 2, 1]);
          });
          Future<Uint8List> loadBytes(CancelToken token) async {
            loaderCalls++;
            tokens.add(token);
            return Uint8List.fromList([1, 2, 3]);
          }

          ImageDownloader.configureSourceImageLoading(
            thumbnailLoadingConfig: (source, image) {
              resolverCalls++;
              return {
                'url': 'cover.temporary-url',
                'loadBytes': loadBytes,
                'onResponse': response,
              };
            },
            thumbnailCover: (_, _) =>
                throw StateError('Native cover already resolved'),
          );

          for (var attempt = 0; attempt < 2; attempt++) {
            final events = await ImageDownloader.loadThumbnail(
              'cover.stable-entry',
              'cloud',
              'comic',
            ).toList();
            expect(events, hasLength(1));
            expect(events.single.imageBytes, [3, 2, 1]);
          }
          expect(loaderCalls, 1);
          expect(resolverCalls, 1);
          expect(response.destroyCount, 1);
          expect(tokens.single.isCancelled, isFalse);
        },
      );

      test(
        'last comic listener cancels the pending loader immediately and allows reload',
        () async {
          final gates = [Completer<Uint8List>(), Completer<Uint8List>()];
          final started = [Completer<CancelToken>(), Completer<CancelToken>()];
          var calls = 0;
          Future<Uint8List> loadBytes(CancelToken token) {
            final index = calls++;
            started[index].complete(token);
            return gates[index].future;
          }

          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig:
                (source, image, comic, chapter, {target}) => {
                  'loadBytes': loadBytes,
                },
          );
          final first = ImageDownloader.loadComicImage(
            'cancel-entry',
            'cloud',
            'comic',
            'chapter',
          ).listen((_) {});
          final second = ImageDownloader.loadComicImage(
            'cancel-entry',
            'cloud',
            'comic',
            'chapter',
          ).listen((_) {});
          final token = await started[0].future.timeout(
            const Duration(seconds: 5),
          );
          await first.cancel();
          expect(token.isCancelled, isFalse);

          final cancel = second.cancel();
          expect(token.isCancelled, isTrue);
          await cancel.timeout(const Duration(seconds: 1));
          expect(gates[0].isCompleted, isFalse);

          final reload = ImageDownloader.loadComicImageBytes(
            'cancel-entry',
            'cloud',
            'comic',
            'chapter',
          );
          final reloadToken = await started[1].future.timeout(
            const Duration(seconds: 5),
          );
          expect(reloadToken.isCancelled, isFalse);
          gates[0].complete(Uint8List.fromList([1]));
          gates[1].complete(Uint8List.fromList([2]));
          expect(await reload, [2]);
          expect(calls, 2);
          expect(
            await ImageDownloader.loadComicImageBytes(
              'cancel-entry',
              'cloud',
              'comic',
              'chapter',
            ),
            [2],
          );
          expect(calls, 2);
        },
      );

      test(
        'cancelAll immediately cancels native preload without retrying',
        () async {
          final started = Completer<CancelToken>();
          var retries = 0;
          final onLoadFailed = _ResponseCallback((_) {
            retries++;
            return <String, dynamic>{};
          });
          Future<Uint8List> loadBytes(CancelToken token) async {
            started.complete(token);
            throw await token.whenCancel;
          }

          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig:
                (source, image, comic, chapter, {target}) => {
                  'loadBytes': loadBytes,
                  'onLoadFailed': onLoadFailed,
                },
          );
          final preload = ImageDownloader.preloadComicImage(
            'preload-cancel',
            'cloud',
            'comic',
            'chapter',
          );
          final token = await started.future.timeout(
            const Duration(seconds: 5),
          );
          final ui = ImageDownloader.loadComicImage(
            'preload-cancel',
            'cloud',
            'comic',
            'chapter',
          ).listen((_) {});
          await ui.cancel();
          expect(token.isCancelled, isFalse);

          ImageDownloader.cancelAllLoadingImages();
          expect(token.isCancelled, isTrue);
          await preload.timeout(const Duration(seconds: 1));
          await pumpEventQueue();
          expect(retries, 0);
          expect(onLoadFailed.destroyCount, 1);
        },
      );

      test(
        'unwrapped comic download cancels its pending native loader',
        () async {
          final started = Completer<CancelToken>();
          Future<Uint8List> loadBytes(CancelToken token) async {
            started.complete(token);
            throw await token.whenCancel;
          }

          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig:
                (source, image, comic, chapter, {target}) => {
                  'loadBytes': loadBytes,
                },
          );
          final subscription = ImageDownloader.loadComicImageUnwrapped(
            'download-cancel',
            'cloud',
            'comic',
            'chapter',
          ).listen((_) {});
          final token = await started.future.timeout(
            const Duration(seconds: 5),
          );
          final cancel = subscription.cancel();
          expect(token.isCancelled, isTrue);
          await cancel.timeout(const Duration(seconds: 1));
        },
      );

      for (final redirected in [false, true]) {
        test(
          '${redirected ? 'redirected' : 'direct'} thumbnail cancels its pending native loader',
          () async {
            final started = Completer<CancelToken>();
            final stopped = Completer<void>();
            final errors = <Object>[];
            Future<Uint8List> loadBytes(CancelToken token) async {
              started.complete(token);
              try {
                throw await token.whenCancel;
              } finally {
                stopped.complete();
              }
            }

            ImageDownloader.configureSourceImageLoading(
              thumbnailLoadingConfig: (source, image) =>
                  image == 'cover.redirect'
                  ? <String, dynamic>{}
                  : {'loadBytes': loadBytes},
              thumbnailCover: (_, _) => 'native-cover-entry',
            );
            final image = redirected ? 'cover.redirect' : 'native-cover-entry';
            final subscription =
                ImageDownloader.loadThumbnail(image, 'cloud', 'comic').listen(
                  (_) => fail('A cancelled loader must not emit image data'),
                  onError: errors.add,
                );
            final token = await started.future.timeout(
              const Duration(seconds: 5),
            );
            final cancel = subscription.cancel();
            expect(token.isCancelled, isTrue);
            await cancel.timeout(const Duration(seconds: 1));
            await stopped.future.timeout(const Duration(seconds: 1));
            await pumpEventQueue();
            expect(errors, isEmpty);
            expect(
              await CacheManager().findCache('native-cover-entry@cloud'),
              isNull,
            );
            expect(
              await CacheManager().findCache('$image@cloud@comic'),
              isNull,
            );
          },
        );
      }

      test(
        'thumbnail loader errors remain observable without cancellation',
        () async {
          final error = StateError('Thumbnail loading failed');
          Future<Uint8List> loadBytes(CancelToken _) async => throw error;
          ImageDownloader.configureSourceImageLoading(
            thumbnailLoadingConfig: (_, _) => {'loadBytes': loadBytes},
          );
          await expectLater(
            ImageDownloader.loadThumbnail('failed-thumbnail', 'cloud').toList(),
            throwsA(same(error)),
          );
        },
      );
    },
    skip: _sqliteAvailable() ? false : 'sqlite3 native library is unavailable',
  );
}
