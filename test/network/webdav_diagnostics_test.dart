import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/app_dio.dart';
import 'package:venera_plus/network/webdav.dart';

void main() {
  late bool wasInitialized;
  late bool wasMuted;

  setUp(() {
    wasInitialized = App.isInitialized;
    wasMuted = Log.isMuted;
    App.isInitialized = false;
    Log.isMuted = false;
    Log.clear();
  });

  tearDown(() {
    Log.clear();
    Log.isMuted = wasMuted;
    App.isInitialized = wasInitialized;
  });

  test(
    'preserves HTTP failure status without logging endpoint paths',
    () async {
      final client = WebDavEndpoint(
        url: 'https://example.com/dav/VeneraPlus',
        user: 'account-secret',
        password: 'password-secret',
      ).createClient(logRequests: true);
      client.c.httpClientAdapter = _DiagnosticAdapter(
        response: ResponseBody.fromString('body-secret', 404),
      );
      addTearDown(() => client.c.close(force: true));

      await expectLater(
        client.readDir('/'),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status',
            404,
          ),
        ),
      );

      final log = Log.logs.map((entry) => entry.content).join('\n');
      expect(log, isNot(contains('/dav')));
      expect(log, isNot(contains('VeneraPlus')));
      expect(log, isNot(contains('secret')));
    },
  );

  test('redacts endpoint and redirect paths and secrets', () async {
    final client = WebDavEndpoint(
      url: 'https://example.com/dav/VeneraPlus',
      user: '',
      password: '',
    ).createClient(logRequests: true);
    final adapter = _DiagnosticAdapter(
      response: ResponseBody.fromString(
        'response-secret',
        302,
        headers: {
          'location': [
            'https://redirect-user:redirect-pass@example.org/Remote/VeneraPlus'
                '?token=redirect-query#redirect-fragment',
          ],
          'set-cookie': ['cookie-secret'],
        },
      ),
    );
    client.c.httpClientAdapter = adapter;
    addTearDown(() => client.c.close(force: true));
    const url =
        'https://url-user:url-pass@example.com/dav/VeneraPlus/%E4%B9%A6'
        '?token=query-secret#fragment-secret';
    await client.c.request<String>(
      url,
      data: 'body-secret',
      options: Options(
        method: 'PUT',
        headers: {'Authorization': 'auth-secret'},
      ),
    );

    final log = Log.logs.map((entry) => entry.content).join('\n');
    expect(log, isNot(contains('/dav')));
    expect(log, isNot(contains('/Remote')));
    expect(log, isNot(contains('VeneraPlus')));
    expect(log, isNot(contains('%E4%B9%A6')));
    expect(log, isNot(contains('书')));
    for (final secret in [
      'url-user',
      'url-pass',
      'query-secret',
      'fragment-secret',
      'body-secret',
      'auth-secret',
      'response-secret',
      'cookie-secret',
      'redirect-user',
      'redirect-pass',
      'redirect-query',
      'redirect-fragment',
    ]) {
      expect(log, isNot(contains(secret)), reason: secret);
    }
  });

  test(
    'preserves transport failure behavior without logging endpoint paths',
    () async {
      final client = WebDavEndpoint(
        url: 'https://example.com/dav/VeneraPlus',
        user: '',
        password: '',
      ).createClient(logRequests: true);
      client.c.httpClientAdapter = _DiagnosticAdapter(fail: true);
      addTearDown(() => client.c.close(force: true));

      await expectLater(client.readDir('/'), throwsA(isA<DioException>()));

      final log = Log.logs.map((entry) => entry.content).join('\n');
      expect(log, isNot(contains('/dav')));
      expect(log, isNot(contains('VeneraPlus')));
      expect(log, isNot(contains('exception-secret')));
    },
  );

  test('request diagnostics are opt-in for other WebDAV consumers', () async {
    final client = WebDavEndpoint(
      url: 'https://example.com/dav/VeneraPlus',
      user: '',
      password: '',
    ).createClient();
    client.c.httpClientAdapter = _DiagnosticAdapter(
      response: ResponseBody.fromString('', 200),
    );
    addTearDown(() => client.c.close(force: true));

    await client.ping();

    expect(Log.logs, isEmpty);
  });
}

class _DiagnosticAdapter implements HttpClientAdapter {
  _DiagnosticAdapter({this.response, this.fail = false});

  final ResponseBody? response;
  final bool fail;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    if (fail) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'exception-secret',
      );
    }
    return response!;
  }

  @override
  void close({bool force = false}) {}
}
