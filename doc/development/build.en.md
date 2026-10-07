# Build and Development

Default Chinese version: [build.zh.md](build.zh.md)

This guide is for developers building, testing, or maintaining VeneraPlus (repository `Venera-Plus`) from source. For installation and usage, see the root [README](../../README.md).

## Prerequisites
> [!IMPORTANT]
> **Build Permission Notice**: Application builds (including `flutter build`, `flutter run`, Gradle/CMake/MSBuild compilation, packaging entry points, and tests that implicitly compile) are prohibited without explicit user permission. Only code modifications and non-building static checks are permitted without authorization.


- Flutter `3.41.4`
- Dart `>=3.8.0 <4.0.0`
- JDK `17` for Android builds
- A Rust toolchain; Android builds require the corresponding Android targets
- Native tooling for the target platform, such as Android SDK / NDK, Xcode, Visual Studio, or Linux GTK/WebKit dependencies
- Windows local builds require Developer Mode because the `pdfrx` native assets used by PDF import create symbolic links during the build

Check the Flutter environment first:

```bash
flutter doctor -v
flutter --version
```

## Dependencies

Clone the repository and resolve dependencies from its lock file:

```bash
git clone https://github.com/Venera-Works/Venera-Plus.git
cd Venera-Plus
flutter pub get --enforce-lockfile
```

> **Note**: The official repository is currently public on GitHub (previously set to private where unauthenticated API requests returned 404); cloning and fetching code is publicly accessible. Official installation packages and releases are subject to the actual state on GitHub Releases; do not infer release status or public update availability solely from source branches.

Do not delete or regenerate `pubspec.lock` without understanding the dependency changes.

See [Dependency Governance](dependencies.en.md) for Git fork provenance, pinned commits, and upgrade requirements.

### Critical Version Pin

The project uses `rhttp 0.15.1` and must keep `flutter_rust_bridge 2.11.1`. With an incompatible version, a build may succeed while the resulting application cannot access the network and reports:

```text
flutter_rust_bridge has not been initialized
```

Check the pinned version in PowerShell:

```powershell
Select-String pubspec.lock -Pattern "flutter_rust_bridge" -Context 0,6
```

The result must include:

```yaml
version: "2.11.1"
```

## Quality Checks

Run at least the following before submitting code:

