import 'dart:async';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/network/remote_storage/remote_storage.dart';

void main() {
  test('429 pauses other archives on the account before retrying', () async {
    var now = DateTime.utc(2026, 10, 23);
    final scheduler = RemoteReadScheduler(
      maxConcurrent: 1,
      minInterval: Duration.zero,
      now: () => now,
    );
    final first = _RangeAdapter(
      (_, index) => index == 0
          ? ResponseBody.fromBytes(
              [],
              429,
              headers: {
                'retry-after': ['2'],
              },
            )
          : _partial(),
    );
    final other = _RangeAdapter((_, _) => _partial());
    final reading = RemoteRangeReader(
      size: 10,
      link: _link,
      dio: _dio(first),
      scheduler: scheduler,
    ).read(2, 3);
    await pumpEventQueue();
    expect(first.requests, hasLength(1));
    final cancel = CancelToken();
    final waiting = RemoteRangeReader(
      size: 10,
      link: _link,
      dio: _dio(other),
      scheduler: scheduler,
    ).read(2, 3, cancelToken: cancel);
    final cancelled = expectLater(waiting, throwsA(isA<DioException>()));
    await pumpEventQueue();
    expect(other.requests, isEmpty);
    cancel.cancel();
    await cancelled;
    expect(first.requests, hasLength(1));
    now = now.add(const Duration(seconds: 2));
    scheduler.defer(retryAfter: '0');
    expect(await reading, [2, 3, 4]);
    expect(first.requests, hasLength(2));
    expect(other.requests, isEmpty);
  });

  test('repeated 429 responses stop after two retries', () async {
    var links = 0;
    final adapter = _RangeAdapter(
      (_, _) => ResponseBody.fromBytes(
        [],
        429,
        headers: {
          'retry-after': ['0'],
        },
      ),
    );
    final reader = RemoteRangeReader(
      size: 10,
      dio: _dio(adapter),
      scheduler: RemoteReadScheduler(minInterval: Duration.zero),
      link: () {
        links++;
        return _link();
      },
    );
    await expectLater(reader.read(2, 3), throwsA(_storageError('429')));
    expect(adapter.requests, hasLength(3));
    expect(links, 1);
  });

  test(
    'invalidated reader does not serve ranges cached before a file change',
    () async {
      final cache = RemoteRangeCache();
      final adapter = _RangeAdapter(
        (options, index) => _partial(
          range: index == 0 ? 'bytes 2-4/10' : 'bytes 5-7/10',
          headers: {
            'etag': ['"version-$index"'],
          },
        ),
      );
      final reader = RemoteRangeReader(
        size: 10,
        link: _link,
        dio: _dio(adapter),
        cache: cache,
        cacheKey: 'version-1',
        scheduler: RemoteReadScheduler(minInterval: Duration.zero),
      );
      expect(await reader.read(2, 3), [2, 3, 4]);
      await expectLater(
        reader.read(5, 3),
        throwsA(_storageError('remote_file_changed')),
      );
      await expectLater(
        reader.read(2, 3),
        throwsA(_storageError('remote_file_changed')),
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'reads an exact bounded range and preserves direct-link headers',
    () async {
      final adapter = _RangeAdapter(
        (options, _) => _partial(
          headers: {
            'etag': ['"version-1"'],
            'last-modified': ['Tue, 20 Oct 2026 00:00:00 GMT'],
          },
          stream: Stream.fromIterable([
            Uint8List.fromList([2]),
            Uint8List.fromList([3, 4]),
          ]),
        ),
      );
      var links = 0;
      final reader = RemoteRangeReader(
        size: 10,
        dio: _dio(adapter),
        link: () async {
          links++;
          return const RemoteLink(
            url: 'https://files.example/archive.cbz?signature=first',
            headers: {
              'Authorization': 'Bearer credential',
              'Cookie': 'session=value',
              'Referer': 'https://files.example/',
              'User-Agent': 'storage-client',
              'range': 'bytes=0-',
              'accept-encoding': 'gzip',
              'If-Match': '"directory-version"',
              'If-Unmodified-Since': 'Thu, 01 Jan 1970 00:00:01 GMT',
            },
          );
        },
      );

      expect(reader.size, 10);
      expect(await reader.read(2, 3), [2, 3, 4]);
      expect(await reader.read(2, 3), [2, 3, 4]);
      expect(links, 1);
      final headers = adapter.requests.first.headers;
      expect(_requestHeader(headers, 'Range'), 'bytes=2-4');
      expect(_requestHeader(headers, 'Accept-Encoding'), 'identity');
      expect(_requestHeader(headers, 'If-Match'), isNull);
      expect(_requestHeader(headers, 'If-Unmodified-Since'), isNull);
      expect(
        _requestHeader(adapter.requests[1].headers, 'If-Match'),
        '"version-1"',
      );
      expect(_requestHeader(headers, 'Authorization'), 'Bearer credential');
      expect(_requestHeader(headers, 'Cookie'), 'session=value');
      expect(_requestHeader(headers, 'Referer'), 'https://files.example/');
      expect(_requestHeader(headers, 'User-Agent'), 'storage-client');
      expect(
        headers.keys.where((name) => name.toLowerCase() == 'range'),
        hasLength(1),
      );
    },
  );

  test(
    'does not abort a completed range when the caller later cancels',
    () async {
      final adapter = _RangeAdapter((_, _) => _partial());
      final caller = CancelToken();
      expect(await _reader(adapter).read(2, 3, cancelToken: caller), [2, 3, 4]);
      final requestToken = adapter.requests.single.cancelToken!;
      expect(requestToken.isCancelled, isFalse);
      caller.cancel('Reader closed after the page completed');
      await Future<void>.value();
      expect(requestToken.isCancelled, isFalse);
    },
  );

  test('rejects invalid bounds without resolving a link', () async {
    var links = 0;
    final reader = RemoteRangeReader(
      size: 10,
      link: () async {
        links++;
        return const RemoteLink(url: 'https://files.example/archive.zip');
      },
    );
    for (final range in [
      [-1, 1],
      [11, 0],
      [0, -1],
      [9, 2],
    ]) {
      await expectLater(reader.read(range[0], range[1]), throwsRangeError);
    }
    expect(await reader.read(10, 0), isEmpty);
    expect(links, 0);
    expect(
      () => RemoteRangeReader(
        size: -1,
        link: () async => const RemoteLink(url: ''),
      ),
      throwsRangeError,
    );
  });

  for (final range in <String?>[
    null,
    'bytes 1-3/10',
    'bytes 2-5/10',
    'bytes 2-4/*',
    'items 2-4/10',
    'bytes 2-4/10, 6-8/10',
  ]) {
    test('rejects an invalid Content-Range: $range', () async {
      final adapter = _RangeAdapter((_, _) => _partial(range: range));
      await expectLater(
        _reader(adapter).read(2, 3),
        throwsA(_storageError('invalid_range_response')),
      );
    });
  }

  test('rejects a changed total file size', () async {
    final adapter = _RangeAdapter((_, _) => _partial(range: 'bytes 2-4/11'));
    await expectLater(
      _reader(adapter).read(2, 3),
      throwsA(_storageError('remote_file_changed')),
    );
  });

  for (final invalidHeader in [
    {
      'content-length': ['2'],
    },
    {
      'content-length': ['not-a-number'],
    },
    {
      'content-encoding': ['gzip'],
    },
    {
      'content-range': ['bytes 2-4/10', 'bytes 2-4/10'],
    },
  ]) {
    test('rejects inconsistent response headers: $invalidHeader', () async {
      final adapter = _RangeAdapter((_, _) => _partial(headers: invalidHeader));
      await expectLater(
        _reader(adapter).read(2, 3),
        throwsA(_storageError('invalid_range_response')),
      );
    });
  }

  test('rejects a body shorter than the requested range', () async {
    final adapter = _RangeAdapter((_, _) => _partial(bytes: [2, 3]));
    await expectLater(
      _reader(adapter).read(2, 3),
      throwsA(_storageError('invalid_range_response')),
    );
  });

  test(
    'aborts an oversized body without waiting for its remaining data',
    () async {
      final aborted = Completer<void>();
      final sourceCancelled = Completer<void>();
      late final StreamController<Uint8List> body;
      body = StreamController<Uint8List>(
        onListen: () => body.add(Uint8List.fromList([2, 3, 4, 5])),
        onCancel: () => sourceCancelled.complete(),
      );
      final adapter = _RangeAdapter((options, _) {
        options.cancelToken!.whenCancel.then((_) => aborted.complete());
        return _partial(stream: body.stream);
      });
      await expectLater(
        _reader(adapter).read(2, 3),
        throwsA(_storageError('invalid_range_response')),
      );
      await aborted.future;
      await sourceCancelled.future;
      unawaited(body.close());
    },
  );

  test(
    'rejects HTTP 200 before subscribing to the full response body',
    () async {
      var bodyStarted = false;
      var closed = false;
      final aborted = Completer<void>();
      Stream<Uint8List> fullBody() async* {
        bodyStarted = true;
        yield Uint8List(1024 * 1024);
        throw StateError('A full archive must never be consumed');
      }

      final adapter = _RangeAdapter((options, _) {
        options.cancelToken!.whenCancel.then((_) => aborted.complete());
        return ResponseBody(fullBody(), 200, onClose: () => closed = true);
      });
      await expectLater(
        _reader(adapter).read(2, 3),
        throwsA(_storageError('range_not_supported')),
      );
      await aborted.future;
      expect(bodyStarted, isFalse);
      expect(closed, isTrue);
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'accepts a bounded response without version or Content-Length headers',
    () async {
      final adapter = _RangeAdapter((_, _) => _partial());
      final reader = _reader(adapter);
      expect(await reader.read(2, 3), [2, 3, 4]);
    },
  );

  test(
    'pins a strong response ETag and detects a same-size replacement',
    () async {
      final adapter = _RangeAdapter(
        (_, index) => _partial(
          headers: {
            'etag': ['"version-$index"'],
          },
        ),
      );
      final reader = _reader(adapter);
      expect(await reader.read(2, 3), [2, 3, 4]);
      await expectLater(
        reader.read(2, 3),
        throwsA(_storageError('remote_file_changed')),
      );
      expect(
        _requestHeader(adapter.requests[1].headers, 'If-Match'),
        '"version-0"',
      );
    },
  );

  test(
    'uses the HTTP Last-Modified validator for weak response ETags',
    () async {
      final modified = DateTime.utc(2026, 10, 20);
      final adapter = _RangeAdapter(
        (_, _) => _partial(
          headers: {
            'etag': ['W/"weak-tag"'],
            'last-modified': [HttpDate.format(modified)],
          },
        ),
      );
      final reader = _reader(adapter);
      expect(await reader.read(2, 3), [2, 3, 4]);
      expect(
        _requestHeader(adapter.requests.first.headers, 'If-Unmodified-Since'),
        isNull,
      );
      expect(await reader.read(2, 3), [2, 3, 4]);
      final headers = adapter.requests[1].headers;
      expect(_requestHeader(headers, 'If-Match'), isNull);
      expect(
        _requestHeader(headers, 'If-Unmodified-Since'),
        HttpDate.format(modified),
      );
    },
  );

  test(
    'detects a changed modification time despite an unchanged weak ETag',
    () async {
      final modified = DateTime.utc(2026, 10, 20);
      final adapter = _RangeAdapter(
        (_, index) => _partial(
          headers: {
            'etag': ['W/"weak-tag"'],
            'last-modified': [
              HttpDate.format(modified.add(Duration(seconds: index))),
            ],
          },
        ),
      );
      final reader = _reader(adapter);
      expect(await reader.read(2, 3), [2, 3, 4]);
      await expectLater(
        reader.read(2, 3),
        throwsA(_storageError('remote_file_changed')),
      );
    },
  );

  test('pins a Last-Modified response when no strong ETag exists', () async {
    final modified = DateTime.utc(2026, 10, 20);
    final adapter = _RangeAdapter(
      (_, index) => _partial(
        headers: {
          'last-modified': [
            HttpDate.format(modified.add(Duration(seconds: index))),
          ],
        },
      ),
    );
    final reader = _reader(adapter);
    expect(await reader.read(2, 3), [2, 3, 4]);
    await expectLater(
      reader.read(2, 3),
      throwsA(_storageError('remote_file_changed')),
    );
  });

  for (final expiredStatus in [401, 403]) {
    test(
      'refreshes a $expiredStatus signed link once and retains new headers',
      () async {
        var links = 0;
        var rejectedBodyStarted = false;
        Stream<Uint8List> rejectedBody() async* {
          rejectedBodyStarted = true;
          yield Uint8List(1024 * 1024);
        }

        final adapter = _RangeAdapter(
          (_, index) => index == 0
              ? ResponseBody(rejectedBody(), expiredStatus)
              : _partial(),
        );
        final reader = RemoteRangeReader(
          size: 10,
          link: () async {
            links++;
            return RemoteLink(
              url: 'https://files.example/archive.zip?signature=$links',
              headers: {
                'Authorization': 'credential-$links',
                'Referer': 'cloud',
              },
            );
          },
          dio: _dio(adapter),
        );
        expect(await reader.read(2, 3), [2, 3, 4]);
        expect(await reader.read(2, 3), [2, 3, 4]);
        expect(links, 2);
        expect(adapter.requests[1].uri.query, 'signature=2');
        expect(
          _requestHeader(adapter.requests[1].headers, 'Authorization'),
          'credential-2',
        );
        expect(_requestHeader(adapter.requests[1].headers, 'Referer'), 'cloud');
        expect(
          _requestHeader(adapter.requests[1].headers, 'Range'),
          'bytes=2-4',
        );
        expect(rejectedBodyStarted, isFalse);
      },
    );

    test(
      'does not refresh a repeatedly expired $expiredStatus link more than once',
      () async {
        var links = 0;
        final adapter = _RangeAdapter(
          (_, _) => ResponseBody.fromBytes([], expiredStatus),
        );
        final reader = RemoteRangeReader(
          size: 10,
          link: () async {
            links++;
            return _link();
          },
          dio: _dio(adapter),
        );
        await expectLater(
          reader.read(2, 3),
          throwsA(_storageError('$expiredStatus')),
        );
        expect(links, 2);
        expect(adapter.requests, hasLength(2));
      },
    );
  }

  test(
    'keeps the original file validator after refreshing a signed URL',
    () async {
      final adapter = _RangeAdapter(
        (_, index) => index == 1
            ? ResponseBody.fromBytes([], 403)
            : _partial(
                headers: {
                  'etag': [index == 0 ? '"old"' : '"new"'],
                },
              ),
      );
      final reader = _reader(adapter);
      expect(await reader.read(2, 3), [2, 3, 4]);
      await expectLater(
        reader.read(2, 3),
        throwsA(_storageError('remote_file_changed')),
      );
      expect(_requestHeader(adapter.requests[2].headers, 'If-Match'), '"old"');
    },
  );

  for (final status in [412, 416, 500]) {
    test('does not retry HTTP $status', () async {
      final adapter = _RangeAdapter(
        (_, _) => ResponseBody.fromBytes([], status),
      );
      await expectLater(
        _reader(adapter).read(2, 3),
        throwsA(_storageError(status == 500 ? '500' : 'remote_file_changed')),
      );
      expect(adapter.requests, hasLength(1));
    });
  }

  test('honors cancellation before resolving a link', () async {
    var links = 0;
    final token = CancelToken()..cancel('reader closed');
    final reader = RemoteRangeReader(
      size: 10,
      link: () async {
        links++;
        return _link();
      },
    );
    await expectLater(
      reader.read(2, 3, cancelToken: token),
      throwsA(_cancelled),
    );
    expect(links, 0);
  });

  test('cancels while link resolution is still pending', () async {
    final token = CancelToken();
    final linkStarted = Completer<void>();
    final linkResult = Completer<RemoteLink>();
    final adapter = _RangeAdapter((_, _) => _partial());
    final reader = RemoteRangeReader(
      size: 10,
      link: () {
        linkStarted.complete();
        return linkResult.future;
      },
      dio: _dio(adapter),
    );
    final pending = expectLater(
      reader.read(2, 3, cancelToken: token),
      throwsA(_cancelled),
    );
    await linkStarted.future;
    token.cancel('reader closed');
    await pending;
    expect(adapter.requests, isEmpty);
    linkResult.complete(await _link());
  });

  test('cancels a request waiting for response headers', () async {
    final token = CancelToken();
    final started = Completer<void>();
    final aborted = Completer<void>();
    final adapter = _RangeAdapter((options, _) {
      options.cancelToken!.whenCancel.then((_) => aborted.complete());
      started.complete();
      return Completer<ResponseBody>().future;
    });
    final pending = expectLater(
      _reader(adapter).read(2, 3, cancelToken: token),
      throwsA(_cancelled),
    );
    await started.future;
    token.cancel('reader closed');
    await pending;
    await aborted.future;
    expect(adapter.requests, hasLength(1));
  });

  test('cancels an active response body and aborts the transport', () async {
    final token = CancelToken();
    final started = Completer<void>();
    final sourceCancelled = Completer<void>();
    final aborted = Completer<void>();
    final body = StreamController<Uint8List>(
      onListen: () => started.complete(),
      onCancel: () => sourceCancelled.complete(),
    );
    final adapter = _RangeAdapter((options, _) {
      options.cancelToken!.whenCancel.then((_) => aborted.complete());
      return _partial(stream: body.stream);
    });
    final pending = expectLater(
      _reader(adapter).read(2, 3, cancelToken: token),
      throwsA(_cancelled),
    );
    await started.future;
    token.cancel('reader closed');
    await pending;
    await sourceCancelled.future;
    await aborted.future;
    unawaited(body.close());
  });
}

final _cancelled = isA<DioException>().having(
  (error) => error.type,
  'type',
  DioExceptionType.cancel,
);

Matcher _storageError(String code) =>
    isA<RemoteStorageException>().having((error) => error.code, 'code', code);

Future<RemoteLink> _link() async =>
    const RemoteLink(url: 'https://files.example/archive.cbz');

Dio _dio(_RangeAdapter adapter) => Dio()..httpClientAdapter = adapter;

RemoteRangeReader _reader(_RangeAdapter adapter) =>
    RemoteRangeReader(size: 10, link: _link, dio: _dio(adapter));

String? _requestHeader(Map<String, dynamic> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value as String?;
    }
  }
  return null;
}

ResponseBody _partial({
  String? range = 'bytes 2-4/10',
  List<int> bytes = const [2, 3, 4],
  Stream<Uint8List>? stream,
  Map<String, List<String>> headers = const {},
}) => ResponseBody(
  stream ?? Stream.value(Uint8List.fromList(bytes)),
  206,
  headers: {
    if (range != null) 'content-range': [range],
    ...headers,
  },
);

class _RangeAdapter implements HttpClientAdapter {
  _RangeAdapter(this.respond);

  final FutureOr<ResponseBody> Function(RequestOptions options, int index)
  respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options, requests.length - 1);
  }

  @override
  void close({bool force = false}) {}
}
