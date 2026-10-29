import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:venera_plus/network/app_dio.dart';

import 'app_release.dart';
import 'github_release_page.dart';

class AppUpdateService {
  AppUpdateService({
    Dio? client,
    this.channel = const MethodChannel('venera/app_update'),
    Future<Directory> Function()? temporaryDirectory,
  }) : _client =
           client ??
           (Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
             ),
           )..httpClientAdapter = RHttpAdapter()),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final Dio _client;
  final MethodChannel channel;
  final Future<Directory> Function() _temporaryDirectory;
  Future<void> _downloadTail = Future<void>.value();
  DateTime? _apiRetryAt;

  Future<AppRelease?> check(String currentVersion) async {
    final includePrerelease = allowsPrereleaseAppUpdates(currentVersion);
    if (_apiRetryAt?.isAfter(DateTime.now()) ?? false) {
      return _checkReleasePage(currentVersion, includePrerelease);
    }
    try {
      return await _checkApi(currentVersion, includePrerelease);
    } on DioException catch (error) {
      final response = error.response;
      final status = response?.statusCode;
      final limited =
          status == 429 ||
          (status == 403 &&
              (response?.headers.value('x-ratelimit-remaining') == '0' ||
                  response?.data.toString().toLowerCase().contains(
                        'rate limit',
                      ) ==
                      true));
      if (!limited) rethrow;
      final retryAfter = int.tryParse(
        response?.headers.value('retry-after') ?? '',
      );
      final reset = int.tryParse(
        response?.headers.value('x-ratelimit-reset') ?? '',
      );
      final now = DateTime.now();
      final resetAt = reset == null
          ? now
          : DateTime.fromMillisecondsSinceEpoch(reset * 1000);
      _apiRetryAt = retryAfter != null
          ? now.add(Duration(seconds: retryAfter))
          : resetAt.isAfter(now)
          ? resetAt
          : now.add(const Duration(minutes: 1));
      return _checkReleasePage(currentVersion, includePrerelease);
    }
  }

  Future<AppRelease?> _checkApi(
    String currentVersion,
    bool includePrerelease,
  ) async {
    final response = await _client.get<dynamic>(
      includePrerelease
          ? 'https://api.github.com/repos/Venera-Works/Venera-Plus/releases?per_page=20'
          : 'https://api.github.com/repos/Venera-Works/Venera-Plus/releases/latest',
      options: Options(headers: {'Accept': 'application/vnd.github+json'}),
    );
    final data = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    final release = selectAppRelease(
      data,
      includePrerelease: includePrerelease,
    );
    return release != null && isNewerAppVersion(release.version, currentVersion)
        ? release
        : null;
  }

  Future<AppRelease?> _checkReleasePage(
    String currentVersion,
    bool includePrerelease,
  ) async {
    final options = Options(
      responseType: ResponseType.plain,
      headers: {'Accept': 'text/html'},
    );
    final response = await _client.get<String>(
      includePrerelease ? githubReleaseBase : '$githubReleaseBase/latest',
      options: options,
    );
    final release = parseGitHubReleasePage(
      response.data!,
      includePrerelease: includePrerelease,
    );
    if (release == null ||
        !isNewerAppVersion(release.version, currentVersion)) {
      return null;
    }
    final assets = await _client.get<String>(
      '$githubReleaseBase/expanded_assets/${Uri.encodeComponent(release.tag)}',
      options: options,
    );
    return AppRelease(
      tag: release.tag,
      notes: release.notes,
      pageUrl: release.pageUrl,
      assets: parseGitHubReleaseAssets(assets.data!, release),
    );
  }

  Future<List<String>> supportedAbis() async =>
      await channel.invokeListMethod<String>('supportedAbis') ?? const [];

  Future<bool> requestInstallPermission() async =>
      await channel.invokeMethod<bool>('requestInstallPermission') ?? false;

  Future<void> installApk(File file) =>
      channel.invokeMethod<void>('install', file.path);

  Future<File> downloadApk(
    AppReleaseAsset asset, {
    required CancelToken cancelToken,
    required ProgressCallback onProgress,
  }) {
    // Wait for canceled transfers to close their files before reusing this path.
    final download = _downloadTail.then(
      (_) => _downloadApk(asset, cancelToken, onProgress),
    );
    _downloadTail = download.then<void>((_) {}, onError: (Object _) {});
    return download;
  }

  Future<File> _downloadApk(
    AppReleaseAsset asset,
    CancelToken cancelToken,
    ProgressCallback onProgress,
  ) async {
    if (p.basename(asset.name) != asset.name || !asset.name.endsWith('.apk')) {
      throw const FormatException('Invalid APK filename');
    }
    final directory = Directory(
      p.join((await _temporaryDirectory()).path, 'app_updates'),
    );
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, asset.name));
    _checkCanceled(cancelToken);
    if (await file.exists()) {
      if (await _isValid(file, asset)) {
        _checkCanceled(cancelToken);
        final size = asset.size ?? await file.length();
        onProgress(size, size);
        return file;
      }
      await file.delete();
    }

    final partial = File('${file.path}.part');
    int? expectedSize = asset.size;
    try {
      await _client.download(
        asset.url,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) expectedSize ??= total;
          onProgress(received, expectedSize ?? 0);
        },
      );
      _checkCanceled(cancelToken);
      if (!await _isValid(partial, asset, expectedSize: expectedSize)) {
        throw const FormatException(
          'The downloaded APK is incomplete or its checksum does not match',
        );
      }
      _checkCanceled(cancelToken);
      return await partial.rename(file.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<bool> _isValid(
    File file,
    AppReleaseAsset asset, {
    int? expectedSize,
  }) async {
    final size = expectedSize ?? asset.size;
    final actualSize = await file.length();
    if (actualSize <= 0 || (size != null && actualSize != size)) return false;
    final expectedDigest = asset.sha256;
    if (size == null && expectedDigest == null) return false;
    return expectedDigest == null ||
        (await sha256.bind(file.openRead()).first).toString() == expectedDigest;
  }

  void _checkCanceled(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
  }
}
