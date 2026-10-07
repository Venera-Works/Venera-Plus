import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera_plus/foundation/log.dart';
import 'package:venera_plus/foundation/extensions.dart';
import 'package:venera_plus/foundation/sync_records.dart';

/// Normalizes a cookie domain for sync domain-session grouping.
/// Removes leading dots and lowercases the domain.
String normalizeCookieDomain(String domain) {
  var d = domain.trim().toLowerCase();
  while (d.startsWith('.')) {
    d = d.substring(1);
  }
  return d;
}

class CookieJarSql {
  late Database _db;

  final String path;

  /// Global callback invoked whenever persistent cookie data changes.
  static void Function()? onCookiesChanged;

  /// Instance-specific callback invoked whenever persistent cookie data changes.
  void Function()? onInstanceCookiesChanged;

  /// Registers a neutral global handler for persistent cookie modifications.
  static void registerCookiesChangedHandler(void Function()? handler) {
    onCookiesChanged = handler;
  }

  void _notifyCookiesChanged() {
    onInstanceCookiesChanged?.call();
    onCookiesChanged?.call();
  }

  CookieJarSql(this.path) {
    init();
  }

  void init() {
    _db = sqlite3.open(path);
    _db.execute('''
      CREATE TABLE IF NOT EXISTS cookies (
        name TEXT NOT NULL,
        value TEXT NOT NULL,
        domain TEXT NOT NULL,
        path TEXT,
        expires INTEGER,
        secure INTEGER,
        httpOnly INTEGER,
        PRIMARY KEY (name, domain, path)
      );
    ''');
  }

  void saveFromResponse(Uri uri, List<Cookie> cookies) {
    var current = loadForRequest(uri);
    var changed = false;
    for (var cookie in cookies) {
      var currentCookie = current.firstWhereOrNull(
        (element) =>
            element.name == cookie.name &&
            (cookie.path == null || cookie.path!.startsWith(element.path!)),
      );
      if (currentCookie != null) {
        cookie.domain = currentCookie.domain;
      }
      final values = [
        cookie.name,
        cookie.value,
        cookie.domain ?? uri.host,
        cookie.path ?? "/",
        cookie.expires?.millisecondsSinceEpoch,
        cookie.secure ? 1 : 0,
        cookie.httpOnly ? 1 : 0,
      ];
      final existing = _db.select(
        '''
        SELECT name, value, domain, path, expires, secure, httpOnly FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''',
        [values[0], values[2], values[3]],
      );
      if (existing.isNotEmpty &&
          syncValuesEqual(existing.single.values.toList(), values)) {
        continue;
      }
      _db.execute('''
        INSERT OR REPLACE INTO cookies
          (name, value, domain, path, expires, secure, httpOnly)
        VALUES (?, ?, ?, ?, ?, ?, ?);
      ''', values);
      changed = true;
    }
    if (changed) _notifyCookiesChanged();
  }

