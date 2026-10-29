import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:venera_plus/network/app_dio.dart';

import 'app_release.dart';

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

  Future<AppRelease?> check(String currentVersion) async {
    final includePrerelease = allowsPrereleaseAppUpdates(currentVersion);
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
        onProgress(asset.size, asset.size);
        return file;
      }
      await file.delete();
    }

    final partial = File('${file.path}.part');
    try {
      await _client.download(
        asset.url,
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, _) => onProgress(received, asset.size),
      );
      _checkCanceled(cancelToken);
      if (!await _isValid(partial, asset)) {
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

  Future<bool> _isValid(File file, AppReleaseAsset asset) async {
    if (asset.size <= 0 || await file.length() != asset.size) return false;
    final expectedDigest = asset.sha256;
    return expectedDigest == null ||
        (await sha256.bind(file.openRead()).first).toString() == expectedDigest;
  }

  void _checkCanceled(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
  }
}
