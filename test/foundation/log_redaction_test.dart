import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/log_redaction.dart';

void main() {
  test('redaction keeps JSON valid and is stable when applied again', () {
    final source = jsonEncode({
      'token': 'private-token',
      'password': 12345,
      'headers': {'Authorization': 'Bearer private-auth'},
      'nested': [
        {'api_key': 'private-key', 'title': 'Public title'},
      ],
      'page': 5,
    });
    final result = redactLogText(source);
    final decoded = jsonDecode(result) as Map;
    expect(decoded['token'], logRedactionMask);
    expect(decoded['password'], logRedactionMask);
    expect((decoded['headers'] as Map)['Authorization'], logRedactionMask);
    expect(
      ((decoded['nested'] as List).single as Map)['api_key'],
      logRedactionMask,
    );
    expect(result, contains('Public title'));
    expect(decoded['page'], 5);
    expect(redactLogText(result), result);
    expect(result, isNot(contains('private-')));
  });

  test('existing network masks preserve header, JSON and URL formatting', () {
    const source =
        'Authorization: <redacted>\n'
        '{"token":"<redacted>","page":5}\n'
        'GET https://example.com/api?token=%3Credacted%3E&page=2\n'
        'GET /api?token=%3Credacted%3E&page=3';
    expect(redactLogText(source), source);
  });

  test('URL cookie redaction retains following public query parameters', () {
    final result = redactLogText(
      'https://example.com/api?cookie=private-cookie&page=2&token=private-token',
    );
    final uri = Uri.parse(result);
    expect(uri.queryParameters['cookie'], logRedactionMask);
    expect(uri.queryParameters['token'], logRedactionMask);
    expect(uri.queryParameters['page'], '2');
    expect(redactLogText(result), result);
    expect(result, isNot(contains('private-')));
  });

  test('header masking is case insensitive and leaves inputs unchanged', () {
    final headers = {
      'cOoKiE': 'account=private-cookie; other=another-cookie',
      'Set-Cookie': ['session=private-session', 'other=another-session'],
      'AUTHORIZATION': 'Bearer private-auth',
      'Proxy-Authorization': 'Basic private-proxy',
      'X-API-Key': 'private-key',
      'X-Custom': 'private-custom',
      'Content-Type': 'application/json',
    };
    final masked = redactLogHeaders(headers, additionallyMasked: ['x-custom']);
    expect(masked['Content-Type'], 'application/json');
    expect(
      masked.values.where((value) => value == logRedactionMask),
      hasLength(6),
    );
    expect(headers['AUTHORIZATION'], 'Bearer private-auth');
    expect(headers['Set-Cookie'], [
      'session=private-session',
      'other=another-session',
    ]);
  });

  test('nested payloads and cycles cannot disclose credential fields', () {
    final payload = <String, dynamic>{
      'items': [
        {'access_token': 'private-access', 'title': 'public title'},
        {'Password': 'private-password', 'refresh-token': 'private-refresh'},
      ],
    };
    payload['cycle'] = payload;
    final result = formatLogBody(payload);
    expect(result, isNot(contains('private-')));
    expect(result, contains('public title'));
    expect(result, contains('<nested value>'));
    expect((payload['items'] as List).first['access_token'], 'private-access');
  });

  test('URLs retain paths and public query values but not credentials', () {
    final result = redactLogText(
      'GET https://private-user:private-pass@example.com/api'
      '?page=2&access_token=private-a&access_token=private-b'
      '&X-Amz-Signature=private-signature&%61pi_key=private-key'
      '&auth=private-auth&X-Amz-Security-Token=private-security#private-fragment',
    );
    expect(result, isNot(contains('private-')));
    expect(result, contains('example.com/api'));
    expect(result, contains('page=2'));
    expect(result, contains('access_token='));
    expect(
      redactLogText('GET https://example.com/api?page=2'),
      'GET https://example.com/api?page=2',
    );
    expect(
      () => redactLogText('GET https://example.com/?token=%zz'),
      returnsNormally,
    );
  });

  for (final text in [
    'headers:\nCookie: a=private-a; b=private-b\nContent-Type: text/html',
    '{cookie: a=private-a; b=private-b, content-type: text/html}',
    '{Authorization: Bearer private-auth, content-type: text/html}',
    '{"Authorization":"Bearer private-auth", "content-type":"text/html"}',
    '{"password":"private-pass with spaces", "items":[{"token":"private-token"}]}',
    'ipb_pass_hash=private-hash; PHPSESSID=private-session; igneous=private-other',
    'refresh_token=private-refresh&client_secret=private-client',
    'Set-Cookie: first=private-first; Expires=Wed, 21 Oct 2026 07:28:00 GMT\npublic',
  ]) {
    test('redacts free-form diagnostic: ${text.split('\n').first}', () {
      final result = redactLogText(text);
      expect(result, isNot(contains('private-')));
      expect(result, contains(logRedactionMask));
      if (text.contains('text/html')) expect(result, contains('text/html'));
    });
  }

  test(
    'console, memory, early replay and files receive redacted text',
    () async {
      final root = Directory('build').absolute.createTempSync('redacted-logs-');
      final buildRoot = Directory('build').resolveSymbolicLinksSync();
      final file = File('${root.path}/logs.txt');
      final muted = Log.isMuted;
      final output = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) output.add(message);
      };
      Log.isMuted = false;
      Log.clear();
      Future<void> Function()? close;
      try {
        Log.info(
          'token=private-title',
          'Cookie: a=private-early; b=private-second',
        );
        close = await Log.startFileSession(file);
        Log.error('network', 'password=private-password\npublic failure');
        Log.info(
          'long',
          'Cookie: ${List.filled(1000, 'private-cookie').join(' ')}',
        );
        await close();
        close = null;
        for (final text in [
          output.join(),
          Log().toString(),
          await file.readAsString(),
        ]) {
          expect(text, isNot(contains('private-')));
          expect(text, contains('public failure'));
        }
      } finally {
        await close?.call();
        Log.clear();
        Log.isMuted = muted;
        debugPrint = previousPrint;
        expect(
          root.resolveSymbolicLinksSync(),
          startsWith('$buildRoot${Platform.pathSeparator}'),
        );
        root.deleteSync(recursive: true);
      }
    },
  );
}
