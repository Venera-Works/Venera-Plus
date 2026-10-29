import 'package:flutter_test/flutter_test.dart';
import 'package:venera_plus/features/app_update/app_update.dart';

import 'fixtures.dart';

void main() {
  test('version checks preserve stable and prerelease update channels', () {
    expect(isNewerAppVersion('1.10.0-rc.2', '1.9.3'), isFalse);
    expect(allowsPrereleaseAppUpdates('1.9.3'), isFalse);
    expect(isNewerAppVersion('1.10.0-rc.2', '1.10.0-rc.1'), isTrue);
    expect(allowsPrereleaseAppUpdates('1.10.0-rc.1'), isTrue);
    expect(isNewerAppVersion('1.10.0', '1.9.3'), isTrue);
    expect(isNewerAppVersion('1.10.0', '1.10.0-rc.2'), isTrue);
    expect(isNewerAppVersion('v1.10.0+32', '1.10.0+31'), isFalse);
    expect(isNewerAppVersion('1.9.9', '1.10.0'), isFalse);
  });

  test('selects a complete release record within the update channel', () {
    final stable = releaseJson('v3.3.0', assets: [assetJson('android.apk')]);
    final beta = releaseJson('v3.4.0-rc.2', prerelease: true);
    final draft = releaseJson('v3.5.0', draft: true);
    for (final releases in [
      [stable, beta, draft],
      [draft, beta, stable],
    ]) {
      final release = selectAppRelease(releases, includePrerelease: false)!;
      expect(release.version, '3.3.0');
      expect(release.notes, contains('**New feature**'));
      expect(release.pageUrl, stable['html_url']);
      expect(release.assets.single.url, 'https://example.com/android.apk');
      expect(release.assets.single.sha256, 'abcdef');
      expect(
        selectAppRelease(releases, includePrerelease: true)!.tag,
        beta['tag_name'],
      );
    }
    expect(selectAppRelease([], includePrerelease: false), isNull);
    expect(selectAppRelease(stable, includePrerelease: false)!.tag, 'v3.3.0');
    expect(
      () => selectAppRelease('invalid', includePrerelease: false),
      throwsFormatException,
    );
    expect(
      () => selectAppRelease({'body': 'invalid'}, includePrerelease: false),
      throwsFormatException,
    );
  });

  test('Android chooses ABI preference before falling back to universal', () {
    AppRelease release(List<String> suffixes) => AppRelease.fromJson(
      releaseJson('v3.3.0', assets: suffixes.map(assetJson).toList()),
    );
    final all = release([
      'android.apk',
      'android-armeabi-v7a.apk',
      'android-arm64-v8a.apk',
      'android-x86_64.apk',
    ]);
    expect(
      all.androidAssetFor(['arm64-v8a', 'armeabi-v7a'])!.name,
      endsWith('-arm64-v8a.apk'),
    );
    expect(
      all.androidAssetFor(['x86_64', 'arm64-v8a'])!.name,
      endsWith('-x86_64.apk'),
    );
    expect(
      all.androidAssetFor(['armeabi-v7a'])!.name,
      endsWith('-armeabi-v7a.apk'),
    );
    expect(
      release(['android.apk']).androidAssetFor(['arm64-v8a'])!.name,
      endsWith('-android.apk'),
    );
    expect(
      release(['android-x86_64.apk']).androidAssetFor(['arm64-v8a']),
      isNull,
    );
  });

  test(
    'Windows keeps installer, portable and architecture assets distinct',
    () {
      final release = AppRelease.fromJson(
        releaseJson(
          'v3.3.0',
          assets: [
            assetJson('windows-arm64-installer.exe'),
            assetJson('windows-arm64-portable.zip'),
            assetJson('windows-installer.exe'),
            assetJson('windows-portable.zip'),
          ],
        ),
      );
      expect(
        release.windowsAsset(portable: false)!.name,
        'VeneraPlus-3.3.0-windows-installer.exe',
      );
      expect(
        release.windowsAsset(portable: true)!.name,
        'VeneraPlus-3.3.0-windows-portable.zip',
      );
      expect(
        release.windowsAsset(portable: false, arm64: true)!.name,
        contains('-windows-arm64-installer.exe'),
      );
      expect(
        release.windowsAsset(portable: true, arm64: true)!.name,
        contains('-windows-arm64-portable.zip'),
      );
    },
  );

  test(
    'in-progress uploads do not become downloadable installation assets',
    () {
      final release = AppRelease.fromJson(
        releaseJson(
          'v3.3.0',
          assets: [
            assetJson('android-arm64-v8a.apk', state: 'starter'),
            {...assetJson('windows-installer.exe'), 'size': 0},
          ],
        ),
      );
      expect(release.androidAssetFor(['arm64-v8a']), isNull);
      expect(release.windowsAsset(portable: false), isNull);
    },
  );
}
