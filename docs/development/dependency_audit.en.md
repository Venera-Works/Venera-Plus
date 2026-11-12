# Git Dependency Management and Replacement Audit (2026-09-30)

中文版本：[dependency_audit.zh.md](dependency_audit.zh.md) · [Governance](dependencies.en.md) · [Machine-Readable Inventory](git_dependencies.json)

This document records the provenance review, customization rationale, and maintenance responsibilities for VeneraPlus's current Git dependencies. The complete commit SHAs, repository URLs, package paths, and statuses are maintained in the machine-readable inventory `docs/development/git_dependencies.json`.

## Completed Governance Changes

- **Removal of `flutter_to_debian`**: Debian packaging has been replaced with the standalone `debian/build.py` script that invokes the host system `dpkg-deb` utility directly, outputting to `build/linux/{x64,arm64}/release/debian`. The transitive dependency `mime_type`, used exclusively by the old package, was removed. CI no longer requires `dart pub global activate -s git flutter_to_debian`.
- **Machine-Readable Inventory and Automated Checker**: Added `docs/development/git_dependencies.json` and `tool/check_git_dependencies.dart`. The code analysis workflow runs this checker after locked dependencies are retrieved, strictly verifying URLs, refs, resolved refs, package paths, and lockfile consistency for all direct and transitive Git packages.
- **Clear Provenance and Responsibility Boundaries**: This project maintains its own dependency strategy and `VeneraPlus` independent project identity (repository `Venera-Plus`), preserving `venera-app` repository URLs with pinned commits. The `maintained-fork` label in the inventory indicates retained custom branches rather than external maintenance by this project; the maintainers of this project are responsible for pin review and runtime compatibility.

## Review Findings for Each Git Dependency

| Dependency | Upstream & Revision | Status & Replacement Criteria |
|---|---|---|
| `flutter_qjs` | `venera-app/flutter_qjs` (`8feae95`) | Migrated to QuickJS-NG, fixes JS numeric/NaN conversions, platform build fixes. Retain custom branch; replacement requires verifying runtime lifetimes, promises, and cross-platform native builds. |
| `photo_view` | `venera-app/photo_view` (`a1255d1`) | Reader depends on custom `getInitialScale` and gesture/animation extensions absent from upstream. Retain custom branch; replacement requires re-adapting reader zooming, dual pages, and auto-reading. |
| `scrollable_positioned_list` | `venera-app/flutter.widgets` (`09e756b`) | Provides reader-specific `scrollControllerCallback` and `scrollBehavior` support. Retain custom branch; replacement requires verifying long-chapter jumping and scroll synchronization. |
| `desktop_webview_window` | `venera-app/flutter_desktop_webview` (`7801fc5`) | Desktop proxy, Linux libsoup, and Windows ARM64 patches. Retained under `license-review`; requires provenance clarification before any replacement. |
| `flutter_inappwebview` | `venera-app/flutter_inappwebview` (`3ef899b`) | 6.2.0-beta.3 branch with `GraphicsContext` release leak fix, locked across 6 platform subpackages. Retain full fork; replacement requires verifying web login, cookies, proxies, and lifecycle. |
| `webdav_client` | `venera-app/webdav_client` (`2f669c9`) | Contains `RHttpAdapter` integration, authentication, redirects, and directory traversal handling. Retain custom branch; replacement requires validating native rhttp transport. |
| `flutter_saf` | `packages/flutter_saf` in `venera-app/venera-prime` (`056a419a504258e6c6352871f9c888b3fd5bc2f4`) | Same-name `0.0.1` plugin derived from `venera-app/flutter_saf` at `fe182cdf40e5fa6230f451bc1d643b860f610d13`. Retains `license-review`; SAF changes and verification boundaries are detailed below. |
| `flutter_7zip` | `venera-app/flutter_7zip` (`b333447`) | Core dependency for 7z/CB7 import and ZIP fallback. Retained under `license-review`; retain pinned commit and evaluate equivalent implementations. |
| `lodepng_flutter` | `venera-app/lodepng_flutter` (`6216834`) | Native PNG encoding pointer and finalizer memory management. Retained under `license-review`; replacement requires verifying large-image encoding throughput and memory safety. |

## SAF Source Update (2026-11-12)

- Uses the Git subdirectory from the [pinned Prime revision](https://github.com/venera-app/venera-prime/tree/056a419a504258e6c6352871f9c888b3fd5bc2f4/packages/flutter_saf) directly, without copying the plugin or editing shared Pub cache sources. The declaration, lockfile, and inventory fix the same URL, path, and full SHA. The plugin name, `0.0.1` version, dependencies, and `org.pkuism.flutter_saf.FlutterSafPlugin` registration remain compatible.
- The comparison starts at `venera-app/flutter_saf` revision `fe182cdf40e5fa6230f451bc1d643b860f610d13`, also recorded in the package's `UPSTREAM.md`. Includes changes associated with [63d3710](https://github.com/venera-app/venera-prime/commit/63d37101806b96b6b83a8845653c5617f52451d6) and [6987ccf](https://github.com/venera-app/venera-prime/commit/6987ccf8e7b471d835af48edb81a026f76e15a24): copying directory-handle arrays before freeing them, scoped JNI attachment/detachment, complete tree URIs and real document IDs, unknown timestamps and text/stat support, write-error propagation, and `wt` fallback only when a Provider explicitly rejects `rwt`. Legacy ExternalStorage paths remain supported; new paths preserve the Provider authority.
- Security-related changes cover subtree boundaries and traversal checks, URI reference counting, handle finalizer updates, and error propagation. Failed reads, listings, and writes are not reported as success. Application callers reopen files from paths inside isolates and retain filesystem symbolic-link protection. No separate upstream PR was submitted; this project adopts the pinned fixes. Rollback must restore the declaration, lockfile, inventory, and callers together and first account for persisted configurations using new Provider URIs.
- The package's `LICENSE` still reads `TODO: Add your license here.` The Prime repository license does not establish that this plugin's source licensing has been resolved; `license-review` remains unchanged.
- Successfully fetched dependencies through project FVM with `pub.dev` using `fvm flutter pub get --enforce-lockfile`, retaining all other locked versions. No build, analyze, test, or formatter was run for this update. Android persistent permissions, third-party Providers, offline recovery, scan stress, JNI lifetimes, denied writes, and EPUB content integrity still need platform verification. Results in Prime's documents are upstream evidence, not VeneraPlus verification.


## Verification Facts and Boundaries

- **Debian Packaging**: Ran `test_debian_package.py` in WSL Debian GNU/Linux; 6/6 tests passed, covering real system `dpkg-deb` creation and unpacking for amd64 and arm64 architectures, ELF64 architecture inspection, and dpkg version sorting. *Note: this was verified against test bundle fixtures and does not constitute full Linux desktop GUI runtime verification.*
- **Dependency Checker**: Ran `dart tool/check_git_dependencies.dart` locally and in CI; produced `inventory matches declarations and lockfile` with zero errors.
- **Lockfile Integrity**: Executed `flutter pub get --enforce-lockfile` with Flutter 3.41.4 against `pub.dev`, strictly preserving all pinned versions.
- **Static Analysis**: Project structure import gates passed; `flutter analyze` completed with 0 errors and 0 warnings (retaining 24 legacy info-level items).
- **Unverified Scope**: Physical Android device / SAF runtime, Linux desktop GUI runtime, and live GitHub Actions runners were not tested in this round; the documentation makes no claims of verification for these environments.
