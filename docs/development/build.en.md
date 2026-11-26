# Build and Development

Default Chinese version: [build.zh.md](build.zh.md)

This guide is for developers building, testing, or maintaining VeneraPlus (repository `Venera-Plus`) from source. For installation and usage, see the root [README](../../README.md).

## Prerequisites
> [!IMPORTANT]
> **Build Permission Notice**: Application builds are prohibited without explicit user permission. 


- FVM to manage the local project SDK
- Flutter `3.41.4`, pinned in the root `.fvmrc`
- Dart `3.11.1`, supplied by the pinned Flutter SDK; the language constraint in `pubspec.yaml` is `>=3.8.0 <4.0.0`
- JDK `17` for Android builds
- Rust `1.88.0`, pinned in `rust-toolchain.toml`; `rhttp` uses signed prebuilts without falling back to local Cargo compilation in application builds
- Native tooling for the target platform, such as Android SDK / NDK, Xcode, Visual Studio, or Linux GTK/WebKit dependencies
- Windows local builds require Developer Mode because the `pdfrx` native assets used by PDF import create symbolic links during the build

Bash examples apply to the corresponding native platform or CI runner. Local application builds and runs require explicit authorization. Archive final local deliverables under the root `dist/` directory; Flutter and packaging scripts retain intermediate files under `build/`.

Run local commands through FVM from the repository root. On first opening the project, create the SDK link and check the Flutter environment:

```bash
fvm use 3.41.4 --skip-pub-get
fvm flutter doctor -v
fvm flutter --version
```

Commit `.fvmrc`, but keep SDK links and caches under `.fvm/` out of version control. Point VS Code's `dart.flutterSdkPath` and Android Studio's Flutter SDK path to the project's `.fvm/flutter_sdk`. Android's `local.properties` is generated locally; do not commit machine-specific SDK paths.

Use `fvm exec` for scripts that invoke `flutter` or `dart` internally, for example `fvm exec python windows/build.py`. Scripts that build an application still require explicit user authorization.

## Dependencies

Clone the repository and resolve dependencies from its lock file:

```bash
git clone https://github.com/Venera-Works/Venera-Plus.git
cd Venera-Plus
fvm use 3.41.4 --skip-pub-get
fvm flutter pub get --enforce-lockfile
```

Use the repository's GitHub Releases page for installation packages and published versions. The current branch may contain unreleased features; see [CHANGELOG](../../CHANGELOG.md) for version differences.

Do not delete or regenerate `pubspec.lock` without understanding the dependency changes.

## OpenList core

This repository no longer compiles OpenList. After resolving Flutter dependencies, each platform build runs
`python3 .github/scripts/fetch_openlist_core.py <platform>` to download the fixed core; supported
platforms are `android`, `ios`, `macos-universal`, `windows-x64`, `linux-x64`, and `linux-arm64`.
The version, source commit, and asset digests are in `native/openlist_core/core.lock.json`. Release
a new Venera-OpenList-Core version first, verify all assets and licenses, then update the lock file
and run the application CI.

The current pin is `core-v0.1.0-beta.7` with RPC ABI `1`. The [core lockfile](../../native/openlist_core/core.lock.json) is authoritative for the version, source revision, and SHA-256 digests. The fetch script prepares native dependencies without starting the application or an OpenList HTTP service.

See [Dependency Governance](dependencies.en.md) for Git fork provenance, pinned commits, and upgrade requirements.

## Separate QuickJS Repository

