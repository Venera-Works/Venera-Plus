import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_plus/network/app_dio.dart';
import 'package:venera_plus/network/image_http3_fallback.dart';

const _url = 'https://example.invalid/page.png';
final _reset = rhttp.RhttpConnectionException(
  rhttp.HttpRequest(url: _url),
  'tls handshake eof',
);

class _Token extends rhttp.CancelToken {
  int cancellations = 0;
  Completer<void>? gate;
  @override
  Future<void> cancel() async {
    cancellations++;
    await gate?.future;
  }
}

class _Adapter extends RHttpAdapter {
  _Adapter(this.respond, {this.proxy = const rhttp.ProxySettings.noProxy()});
  final Future<rhttp.HttpResponse> Function(rhttp.ClientSettings) respond;
  final rhttp.ProxySettings proxy;
  final tokens = <_Token>[];
  final protocols = <rhttp.HttpVersionPref>[];
  Completer<void>? cleanup;
  @override
  Future<rhttp.ClientSettings> get settings async =>
      rhttp.ClientSettings(proxySettings: proxy, throwOnStatusCode: false);
  @override
  rhttp.CancelToken createCancelToken() {
    final token = _Token()..gate = tokens.isEmpty ? cleanup : null;
    tokens.add(token);
    return token;
  }

  @override
  Future<rhttp.HttpResponse> performRequest(
    RequestOptions options,
    Stream<Uint8List>? body,
    rhttp.CancelToken token,
    rhttp.ClientSettings configured,
  ) {
    protocols.add(configured.httpVersionPref);
    return respond(configured);
  }
}

rhttp.HttpStreamResponse _response({
  Stream<Uint8List>? body,
  int status = 200,
}) => rhttp.HttpStreamResponse(
  remoteIp: null,
  request: rhttp.HttpRequest(url: _url),
  version: rhttp.HttpVersion.http3,
  statusCode: status,
  headers: const [],
  body: body ?? Stream.value(Uint8List.fromList([1, 2])),
);
RequestOptions _options({
  String method = 'GET',
  Object? data,
  Duration? timeout,
}) => RequestOptions(
  path: _url,
  method: method,
  data: data,
  receiveTimeout: timeout,
  extra: {'allowImageHttp3Fallback': true},
);

void main() {
  test(
    'TLS reset falls back once after the original request is released',
    () async {
      final gate = Completer<void>();
      final adapter = _Adapter((settings) async {
        if (settings.httpVersionPref != rhttp.HttpVersionPref.http3) {
          throw _reset;
        }
        return _response();
      })..cleanup = gate;
      final result = adapter.fetch(_options(), null, null);
      await pumpEventQueue();
      expect(adapter.protocols, [rhttp.HttpVersionPref.all]);
      expect(adapter.tokens.single.cancellations, 1);
      gate.complete();
      final response = await result;
      expect(adapter.protocols, [
        rhttp.HttpVersionPref.all,
        rhttp.HttpVersionPref.http3,
      ]);
      expect((await response.stream.toList()).single, [1, 2]);
    },
  );

  for (final scenario in ['proxy', 'post', 'body', 'certificate', 'dns']) {
    test('$scenario is not retried over HTTP/3', () async {
      final failure = scenario == 'certificate' || scenario == 'dns'
          ? rhttp.RhttpConnectionException(
              rhttp.HttpRequest(url: _url),
              '$scenario error',
            )
          : _reset;
      final adapter = _Adapter(
        (_) async => throw failure,
        proxy: scenario == 'proxy'
            ? const rhttp.ProxySettings.proxy('http://localhost:1234')
            : const rhttp.ProxySettings.noProxy(),
      );
      await expectLater(
        adapter.fetch(
          _options(
            method: scenario == 'post' ? 'POST' : 'GET',
            data: scenario == 'body' ? 'body' : null,
          ),
          null,
          null,
        ),
        throwsA(same(failure)),
      );
      expect(adapter.protocols, hasLength(1));
    });
  }

  test('HTTP errors and body failures do not start another request', () async {
    final adapter = _Adapter(
      (_) async => _response(status: 403, body: Stream.error(_reset)),
    );
    final response = await adapter.fetch(_options(), null, null);
    expect(response.statusCode, 403);
    await expectLater(response.stream.toList(), throwsA(same(_reset)));
    expect(adapter.protocols, hasLength(1));
  });

  test(
    'cancellation during cleanup prevents the fallback from starting',
    () async {
      final gate = Completer<void>(), cancel = Completer<void>();
      final adapter = _Adapter((_) async => throw _reset)..cleanup = gate;
      final result = adapter.fetch(_options(), null, cancel.future);
      final failed = expectLater(result, throwsA(same(_reset)));
      await pumpEventQueue();
      cancel.complete();
      await pumpEventQueue();
      gate.complete();
      await failed;
      expect(adapter.protocols, hasLength(1));
    },
  );

  test(
    'fallback respects the shorter header timeout and closes a late body',
    () async {
      final lateResponse = Completer<rhttp.HttpResponse>();
      final adapter = _Adapter((settings) async {
        if (settings.httpVersionPref == rhttp.HttpVersionPref.all) throw _reset;
        return lateResponse.future;
      });
      await expectLater(
        adapter.fetch(
          _options(timeout: const Duration(milliseconds: 10)),
          null,
          null,
        ),
        throwsA(isA<ImageHttp3FallbackFailure>()),
      );
      final closed = Completer<void>();
      final body = StreamController<Uint8List>(onCancel: closed.complete);
      lateResponse.complete(_response(body: body.stream));
      await closed.future.timeout(const Duration(seconds: 1));
      await body.close();
      expect(adapter.tokens.last.cancellations, 1);
    },
  );
}
