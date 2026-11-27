import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/bangumi/bangumi.dart';
import 'package:venera_plus/foundation/appdata.dart';

void main() {
  tearDown(() {
    appdata.settings['bangumiServer'] = bangumiOfficialServer.apiUrl;
    appdata.settings['bangumiCustomServers'] = <Map<String, String>>[];
  });

  test('presets keep independent API, image and Token addresses', () {
    expect(bangumiPresetServers.map((server) => server.name), [
      'bgm.tv',
      'bgm.lat',
    ]);
    expect(bangumiPresetServers.first, same(bangumiOfficialServer));
    final bgmLat = bangumiPresetServers[1];
    expect(bgmLat.apiUrl, 'https://api.bgm.lat');
    expect(bgmLat.imageUrl, 'https://lain.bgm.lat');
    expect(bgmLat.tokenUrl, 'https://next.bgm.lat/demo/access-token');
  });

  test('custom addresses preserve proxy paths and default optional fields', () {
    final server = BangumiServer.fromJson({
      'apiUrl': ' API.Example.com/bangumi/ ',
      'imageUrl': 'img.example.com/proxy/',
    })!;
    expect(server.name, 'api.example.com');
    expect(server.apiUrl, 'https://api.example.com/bangumi');
    expect(server.imageUrl, 'https://img.example.com/proxy');
    expect(server.tokenUrl, bangumiOfficialServer.tokenUrl);
    expect(normalizeBangumiUrl('https://user:secret@example.com'), isNull);
    expect(normalizeBangumiUrl('http://example.com'), isNull);
    expect(normalizeBangumiUrl('example.com?token=secret'), isNull);
    expect(normalizeBangumiUrl('example.com#fragment'), isNull);
    expect(
      BangumiServer.fromJson({
        'apiUrl': 'example.com',
        'imageUrl': 'not a host',
      }),
      isNull,
    );
  });

  test(
    'custom servers append in saved order and deduplicate normalized API addresses',
    () {
      appdata.settings['bangumiCustomServers'] = [
        {'apiUrl': 'first.example.com', 'name': 'First'},
        {'apiUrl': 'https://API.BGM.TV/'},
        {'apiUrl': 'second.example.com', 'name': 'Second'},
        {'apiUrl': 'https://FIRST.example.com/'},
        {'apiUrl': 42},
      ];
      expect(bangumiServers.map((server) => server.name), [
        'bgm.tv',
        'bgm.lat',
        'First',
        'Second',
      ]);
      appdata.settings['bangumiServer'] = 'https://second.example.com';
      expect(currentBangumiServer.name, 'Second');
      appdata.settings['bangumiServer'] = 'https://missing.example.com';
      expect(currentBangumiServer, same(bangumiOfficialServer));
    },
  );

  test('legacy bangumi.lat selections resolve without rewriting settings', () {
    for (final selected in [
      'https://api.bangumi.lat',
      'https://API.BANGUMI.LAT/',
    ]) {
      appdata.settings['bangumiServer'] = selected;
      expect(currentBangumiServer, same(bangumiPresetServers[1]));
      expect(appdata.settings['bangumiServer'], selected);
    }
  });

  test('a removed anibt.net selection falls back to the official server', () {
    appdata.settings['bangumiServer'] = 'https://bgmapi.anibt.net';
    expect(currentBangumiServer, same(bangumiOfficialServer));
  });

  test('a custom bangumi.lat server takes priority over migration', () {
    const custom = {
      'name': 'Custom Bangumi mirror',
      'apiUrl': 'https://api.bangumi.lat',
      'imageUrl': 'https://images.example.com',
      'tokenUrl': 'https://accounts.example.com/token',
    };
    appdata.settings['bangumiCustomServers'] = [custom];
    appdata.settings['bangumiServer'] = custom['apiUrl'];
    expect(currentBangumiServer.toJson(), custom);
  });

  test(
    'image override preserves path and query and does not apply its prefix twice',
    () {
      const server = BangumiServer(
        name: 'Custom',
        apiUrl: 'https://api.example.com',
        imageUrl: 'https://img.example.com/proxy',
      );
      const source = 'https://lain.bgm.tv/r/400/pic/cover.jpg?size=2';
      final resolved = server.resolveImageUrl(source);
      expect(
        resolved,
        'https://img.example.com/proxy/r/400/pic/cover.jpg?size=2',
      );
      expect(server.resolveImageUrl(resolved), resolved);
      expect(server.resolveImageUrl('local-cover.jpg'), 'local-cover.jpg');
      const direct = BangumiServer(
        name: 'Direct',
        apiUrl: 'https://api.example.com',
      );
      expect(direct.resolveImageUrl(source), source);
    },
  );

  test('probe requests the configured public API anonymously', () async {
    appdata.settings['bangumiAccessToken'] = 'saved-secret';
    addTearDown(() => appdata.settings['bangumiAccessToken'] = '');
    final adapter = _Adapter(
      (_) async => _response(200, jsonEncode({'id': 2, 'name': '坟场'})),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    const server = BangumiServer(
      name: 'Custom',
      apiUrl: 'https://example.com/proxy',
    );
    final result = await probeBangumiServer(server, CancelToken(), dio: dio);
    expect(result.status, BangumiProbeStatus.available);
    expect(result.elapsed, greaterThanOrEqualTo(Duration.zero));
    final request = adapter.requests.single;
    expect(request.uri.toString(), 'https://example.com/proxy/v0/subjects/2');
    expect(request.method, 'GET');
    expect(request.headers['Accept'], 'application/json');
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      isNot(contains('cookie')),
    );
  });

  for (final (label, status, body, expected) in [
    (
      'Anubis challenge with HTTP 200',
      200,
      '<html>Anubis verification</html>',
      BangumiProbeStatus.verificationRequired,
    ),
    (
      'ordinary HTML with HTTP 200',
      200,
      '<html>Homepage</html>',
      BangumiProbeStatus.invalidResponse,
    ),
    (
      'wrong subject schema',
      200,
      '{"id":3,"name":"Wrong"}',
      BangumiProbeStatus.invalidResponse,
    ),
    (
      'server error',
      503,
      '{"error":"Unavailable"}',
      BangumiProbeStatus.unavailable,
    ),
  ]) {
    test('probe classifies $label', () async {
      final dio = Dio()
        ..httpClientAdapter = _Adapter((_) async => _response(status, body));
      final result = await probeBangumiServer(
        bangumiOfficialServer,
        CancelToken(),
        dio: dio,
      );
      expect(result.status, expected);
      expect(result.statusCode, status);
    });
  }

  test('probe recognizes a Cloudflare challenge', () async {
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        (_) async => _response(
          403,
          '<html>Challenge</html>',
          headers: {
            'cf-mitigated': ['challenge'],
          },
        ),
      );
    final result = await probeBangumiServer(
      bangumiOfficialServer,
      CancelToken(),
      dio: dio,
    );
    expect(result.status, BangumiProbeStatus.verificationRequired);
  });

  test('probe deadline cancels a stalled request', () async {
    final pending = Completer<ResponseBody>();
    final dio = Dio()..httpClientAdapter = _Adapter((_) => pending.future);
    final token = CancelToken();
    final result = await probeBangumiServer(
      bangumiOfficialServer,
      token,
      dio: dio,
      timeout: const Duration(milliseconds: 10),
    );
    expect(result.status, BangumiProbeStatus.timeout);
    expect(token.isCancelled, isTrue);
    pending.complete(_response(200, '{"id":2,"name":"Late"}'));
  });

  test(
    'closing a probe preserves cancellation rather than reporting a failed server',
    () async {
      final token = CancelToken()..cancel('List closed');
      await expectLater(
        probeBangumiServer(bangumiOfficialServer, token, dio: Dio()),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    },
  );
}

ResponseBody _response(
  int status,
  String body, {
  Map<String, List<String>> headers = const {},
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: ['text/plain'],
    ...headers,
  },
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Future<ResponseBody> Function(RequestOptions options) respond;
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