`flutter_qjs` is maintained in [Venera-Works/Venera-flutter_qjs](https://github.com/Venera-Works/Venera-flutter_qjs).

## Precompiled rhttp native libraries

The repository is now `Venera-Works/Venera-rhttp`. The published `precompiled_a75ea2c9d25abac35a14b40d2261964a` configuration still uses the original download prefix in `cargokit.yaml`; GitHub redirects release and asset requests to the renamed repository. That prefix contributes to Cargokit's source identifier, so this rename preserves it and the matching lock and download-only patch. Changing it alone would make builds request an unpublished identifier. Publish the corresponding prebuilts before migrating that prefix and synchronizing application configuration.

`Venera-Works/Venera-rhttp` builds, signs, and releases the `rhttp` native libraries independently; its local checkout is `cache/Venera-rhttp`. The application's `native/prebuilts/rhttp/lock.json` pins the package archive digest, bridge version, and toolchain versions. `cargokit.yaml` pins the release URL, public key, and build arguments; `Cargo.toml` and `Cargo.lock` pin native dependencies. Keep all four files identical to the resource repository's `rhttp/` files.

After resolving Flutter dependencies, each platform CI runs `dart tool/prepare_rhttp_prebuilt.dart`. It checks `pubspec.lock`, configures the resolved `rhttp` package, and makes that package's Cargokit accept precompiled artifacts only. The subsequent build downloads artifacts by source hash and verifies their Ed25519 signatures. A missing target file or invalid signature fails the build instead of falling back to Cargo. Repeated preparation is idempotent; unexpected dependency source is rejected before modification.

Both preparation scripts apply the Cargo manifest and lockfile before computing the source hash. They pin the Rust bridge runtime and macros to upstream revision [`d59f05b6b0da3606933385f80cbd9e21cc35b59c`](https://github.com/fzyzcjy/flutter_rust_bridge/commit/d59f05b6b0da3606933385f80cbd9e21cc35b59c), retaining version `2.11.1` and the existing Dart bindings while fixing the `unwrap()` crash from callbacks returning after request cancellation. Publish the complete prebuilts for the new hash before building the application; old artifacts are not reused.

The current native configuration uses Rust `1.88.0` and security-patched dependencies for [`precompiled_a75ea2c9d25abac35a14b40d2261964a`](https://github.com/Venera-Works/Venera-rhttp/releases/tag/precompiled_a75ea2c9d25abac35a14b40d2261964a). `time 0.3.47` requires Rust `1.88.0` or later, so the application toolchain, CI preparation, and native configuration use the same version; FRB bindings remain at `2.11.1`. Prebuilt signature checks, application builds, and device runtime checks are separate acceptance steps. See [Dependency Governance](dependencies.en.md#critical-native-and-platform-dependency-boundaries) for the fixes.

The preparation script resolves Pub package URIs as directories, supporting absolute or relative URIs, an omitted trailing `/`, and paths containing spaces. Apple CI creates `~/.cargo/bin` before installing the Rustup wrapper and adds that directory to subsequent steps' `PATH` so Rustup installation operations are serialized during parallel plugin builds.

To prepare native dependencies locally, enter a PowerShell 7 subprocess through `fvm exec` before setting the project Pub cache and official package source. This preserves the shared package cache and prevents the `PUB_CACHE` change from affecting FVM's own startup:

```powershell
fvm exec pwsh -NoProfile -Command '
  $env:PUB_CACHE = Join-Path (Get-Location) ".pub-cache"
  $env:PUB_HOSTED_URL = "https://pub.dev"
  flutter pub get --enforce-lockfile
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  dart tool/prepare_rhttp_prebuilt.dart
  exit $LASTEXITCODE
'
```

The environment changes apply only to that subprocess. Use the same cache settings for later commands that may resolve dependencies again. Preparation output should contain the current release tag and `local Rust compilation is disabled`. Successful preparation establishes the package configuration and source hash; Cargokit performs the actual download and signature verification later. Preparation itself does not build the application.

Complete the matching prebuild release in the resource repository before building the application. Artifacts cover four Android ABIs (including x86 for Debug), Windows x64, Linux x64/ARM64, both macOS architectures, and iOS devices/simulators. On upgrade, synchronize both repositories' lock and configuration files, review the Cargokit source digests, and verify native bindings and networking. Application build permission requirements still apply.

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

## Startup timing diagnostics

Application log entries titled `Startup` measure time from the Dart entry point. Milestones are `First loading frame` (the Android loading screen), `Local app ready` (the first home or authorization frame), and `OpenList ready` (the native core and accounts are ready). Without OpenList accounts, the core is not started eagerly and its readiness milestone is omitted.

Entries for `Settings`, `Storage migrations`, databases, comic sources, and dictionaries report individual initialization durations. Concurrent durations must not be added together. Compare cold starts on the same device with the same data and build mode, including normal connectivity, offline operation, and expired accounts. Logs contain no account credentials. Use Android platform tools separately to measure engine startup before the Dart entry point.

Use CI artifacts for device comparisons. Local application builds and runs still require explicit user authorization.

## Quality Checks

Choose local checks for the affected scope and reuse valid results. For documentation changes, check links, examples, and `git diff --check`. Adjust the network adapter examples below to the changed Dart files and affected modules. Keep independent reference repositories under `cache/` out of analysis:

```bash
python .github/scripts/check_structure_imports.py
fvm dart tool/check_git_dependencies.dart
fvm dart format lib/network/app_dio.dart test/network/rhttp_adapter_test.dart
fvm dart format --output=none --set-exit-if-changed lib/network/app_dio.dart test/network/rhttp_adapter_test.dart
fvm flutter analyze --no-pub lib/network/app_dio.dart test/network/rhttp_adapter_test.dart
fvm flutter test --no-pub test/network/rhttp_adapter_test.dart
git diff --check
```

CI runs static checks and two Dart test shards in parallel. Test files matching `*_test.dart` are sorted by path and assigned alternately to the two shards. Each runs `flutter test --no-pub --coverage <shard file list>` so its runner loads only its assigned files, then uploads its coverage report. The `analyze` gate requires static checks and every shard to succeed, then merges hit counts by source file and line, recalculates line coverage, and publishes `coverage/lcov.info` in the workflow summary and the `dart-coverage` artifact. Coverage is currently a visible baseline rather than a repository-wide hard threshold. Changes to critical behavior still require focused tests.

Reader widget tests that use real SQLite should await `HistoryManager.flushReadingProgress()` through `runWidgetIo` in `test/widget_test_io.dart` (or an equivalent local helper) before bookmark operations or direct image-favorite queries. `pumpAndSettle()` settles Flutter frames; background isolate database writes must be awaited separately.

Reuse `test/support/sqlite.dart` for SQLite availability checks. Ordinary tests may skip according to their existing conditions when a native library is absent; strict platform smoke switches require real dependencies. After completion or cancellation, stop any surviving test, Dart, or Java child processes started for the checks.

WebDAV fixtures store directory and file keys as decoded logical paths. Decode once at HTTP ingress, and encode each segment when generating `PROPFIND` response `href` values. Path regressions should cover spaces, Unicode, literal percent signs, and case preservation to catch mismatched upload/listing paths and repeated percent decoding.

Use the following regression entry points by passing the test paths to `fvm flutter test --no-pub`:

| Module | Behavior to preserve | Tests |
|---|---|---|
| Application data sync | Unique snapshot filenames, numeric version ordering, distinct snapshots with the same version, version rollback after upload failure, batched real-time edits, and cleanup intervals | [data_sync_transfer_test.dart](../../test/features/sync/data_sync_transfer_test.dart), [app_data_transfer_test.dart](../../test/features/sync/app_data_transfer_test.dart), [data_sync_schedule_test.dart](../../test/features/sync/data_sync_schedule_test.dart) |
| History and image favorites | Notify sync after persistence; importing a snapshot does not trigger another upload | [history_sync_notifications_test.dart](../../test/features/history/history_sync_notifications_test.dart), [data_sync_transfer_test.dart](../../test/features/sync/data_sync_transfer_test.dart) |
| Reader | Accumulate rapid and reverse navigation targets, preserve split-page and comment boundaries, reduce waterfall refreshes, and cancel delayed callbacks on exit | [gallery_coordinator_test.dart](../../test/features/reader/gallery_coordinator_test.dart), [gallery_lifecycle_widget_test.dart](../../test/features/reader/gallery_lifecycle_widget_test.dart) |
| Local favorite filters | Reuse All-list results without history queries and retain only visible selections after filter changes | [local_favorites_filter_test.dart](../../test/features/favorites/local_favorites_filter_test.dart) |
| WebView and Cloudflare | Keep Windows proxy environments and cookies aligned, wait for valid page content, coalesce asynchronous checks, and leave replacement pages untouched after closure | [windows_webview_environment_test.dart](../../test/routing/windows_webview_environment_test.dart), [webview_lifecycle_test.dart](../../test/routing/webview_lifecycle_test.dart) |
| Cover transitions | Retain the Hero controller across navigation rebuilds and remove overlays after cancelled back gestures or navigator replacement | [navigation_hero_lifecycle_test.dart](../../test/components/navigation_hero_lifecycle_test.dart) |
| Remote libraries | Progressive discovery, asynchronous indexes, automatic refresh, and recovery after rate limiting | [remote_library_pipeline_test.dart](../../test/features/remote_library/remote_library_pipeline_test.dart), [remote_library_repository_test.dart](../../test/features/remote_library/remote_library_repository_test.dart), [remote_library_retry_lifecycle_test.dart](../../test/features/remote_library/remote_library_retry_lifecycle_test.dart) |

Sync still reads legacy snapshots, but every device sharing a directory must upgrade to recognize the new filenames; see [App Data Synchronization](../user/data_sync.en.md). WebView unit and widget tests use platform interface substitutes and do not replace Windows WebView2 checks with real proxy, login, and cookie behavior.

Pull requests also run `依赖安全审查` and `PR 平台冒烟构建`. Dependency review blocks newly introduced high or critical vulnerabilities. Changes to application code, native platforms, dependencies, build scripts, workflows, or native integration tests trigger Android and Windows Debug smoke builds. The workflow configuration remains the source of truth for exact triggers; documentation-only changes skip platform jobs.

After the Debug build, the Android PR job runs `:app:testDebugUnitTest --tests com.github.veneraworks.veneraplus.DownloadSessionStateTest`. JUnit executes `test/native/download_session_state_test.kt` to check download session generations, ownership, and progress bounds. Changes under `test/native/` also trigger platform jobs. The Windows PR job configures and compiles `windows/tests/` against the existing Debug build's Flutter engine library, then runs startup and global hotkey tests through CTest. Missing tests or test failures fail the gate.

After the existing Windows Debug build, the PR job checks `flutter_qjs_plugin.dll`, `zip_flutter.dll`, and `flutter_windows.dll`, adds the runner directory to `PATH`, and runs native ZIP, source transaction and metadata probing tests, plus QuickJS WebSocket, Gzip, Comment, image script, and source callback bridge cases with `CI_REQUIRE_QUICKJS=true` and `CI_REQUIRE_NATIVE_ZIP=true`. Changes to any test file listed below also trigger platform validation:

```powershell
fvm flutter test --no-pub --reporter=expanded `
  --dart-define=CI_REQUIRE_QUICKJS=true --dart-define=CI_REQUIRE_NATIVE_ZIP=true `
  --name 'App data transfer with native ZIP|ComicSourceParser\.probeKey metadata sandboxing|source runtime transactions|SourceFileMetadata|QuickJS|ComicSourceParser (detects comic\.updateReadProgress|bridges comic\.onImageLoad)' `
  test/features/sync/app_data_transfer_test.dart `
  test/features/comic_source/source_parser_test.dart `
  test/features/comic_source/source_lifecycle_test.dart `
  test/features/comic_source/source_files_test.dart `
  test/features/comic_source/comic_source_save_test.dart `
  test/foundation/js_engine_test.dart `
  test/foundation/image_processing_test.dart
```

The strict switches require real native libraries and fail when they are missing. Do not trigger a native build locally to run these tests; use read-only validation only when compatible DLLs and native assets already exist.

The Windows PR job also runs `test/integration/rhttp_callback_smoke.dart` against the existing bundled `rhttp.dll`. A local HTTP server delays a response callback until after cancellation, verifying process survival, cancellation semantics, and a complete response to a subsequent request. Run it directly against an existing DLL without starting the application:

```powershell
fvm dart --packages=.dart_tool/package_config.json test/integration/rhttp_callback_smoke.dart build/windows/x64/runner/Debug/rhttp.dll
```

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

CI formatting checks cover `lib`, `test`, and `tool`. Workflows run the checks above; required merge checks and branch-deletion restrictions are configured separately through GitHub branch protection or rulesets and cannot be confirmed from repository files alone.

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
fvm flutter pub get --enforce-lockfile
fvm flutter build apk --release
```

Do not add `--no-pub` to Android Release builds on Flutter 3.41.4: this flag also skips regenerating plugin registration code for Release mode, which can leave `GeneratedPluginRegistrant.java` referencing `integration_test` that has already been excluded from the release compilation. Keep the preceding lockfile check; the shared Android Release build verifies that `pubspec.lock` remains unchanged after building. See [Flutter #163774](https://github.com/flutter/flutter/issues/163774).

Artifacts are normally written to `build/app/outputs/apk/release/`.

Signing files and passwords are sensitive and must not be committed.

## Desktop and iOS Builds

With the native toolchain installed on the corresponding operating system, run:

```bash
fvm flutter pub get --enforce-lockfile
fvm flutter build windows --no-pub
fvm flutter build linux --no-pub
fvm flutter build macos --no-pub
```

The Windows packaging script `windows/build.py` defaults `CMAKE_BUILD_PARALLEL_LEVEL` to the CPU count, enabling project-level parallel builds in CMake/MSBuild. Set the environment variable explicitly to override this default.

Use a no-codesign build to validate iOS first:

```bash
fvm flutter pub get --enforce-lockfile
fvm flutter build ios --release --no-codesign --no-pub
```

macOS and iOS CI use the ARM64 Flutter SDK on ARM64 runners. iOS CI creates `~/.cargo/bin` before installing the serialized Rustup wrapper and adds it to `PATH` for subsequent steps, supporting macOS runners where the directory is absent. Prerelease builds set the iOS package version with `--build-name` and `--build-number`, preserving the full Beta version in `pubspec.yaml` for the app to read.

macOS CI runs `flutter build macos --release --no-pub` once to produce a Universal app. `.github/scripts/package_macos_dmg.py` thins the app for each architecture and checks its binaries, then re-signs the app from the inside out. It signs the outer app with the Release entitlements and verifies the signatures in strict mode. CI produces exactly two DMGs, `VeneraPlus-<version>-macos-arm64.dmg` (Apple Silicon) and `VeneraPlus-<version>-macos-x86_64.dmg` (Intel). The version comes from `pubspec.yaml` with the `+build` suffix removed.

### Linux Debian Packaging

Linux Debian packages are built using the host system `dpkg-deb` utility and the project script `debian/build.py`:

```bash
fvm flutter build linux --release --no-pub
fvm exec python debian/build.py x64 --skip-build
```

The required architecture argument is `x64` or `arm64` and must match the existing release bundle; replace `x64` with `arm64` for ARM64 packaging. Packages are written to `build/linux/{x64,arm64}/release/debian/`; archive local deliverables under `dist/`. This replaces `flutter_to_debian` without a global Git packaging tool.

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

Maintain daily changes only under Unreleased in `CHANGELOG.md`. Archive them under the matching version during release, preserving published entries. Formal releases also update the root README version and download links; Beta descriptions start with the warning required by `AGENTS.md`.

The `代码分析` workflow runs version and structure checks, Python script tests, Dart formatting checks across `lib`, `test`, and `tool` (covering subdirectories), `flutter analyze`, the full Dart test suite, and coverage reporting. `依赖安全审查` checks dependencies added or upgraded by a pull request, while `PR 平台冒烟构建` verifies Android and Windows compilation as well as native database integration test scenarios when the changed files can affect platform builds; it can also be dispatched manually to validate a released core.

`构建` (`.github/workflows/build.yml`) provides both manual platform selection and a reusable workflow, sharing build steps, artifact validation, and Actions artifact uploads for Android, Windows, macOS, iOS, and Linux x64/ARM64. Manual runs select Android and Windows by default. Ordinary manual builds upload the four Android APK variants, the Windows installer EXE and complete portable ZIP, and the two macOS DMGs as individual files. Artifact names use the complete filenames, and artifacts are retained for seven days. A temporary Android signing key is generated when release signing credentials are absent.

`完整构建` (`.github/workflows/main.yml`) validates release metadata, prepares the Release, and handles completion, calling the shared workflow with the internal `release_mode: true` input. It builds Android, Windows, macOS, iOS, and Linux x64/ARM64 by default. Release mode groups Android packages in `apks`, Windows packages in `windows_build`, and both macOS DMGs in `macos_build`. The corresponding jobs download and validate these files before uploading them to the Release. Release builds require Android release signing credentials and fail when they are absent. Actions artifacts used for Release uploads follow the repository's default retention period.

Only pushes of `v*` tags create or resume a prerelease and upload Release assets. Each Release asset upload job in the shared workflow depends only on its corresponding build, allowing assets to appear as platforms finish. `完整构建` completes the Release only after every required build and upload succeeds; otherwise it marks the build as incomplete. Manual runs of `完整构建` still require a valid release tag and only produce Actions artifacts. Release mode does not automatically cancel running builds; ordinary manual builds continue to cancel superseded runs.

The current `main.yml` dependency chain is release metadata → Release preparation → shared builds → Release finalization. It does not explicitly depend on quality results from `analyze.yml`. The quality workflow and a successful tag build are separate results.

Native CI build jobs configure compilation and dependency caching: `sccache` caches Rust on native jobs and C/C++ on supported Linux CMake generator paths (the Windows C/C++ wrapper was intentionally not retained), Cargo caches registry and Git downloads, and Android jobs reuse the Gradle build cache. Jobs print statistics via `sccache --show-stats` upon completion to verify warm-cache hits. Final release packages and installers are always rebuilt and are never reused from cache.

Android release workflows require these repository Secrets:

- `ANDROID_KEYSTORE`: Base64 content of the keystore file
- `ANDROID_KEY_PROPERTIES`: text content of `key.properties`

As an independent VeneraPlus project under Venera-Works (repository `Venera-Plus`), upstream AltStore release automation, repository metadata, and pull-request generation have been completely removed. This repository does not provide a public AltStore source.

AI issue checking is disabled by default. After confirming that `API_URL` and `API_KEY` work, set the repository variable `ENABLE_AI_ISSUE_CHECK` to `true`; `ISSUE_CHECK_MODEL` can override the default model. The workflow posts summaries and close recommendations only and never closes an issue automatically.

Never put Secrets, signing files, or real passwords in code, logs, or documentation examples.

## Troubleshooting

### Startup reports that configuration and backups cannot be loaded

Startup tries `appdata.json`, `appdata.json.bak`, and `syncdata.json` in the application data directory. A valid copy still restores configuration. If existing copies all fail to load or validate, the app shows the startup failure page and preserves the files instead of continuing and saving defaults. A first installation without any of these files initializes normally.

Keep existing files and inspect the failed field in the logs, then restore a verified backup before retrying. Retain any `appdata.json.corrupt-*` files incorrectly marked by an earlier version for inspection; the fix does not automatically overwrite current settings with historical files. Brightness accepts both legacy integer and current fractional values.

### The Build Succeeds but the App Has No Network Access

First confirm that `flutter_rust_bridge` is still `2.11.1` and that dependencies were resolved from the current repository `pubspec.lock`. Do not blindly upgrade dependencies to address initialization failures.

### `flutter_rust_bridge has not been initialized`

This usually means dependency versions have drifted. Restore the repository `pubspec.lock`, confirm the required Flutter version, and run:

```bash
fvm flutter pub get --enforce-lockfile
```

### `Unable to satisfy pubspec.yaml using pubspec.lock`

The Flutter/Dart version or package-source environment usually does not match. Check the Flutter version required by this guide and the output of `fvm flutter doctor -v`; do not immediately delete the lock file.

The repository lock file uses `https://pub.dev`. If `PUB_HOSTED_URL` points to another mirror, temporarily align it in a PowerShell child process using the project SDK. Keep `--enforce-lockfile` and preserve the lock file:

```powershell
fvm exec pwsh -NoProfile -Command '
  $env:PUB_HOSTED_URL = "https://pub.dev"
  flutter pub get --enforce-lockfile
  exit $LASTEXITCODE
'
```

### Slow Gradle Downloads

You may temporarily use a local Gradle wrapper mirror or configure a network proxy. Environment-specific URLs must not be committed. Before submitting changes, verify that `gradle-wrapper.properties` does not contain local mirror edits.

## Logs and startup diagnostics

Logs append to `logs.txt` in the application data directory (Android prefers the application external storage directory). Common authentication, Cookie, token and password fields are redacted before output. At approximately 2 MiB, the file rotates to `logs.previous.txt`, retaining the current and previous files. Early startup logs are replayed, and normal exit and log export await pending writes. Force-stop may lose records not yet written. The startup failure page offers a stage, redacted error details and copying; Android retains its retry action.

The Windows global hide/restore shortcut is under “Settings → Appearance and Interface → Window” and is disabled by default. Its `windows_hotkey.json` configuration stays in the application data directory and is excluded from application data exports and synchronization. Press the shortcut again or launch the application to recover the main window.
