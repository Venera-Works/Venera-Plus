import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/storage/token_import.dart';

void main() {
  const providers = {
    '115 Open': ('115cloud', '115cloud_go'),
    '123 Open': ('123cloud', '123cloud_oa'),
    'BaiduNetdisk': ('baiduyun', 'baiduyun_go'),
    'Onedrive': ('onedrive', 'onedrive_pr'),
  };

  test('uses the selected OAuth modes with official OpenList parameters', () {
    for (final provider in providers.entries) {
      final uri = openListLoginUri(provider.key);
      expect(uri.origin, 'https://api.oplist.org');
      expect(uri.path, '/${provider.value.$1}/requests');
      expect(uri.queryParameters, {
        'driver_txt': provider.value.$2,
        'server_use': 'true',
        'client_uid': '',
        'client_key': '',
      });
    }
  });

  test('imports official callbacks into the matching native driver', () {
    for (final provider in providers.entries) {
      final value = parseOpenListLoginCallback(
        _callback({
          'driver_txt': provider.value.$2,
          'access_token': 'access',
          'refresh_token': 'refresh',
          'server_use': 'true',
          'client_uid': 'previous-client',
          'client_key': 'previous-secret',
        }),
        driver: provider.key,
      )!;
      expect(value['server_use'], isTrue);
      if (provider.key == '123 Open') {
        expect(value['AccessToken'], 'access');
        expect(value['RefreshToken'], 'refresh');
        expect(value['ClientID'], isEmpty);
        expect(value['ClientSecret'], isEmpty);
      } else {
        expect(value['refresh_token'], 'refresh');
      }
      if (provider.key != '115 Open') {
        expect(value['use_online_api'], isTrue);
        expect(
          value['api_url_address'],
          'https://api.oplist.org/${provider.value.$1}/renewapi',
        );
      }
      if (provider.key == 'Onedrive') {
        expect(value['region'], 'global');
        expect(value['client_id'], isEmpty);
        expect(value['client_secret'], isEmpty);
      }
    }
  });

  test('only accepts the official result URL for the current provider', () {
    final callback = _callback({
      'driver_txt': 'baiduyun_go',
      'refresh_token': 'refresh',
    });
    for (final url in [
      callback.replaceFirst('https:', 'http:'),
      callback.replaceFirst('api.oplist.org', 'example.com'),
      callback.replaceFirst('api.oplist.org', 'api.oplist.org:8443'),
      callback.replaceFirst('/#', '/other/#'),
      'https://api.oplist.org/baiduyun/callback?code=temporary-code',
      'https://api.oplist.org/#',
    ]) {
      expect(parseOpenListLoginCallback(url, driver: 'BaiduNetdisk'), isNull);
    }
    expect(
      () => parseOpenListLoginCallback(callback, driver: '123 Open'),
      throwsFormatException,
    );
  });

  test('rejects error callbacks and incomplete tokens before saving', () {
    expect(
      () => parseOpenListLoginCallback(
        _callback({
          'driver_txt': 'baiduyun_go',
          'refresh_token': 'partial',
          'message_err': '授权已取消',
        }),
        driver: 'BaiduNetdisk',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '授权已取消',
        ),
      ),
    );
    for (final tokens in [
      {'access_token': 'access'},
      {'refresh_token': 'refresh'},
    ]) {
      expect(
        () => parseOpenListLoginCallback(
          _callback({'driver_txt': '115cloud_go', ...tokens}),
          driver: '115 Open',
        ),
        throwsFormatException,
      );
    }
  });
}

String _callback(Map<String, dynamic> data) =>
    'https://api.oplist.org/#${base64Encode(utf8.encode(jsonEncode(data)))}';
