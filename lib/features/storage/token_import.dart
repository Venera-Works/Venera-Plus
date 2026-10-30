import 'dart:convert';

const openListSupportedDrivers = <String>{
  'BaiduNetdisk',
  'Quark',
  '115 Open',
  '123 Open',
  'Onedrive',
  'GoogleDrive',
};

const openListLoginDrivers = <String, String>{
  '115 Open': '115cloud_go',
  '123 Open': '123cloud_oa',
  'BaiduNetdisk': 'baiduyun_go',
  'Onedrive': 'onedrive_pr',
};

Uri openListLoginUri(String driver) {
  final loginDriver = openListLoginDrivers[driver];
  if (loginDriver == null) {
    throw ArgumentError.value(driver, 'driver', 'Unsupported login provider');
  }
  return Uri.https(
    'api.oplist.org',
    '/${loginDriver.split('_').first}/requests',
    {
      'driver_txt': loginDriver,
      'server_use': 'true',
      'client_uid': '',
      'client_key': '',
    },
  );
}

Map<String, dynamic>? parseOpenListLoginCallback(
  String url, {
  required String driver,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'api.oplist.org' ||
      uri.port != 443 ||
      uri.path != '/' ||
      uri.fragment.isEmpty) {
    return null;
  }
  final value = parseOpenListAuthorization(url, driver: driver);
  final error = value.remove('message_err');
  if (error != null && '$error'.isNotEmpty) {
    throw FormatException('$error');
  }
  if (value['driver_txt'] != openListLoginDrivers[driver]) {
    throw const FormatException(
      'Authorization does not match the selected provider',
    );
  }
  final refreshKey = driver == '123 Open' ? 'RefreshToken' : 'refresh_token';
  if ((value[refreshKey] as String? ?? '').isEmpty) {
    throw const FormatException('Refresh Token is required');
  }
  if (driver == '115 Open' &&
      (value['access_token'] as String? ?? '').isEmpty) {
    throw const FormatException('Access Token is required');
  }
  value['server_use'] = true;
  // Reauthorization with official parameters replaces any previous app keys.
  final clientKeys = switch (driver) {
    '123 Open' => ['ClientID', 'ClientSecret'],
    _ => ['client_id', 'client_secret'],
  };
  for (final key in clientKeys) {
    value[key] = '';
  }
  if (driver != '115 Open') {
    value['use_online_api'] = true;
    value['api_url_address'] = Uri.https(
      'api.oplist.org',
      '/${openListLoginDrivers[driver]!.split('_').first}/renewapi',
    ).toString();
  }
  if (driver == 'Onedrive') value['region'] = 'global';
  return value;
}

Map<String, dynamic> parseOpenListAuthorization(
  String text, {
  required String driver,
}) {
  final value = normalizeOpenListAuthorization(
    _decodePayload(text.trim()),
    driver: driver,
  );
  if (driver == '123 Open') {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rawExpiresIn = value.remove('expires_in');
    final expiresIn = rawExpiresIn is num
        ? rawExpiresIn.toInt()
        : int.tryParse('$rawExpiresIn') ?? 0;
    value['token_updated_at'] ??= now;
    value['access_token_expires_at'] ??= expiresIn > 0
        ? now + expiresIn * 1000
        : 0;
  }
  return value;
}

Map<String, dynamic> buildOpenListAuthorization({
  required String driver,
  required String accessToken,
  required String refreshToken,
  String cookie = '',
  Map<String, dynamic> authorization = const {},
}) {
  if (driver == 'Quark') {
    return normalizeOpenListAuthorization({
      ...authorization,
      'cookie': cookie.trim(),
    }, driver: driver);
  }
  final value = <String, dynamic>{...authorization}
    ..remove('AccessToken')
    ..remove('RefreshToken');
  final result = normalizeOpenListAuthorization({
    ...value,
    'access_token': accessToken.trim(),
    'refresh_token': refreshToken.trim(),
  }, driver: driver);
  if (driver == '123 Open') {
    final previous = normalizeOpenListAuthorization(
      authorization,
      driver: driver,
    );
    if ([
      'AccessToken',
      'RefreshToken',
    ].any((key) => (previous[key] ?? '') != (result[key] ?? ''))) {
      result['token_updated_at'] = DateTime.now().millisecondsSinceEpoch;
      if ((previous['AccessToken'] ?? '') != (result['AccessToken'] ?? '')) {
        result['access_token_expires_at'] = 0;
      }
    }
    result.remove('expires_in');
  }
  return result;
}

/// Maps api.oplist.org callback fields and saved authorization to OpenList's
/// actual driver addition field names, with a single canonical token per key.
Map<String, dynamic> normalizeOpenListAuthorization(
  Map<String, dynamic> source, {
  required String driver,
}) {
  if (!openListSupportedDrivers.contains(driver)) {
    throw ArgumentError.value(driver, 'driver', 'Unsupported OpenList driver');
  }
  final value = <String, dynamic>{...source};
  if (driver == 'Quark') {
    _move(value, 'Cookie', 'cookie');
    return value;
  }
  final callbackDriver = value.remove('driver') ?? value['driver_txt'];
  if (callbackDriver is String && callbackDriver.isNotEmpty) {
    value['driver_txt'] = callbackDriver;
  }
  _move(value, 'AccessToken', 'access_token');
  _move(value, 'RefreshToken', 'refresh_token');
  _move(value, 'ClientID', 'client_id');
  _move(value, 'ClientSecret', 'client_secret');
  _move(value, 'client_uid', 'client_id');
  _move(value, 'client_key', 'client_secret');
  if (driver != '115 Open') value['use_online_api'] ??= true;
  if (driver == '123 Open') {
    _move(value, 'access_token', 'AccessToken');
    _move(value, 'refresh_token', 'RefreshToken');
    _move(value, 'client_id', 'ClientID');
    _move(value, 'client_secret', 'ClientSecret');
    value['driver_txt'] ??= '123cloud_oa';
    value['server_use'] ??= true;
    return value;
  }
  if (driver == 'BaiduNetdisk') {
    // Baidu's AccessToken has no JSON tag in the pinned driver; keep its
    // Pascal spelling while RefreshToken remains the driver's snake field.
    _move(value, 'access_token', 'AccessToken');
    return value;
  }
  return value;
}

Map<String, dynamic> _decodePayload(String value) {
  final hash = value.indexOf('#');
  if (hash >= 0) {
    value = value.substring(hash + 1);
  }
  value = Uri.decodeFull(value);
  try {
    final result = jsonDecode(value);
    if (result is Map) return result.map((key, item) => MapEntry('$key', item));
  } catch (_) {}
  try {
    final result = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(value))),
    );
    if (result is Map) return result.map((key, item) => MapEntry('$key', item));
  } catch (_) {}
  throw const FormatException('Invalid authorization response');
}

void _move(Map<String, dynamic> value, String source, String destination) {
  if (source == destination) {
    return;
  }
  final token = value.remove(source);
  if (token != null &&
      token != '' &&
      (value[destination] == null || value[destination] == '')) {
    value[destination] = token;
  }
}
