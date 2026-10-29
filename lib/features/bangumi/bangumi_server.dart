import 'dart:async';
import 'dart:convert';

import 'package:venera_plus/foundation/appdata.dart';
import 'package:venera_plus/network/app_dio.dart';

const bangumiOfficialServer = BangumiServer(
  name: 'bgm.tv',
  apiUrl: 'https://api.bgm.tv',
  imageUrl: 'https://lain.bgm.tv',
);

const bangumiPresetServers = [
  bangumiOfficialServer,
  BangumiServer(
    name: 'bangumi.lat',
    apiUrl: 'https://api.bangumi.lat',
    imageUrl: 'https://lain.bangumi.lat',
    tokenUrl: 'https://next.bangumi.lat/demo/access-token',
  ),
  BangumiServer(
    name: 'anibt.net',
    apiUrl: 'https://bgmapi.anibt.net',
    imageUrl: 'https://bgmimg.anibt.net',
  ),
];

String? normalizeBangumiUrl(String input) {
  final value = input.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(uri.host)) {
    return null;
  }
  return uri
      .replace(
        host: uri.host.toLowerCase(),
        path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
      )
      .toString();
}

class BangumiServer {
  const BangumiServer({
    required this.name,
    required this.apiUrl,
    this.imageUrl = '',
    this.tokenUrl = 'https://next.bgm.tv/demo/access-token',
  });

  final String name;
  final String apiUrl;
  final String imageUrl;
  final String tokenUrl;

  bool get isPreset =>
      bangumiPresetServers.any((server) => server.apiUrl == apiUrl);

  String resolveImageUrl(String url) {
    if (imageUrl.isEmpty || url.isEmpty) return url;
    final source = Uri.tryParse(url.startsWith('//') ? 'https:$url' : url);
    if (source == null || !source.hasAuthority) return url;
    final target = Uri.parse(imageUrl);
    if (source.origin == target.origin &&
        (target.path.isEmpty || source.path.startsWith('${target.path}/'))) {
      return source.toString();
    }
    return target
        .replace(
          path: '${target.path}${source.path}',
          query: source.hasQuery ? source.query : null,
          fragment: source.hasFragment ? source.fragment : null,
        )
        .toString();
  }

  Map<String, String> toJson() => {
    'name': name,
    'apiUrl': apiUrl,
    'imageUrl': imageUrl,
    'tokenUrl': tokenUrl,
  };

  static BangumiServer? fromJson(Object? value) {
    if (value is! Map || value['apiUrl'] is! String) return null;
    final apiUrl = normalizeBangumiUrl(value['apiUrl'] as String);
    if (apiUrl == null) return null;
    final rawImage = value['imageUrl'];
    final imageUrl = rawImage is String && rawImage.trim().isNotEmpty
        ? normalizeBangumiUrl(rawImage)
        : '';
    final rawToken = value['tokenUrl'];
    final tokenUrl = rawToken is String && rawToken.trim().isNotEmpty
        ? normalizeBangumiUrl(rawToken)
        : bangumiOfficialServer.tokenUrl;
    if (imageUrl == null || tokenUrl == null) return null;
    final rawName = value['name'];
    return BangumiServer(
      name: rawName is String && rawName.trim().isNotEmpty
          ? rawName.trim()
          : Uri.parse(apiUrl).host,
      apiUrl: apiUrl,
      imageUrl: imageUrl,
      tokenUrl: tokenUrl,
    );
  }
}

List<BangumiServer> get bangumiServers {
  final servers = {
    for (final server in bangumiPresetServers) server.apiUrl: server,
  };
  final custom = appdata.settings['bangumiCustomServers'];
  if (custom is List) {
    for (final value in custom) {
      final server = BangumiServer.fromJson(value);
      if (server != null) servers.putIfAbsent(server.apiUrl, () => server);
    }
  }
  return servers.values.toList();
}

BangumiServer get currentBangumiServer {
  final selected = appdata.settings['bangumiServer'];
  return bangumiServers.firstWhere(
    (server) => server.apiUrl == selected,
    orElse: () => bangumiOfficialServer,
  );
}

enum BangumiProbeStatus {
  available,
  timeout,
  verificationRequired,
  invalidResponse,
  unavailable,
}

class BangumiProbeResult {
  const BangumiProbeResult(
    this.status, {
    this.elapsed = Duration.zero,
    this.statusCode,
  });

  final BangumiProbeStatus status;
  final Duration elapsed;
  final int? statusCode;
}

typedef BangumiServerProbe =
    Future<BangumiProbeResult> Function(
      BangumiServer server,
      CancelToken cancelToken,
    );

Future<BangumiProbeResult> probeBangumiServer(
  BangumiServer server,
  CancelToken cancelToken, {
  Dio? dio,
  Duration timeout = const Duration(seconds: 5),
}) async {
  // Keep probes anonymous and uncached while using the app's proxy and DNS adapter.
  final client = dio ?? (Dio()..httpClientAdapter = RHttpAdapter());
  final clock = Stopwatch()..start();
  BangumiProbeResult result(BangumiProbeStatus status, [int? statusCode]) =>
      BangumiProbeResult(
        status,
        elapsed: clock.elapsed,
        statusCode: statusCode,
      );
  try {
    final response = await client
        .get<String>(
          '${server.apiUrl}/v0/subjects/2',
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'Accept': 'application/json'},
            validateStatus: (_) => true,
          ),
        )
        .timeout(
          timeout,
          onTimeout: () {
            cancelToken.cancel('Bangumi connection test timed out');
            throw TimeoutException('Bangumi connection test timed out');
          },
        );
    final body = response.data ?? '';
    if (response.headers.value('cf-mitigated') == 'challenge' ||
        (body.trimLeft().startsWith('<') &&
            body.toLowerCase().contains('anubis'))) {
      return result(
        BangumiProbeStatus.verificationRequired,
        response.statusCode,
      );
    }
    if (response.statusCode != 200) {
      return result(BangumiProbeStatus.unavailable, response.statusCode);
    }
    Object? data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      return result(BangumiProbeStatus.invalidResponse, response.statusCode);
    }
    return result(
      data is Map && data['id'] == 2 && data['name'] is String
          ? BangumiProbeStatus.available
          : BangumiProbeStatus.invalidResponse,
      response.statusCode,
    );
  } on TimeoutException {
    return result(BangumiProbeStatus.timeout);
  } on DioException catch (error) {
    if (CancelToken.isCancel(error)) rethrow;
    return result(switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => BangumiProbeStatus.timeout,
      _ => BangumiProbeStatus.unavailable,
    });
  } finally {
    clock.stop();
    if (dio == null) client.close(force: true);
  }
}
