import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/network/app_dio.dart';

const _url = 'https://example.invalid/comic.cbz';

class _CancelToken extends rhttp.CancelToken {
  Future<void> Function()? onCancel;
  int calls = 0;
  final started = Completer<void>();

  @override
  Future<void> cancel() {
    calls++;
    if (!started.isCompleted) started.complete();
    return onCancel?.call() ?? Future<void>.value();
  }
}

class _Adapter extends RHttpAdapter {
  _Adapter(this.respond);

  final Future<rhttp.HttpResponse> Function(RequestOptions options) respond;
  final token = _CancelToken();

  @override
  rhttp.CancelToken createCancelToken() => token;

  @override
  Future<rhttp.HttpResponse> request(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    rhttp.CancelToken cancelToken,
  ) => respond(options);
}

class _ReusableAdapter extends RHttpAdapter {
  _ReusableAdapter(this.clientReady, {this.onCreate})
    : super(reuseConnections: true);

  final Future<rhttp.RhttpClient> clientReady;
  final Future<rhttp.RhttpClient> Function(rhttp.ClientSettings)? onCreate;
  rhttp.ProxySettings? proxy;
  var creations = 0;

  @override
  Future<rhttp.ClientSettings> get settings async =>
      rhttp.ClientSettings(proxySettings: proxy);

  @override
  rhttp.CancelToken createCancelToken() => _CancelToken();

  @override
  Future<rhttp.RhttpClient> createReusableClient(
    rhttp.ClientSettings configured,
  ) {
    creations++;
    return onCreate?.call(configured) ?? clientReady;
  }
}

class _ReusableClient implements rhttp.RhttpClient {
  var requests = 0;
  var disposed = false;
  bool? cancelRunning;
  Future<void>? beforeResponse;

  @override
  Future<rhttp.HttpResponse> request({
    required rhttp.HttpMethod method,
    required String url,
    Map<String, String>? query,
    List<(String, String)>? queryRaw,
    rhttp.HttpHeaders? headers,
    rhttp.HttpBody? body,
    required rhttp.HttpExpectBody expectBody,
    rhttp.CancelToken? cancelToken,
    rhttp.ProgressCallback? onSendProgress,
    rhttp.ProgressCallback? onReceiveProgress,
  }) async {
    if (disposed) throw StateError('会话已关闭');
    requests++;
    await beforeResponse;
    return _response(Stream.value(Uint8List.fromList([requests])));
  }