```bash
python .github/scripts/check_structure_imports.py
dart tool/check_git_dependencies.dart
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

CI runs `flutter test --coverage`, publishes line coverage in the workflow summary, and uploads `coverage/lcov.info`. Coverage is currently a visible baseline rather than a repository-wide hard threshold. Changes to critical behavior still require focused tests.

Pull requests also run `依赖安全审查` and `PR 平台冒烟构建`. Dependency review blocks newly introduced dependencies with high or critical vulnerabilities. When changes touch app code, native platform directories, dependencies, build scripts, workflows, or native tests under `test/integration/`, `test/driver/`, `test/features/sync/legacy_sync_reader_test.dart`, or `test/features/sync/source_identity_recovery_test.dart`, the platform workflow runs Android Debug (arm64 compilation gate and x86_64 emulator native integration testing) and Windows Debug (application build, QuickJS source migration and identity recovery tests, real startup smoke script, and native integration testing). CI change detection precisely matches these two native test directories and the specific source test files rather than expanding to all `test/` paths; documentation-only changes skip these platform jobs.

Legacy sync archive migration and source identity recovery tests separate SQLite favorite/history schema migration from comic source script execution that requires QuickJS. When the native QuickJS library is unavailable in standard `flutter test --coverage`, only the respective native groups (`LegacySyncReader QuickJS Source Migration` and `SourceIdentityRecovery QuickJS`) are skipped; database migration still runs independently. After the existing Debug build, the Windows PR platform job checks `flutter_qjs_plugin.dll` and `flutter_windows.dll`, adds the artifact directory to `PATH`, and runs `flutter test --no-pub --reporter=expanded --dart-define=CI_REQUIRE_QUICKJS=true --name 'LegacySyncReader QuickJS Source Migration|SourceIdentityRecovery QuickJS' test/features/sync/legacy_sync_reader_test.dart test/features/sync/source_identity_recovery_test.dart`. This strict switch requires the real native runtime and fails instead of skipping when it is missing. The groups cover computed-key script/session migration, normalization of identical aliases to canonical files while preserving logical names and sessions, differing same-key contents persisting as durable conflict candidates across restart without resurrection, aborting unproven destructive applies, and authentic Windows `CreateFileW` sharing violation recovery where failed old-file deletion retains the journal and recovers cleanly without duplicate-key errors, without adding an application build step.

Native integration test scenarios and host drivers are consolidated under `test/`: `test/integration/platform_smoke.dart` serves as the test scenario entry, while `test/driver/platform_smoke_driver.dart` serves as the shared host-side driver. To prevent accidental discovery and coverage collection by standard `flutter test --coverage`, both entry files intentionally omit the `_test.dart` suffix. The legacy root `integration_test/` and `test_driver/` directories have been removed without compatibility shims.

Because Flutter 3.41.4 device integration test recognition in `flutter test` hardcodes the root `integration_test/` directory, both platforms must use `flutter drive` with explicit `--driver=...` and `--target=...` options after the relocation (Windows can no longer run via `flutter test -d windows`). Running native smoke tests requires the explicit safety switch `--dart-define=CI_NATIVE_SMOKE=true`, which is strictly restricted to disposable CI runners; running them in local environments is discouraged.

Within an isolated temporary directory, the suite validates SQLite native loading, background isolates, legacy schema migrations, transaction writes, reopen persistence, and authentic backup/restore. It then starts authentic `MyApp` initialization and the home page, clicks the main navigation Library icon (located by icon in compact navigation), waits for layout refresh before clicking Reading Records to reach the authentic history records view, and verifies database-seeded history titles in the disposable runner profile, asserting that no uncaught exceptions occurred.

Both platforms transmit screenshot Base64 data and host output paths via `binding.reportData` to the shared host driver, which strictly validates PNG signatures and positive dimensions before writing to disk; the Windows application no longer writes screenshot files directly. Artifact output defaults to `build/smoke-artifacts/android_smoke.png` on Android and `build/smoke-artifacts/smoke_rendered_frame.png` on Windows (Windows CI additionally specifies an absolute directory via `SMOKE_ARTIFACT_DIR`).

Explicit copyable `flutter drive` commands for disposable runner environments:

Android (with emulator ready):

```bash
flutter drive \
  --driver=test/driver/platform_smoke_driver.dart \
  --target=test/integration/platform_smoke.dart \
  -d emulator-5554 \
  --dart-define=CI_NATIVE_SMOKE=true
