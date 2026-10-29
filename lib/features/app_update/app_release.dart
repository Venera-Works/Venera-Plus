class AppReleaseAsset {
  const AppReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
  });

  final String name;
  final String url;

  /// Release web pages publish a digest but not an exact byte count.
  final int? size;
  final String? sha256;

  factory AppReleaseAsset.fromJson(Map<dynamic, dynamic> json) {
    final digest = json['digest'];
    return AppReleaseAsset(
      name: json['name'] as String,
      url: json['browser_download_url'] as String,
      size: json['size'] as int?,
      sha256: digest is String && digest.startsWith('sha256:')
          ? digest.substring(7).toLowerCase()
          : null,
    );
  }
}

class AppRelease {
  const AppRelease({
    required this.tag,
    required this.notes,
    required this.pageUrl,
    required this.assets,
  });

  final String tag;
  final String notes;
  final String pageUrl;
  final List<AppReleaseAsset> assets;

  String get version => tag.replaceFirst(RegExp(r'^[vV]'), '');

  factory AppRelease.fromJson(Map<dynamic, dynamic> json) {
    final tag = json['tag_name'];
    final pageUrl = json['html_url'];
    if (tag is! String ||
        tag.isEmpty ||
        pageUrl is! String ||
        pageUrl.isEmpty) {
      throw const FormatException('Invalid release information');
    }
    return AppRelease(
      tag: tag,
      notes: (json['body'] as String?)?.trim() ?? '',
      pageUrl: pageUrl,
      assets: [
        for (final asset
            in (json['assets'] as List? ?? const []).whereType<Map>())
          if (asset['state'] == null || asset['state'] == 'uploaded')
            AppReleaseAsset.fromJson(asset),
      ],
    );
  }

  AppReleaseAsset? _assetNamed(String name) {
    for (final asset in assets) {
      if (asset.name == name && (asset.size == null || asset.size! > 0)) {
        return asset;
      }
    }
    return null;
  }

  AppReleaseAsset? androidAssetFor(List<String> supportedAbis) {
    for (final abi in supportedAbis) {
      final asset = _assetNamed('VeneraPlus-$version-android-$abi.apk');
      if (asset != null) return asset;
    }
    return _assetNamed('VeneraPlus-$version-android.apk');
  }

  AppReleaseAsset? windowsAsset({required bool portable, bool arm64 = false}) {
    final platform = arm64 ? 'windows-arm64' : 'windows';
    final suffix = portable ? 'portable.zip' : 'installer.exe';
    return _assetNamed('VeneraPlus-$version-$platform-$suffix');
  }
}

AppRelease? selectAppRelease(
  Object? response, {
  required bool includePrerelease,
}) {
  if (response is! List && response is! Map) {
    throw const FormatException('Invalid release response');
  }
  final releases = response is List ? response : [response];
  AppRelease? latest;
  for (final release in releases.whereType<Map>()) {
    if (release['draft'] == true ||
        (!includePrerelease && release['prerelease'] == true)) {
      continue;
    }
    final candidate = AppRelease.fromJson(release);
    if (!includePrerelease && allowsPrereleaseAppUpdates(candidate.version)) {
      continue;
    }
    if (latest == null || _compareVersion(candidate.version, latest.version)) {
      latest = candidate;
    }
  }
  return latest;
}

bool allowsPrereleaseAppUpdates(String currentVersion) =>
    _prerelease(currentVersion) != null;

/// Stable installations only consider prereleases when explicitly included.
bool isNewerAppVersion(
  String remoteVersion,
  String currentVersion, {
  bool includePrerelease = false,
}) {
  if (!includePrerelease &&
      allowsPrereleaseAppUpdates(remoteVersion) &&
      !allowsPrereleaseAppUpdates(currentVersion)) {
    return false;
  }
  return _compareVersion(remoteVersion, currentVersion);
}

bool _compareVersion(String remoteVersion, String currentVersion) {
  final remote = _versionNumbers(remoteVersion);
  final current = _versionNumbers(currentVersion);
  final length = remote.length > current.length
      ? remote.length
      : current.length;
  for (var i = 0; i < length; i++) {
    final a = i < remote.length ? remote[i] : 0;
    final b = i < current.length ? current[i] : 0;
    if (a != b) return a > b;
  }
  return _comparePrerelease(
    _prerelease(remoteVersion),
    _prerelease(currentVersion),
  );
}

String _versionCore(String version) =>
    version.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;

List<int> _versionNumbers(String version) => _versionCore(version)
    .split('-')
    .first
    .split('.')
    .map((segment) => int.tryParse(segment) ?? 0)
    .toList();

String? _prerelease(String version) {
  final core = _versionCore(version);
  final index = core.indexOf('-');
  return index == -1 ? null : core.substring(index + 1);
}

bool _comparePrerelease(String? remote, String? current) {
  if (remote == null || current == null) {
    return remote == null && current != null;
  }
  final a = remote.split('.');
  final b = current.split('.');
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    if (i >= a.length) return false;
    if (i >= b.length) return true;
    final numberA = int.tryParse(a[i]);
    final numberB = int.tryParse(b[i]);
    if (numberA != null && numberB != null) {
      if (numberA != numberB) return numberA > numberB;
    } else if (numberA != null) {
      return false;
    } else if (numberB != null) {
      return true;
    } else {
      final comparison = a[i].compareTo(b[i]);
      if (comparison != 0) return comparison > 0;
    }
  }
  return false;
}
