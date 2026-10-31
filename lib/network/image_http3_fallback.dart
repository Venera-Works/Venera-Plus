import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

/// Only connection-stage TLS EOF/reset errors qualify, not status/body errors.
bool isImageTlsConnectionInterruption(Object error) {
  if (error is! rhttp.RhttpConnectionException) return false;
  final message = error.message.toLowerCase();
  if (message.contains('certificate') ||
      message.contains('unknownissuer') ||
      message.contains('dns error') ||
      message.contains('dns lookup') ||
      message.contains('failed to lookup address') ||
      message.contains('name resolution')) {
    return false;
  }
  return message.contains('tls handshake eof') ||
      message.contains('connection reset') ||
      message.contains('connectionreset') ||
      message.contains('forcibly closed by the remote host') ||
      (message.contains('handshake') &&
          (message.contains('unexpected eof') ||
              message.contains('unexpectedeof') ||
              message.contains('unexpected end of file') ||
              message.contains('terminated')));
}

Duration imageHttp3HeaderTimeout(
  RequestOptions options,
  rhttp.ClientSettings settings,
) {
  var timeout = const Duration(seconds: 5);
  for (final configured in [
    options.connectTimeout,
    options.receiveTimeout,
    settings.timeoutSettings?.connectTimeout,
  ]) {
    if (configured != null &&
        configured > Duration.zero &&
        configured < timeout) {
      timeout = configured;
    }
  }
  return timeout;
}

/// Retain both failures without adding signed URLs or credentials to diagnostics.
class ImageHttp3FallbackFailure implements Exception {
  const ImageHttp3FallbackFailure({
    required this.originalError,
    required this.fallbackError,
  });

  final Object originalError;
  final Object fallbackError;

  @override
  String toString() =>
      'Image request failed over TCP/TLS and HTTP/3 '
      '(TCP/TLS: ${originalError.runtimeType}, '
      'HTTP/3: ${fallbackError.runtimeType})';
}