```

Windows (PowerShell, `--timeout` is in seconds, so 900 specifies 15 minutes):

```powershell
$smokeDir = (Join-Path (Get-Location) 'build\smoke-artifacts')
New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null
flutter drive --driver=test/driver/platform_smoke_driver.dart --target=test/integration/platform_smoke.dart -d windows "--dart-define=CI_NATIVE_SMOKE=true" "--dart-define=SMOKE_ARTIFACT_DIR=$smokeDir" --timeout 900
```

Dart formatting checks cover `lib` and `test` (recursively covering all subdirectories). The `main` branch requires code analysis, dependency review, and the platform smoke-build gate to pass, and direct force-pushes or branch deletion are disabled.

For release-related changes, also run:

```bash
python .github/scripts/release_version.py --check
```

See [Project Structure](../architecture/project_structure.en.md) for module boundaries and entry-point rules.

## Android Build

Place local release signing files at:

```text
android/keystore.jks
android/key.properties
```

Example `android/key.properties`:

```properties
storePassword=your store password
keyPassword=your key password
keyAlias=your key alias
storeFile=../keystore.jks
```

Build the APK:

```bash
flutter pub get --enforce-lockfile
flutter build apk --release
```

Do not add `--no-pub` to Android Release builds on Flutter 3.41.4: this flag also skips regenerating plugin registration code for Release mode, which can leave `GeneratedPluginRegistrant.java` referencing `integration_test` that has already been excluded from the release compilation. Keep the preceding lockfile check; both Android Release workflows verify that `pubspec.lock` remains unchanged after building. See [Flutter #163774](https://github.com/flutter/flutter/issues/163774).

Artifacts are normally written to `build/app/outputs/apk/release/`.

Signing files and passwords are sensitive and must not be committed.

## Desktop and iOS Builds

With the native toolchain installed on the corresponding operating system, run:

```bash
flutter pub get --enforce-lockfile
flutter build windows --no-pub
flutter build linux --no-pub
flutter build macos --no-pub
```

Use a no-codesign build to validate iOS first:

```bash
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub
```

### Linux Debian Packaging

Linux Debian packages are built using the host system `dpkg-deb` utility and the project script `debian/build.py`:

```bash
flutter build linux --release --no-pub
python debian/build.py --skip-build
```

Built packages are placed in `build/linux/{x64,arm64}/release/debian/`. This approach replaces the legacy `flutter_to_debian` dependency and avoids global Git package activation.

The release workflow builds the Windows installer and portable package; this repository does not maintain winget manifests or public package-manager entries.
## GitHub Actions and Release Versions

Repository workflows handle continuous integration, manual builds, tag releases, and distribution metadata. The release version is maintained centrally in `release.json`:

```json
{
  "version": "1.2.3",
  "build": 123
}
```

Before a release, update `release.json`, then synchronize and validate related files:

```bash
python .github/scripts/release_version.py --write
python .github/scripts/release_version.py --check --tag v1.2.3
```

`pubspec.yaml`, the release tag, and the version section in `CHANGELOG.md` must match `release.json`.

The `代码分析` workflow runs version and structure checks, Python script tests, Dart formatting checks across `lib` and `test` (covering subdirectories), `flutter analyze`, the full Dart test suite, and coverage reporting. `依赖安全审查` checks dependencies added or upgraded by a pull request, while `PR 平台冒烟构建` verifies Android and Windows compilation as well as native database integration test scenarios when the changed files can affect platform builds. Before starting multi-platform builds, `完整构建` reuses the same quality workflow. Manual platform builds and tag releases both reuse `.github/workflows/build.yml` so their build definitions cannot drift apart.

Native CI build jobs configure compilation and dependency caching: `sccache` caches Rust on native jobs and C/C++ on supported Linux CMake generator paths (the Windows C/C++ wrapper was intentionally not retained), Cargo caches registry and Git downloads, and Android jobs reuse the Gradle build cache. Jobs print statistics via `sccache --show-stats` upon completion to verify warm-cache hits. Final release packages and installers are always rebuilt and are never reused from cache.

Android release workflows require these repository Secrets:

- `ANDROID_KEYSTORE`: Base64 content of the keystore file
- `ANDROID_KEY_PROPERTIES`: text content of `key.properties`

As an independent VeneraPlus project under Venera-Works (repository `Venera-Plus`), upstream AltStore release automation, repository metadata, and pull-request generation have been completely removed. This repository does not provide a public AltStore source.

AI issue checking is disabled by default. After confirming that `API_URL` and `API_KEY` work, set the repository variable `ENABLE_AI_ISSUE_CHECK` to `true`; `ISSUE_CHECK_MODEL` can override the default model. The workflow posts summaries and close recommendations only and never closes an issue automatically.

Never put Secrets, signing files, or real passwords in code, logs, or documentation examples.

## Troubleshooting

### The Build Succeeds but the App Has No Network Access

First confirm that `flutter_rust_bridge` is still `2.11.1` and that dependencies were resolved from the current repository `pubspec.lock`. Do not blindly upgrade dependencies to address initialization failures.

### `flutter_rust_bridge has not been initialized`

This usually means dependency versions have drifted. Restore the repository `pubspec.lock`, confirm the required Flutter version, and run:

```bash
flutter pub get --enforce-lockfile
```

### `Unable to satisfy pubspec.yaml using pubspec.lock`

The Flutter/Dart version or package-source environment usually does not match. Check the Flutter version required by this guide and the output of `flutter doctor -v`; do not immediately delete the lock file.

### Slow Gradle Downloads

You may temporarily use a local Gradle wrapper mirror or configure a network proxy. Environment-specific URLs must not be committed. Before submitting changes, verify that `gradle-wrapper.properties` does not contain local mirror edits.
