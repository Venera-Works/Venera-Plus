import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:rhttp/src/rust/api/error.dart' as native_error;
import 'package:rhttp/src/rust/api/http.dart' as native;
import 'package:rhttp/src/rust/frb_generated.dart';
import 'package:rhttp/src/rust/lib.dart';

// Run directly with Dart and an existing rhttp library; no app build is needed.
// Delaying a real callback makes the cancellation race deterministic.
Future<void> main(List<String> arguments) async {
  await RustLib.init(externalLibrary: ExternalLibrary.open(arguments.single));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = server.listen((request) async {
    request.response.write('callback-ok');
    await request.response.close();
  });
  final url = 'http://127.0.0.1:${server.port}/';

  try {
    await _cancelWithLateCallback(url).timeout(const Duration(seconds: 10));
    final response = await native
        .makeHttpRequest(
          method: const native.HttpMethod(method: 'GET'),
          url: url,
          expectBody: native.HttpExpectBody.text,
          onCancelToken: (_) {},
          cancelable: false,
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200 ||
        response.body != const native.HttpResponseBody.text('callback-ok')) {
      throw StateError(
        'Request after cancellation returned an invalid response',
      );
    }
    stdout.writeln(
      'PASS: canceled callback returned safely; subsequent HTTP 200 body verified.',
    );
  } finally {
    await requests.cancel();
    await server.close(force: true);
    RustLib.dispose();
  }
}

Future<void> _cancelWithLateCallback(String url) async {
  final token = Completer<CancellationToken>();
  final responseEntered = Completer<int>();
  final cancellationEntered = Completer<native_error.RhttpError>();
  final replyGate = Completer<void>();
  final replyReturned = Completer<void>();
  final bodyDone = Completer<void>();
  final bodyErrors = <Object>[];
  final received = <int>[];

  final body = native.makeHttpRequestReceiveStream(
    method: const native.HttpMethod(method: 'GET'),
    url: url,
    cancelable: true,
    onCancelToken: token.complete,
    onResponse: (response) async {
      responseEntered.complete(response.statusCode);
      await replyGate.future;
      replyReturned.complete();
    },
    onError: cancellationEntered.complete,
  );
  final subscription = body.listen(
    received.addAll,
    onError: (Object error, StackTrace stack) => bodyErrors.add(error),
    onDone: bodyDone.complete,
  );

  try {
    if (await responseEntered.future != 200) {
      throw StateError('Local response callback did not receive HTTP 200');
    }
    await native.cancelRequest(token: await token.future);
    if (await cancellationEntered.future !=
        const native_error.RhttpError.rhttpCancelError()) {
      throw StateError('Request did not report cancellation');
    }
    await bodyDone.future;
    // The cancellation branch has now dropped the pending callback receiver.
    replyGate.complete();
    await replyReturned.future;
    if (received.isNotEmpty ||
        bodyErrors.length != 1 ||
        bodyErrors.single is! AnyhowException ||
        !(bodyErrors.single as AnyhowException).message.contains(
          'STREAM_CANCEL_ERROR',
        )) {
      throw StateError(
        'Canceled response body had unexpected events: $bodyErrors',
      );
    }
  } finally {
    if (!replyGate.isCompleted) replyGate.complete();
    await subscription.cancel();
  }
}