  List<Cookie> _loadWithDomain(String domain) {
    var rows = _db.select(
      '''
      SELECT name, value, domain, path, expires, secure, httpOnly
      FROM cookies
      WHERE domain = ?;
    ''',
      [domain],
    );

    return rows
        .map(
          (row) => Cookie(row["name"] as String, row["value"] as String)
            ..domain = row["domain"] as String
            ..path = row["path"] as String
            ..expires = row["expires"] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row["expires"] as int)
            ..secure = row["secure"] == 1
            ..httpOnly = row["httpOnly"] == 1,
        )
        .toList();
  }

  List<String> _getAcceptedDomains(String host) {
    var acceptedDomains = <String>[host];
    var hostParts = host.split(".");
    for (var i = 0; i < hostParts.length - 1; i++) {
      acceptedDomains.add(".${hostParts.sublist(i).join(".")}");
    }
    return acceptedDomains;
  }

  List<Cookie> loadForRequest(Uri uri) {
    // if uri.host is example.example.com, acceptedDomains will be [".example.example.com", ".example.com", "example.com"]
    var acceptedDomains = _getAcceptedDomains(uri.host);

    var cookies = <Cookie>[];
    for (var domain in acceptedDomains) {
      cookies.addAll(_loadWithDomain(domain));
    }

    // check expires
    var expires = cookies.where(
      (cookie) =>
          cookie.expires != null && cookie.expires!.isBefore(DateTime.now()),
    );
    for (var cookie in expires) {
      _db.execute(
        '''
        DELETE FROM cookies
        WHERE name = ? AND domain = ? AND path = ?;
      ''',
        [cookie.name, cookie.domain, cookie.path],
      );
    }
    if (expires.isNotEmpty) {
      _notifyCookiesChanged();
    }

    return cookies
        .where(
          (element) =>
              !expires.contains(element) && _checkPathMatch(uri, element.path),
        )
        .toList();
  }

  bool _checkPathMatch(Uri uri, String? cookiePath) {
    if (cookiePath == null) {
      return true;
    }

    if (cookiePath == uri.path) {
      return true;
    }

    if (cookiePath == "/") {
      return true;
    }

    if (cookiePath.endsWith("/")) {
      return uri.path.startsWith(cookiePath);
    }

    return uri.path.startsWith(cookiePath);
  }

  void saveFromResponseCookieHeader(Uri uri, List<String> cookieHeader) {
    var cookies = <Cookie>[];
    for (var header in cookieHeader) {
      try {
        var cookie = Cookie.fromSetCookieValue(header);
        cookies.add(cookie);
      } catch (_) {
        Log.warning("Network", "Invalid cookie header: $header");
        continue;
      }
    }
    saveFromResponse(uri, cookies);
  }

  String loadForRequestCookieHeader(Uri uri) {
    var cookies = loadForRequest(uri);
    var map = <String, Cookie>{};
    for (var cookie in cookies) {
      if (map.containsKey(cookie.name)) {
        if (cookie.domain![0] != '.' && map[cookie.name]!.domain![0] == '.') {
          map[cookie.name] = cookie;
        } else if (cookie.domain!.length > map[cookie.name]!.domain!.length) {
          map[cookie.name] = cookie;
        }
      } else {
        map[cookie.name] = cookie;
      }
    }
    return map.entries
        .map((cookie) => "${cookie.value.name}=${cookie.value.value}")
        .join("; ");
  }

  void delete(Uri uri, String name) {
    var changed = false;
    for (var domain in _getAcceptedDomains(uri.host)) {
      _db.execute(
        '''
        DELETE FROM cookies WHERE name = ? AND domain = ? AND path = ?;
      ''',
        [name, domain, uri.path],
      );
      changed = changed || _db.updatedRows > 0;
    }
    if (changed) _notifyCookiesChanged();
  }

  void deleteUri(Uri uri) {
    var changed = false;
    for (var domain in _getAcceptedDomains(uri.host)) {
      _db.execute('DELETE FROM cookies WHERE domain = ?;', [domain]);
      changed = changed || _db.updatedRows > 0;
    }
    if (changed) _notifyCookiesChanged();
  }

  void deleteAll() {
    _db.execute('DELETE FROM cookies;');
    if (_db.updatedRows > 0) _notifyCookiesChanged();
  }

  /// Exports all stored cookies grouped and sorted by normalized domain.
  Map<String, List<Map<String, Object?>>> exportAllCookiesGroupedByDomain() {
    final rows = _db.select('''
      SELECT name, value, domain, path, expires, secure, httpOnly
      FROM cookies;
    ''');
    final map = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final domain = row['domain'] as String;
      final normalized = normalizeCookieDomain(domain);
      final item = <String, Object?>{
        'name': row['name'] as String,
        'value': row['value'] as String,
        'domain': domain,
        'path': row['path'] as String? ?? '/',
        'expires': row['expires'] as int?,
        'secure': (row['secure'] == 1),
        'httpOnly': (row['httpOnly'] == 1),
      };
      map.putIfAbsent(normalized, () => []).add(item);
    }

    for (final list in map.values) {
      list.sort((a, b) {
        final cmpName = (a['name'] as String).compareTo(b['name'] as String);
        if (cmpName != 0) return cmpName;
        final cmpPath = ((a['path'] as String?) ?? '').compareTo(
          (b['path'] as String?) ?? '',
        );
        if (cmpPath != 0) return cmpPath;
        return ((a['domain'] as String?) ?? '').compareTo(
          (b['domain'] as String?) ?? '',
        );
      });
    }
    return map;
  }

  /// Validates ownership before any cookie/session replacement can occur.
  static List<Map<String, Object?>> validateDomainCookies(
    String normalizedDomain,
    List<Map<String, Object?>> cookieRows,
  ) {
    final norm = normalizeCookieDomain(normalizedDomain);
    if (norm.isEmpty || norm != normalizedDomain) {
      throw const FormatException('Cookie record domain must be normalized');
    }
    final result = <Map<String, Object?>>[];
    final identities = <String>{};
    for (final row in cookieRows) {
      final domain = row['domain'];
      final path = row['path'] ?? '/';
      final expires = row['expires'];
      final secure = row['secure'] ?? false;
      final httpOnly = row['httpOnly'] ?? false;
      bool validFlag(Object? value) =>
          value is bool || (value is int && (value == 0 || value == 1));
      if (row['name'] is! String ||
          row['value'] is! String ||
          domain is! String ||
          normalizeCookieDomain(domain) != norm ||
          path is! String ||
          (expires != null && expires is! int) ||
          !validFlag(secure) ||
          !validFlag(httpOnly)) {
        throw FormatException('Invalid cookie row for domain "$norm"');
      }
      final identity = syncRecordKey('cookie', [row['name'], domain, path]);
      if (!identities.add(identity)) {
        throw FormatException('Duplicate cookie identity for domain "$norm"');
      }
      result.add({
        'name': row['name'],
        'value': row['value'],
        'domain': domain,
        'path': path,
        'expires': expires,
        'secure': secure == true || secure == 1,
        'httpOnly': httpOnly == true || httpOnly == 1,
      });
    }
    result.sort((a, b) {
      final name = (a['name'] as String).compareTo(b['name'] as String);
      if (name != 0) return name;
      final path = (a['path'] as String).compareTo(b['path'] as String);
      if (path != 0) return path;
      return (a['domain'] as String).compareTo(b['domain'] as String);
    });
    return result;
  }

  /// Replaces the complete materialized cookie view in one SQLite transaction.
  /// Equal sessions perform no row writes or change notifications.
  void applyAllDomainCookies(
    Map<String, List<Map<String, Object?>>> domains, {
    bool notify = false,
    bool replaceAll = true,
  }) {
    final validated = {
      for (final entry in domains.entries)
        entry.key: validateDomainCookies(entry.key, entry.value),
    };
    var changed = false;
    _db.execute('BEGIN TRANSACTION;');
    try {
      final existing = exportAllCookiesGroupedByDomain();
      final managed = {...validated.keys, if (replaceAll) ...existing.keys};
      for (final domain in managed) {
        final next = validated[domain] ?? [];
        final previous = existing[domain] ?? [];
        if (syncValuesEqual(previous, next)) continue;
        for (final physical in previous.map((row) => row['domain']).toSet()) {
          _db.execute('DELETE FROM cookies WHERE domain = ?;', [physical]);
        }
        for (final row in next) {
          _db.execute(
            '''
            INSERT INTO cookies
              (name, value, domain, path, expires, secure, httpOnly)
            VALUES (?, ?, ?, ?, ?, ?, ?);
          ''',
            [
              row['name'],
              row['value'],
              row['domain'],
              row['path'],
              row['expires'],
              row['secure'] == true ? 1 : 0,
              row['httpOnly'] == true ? 1 : 0,
            ],
          );
        }
        changed = true;
      }
      _db.execute('COMMIT;');
    } catch (_) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    if (changed && notify) _notifyCookiesChanged();
  }

  void applyDomainCookies(
    String normalizedDomain,
    List<Map<String, Object?>> cookieRows, {
    bool notify = false,
  }) {
    applyAllDomainCookies(
      {normalizeCookieDomain(normalizedDomain): cookieRows},
      notify: notify,
      replaceAll: false,
    );
  }

  void deleteDomainCookies(String normalizedDomain, {bool notify = false}) {
    applyDomainCookies(normalizedDomain, [], notify: notify);
  }

  void dispose() {
    _db.dispose();
  }
}

