import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:venera_plus/network/proxy.dart';

final googleDriveDefaultCallback = Uri.https(
  'api.oplist.org',
  '/googleui/callback',
);

Uri googleDriveCallbackUri(String address) {
  final text = address.trim();
  if (text.isEmpty) return googleDriveDefaultCallback;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException('Enter a valid HTTPS OAuth callback address.');
  }
  return uri;
}

Future<String?> authorizeGoogleDrive({
  required Uri callback,
  required String clientId,
  required String clientSecret,
  required CancelToken cancelToken,
}) async {
  final random = Random.secure();
  String randomValue() =>
      _base64Url(List<int>.generate(32, (_) => random.nextInt(256)));

  final pollKey = randomValue();
  final state = _challenge(pollKey);
  final verifier = randomValue();
  final proxy = await getProxy();
  final client =
      Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
            followRedirects: false,
            validateStatus: (status) => status != null,
          ),
        )
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () =>
              HttpClient()
                ..findProxy = (_) => proxy == null ? 'DIRECT' : 'PROXY $proxy',
        );
  try {
    final started = await client.postUri<Object>(
      callback,
      data: {'action': 'start', 'state': state},
      cancelToken: cancelToken,
    );
    final session = started.data;
    if (started.statusCode != 201 ||
        session is! Map ||
        session['protocol'] != 'venera-google-drive-v1') {
      throw const FormatException(
        'This callback does not support automatic Google Drive authorization.',
      );
    }

    final elapsed = Stopwatch()..start();
    final loginUri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': callback.toString(),
      'response_type': 'code',
      'scope': 'https://www.googleapis.com/auth/drive',
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
      'code_challenge': _challenge(verifier),
      'code_challenge_method': 'S256',
    });
    if (cancelToken.isCancelled) return null;
    if (!await launchUrl(loginUri, mode: LaunchMode.externalApplication)) {
      throw const FormatException('Unable to open the browser.');
    }

    while (elapsed.elapsed < const Duration(minutes: 5)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (cancelToken.isCancelled) return null;
      final Response<Object> result;
      try {
        result = await client.postUri<Object>(
          callback,
          data: {'action': 'take', 'poll_key': pollKey},
          cancelToken: cancelToken,
        );
      } on DioException catch (error) {
        if (error.type == DioExceptionType.connectionError ||
            error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.receiveTimeout) {
          continue;
        }
        rethrow;
      }
      if (result.statusCode == 202) continue;
      if (result.statusCode == 410) break;
      final data = result.data;
      if (result.statusCode != 200 || data is! Map || data['state'] != state) {
        throw const FormatException('Invalid authorization response');
      }
      final code = data['code'];
      if (code is! String || code.isEmpty) {
        throw const FormatException(
          'Google Drive authorization was not granted.',
        );
      }
      final response = await client.postUri<Object>(
        Uri.https('oauth2.googleapis.com', '/token'),
        data: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': callback.toString(),
          'client_id': clientId,
          'client_secret': clientSecret,
          'code_verifier': verifier,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
        cancelToken: cancelToken,
      );
      final tokens = response.data;
      if (response.statusCode != 200 || tokens is! Map) {
        throw const FormatException(
          'Google rejected the token request. Check the OAuth client credentials.',
        );
      }
      final refresh = tokens['refresh_token'];
      if (refresh is! String || refresh.trim().isEmpty) {
        throw const FormatException('Refresh Token is required');
      }
      return refresh;
    }
    throw const FormatException('Google Drive authorization timed out.');
  } on DioException catch (error) {
    if (CancelToken.isCancel(error)) return null;
    throw const FormatException(
      'Unable to complete Google Drive authorization. Check the network and callback address.',
    );
  } finally {
    client.close(force: true);
  }
}

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

String _challenge(String value) =>
    _base64Url(sha256.convert(ascii.encode(value)).bytes);
