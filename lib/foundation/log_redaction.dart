const logRedactionMask = '********';

final _keySeparators = RegExp(r'[-_\s]');
String _normalizedKey(String key) =>
    key.toLowerCase().replaceAll(_keySeparators, '');

const _credentials = {
  'authorization',
  'proxyauthorization',
  'cookie',
  'cookies',
  'setcookie',
  'password',
  'passwd',
  'pwd',
  'secret',
  'auth',
  'jwt',
  'clientsecret',
  'token',
  'accesstoken',
  'refreshtoken',
  'idtoken',
  'authtoken',
  'xauthtoken',
  'apikey',
  'xapikey',
  'session',
  'sessionid',
  'phpsessid',
  'ipbpasshash',
  'igneous',
  'signature',
  'sign',
  'sig',
  'xamzsignature',
  'xamzsecuritytoken',
  'xamzcredential',
  'xgoogsignature',
  'xgoogcredential',
};

/// Copies only diagnostic data. Never use this result as request headers.
Map<String, Object?> redactLogHeaders(
  Map<String, dynamic> headers, {
  Iterable<String> additionallyMasked = const [],
}) {
  final masked = additionallyMasked.map(_normalizedKey).toSet();
  return headers.map(
    (key, value) => MapEntry(
      key,
      _credentials.contains(_normalizedKey(key)) ||
              masked.contains(_normalizedKey(key))
          ? logRedactionMask
          : _redactValue(value, 0),
    ),
  );
}

String formatLogBody(Object? value) => _redactValue(value, 0).toString();

Object? _redactValue(Object? value, int depth) {
  if (depth > 12) return '<nested value>';
  if (value is Map) {
    return value.map(
      (key, child) => MapEntry(
        key,
        _credentials.contains(_normalizedKey(key.toString()))
            ? logRedactionMask
            : _redactValue(child, depth + 1),
      ),
    );
  }
  if (value is List) {
    return value.map((child) => _redactValue(child, depth + 1)).toList();
  }
  return value is String ? redactLogText(value) : value;
}

final _urls = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false);
final _headers = RegExp(
  r'''(\b(?:proxy[-_]?authorization|authorization|set[-_]?cookie|cookies?)\b["']?[ \t]*[:=][ \t]*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n}\]]*?(?=,\s*["']?[a-z][\w-]*["']?\s*:|[\r\n}\]]|$))''',
  caseSensitive: false,
);
final _fields = RegExp(
  r'''(\b(?:password|passwd|pwd|secret|auth|jwt|client[-_]?secret|(?:access[-_]?|refresh[-_]?|id[-_]?|auth[-_]?|x[-_]auth[-_]?)?token|(?:x[-_]?)?api[-_]?key|session(?:[-_]?id)?|phpsessid|ipb[-_]pass[-_]hash|igneous|signature|sign|sig|x[-_]amz[-_](?:signature|security[-_]?token|credential)|x[-_]goog[-_](?:signature|credential))\b["']?[ \t]*[:=][ \t]*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;&}\]]+)''',
  caseSensitive: false,
);

/// A final safeguard for exception messages and source-script logs as well as
/// structured HTTP diagnostics. Redaction precedes truncation and persistence.
String redactLogText(String text) {
  var result = text.replaceAllMapped(_urls, (match) {
    final original = match.group(0)!;
    try {
      final uri = Uri.parse(original);
      var changed = uri.userInfo.isNotEmpty || uri.hasFragment;
      final query = uri.queryParametersAll.map((key, values) {
        if (_credentials.contains(_normalizedKey(key)) ||
            _normalizedKey(key) == 'key') {
          changed = true;
          return MapEntry(key, [for (final _ in values) logRedactionMask]);
        }
        return MapEntry(key, values);
      });
      if (!changed) return original;
      return uri
          .replace(userInfo: '', queryParameters: uri.hasQuery ? query : null)
          .removeFragment()
          .toString();
    } on FormatException {
      return '<invalid URL>';
    }
  });
  result = result.replaceAllMapped(
    _headers,
    (match) => '${match.group(1)}$logRedactionMask',
  );
  return result.replaceAllMapped(
    _fields,
    (match) => '${match.group(1)}$logRedactionMask',
  );
}