  @override
  void dispose({bool cancelRunningRequests = false}) {
    disposed = true;
    cancelRunning = cancelRunningRequests;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

rhttp.HttpStreamResponse _response(
  Stream<Uint8List> body, {
  int statusCode = 206,
}) => rhttp.HttpStreamResponse(
  remoteIp: null,
  request: rhttp.HttpRequest(url: _url),
  version: rhttp.HttpVersion.http1_1,
  statusCode: statusCode,
  headers: const [('Content-Type', 'application/octet-stream')],
  body: body,
);

// Reproduce FRB 2.11.1 stream_sink.dart's eager async* receive loop and
// listenAndBuffer forwarding, followed by rhttp 0.15.1's error transformer.
// A pending decoder exception can escape through subscription.cancel() instead
// of the transformer's onError. This fixture needs no rhttp native DLL.
class _FrbBody {
  _FrbBody() {
    _buffer = StreamController<Uint8List>(sync: true);
    final raw = _receive().listen(
      _buffer.add,
      onError: _buffer.addError,
      onDone: _buffer.close,
    );
    _buffer
      ..onListen = () {
        listeners++;
      }
      ..onPause = raw.pause
      ..onResume = raw.resume
      ..onCancel = () {
        cancellations++;
        return raw.cancel();
      };
    stream = _buffer.stream.transform(
      StreamTransformer<Uint8List, Uint8List>.fromHandlers(
        handleError: (error, stack, sink) {
          if (error is AnyhowException &&
              error.message.contains('STREAM_CANCEL_ERROR')) {
            sink.addError(
              rhttp.RhttpCancelException(rhttp.HttpRequest(url: _url)),
              stack,
            );
          } else {
            sink.addError(error, stack);
          }
        },
      ),
    );
  }

  final started = Completer<void>();
  final stopped = Completer<void>();
  final cancelSignal = Completer<void>();
  late final StreamController<Uint8List> _buffer;
  late final Stream<Uint8List> stream;
  int listeners = 0;
  int cancellations = 0;

  Stream<Uint8List> _receive() async* {
    started.complete();
    try {
      await cancelSignal.future;
      throw AnyhowException('STREAM_CANCEL_ERROR');
    } finally {
      stopped.complete();
    }
  }

  Future<void> cancel() async {
    if (!cancelSignal.isCompleted) cancelSignal.complete();
  }
}

Future<List<Object>> _uncaughtDuring(Future<void> Function() action) async {
  final uncaught = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(() async {
    try {
      await action();
      await pumpEventQueue();
      done.complete();
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  }, (error, _) => uncaught.add(error));
  await done.future.timeout(const Duration(seconds: 5));
  return uncaught;
}

void main() {
  test('代理开关和端口变化重建会话，相同代理继续复用', () async {
    final clients = <_ReusableClient>[];
    final adapter = _ReusableAdapter(
      Future.value(_ReusableClient()),
      onCreate: (_) async {
        final client = _ReusableClient();
        clients.add(client);
        return client;
      },
    );
    for (final proxy in [
      rhttp.ProxySettings.proxy('127.0.0.1:7890'),
      rhttp.ProxySettings.proxy('127.0.0.1:7890'),
      const rhttp.ProxySettings.noProxy(),
      rhttp.ProxySettings.proxy('127.0.0.1:7891'),
      rhttp.ProxySettings.proxy('127.0.0.1:7890'),
    ]) {
      adapter.proxy = proxy;
      final response = await adapter.fetch(
        RequestOptions(path: _url),
        null,
        null,
      );
      await response.stream.drain<void>();
    }
    expect(adapter.creations, 4);
    expect(clients.map((client) => client.requests), [2, 1, 1, 1]);
    for (final client in clients.take(3)) {
      expect(client.disposed, isTrue);
      expect(client.cancelRunning, isFalse);
    }
    adapter.close(force: true);
    expect(clients.last.cancelRunning, isTrue);
  });

  test('切换代理不会取消已开始的请求', () async {
    final gate = Completer<void>();
    final old = _ReusableClient()..beforeResponse = gate.future;
    final current = _ReusableClient();
    final adapter = _ReusableAdapter(
      Future.value(current),
      onCreate: (settings) async =>
          settings.proxySettings is rhttp.StaticProxy ? old : current,
    )..proxy = const rhttp.ProxySettings.proxy('127.0.0.1:7890');
    final oldResponse = adapter.fetch(RequestOptions(path: _url), null, null);
    await pumpEventQueue();
    expect(old.requests, 1);

    adapter.proxy = const rhttp.ProxySettings.noProxy();
    final response = await adapter.fetch(
      RequestOptions(path: _url),
      null,
      null,
    );
    await response.stream.drain<void>();
    expect(old.disposed, isTrue);
    expect(old.cancelRunning, isFalse);
    gate.complete();
    await (await oldResponse).stream.drain<void>();
    adapter.close(force: true);
    expect(current.cancelRunning, isTrue);
  });

  test('初始化中切换代理时迟到的旧会话不会覆盖新会话', () async {
    final oldReady = Completer<rhttp.RhttpClient>();
    final currentReady = Completer<rhttp.RhttpClient>();
    final old = _ReusableClient();
    final current = _ReusableClient();
    final adapter = _ReusableAdapter(
      currentReady.future,
      onCreate: (settings) => settings.proxySettings is rhttp.StaticProxy
          ? oldReady.future
          : currentReady.future,
    )..proxy = const rhttp.ProxySettings.proxy('127.0.0.1:7890');
    final oldResponse = adapter.fetch(RequestOptions(path: _url), null, null);
    await pumpEventQueue();

    adapter.proxy = const rhttp.ProxySettings.noProxy();
    final responses = [
      adapter.fetch(RequestOptions(path: _url), null, null),
      adapter.fetch(RequestOptions(path: _url), null, null),
    ];
    await pumpEventQueue();
    expect(adapter.creations, 2);
    currentReady.complete(current);
    for (final response in await Future.wait(responses)) {
      await response.stream.drain<void>();
    }
    oldReady.complete(old);
    await (await oldResponse).stream.drain<void>();
    expect(old.disposed, isTrue);
    expect(old.cancelRunning, isFalse);
    adapter.close(force: true);
    expect(current.cancelRunning, isTrue);
  });

  test('切换代理后的初始化尚未完成时关闭会释放两个客户端', () async {
    final oldReady = Completer<rhttp.RhttpClient>();
    final currentReady = Completer<rhttp.RhttpClient>();
    final old = _ReusableClient();
    final current = _ReusableClient();
    final adapter = _ReusableAdapter(
      currentReady.future,
      onCreate: (settings) => settings.proxySettings is rhttp.StaticProxy
          ? oldReady.future
          : currentReady.future,
    )..proxy = const rhttp.ProxySettings.proxy('127.0.0.1:7890');
    final oldCheck = expectLater(
      adapter.fetch(RequestOptions(path: _url), null, null),
      throwsStateError,
    );
    await pumpEventQueue();
    adapter.proxy = const rhttp.ProxySettings.noProxy();
    final currentCheck = expectLater(
      adapter.fetch(RequestOptions(path: _url), null, null),
      throwsStateError,
    );
    await pumpEventQueue();
    adapter.close(force: true);
    oldReady.complete(old);
    currentReady.complete(current);
    await Future.wait([oldCheck, currentCheck]);
    for (final client in [old, current]) {
      expect(client.disposed, isTrue);
      expect(client.cancelRunning, isTrue);
      expect(client.requests, 0);
    }
  });

  test('复用会话依次返回响应，关闭后拒绝继续请求', () async {
    final client = _ReusableClient();
    final adapter = _ReusableAdapter(Future.value(client));
    for (var i = 1; i <= 2; i++) {
      final response = await adapter.fetch(
        RequestOptions(path: _url),
        null,
        null,
      );
      expect((await response.stream.toList()).single, [i]);
    }
    expect(adapter.creations, 1);
    adapter.close(force: true);
    expect(client.disposed, isTrue);
    expect(client.cancelRunning, isTrue);
    await expectLater(
      adapter.fetch(RequestOptions(path: _url), null, null),
      throwsStateError,
    );
    expect(client.requests, 2);
  });

  test('初始化期间关闭会话会释放迟到的客户端且不发送请求', () async {
    final ready = Completer<rhttp.RhttpClient>();
    final client = _ReusableClient();
    final adapter = _ReusableAdapter(ready.future);
    final response = adapter.fetch(RequestOptions(path: _url), null, null);
    final check = expectLater(response, throwsStateError);
    await pumpEventQueue();
    adapter.close(force: true);
    ready.complete(client);
    await check;
    expect(client.disposed, isTrue);
    expect(client.cancelRunning, isTrue);
    expect(client.requests, 0);
  });

  test(
    'native body is listened to before delivery and pauses until consumption',
    () async {
      final source = StreamController<Uint8List>();
      final adapter = _Adapter((_) async => _response(source.stream));
      final response = await adapter.fetch(
        RequestOptions(path: _url),
        null,
        null,
      );
      expect(source.hasListener, isTrue);
      expect(source.isPaused, isTrue);

      final data = response.stream.toList();
      await pumpEventQueue();
      expect(source.isPaused, isFalse);
      source.add(Uint8List.fromList([1, 2, 3]));
      await source.close();
      expect((await data).single, [1, 2, 3]);
      expect(adapter.token.calls, 0);
    },
  );

  test(
    'header rejection closes an unconsumed native body without unhandled decoder errors',
    () async {
      final uncaught = await _uncaughtDuring(() async {
        final body = _FrbBody();
        await body.started.future;
        final adapter = _Adapter(
          (_) async => _response(body.stream, statusCode: 403),
        );
        adapter.token.onCancel = body.cancel;
        final dio = Dio(
          BaseOptions(
            responseType: ResponseType.stream,
            receiveDataWhenStatusError: false,
          ),
        )..httpClientAdapter = adapter;

        await expectLater(
          dio.get<ResponseBody>(_url),
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.badResponse,
            ),
          ),
        );
        await body.stopped.future;
        expect(body.listeners, 1);
        expect(body.cancellations, 1);
        expect(adapter.token.calls, 1);
        dio.close();
      });
      expect(uncaught, isEmpty);
    },
  );

  test(
    'cancellation before response delivery also closes a late native body',
    () async {
      final uncaught = await _uncaughtDuring(() async {
        final body = _FrbBody();
        await body.started.future;
        final delivered = Completer<rhttp.HttpResponse>();
        final cancel = Completer<void>();
        final adapter = _Adapter((_) => delivered.future);
        adapter.token.onCancel = () async {
          await body.cancel();
          throw AnyhowException('STREAM_CANCEL_ERROR');
        };
        final fetch = adapter.fetch(
          RequestOptions(path: _url),
          null,
          cancel.future,
        );
        cancel.complete();
        await adapter.token.started.future;
        delivered.complete(_response(body.stream));
        await expectLater(
          fetch,
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        await body.stopped.future;
        expect(body.listeners, 1);
        expect(body.cancellations, 1);
        expect(adapter.token.calls, 1);
      });
      expect(uncaught, isEmpty);
    },
  );

  test(
    'cancellation after headers handles both native and async stream cancel failures',
    () async {
      final uncaught = await _uncaughtDuring(() async {
        final body = _FrbBody();
        await body.started.future;
        final cancel = Completer<void>();
        final adapter = _Adapter((_) async => _response(body.stream));
        adapter.token.onCancel = () async {
          await body.cancel();
          throw AnyhowException('STREAM_CANCEL_ERROR');
        };
        await adapter.fetch(RequestOptions(path: _url), null, cancel.future);
        expect(body.listeners, 1);
        cancel.complete();
        await body.stopped.future;
        expect(body.cancellations, 1);
        expect(adapter.token.calls, 1);
      });
      expect(uncaught, isEmpty);
    },
  );

  test(
    'consumer cancellation stops native work once and handles pending decoder failure',
    () async {
      final uncaught = await _uncaughtDuring(() async {
        final body = _FrbBody();
        await body.started.future;
        final cancel = Completer<void>();
        final adapter = _Adapter((_) async => _response(body.stream));
        adapter.token.onCancel = body.cancel;
        final response = await adapter.fetch(
          RequestOptions(path: _url),
          null,
          cancel.future,
        );
        final subscription = response.stream.listen((_) {});
        await pumpEventQueue();
        await subscription.cancel();
        cancel.complete();
        await body.stopped.future;
        expect(body.cancellations, 1);
        expect(adapter.token.calls, 1);
      });
      expect(uncaught, isEmpty);
    },
  );

  test('successful EOF ignores late request cancellation', () async {
    final source = StreamController<Uint8List>();
    final cancel = Completer<void>();
    final adapter = _Adapter((_) async => _response(source.stream));
    final response = await adapter.fetch(
      RequestOptions(path: _url),
      null,
      cancel.future,
    );
    final data = response.stream.toList();
    source.add(Uint8List.fromList([4, 5]));
    await source.close();
    expect((await data).single, [4, 5]);
    cancel.complete();
    await pumpEventQueue();
    expect(adapter.token.calls, 0);
  });

  for (final error in <Object>[
    StateError('Connection reset by peer'),
    AnyhowException('STREAM_CANCEL_ERROR'),
    rhttp.RhttpConnectionException(
      rhttp.HttpRequest(url: _url),
      'connection lost',
    ),
  ]) {
    test(
      'active body error remains observable: ${error.runtimeType}',
      () async {
        final source = StreamController<Uint8List>();
        final adapter = _Adapter((_) async => _response(source.stream));
        final response = await adapter.fetch(
          RequestOptions(path: _url),
          null,
          null,
        );
        source.addError(error, StackTrace.current);
        await expectLater(response.stream.toList(), throwsA(same(error)));
        await source.close();
      },
    );
  }

  test(
    'request failure propagates and ignores cancellation after failure',
    () async {
      final error = StateError('TLS handshake failed');
      final cancel = Completer<void>();
      final adapter = _Adapter((_) async => throw error);
      await expectLater(
        adapter.fetch(RequestOptions(path: _url), null, cancel.future),
        throwsA(same(error)),
      );
      cancel.complete();
      await pumpEventQueue();
      expect(adapter.token.calls, 0);
    },
  );

  test(
    'unexpected cancellation cleanup failures are reported rather than unhandled',
    () async {
      final previousMuted = Log.isMuted;
      Log.isMuted = false;
      addTearDown(() => Log.isMuted = previousMuted);
      final error = StateError('Native cancellation transport failed');
      final logStart = Log.logs.length;
      final uncaught = await _uncaughtDuring(() async {
        final source = StreamController<Uint8List>();
        final adapter = _Adapter((_) async => _response(source.stream));
        adapter.token.onCancel = () async => throw error;
        final response = await adapter.fetch(
          RequestOptions(path: _url),
          null,
          null,
        );
        await response.stream.listen((_) {}).cancel();
        await source.close();
      });
      expect(uncaught, isEmpty);
      expect(
        Log.logs
            .skip(logStart)
            .any(
              (item) =>
                  item.title == 'Network stream cleanup' &&
                  item.content.contains(error.toString()),
            ),
        isTrue,
      );
    },
  );
}