class SingleInstanceCookieJar extends CookieJarSql {
  factory SingleInstanceCookieJar(String path) =>
      instance ??= SingleInstanceCookieJar._create(path);

  SingleInstanceCookieJar._create(super.path);

  static SingleInstanceCookieJar? instance;

  static Future<SingleInstanceCookieJar> createInstance() async {
    if (instance != null) {
      return instance!;
    }
    var dataPath = (await getApplicationSupportDirectory()).path;
    instance = SingleInstanceCookieJar("$dataPath/cookie.db");
    return instance!;
  }
}

class CookieManagerSql extends Interceptor {
  CookieManagerSql(CookieJarSql cookieJar) : this.dynamic(() => cookieJar);

  CookieManagerSql.dynamic(this._cookieJarProvider);

  final CookieJarSql? Function() _cookieJarProvider;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      final cookieJar = _cookieJarProvider();
      var cookies = cookieJar?.loadForRequestCookieHeader(options.uri) ?? "";
      if (cookies.isNotEmpty) {
        if (options.headers["cookie"] != null) {
          cookies = "${options.headers["cookie"]}; $cookies";
        }
        options.headers["cookie"] = cookies;
      }
    } catch (e, s) {
      Log.error("Network", "Failed to load cookies: $e", s);
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    try {
      _cookieJarProvider()?.saveFromResponseCookieHeader(
        response.requestOptions.uri,
        response.headers["set-cookie"] ?? [],
      );
    } catch (e, s) {
      Log.error("Network", "Failed to save cookies: $e", s);
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
  }
}
