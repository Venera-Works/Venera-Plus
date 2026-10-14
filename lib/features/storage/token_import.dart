import 'dart:convert';

const openListSupportedDrivers = <String>{
  'BaiduNetdisk',
  'QuarkOpen',
  '115 Open',
  '123 Open',
  'Onedrive',
  'GoogleDrive',
};

Map<String, dynamic> parseOpenListAuthorization(
  String text, {
  required String driver,
}) =>
    normalizeOpenListAuthorization(_decodePayload(text.trim()), driver: driver);

Map<String, dynamic> buildOpenListAuthorization({
  required String driver,
  required String accessToken,
  required String refreshToken,
  String? appId,
  String? signKey,
}) => normalizeOpenListAuthorization({
  'access_token': accessToken.trim(),
  'refresh_token': refreshToken.trim(),
  if (appId != null) 'app_id': appId.trim(),
  if (signKey != null) 'sign_key': signKey.trim(),
}, driver: driver);

/// Maps api.oplist.org callback fields and pasted token JSON to OpenList's
/// actual driver addition field names, with a single canonical token per key.
Map<String, dynamic> normalizeOpenListAuthorization(
  Map<String, dynamic> source, {
  required String driver,
}) {
  if (!openListSupportedDrivers.contains(driver)) {
    throw ArgumentError.value(driver, 'driver', 'Unsupported OpenList driver');
  }
  final value = <String, dynamic>{...source};
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
  if (driver == 'QuarkOpen') {
    _move(value, 'AppID', 'app_id');
    _move(value, 'SignKey', 'sign_key');
  }
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
  throw const FormatException(
    'Paste the OpenList token JSON or callback payload',
  );
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
