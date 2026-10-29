import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/app_update/app_update.dart';
import 'package:venera_plus/network/app_dio.dart';

import 'fixtures.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final Future<ResponseBody> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Dio client;
  final bytes = utf8.encode('test installation package');
  const channel = MethodChannel('venera/app_update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  AppReleaseAsset asset({int? size, String? digest}) => AppReleaseAsset(
    name: 'VeneraPlus-3.3.0-android-arm64-v8a.apk',
    url: 'https://example.com/update.apk',
    size: size ?? bytes.length,
    sha256: digest ?? sha256.convert(bytes).toString(),
  );

  AppUpdateService service(_Adapter adapter) {
    client.httpClientAdapter = adapter;
    return AppUpdateService(
      client: client,
      temporaryDirectory: () async => root,
    );
  }

  ResponseBody body(List<int> data) => ResponseBody.fromBytes(
    data,
    200,
    headers: {
      Headers.contentLengthHeader: ['${data.length}'],
    },
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('app-update-test-');
    client = Dio();
  });
  tearDown(() {
    client.close(force: true);
    messenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  test(
    'checks the proper release endpoint and propagates request failures',
    () async {
      final adapter = _Adapter(
        (_) async => ResponseBody.fromString(
          jsonEncode(releaseJson('v3.3.0')),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      final updater = service(adapter);
      expect((await updater.check('3.2.0'))!.version, '3.3.0');
      expect(adapter.requests.last.uri.path, endsWith('/releases/latest'));
      expect(await updater.check('3.3.0'), isNull);
      expect((await updater.check('3.2.0-beta1'))!.version, '3.3.0');
      expect(adapter.requests.last.uri.query, 'per_page=20');
      client.httpClientAdapter = _Adapter(
        (_) async => ResponseBody.fromString('Unavailable', 503),
      );
      await expectLater(updater.check('3.2.0'), throwsA(isA<DioException>()));
    },
  );

  test(
    'validates streamed APKs, reuses completed downloads and replaces corrupt cache',
    () async {
      final adapter = _Adapter((_) async => body(bytes));
      final updater = service(adapter);
      final progress = <(int, int)>[];
      Future<File> download() => updater.downloadApk(
        asset(),
        cancelToken: CancelToken(),
        onProgress: (received, total) => progress.add((received, total)),
      );
      final files = await Future.wait([download(), download()]);
      final file = files.first;
      expect(files.last.path, file.path);
      expect(await file.readAsBytes(), bytes);
      expect(file.parent.path, endsWith('app_updates'));
      expect(File('${file.path}.part').existsSync(), isFalse);
      expect(progress.last, (bytes.length, bytes.length));
      expect((await download()).path, file.path);
      expect(adapter.requests, hasLength(1));
      await file.writeAsBytes(List.filled(bytes.length, 0));
      await download();
      expect(await file.readAsBytes(), bytes);
      expect(adapter.requests, hasLength(2));
    },
  );

  for (final status in [403, 429]) {
    test(
      'API $status rate limits use public releases and retain verified APK downloads',
      () async {
        final adapter = _Adapter((request) async {
          if (request.uri.host == 'api.github.com') {
            return ResponseBody.fromString(
              '{"message":"API rate limit exceeded"}',
              status,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
                'x-ratelimit-remaining': ['0'],
                'x-ratelimit-reset': [
                  '${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}',
                ],
              },
            );
          }
          if (request.uri.path.endsWith('/releases')) {
            expect(request.headers['Accept'], 'text/html');
            return ResponseBody.fromString(
              releasePageHtml('v3.3.0') +
                  releasePageHtml('v3.4.0-beta1', prerelease: true),
              200,
            );
          }
          if (request.uri.path.contains('/expanded_assets/')) {
            expect(request.uri.path, endsWith('/v3.4.0-beta1'));
            return ResponseBody.fromString(
              releaseAssetsHtml(
                'v3.4.0-beta1',
                sha256.convert(bytes).toString(),
              ),
              200,
            );
          }
          expect(
            request.uri.path,
            contains('/releases/download/v3.4.0-beta1/'),
          );
          return body(bytes);
        });
        final updater = service(adapter);
        final release = (await updater.check('3.2.0-beta1'))!;
        expect(release.tag, 'v3.4.0-beta1');
        expect(release.notes, contains('## Important changes'));
        expect(release.notes, contains('**Read before updating**'));
        expect(
          release.notes,
          contains(
            '[Details](https://github.com/Venera-Works/Venera-Plus/issues/1)',
          ),
        );
        expect(
          release.notes,
          contains('```\nfirst line\n  second line <code>\n```'),
        );
        final apk = release.androidAssetFor(['arm64-v8a'])!;
        expect(apk.size, isNull);
        expect(release.assets, hasLength(1));
        expect(apk.sha256, sha256.convert(bytes).toString());
        final progress = <int>[];
        final file = await updater.downloadApk(
          apk,
          cancelToken: CancelToken(),
          onProgress: (_, total) => progress.add(total),
        );
        expect(await file.readAsBytes(), bytes);
        expect(progress.last, bytes.length);
        expect(await updater.check('3.4.0-beta1'), isNull);
        expect(
          adapter.requests.where(
            (request) => request.uri.host == 'api.github.com',
          ),
          hasLength(1),
        );
        expect(
          adapter.requests.where(
            (request) => request.uri.path.contains('/expanded_assets/'),
          ),
          hasLength(1),
        );
      },
    );
  }

  test(
    'stable users use the public latest release when the API is limited',
    () async {
      final adapter = _Adapter((request) async {
        if (request.uri.host == 'api.github.com') {
          return ResponseBody.fromString('API rate limit exceeded', 403);
        }
        if (request.uri.path.endsWith('/latest')) {
          return ResponseBody.fromString(
            releasePageHtml('v3.3.0', section: false),
            200,
          );
        }
        expect(request.uri.path, endsWith('/expanded_assets/v3.3.0'));
        return ResponseBody.fromString(
          releaseAssetsHtml('v3.3.0', sha256.convert(bytes).toString()),
          200,
        );
      });
      final release = (await service(adapter).check('3.2.0'))!;
      expect(release.version, '3.3.0');
      expect(release.pageUrl, endsWith('/releases/tag/v3.3.0'));
      expect(adapter.requests[1].uri.path, endsWith('/releases/latest'));
    },
  );

  test(
    'unrelated forbidden responses propagate without claiming a rate limit',
    () async {
      final adapter = _Adapter(
        (_) async => ResponseBody.fromString('Access denied', 403),
      );
      await expectLater(
        service(adapter).check('3.2.0'),
        throwsA(isA<DioException>()),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'an invalid fallback page fails rather than reporting no update',
    () async {
      final adapter = _Adapter(
        (request) async => request.uri.host == 'api.github.com'
            ? ResponseBody.fromString('API rate limit exceeded', 403)
            : ResponseBody.fromString(
                '<html><body>Access denied</body></html>',
                200,
              ),
      );
      await expectLater(service(adapter).check('3.2.0'), throwsFormatException);
    },
  );

  test('size and digest failures discard partial APKs', () async {
    final updater = service(_Adapter((_) async => body(bytes)));
    for (final invalid in [
      asset(size: bytes.length + 1),
      asset(digest: '0' * 64),
      AppReleaseAsset(
        name: asset().name,
        url: asset().url,
        size: null,
        sha256: '0' * 64,
      ),
    ]) {
      await expectLater(
        updater.downloadApk(
          invalid,
          cancelToken: CancelToken(),
          onProgress: (_, _) {},
        ),
        throwsFormatException,
      );
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    }
  });

  test(
    'canceling an active download leaves no installable or partial APK',
    () async {
      final requested = Completer<void>();
      final stream = StreamController<Uint8List>();
      final adapter = _Adapter((_) async {
        requested.complete();
        return ResponseBody(
          stream.stream,
          200,
          headers: {
            Headers.contentLengthHeader: ['${bytes.length}'],
          },
        );
      });
      final updater = service(adapter);
      final cancel = CancelToken();
      final download = updater.downloadApk(
        asset(),
        cancelToken: cancel,
        onProgress: (_, _) {},
      );
      final expectation = expectLater(
        download,
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      await requested.future;
      await pumpEventQueue();
      cancel.cancel('User canceled');
      await expectation;
      await stream.close();
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  test('uses native ABI, permission and installation methods', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'supportedAbis' => ['arm64-v8a', 'armeabi-v7a'],
        'requestInstallPermission' => false,
        _ => null,
      };
    });
    final updater = service(_Adapter((_) async => body(bytes)));
    expect(await updater.supportedAbis(), ['arm64-v8a', 'armeabi-v7a']);
    expect(await updater.requestInstallPermission(), isFalse);
    final file = File('${root.path}/update.apk');
    await updater.installApk(file);
    expect(calls.map((call) => call.method), [
      'supportedAbis',
      'requestInstallPermission',
      'install',
    ]);
    expect(calls.last.arguments, file.path);
  });
}
