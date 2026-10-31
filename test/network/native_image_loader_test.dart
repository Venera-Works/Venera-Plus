import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/cache_manager.dart';
import 'package:venera_plus/foundation/image_provider/reader_image.dart';
import 'package:venera_plus/network/images.dart';
import 'package:venera_plus/network/remote_storage/remote_read_scheduler.dart';

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
        'thumbnail stop signal closes the stream while its resolver is pending',
        () async {
          final started = Completer<void>();
          final config = Completer<Map<String, dynamic>>();
          final cancel = Completer<void>();
          var loaderCalls = 0;
          ImageDownloader.configureSourceImageLoading(
            thumbnailLoadingConfig: (source, image) {
              started.complete();
              return config.future;
            },
          );
          final result = ImageDownloader.loadThumbnail(
            'cancelled-cover',
            'cloud',
            null,
            cancel.future,
          ).toList();
          await started.future.timeout(const Duration(seconds: 5));
          cancel.complete();
          expect(await result.timeout(const Duration(seconds: 1)), isEmpty);
          config.complete({
            'loadBytes': (CancelToken token) async {
              loaderCalls++;
              return Uint8List.fromList([1, 2, 3]);
            },
          });
          await pumpEventQueue();
          expect(loaderCalls, 0);
          expect(
            await CacheManager().findCache('cancelled-cover@cloud'),
            isNull,
          );
        },
      );

      test(
        'thumbnail timeout cancels a stalled loader and discards late bytes',
        () async {
          final started = Completer<CancelToken>();
          final release = Completer<Uint8List>();
          ImageDownloader.configureSourceImageLoading(
            thumbnailLoadingConfig: (source, image) {
              Future<Uint8List> loadBytes(CancelToken token) {
                started.complete(token);
                return release.future;
              }

              return {'loadBytes': loadBytes};
            },
          );
          final result = ImageDownloader.loadThumbnail(
            'stalled-cover',
            'cloud',
          ).toList();
          final failed = expectLater(result, throwsA(isA<TimeoutException>()));
          final token = await started.future.timeout(
            const Duration(seconds: 5),
          );
          try {
            await failed.timeout(const Duration(seconds: 35));
            expect(token.isCancelled, isTrue);
          } finally {
            release.complete(Uint8List.fromList([1, 2, 3]));
          }
          await pumpEventQueue();
          expect(await CacheManager().findCache('stalled-cover@cloud'), isNull);
        },
        timeout: const Timeout(Duration(seconds: 45)),
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
        'native comic contexts stay foreground across async resolver and loader',
        () async {
          final contexts = <RemoteReadContext>[];
          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig:
                (source, image, comic, chapter, {target}) async {
                  final context = RemoteReadContext.current;
                  contexts.add(context);
                  await Future<void>.value();
                  expect(identical(RemoteReadContext.current, context), isTrue);
                  Future<Uint8List> loadBytes(CancelToken _) async {
                    expect(
                      identical(RemoteReadContext.current, context),
                      isTrue,
                    );
                    await Future<void>.value();
                    expect(
                      identical(RemoteReadContext.current, context),
                      isTrue,
                    );
                    expect(context.priority, RemoteReadPriority.foreground);
                    return Uint8List.fromList([9]);
                  }

                  return {'loadBytes': loadBytes};
                },
          );
          expect(
            await ImageDownloader.loadComicImageBytes(
              'context-body',
              'cloud',
              'comic',
              'chapter',
            ),
            [9],
          );
          final events = await ImageDownloader.loadComicImageUnwrapped(
            'context-download',
            'cloud',
            'comic',
            'chapter',
          ).toList();
          expect(events.last.imageBytes, [9]);
          expect(contexts, hasLength(2));
          expect(identical(contexts[0], contexts[1]), isFalse);
        },
      );

      test(
        'native redirected thumbnail keeps cover priority inside a preload caller',
        () async {
          final contexts = <RemoteReadContext>[];
          ImageDownloader.configureSourceImageLoading(
            thumbnailLoadingConfig: (source, image) async {
              final context = RemoteReadContext.current;
              contexts.add(context);
              await Future<void>.value();
              expect(context.priority, RemoteReadPriority.cover);
              if (image == 'cover.priority') return <String, dynamic>{};
              Future<Uint8List> loadBytes(CancelToken _) async {
                await Future<void>.value();
                expect(identical(RemoteReadContext.current, context), isTrue);
                return Uint8List.fromList([8]);
              }

              return {'loadBytes': loadBytes};
            },
            thumbnailCover: (_, _) async => 'priority-cover-entry',
          );
          final events =
              await RemoteReadContext(priority: RemoteReadPriority.preload).run(
                () => ImageDownloader.loadThumbnail(
                  'cover.priority',
                  'cloud',
                  'comic',
                ).toList(),
              );
          expect(events.single.imageBytes, [8]);
          expect(contexts, hasLength(2));
          expect(identical(contexts[0], contexts[1]), isTrue);
        },
      );

      test(
        'foreground joins and promotes an active native preload without another request',
        () async {
          final started = Completer<RemoteReadContext>();
          final gate = Completer<Uint8List>();
          late CancelToken token;
          var calls = 0;
          Future<Uint8List> loadBytes(CancelToken cancelToken) async {
            calls++;
            token = cancelToken;
            final context = RemoteReadContext.current;
            started.complete(context);
            final bytes = await gate.future;
            expect(identical(RemoteReadContext.current, context), isTrue);
            expect(context.priority, RemoteReadPriority.foreground);
            return bytes;
          }

          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig:
                (source, image, comic, chapter, {target}) => {
                  'loadBytes': loadBytes,
                },
          );
          final preload = ImageDownloader.preloadComicImage(
            'priority-shared',
            'cloud',
            'comic',
            'chapter',
          );
          final context = await started.future.timeout(
            const Duration(seconds: 5),
          );
          expect(context.priority, RemoteReadPriority.preload);
          final visible = ImageDownloader.loadComicImageBytes(
            'priority-shared',
            'cloud',
            'comic',
            'chapter',
          );
          expect(context.priority, RemoteReadPriority.foreground);
          final png = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
          );
          gate.complete(png);
          expect(await visible, png);
          await preload;
          expect(token.isCancelled, isFalse);
          expect(
            await ImageDownloader.loadComicImageBytes(
              'priority-shared',
              'cloud',
              'comic',
              'chapter',
            ),
            png,
          );
          expect(calls, 1);
        },
      );

      test(
        'separate native preload streams promote and cancel independently',
        () async {
          final contexts = <String, RemoteReadContext>{};
          final tokens = <String, CancelToken>{};
          final started = Completer<void>();
          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig: (source, image, comic, chapter, {target}) {
              Future<Uint8List> loadBytes(CancelToken token) async {
                contexts[image] = RemoteReadContext.current;
                tokens[image] = token;
                if (contexts.length == 2) started.complete();
                throw await token.whenCancel;
              }

              return {'loadBytes': loadBytes};
            },
          );
          final caller = RemoteReadContext(
            priority: RemoteReadPriority.preload,
          );
          final first = caller.run(
            () => ImageDownloader.loadComicImage(
              'priority-first',
              'cloud',
              'comic',
              'chapter',
            ).listen((_) {}),
          );
          final second = caller.run(
            () => ImageDownloader.loadComicImage(
              'priority-second',
              'cloud',
              'comic',
              'chapter',
            ).listen((_) {}),
          );
          await started.future.timeout(const Duration(seconds: 5));
          ImageDownloader.promoteComicImage(
            'priority-first',
            'cloud',
            'comic',
            'chapter',
          );
          expect(
            contexts['priority-first']!.priority,
            RemoteReadPriority.foreground,
          );
          expect(
            contexts['priority-second']!.priority,
            RemoteReadPriority.preload,
          );
          expect(caller.priority, RemoteReadPriority.preload);
          await first.cancel();
          expect(tokens['priority-first']!.isCancelled, isTrue);
          expect(tokens['priority-second']!.isCancelled, isFalse);
          await second.cancel();
          await pumpEventQueue();
        },
      );

      test(
        'visible reuse of a precached pending completer promotes the existing native load',
        () async {
          final started = Completer<RemoteReadContext>();
          final gate = Completer<Uint8List>();
          var calls = 0;
          Future<Uint8List> loadBytes(CancelToken _) async {
            calls++;
            started.complete(RemoteReadContext.current);
            return gate.future;
          }

          ImageDownloader.configureSourceImageLoading(
            comicImageLoadingConfig:
                (source, image, comic, chapter, {target}) => {
                  'loadBytes': loadBytes,
                },
          );
          const provider = ReaderImageProvider(
            'priority-pending-provider',
            'cloud',
            'comic',
            'chapter',
            1,
          );
          final precached = RemoteReadContext(
            priority: RemoteReadPriority.preload,
          ).run(() => provider.resolve(ImageConfiguration.empty));
          final firstDone = Completer<void>();
          final firstListener = ImageStreamListener((image, _) {
            image.dispose();
            firstDone.complete();
          }, onError: firstDone.completeError);
          precached.addListener(firstListener);
          final context = await started.future.timeout(
            const Duration(seconds: 5),
          );
          final visible = provider.resolve(ImageConfiguration.empty);
          final visibleDone = Completer<void>();
          final visibleListener = ImageStreamListener((image, _) {
            image.dispose();
            visibleDone.complete();
          }, onError: visibleDone.completeError);
          visible.addListener(visibleListener);
          try {
            expect(identical(precached.completer, visible.completer), isTrue);
            expect(context.priority, RemoteReadPriority.preload);
            ImageDownloader.promoteComicImage(
              provider.imageKey,
              provider.sourceKey,
              provider.cid,
              provider.eid,
              target: provider.target,
            );
            expect(context.priority, RemoteReadPriority.foreground);
            gate.complete(
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg==',
              ),
            );
            await Future.wait([
              firstDone.future,
              visibleDone.future,
            ]).timeout(const Duration(seconds: 5));
            expect(calls, 1);
          } finally {
            precached.removeListener(firstListener);
            visible.removeListener(visibleListener);
            await provider.evict();
          }
        },
      );

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
