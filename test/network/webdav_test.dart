import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/app.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/webdav.dart';

void main() {
  group('WebDAV paths and credentials', () {
    test('WebDavEndpoint normalizes credentials and builds auth headers', () {
      final endpoint = WebDavEndpoint(
        url: ' https://example.com/dav/ ',
        user: ' user ',
        password: ' pass ',
      );

      expect(endpoint.url, 'https://example.com/dav');
      expect(endpoint.user, 'user');
      expect(endpoint.password, ' pass ');
      expect(endpoint.authHeaders, {'authorization': 'Basic dXNlcjogcGFzcyA='});
    });

    test('WebDavEndpoint removes default ports, query, and fragment', () {
      final endpoint = WebDavEndpoint(
        url: 'HTTPS://Example.COM:443/dav/?token=secret#section',
        user: '',
        password: '',
      );

      expect(endpoint.url, 'https://example.com/dav');
    });

    test('WebDavEndpoint encodes each remote path segment', () {
      final endpoint = WebDavEndpoint(
        url: 'https://example.com/dav/',
        user: '',
        password: '',
      );

      expect(
        endpoint.fileUrl('/漫画/第 01 卷/001.jpg'),
        'https://example.com/dav/%E6%BC%AB%E7%94%BB/%E7%AC%AC%2001%20%E5%8D%B7/001.jpg',
      );
      expect(endpoint.authHeaders, isEmpty);
    });

    test('normalizes and joins WebDAV directory paths', () {
      expect(
        normalizeWebDavDirectoryPath('', fallback: '/fallback/'),
        '/fallback/',
      );
      expect(
        normalizeWebDavDirectoryPath(r'manga\books', fallback: '/fallback/'),
        '/manga/books/',
      );
      expect(joinWebDavFilePath('/manga/', r'Book\1.jpg'), '/manga/Book/1.jpg');
      expect(
        joinWebDavDirectoryPath('/manga', 'Book/Chapter 1'),
        '/manga/Book/Chapter 1/',
      );
    });

    test('rejects empty and traversing relative paths', () {
      expect(() => normalizeWebDavRelativePath(''), throwsFormatException);
      expect(
        () => normalizeWebDavRelativePath('../secret'),
        throwsFormatException,
      );
      expect(
        () => normalizeWebDavRelativePath('book/./page'),
        throwsFormatException,
      );
    });
  });

  group('WebDAV HTTP', () {
    for (final trailingSlash in ['', '/']) {
      test(
        'WebDAV preserves mixed-case paths over HTTP ($trailingSlash)',
        () async {
          final server = await _CaseSensitiveWebDav.start();
          addTearDown(server.close);
          final client = WebDavEndpoint(
            url: '${server.url}/VeneraPlus$trailingSlash',
            user: '',
            password: '',
          ).createClient();
          // Exercise the real WebDAV request builder without requiring a native
          // rhttp library in CI. The server uses case-sensitive keys on every OS.
          client.c.httpClientAdapter = IOHttpClientAdapter();
          addTearDown(() => client.c.close(force: true));

          expect(await client.readDir('/'), isEmpty);
          const name = 'Snapshot.venera';
          final bytes = Uint8List.fromList(utf8.encode('test snapshot'));
          await client.write(name, bytes);
          expect(await client.read(name), bytes);
          await client.remove(name);

          expect(server.requests, [
            'PROPFIND /dav/VeneraPlus/',
            'OPTIONS /dav/VeneraPlus/Snapshot.venera',
            'PUT /dav/VeneraPlus/Snapshot.venera',
            'OPTIONS /dav/VeneraPlus/Snapshot.venera',
            'GET /dav/VeneraPlus/Snapshot.venera',
            'DELETE /dav/VeneraPlus/Snapshot.venera',
          ]);
          expect(server.files, isEmpty);
        },
      );
    }

    test(
      'a directory case mismatch stays an error without creating folders',
      () async {
        final server = await _CaseSensitiveWebDav.start();
        addTearDown(server.close);
        final client = WebDavEndpoint(
          url: '${server.url}/veneraplus',
          user: '',
          password: '',
        ).createClient();
        client.c.httpClientAdapter = IOHttpClientAdapter();
        addTearDown(() => client.c.close(force: true));

        await expectLater(
          client.readDir('/'),
          throwsA(
            isA<DioException>().having(
              (error) => error.response?.statusCode,
              'HTTP status',
              HttpStatus.notFound,
            ),
          ),
        );
        expect(server.requests, ['PROPFIND /dav/veneraplus/']);
      },
    );
  });

  group('WebDAV diagnostics', () {
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
  });
}

class _CaseSensitiveWebDav {
  _CaseSensitiveWebDav(this.server);

  final HttpServer server;
  final requests = <String>[];
  final files = <String, List<int>>{};

  String get url => 'http://127.0.0.1:${server.port}/dav';

  static Future<_CaseSensitiveWebDav> start() async {
    final fixture = _CaseSensitiveWebDav(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    return fixture;
  }

  Future<void> close() async => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    final body = await request.fold<List<int>>(
      [],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    // Existing directories can be listed and their files modified. Creating
    // any directory is denied, including attempts to recreate an existing one.
    if (request.method == 'MKCOL') {
      request.response.statusCode = HttpStatus.forbidden;
    } else if (!path.startsWith('/dav/VeneraPlus/')) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      switch (request.method) {
        case 'OPTIONS':
          request.response.statusCode = HttpStatus.ok;
        case 'PROPFIND':
          request.response.statusCode = HttpStatus.multiStatus;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.write('''<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:"><D:response>
  <D:href>/dav/VeneraPlus/</D:href>
  <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response></D:multistatus>''');
        case 'PUT':
          files[path] = body;
          request.response.statusCode = HttpStatus.created;
        case 'GET':
          final bytes = files[path];
          if (bytes == null) {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            request.response.add(bytes);
          }
        case 'DELETE':
          files.remove(path);
          request.response.statusCode = HttpStatus.noContent;
        default:
          request.response.statusCode = HttpStatus.methodNotAllowed;
      }
    }
    await request.response.close();
  }
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
