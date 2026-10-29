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

  test('size and digest failures discard partial APKs', () async {
    final updater = service(_Adapter((_) async => body(bytes)));
    for (final invalid in [
      asset(size: bytes.length + 1),
      asset(digest: '0' * 64),
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
