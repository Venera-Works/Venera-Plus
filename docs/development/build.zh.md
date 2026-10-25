# 构建与开发

English version: [build.en.md](build.en.md)

本文面向准备从源码构建、测试或维护 VeneraPlus（代码仓库 `Venera-Plus`）的开发者。安装和使用说明请阅读仓库根目录的 [README](../../README.md)。

## 环境要求
> [!IMPORTANT]
> **构建权限须知**：未经用户明确允许，禁止运行任何应用构建。


- FVM，用于管理本地项目 SDK
- Flutter `3.41.4`，由根目录 `.fvmrc` 固定
- Dart `>=3.8.0 <4.0.0`
- JDK `17`，用于 Android 构建
- Rust 工具链；Android 构建需要安装对应 Android targets
- 目标平台原生构建环境，例如 Android SDK / NDK、Xcode、Visual Studio 或 Linux GTK/WebKit 依赖
- Windows 本地构建需要开启系统“开发者模式”；PDF 导入依赖的 `pdfrx` native assets 会在构建时创建符号链接

本地命令均在仓库根目录通过 FVM 执行。首次进入项目时，创建 SDK 链接并检查 Flutter 环境：

```bash
fvm use 3.41.4 --skip-pub-get
fvm flutter doctor -v
fvm flutter --version
```

`.fvmrc` 纳入版本控制，`.fvm/` 中的 SDK 链接和缓存不提交。VS Code 的 `dart.flutterSdkPath` 和 Android Studio 的 Flutter SDK 路径应指向项目的 `.fvm/flutter_sdk`。Android 的 `local.properties` 为本地生成配置，不提交机器上的 SDK 路径。

调用内部使用 `flutter` 或 `dart` 的脚本时，通过 `fvm exec` 传递项目 SDK 环境，例如 `fvm exec python windows/build.py`。此类脚本涉及应用构建时，仍须先取得用户明确授权。

## 获取依赖

克隆仓库后，使用仓库锁文件获取依赖：

```bash
git clone https://github.com/Venera-Works/Venera-Plus.git
cd Venera-Plus
fvm use 3.41.4 --skip-pub-get
fvm flutter pub get --enforce-lockfile
```

> **注意**：官方仓库当前在 GitHub 上为公开仓库（Public；此前曾设为私有并在未鉴权请求时返回 404），克隆与拉取代码可公开访问。正式安装包与版本发布以 GitHub Releases 实际页面状态为准，不能仅从源码分支推断已发布或公网更新可用。

不要在不了解依赖影响的情况下删除或重新生成 `pubspec.lock`。

## OpenList 内核

应用不再在本仓库编译 OpenList。各平台构建在获取 Flutter 依赖后运行
`python3 .github/scripts/fetch_openlist_core.py <platform>` 下载固定内核；平台参数为
`android`、`ios`、`macos-universal`、`windows-x64`、`linux-x64` 或 `linux-arm64`。
版本、源码提交和资产摘要均保存在 `native/openlist_core/core.lock.json`。先在
Venera-OpenList-Core 发布新版本，确认全部资产与许可证存在后再更新锁文件并运行应用 CI。

Git fork 的来源、固定 commit 和升级要求见[依赖治理](dependencies.zh.md)。

### 关键依赖锁定

项目依赖 `rhttp 0.15.1`，必须保持 `flutter_rust_bridge 2.11.1`。版本不匹配时，构建可能成功，但应用启动后无法联网，并提示：

```text
flutter_rust_bridge has not been initialized
```

在 PowerShell 中可以检查锁定版本：

```powershell
Select-String pubspec.lock -Pattern "flutter_rust_bridge" -Context 0,6
```

结果应包含：

```yaml
version: "2.11.1"
```

## 启动耗时排查

应用日志中的 `Startup` 记录以 Dart 入口为起点，分别标记 `First loading frame`（Android 加载界面的首帧）、`Local app ready`（首页或鉴权页首帧）和 `OpenList ready`（网盘内核与账号就绪）。无网盘账号时不会预先启动 OpenList，也不会产生该就绪标记。

`Settings`、`Storage migrations`、各数据库、漫画源、词库等记录各自的初始化耗时；并发任务的耗时不能直接相加。排查时使用同一设备、相同数据和同一构建模式，对比正常网络、断网及账号失效时的冷启动日志。日志不包含账号凭据。点击图标到 Dart 入口之前的引擎耗时需另用 Android 平台工具测量。

使用 CI 构建产物进行真机对比；本地构建和运行仍需用户明确授权。

## 质量检查

提交代码前至少运行：

```bash
python .github/scripts/check_structure_imports.py
fvm dart tool/check_git_dependencies.dart
fvm dart format .
fvm dart format --output=none --set-exit-if-changed .
fvm flutter analyze --no-pub
fvm flutter test --no-pub
git diff --check
```

CI 会使用 `flutter test --coverage` 生成 `coverage/lcov.info`，在工作流摘要中显示行覆盖率，并上传报告产物。当前覆盖率用于建立可见基线，尚未设置统一硬阈值；涉及关键业务路径的改动仍必须增加针对性测试。

WebDAV 测试夹具的目录和文件键统一使用解码后的逻辑路径；仅在 HTTP 请求入口解码一次，生成 `PROPFIND` 响应的 `href` 时逐段编码。路径回归应覆盖空格、Unicode、字面百分号和大小写，避免上传与目录发现使用不同路径，或重复解码百分号。

PR 还会运行 `依赖安全审查` 和 `PR 平台冒烟构建`。依赖审查会阻止引入高危或严重漏洞依赖；改动涉及业务代码、原生平台目录、依赖、构建脚本、工作流或原生集成测试时，平台工作流会执行 Android 与 Windows Debug 冒烟构建。CI 的具体触发规则以工作流配置为准；文档等不影响构建的改动会跳过平台任务。

Windows PR 任务在**已有 Debug 构建后**检查 `flutter_qjs_plugin.dll`、`zip_flutter.dll` 和 `flutter_windows.dll`，将产物目录加入 `PATH`，并以 `CI_REQUIRE_QUICKJS=true` 和 `CI_REQUIRE_NATIVE_ZIP=true` 运行当前原生 ZIP 与 QuickJS 场景：

```powershell
flutter test --no-pub --reporter=expanded `
  --dart-define=CI_REQUIRE_QUICKJS=true --dart-define=CI_REQUIRE_NATIVE_ZIP=true `
  --name 'App data transfer with native ZIP|ComicSourceParser\.probeKey metadata sandboxing|source runtime transactions|SourceFileMetadata' `
  test/features/sync/app_data_transfer_test.dart `
  test/features/comic_source/source_parser_test.dart `
  test/features/comic_source/source_lifecycle_test.dart `
  test/features/comic_source/source_files_test.dart
```

严格开关要求真实原生库，缺库时必须失败而非跳过。本机不得为了运行这些测试触发原生构建；仅可在已有兼容 DLL 和原生资源的前提下进行只读验证。

原生集成测试与驱动已统一收敛至 `test/` 目录：场景入口为 `test/integration/platform_smoke.dart`，宿主端驱动为 `test/driver/platform_smoke_driver.dart`。为避免被日常 `flutter test --coverage` 默认发现与覆盖率统计收集，两个入口刻意省略了 `_test.dart` 后缀；旧根目录 `integration_test/` 与 `test_driver/` 已彻底移除，不保留兼容入口。

由于 Flutter 3.41.4 的 `flutter test` 对设备集成测试的路径识别硬编码为根 `integration_test/` 目录，移动后 Android 与 Windows 均必须使用 `flutter drive` 并显式传入 `--driver=...` 和 `--target=...`（Windows 不可继续通过 `flutter test -d windows` 运行）。测试运行时须显式传入 `--dart-define=CI_NATIVE_SMOKE=true` 作为安全保护开关，该开关严格限制仅在一次性 CI runner 中使用，不鼓励在本地环境直接构建与执行。

原生集成测试在 suite 临时隔离目录中验证 SQLite 原生加载、后台 Isolate、旧版本数据库模式迁移、事务写入、重开持久化及真实数据备份还原；随后启动真实 `MyApp` 初始化并进入首页，点击主导航书库（Library）图标（紧凑导航栏通过图标定位），等待布局刷新后点击阅读记录（Reading Records）导航至真实历史记录视图，校验数据库播种的历史标题，全过程使用一次性运行器 profile 并断言无未捕获异常。

在截图验证方面，Android 与 Windows 均通过 `binding.reportData` 向宿主端驱动传递截图 Base64 数据与宿主输出路径，由共享驱动统一强校验 PNG 签名与正向尺寸后写入落盘；截图不再由 Windows 应用直接写文件。产物落盘路径默认分别为 Android 的 `build/smoke-artifacts/android_smoke.png` 与 Windows 的 `build/smoke-artifacts/smoke_rendered_frame.png`（Windows CI 环境额外通过 `SMOKE_ARTIFACT_DIR` 指定绝对输出目录）。

一次性 CI 环境中的显式执行命令如下：

Android（模拟器已就绪）：

```bash
flutter drive \
  --driver=test/driver/platform_smoke_driver.dart \
  --target=test/integration/platform_smoke.dart \
  -d emulator-5554 \
  --dart-define=CI_NATIVE_SMOKE=true
```

Windows（PowerShell，`--timeout` 单位为秒，900 即 15 分钟）：

```powershell
$smokeDir = (Join-Path (Get-Location) 'build\smoke-artifacts')
New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null
flutter drive --driver=test/driver/platform_smoke_driver.dart --target=test/integration/platform_smoke.dart -d windows "--dart-define=CI_NATIVE_SMOKE=true" "--dart-define=SMOKE_ARTIFACT_DIR=$smokeDir" --timeout 900
```

Dart 格式检查覆盖 `lib` 与 `test`（自动递归覆盖子目录）。`main` 分支要求 PR 通过代码分析、依赖审查和平台冒烟构建门禁，并禁止直接强推或删除分支。

涉及发布版本时再运行：

```bash
python .github/scripts/release_version.py --check
```

仓库模块边界和入口约定见[项目结构约定](../architecture/project_structure.zh.md)。

## Android 构建

本地 release 签名文件放置在：

```text
android/keystore.jks
android/key.properties
```

`android/key.properties` 示例：

```properties
storePassword=你的 store 密码
keyPassword=你的 key 密码
keyAlias=你的 key alias
storeFile=../keystore.jks
```

构建 APK：

```bash
fvm flutter pub get --enforce-lockfile
fvm flutter build apk --release
```

Flutter 3.41.4 的 Android Release 构建不要添加 `--no-pub`：该参数还会跳过按 Release 模式重新生成插件注册代码，导致 `GeneratedPluginRegistrant.java` 可能仍引用已被发布编译排除的 `integration_test`。保留前置锁文件校验；两个 Android Release 工作流会在构建后检查 `pubspec.lock` 未变化。详见 [Flutter #163774](https://github.com/flutter/flutter/issues/163774)。

构建产物通常位于 `build/app/outputs/apk/release/`。

签名文件和密码属于敏感信息，不应提交到仓库。

## 桌面端与 iOS 构建

在对应操作系统和原生工具链就绪后执行：

```bash
fvm flutter pub get --enforce-lockfile
fvm flutter build windows --no-pub
fvm flutter build linux --no-pub
fvm flutter build macos --no-pub
```

iOS 可先执行无签名构建验证：

```bash
fvm flutter pub get --enforce-lockfile
fvm flutter build ios --release --no-codesign --no-pub
```

### Linux Debian 打包

Linux Debian 安装包使用系统自带的 `dpkg-deb` 工具与项目脚本 `debian/build.py` 打包：

```bash
fvm flutter build linux --release --no-pub
python debian/build.py --skip-build
```

构建产物位于 `build/linux/{x64,arm64}/release/debian/`。该方式替代了旧的 `flutter_to_debian` 依赖，不再需要全局安装 Git 打包工具。

Windows 安装器与便携包由发布工作流生成；本仓库不维护 winget manifest 或公共包管理器条目。
## GitHub Actions 与发布版本

仓库工作流负责持续集成、手动构建、tag 发布和分发元数据维护。发布版本号统一维护在 `release.json`：

```json
{
  "version": "1.2.3",
  "build": 123
}
```

准备发布时先更新 `release.json`，再同步并校验相关文件：

```bash
python .github/scripts/release_version.py --write
python .github/scripts/release_version.py --check --tag v1.2.3
```

`pubspec.yaml`、发布 tag 和 `CHANGELOG.md` 版本章节必须与 `release.json` 一致。

`代码分析` 工作流会运行版本与结构检查、Python 脚本测试、Dart 格式检查（`lib` 与 `test`，覆盖子目录）、`flutter analyze`、完整 Dart 测试及覆盖率汇总。`依赖安全审查` 会检查 PR 新增或升级的依赖，`PR 平台冒烟构建` 会按改动范围验证 Android 和 Windows 的编译与原生数据库集成测试场景，也可通过手动触发验证已发布的内核。`完整构建` 在开始多平台构建前会复用同一质量工作流；手动平台构建和 tag 发布则共同复用 `.github/workflows/build.yml`，避免两套构建定义产生差异。

原生平台 CI 构建任务配置了编译与依赖缓存：使用 `sccache` 缓存原生任务中的 Rust 编译及受支持的 Linux CMake 生成器路径下的 C/C++ 编译（未保留 Windows C/C++ 包装器），使用 Cargo 注册表与 Git 下载缓存，以及 Android Gradle 构建缓存。构建步骤在结束时通过 `sccache --show-stats` 打印统计信息，用于确认热缓存命中情况。最终发布包与安装包等产物始终重新构建生成，不会从缓存复用。

Android release 工作流需要以下仓库 Secrets：

- `ANDROID_KEYSTORE`：keystore 文件的 Base64 内容
- `ANDROID_KEY_PROPERTIES`：`key.properties` 文本内容

本项目为 Venera-Works 旗下的独立 VeneraPlus 项目（代码仓库 `Venera-Plus`），已彻底移除上游 AltStore 自动化发布脚本、仓库元数据及 PR 生成流程，不提供公开发行的 AltStore 源。

AI Issue 检查默认关闭。仅在确认 `API_URL`、`API_KEY` 可用后，将仓库变量 `ENABLE_AI_ISSUE_CHECK` 设为 `true`；可通过 `ISSUE_CHECK_MODEL` 覆盖默认模型。该流程只发表评论和关闭建议，不会自动关闭 Issue。

不要把 Secrets、签名文件或实际密码写入代码、日志和文档示例。

## 构建问题排查

### 构建成功但应用无法联网

优先确认 `flutter_rust_bridge` 仍为 `2.11.1`，并确认依赖是通过当前仓库的 `pubspec.lock` 获取。不要通过盲目升级依赖解决初始化错误。

### 提示 `flutter_rust_bridge has not been initialized`

通常是依赖版本漂移。恢复仓库中的 `pubspec.lock`，确认 Flutter 版本符合要求，再运行：

```bash
fvm flutter pub get --enforce-lockfile
```

### 提示 `Unable to satisfy pubspec.yaml using pubspec.lock`

通常是 Flutter/Dart 版本或包源环境不匹配。先核对本页要求的 Flutter 版本和 `fvm flutter doctor -v` 输出，不要直接删除锁文件。

本仓库锁文件中的包源为 `https://pub.dev`。如果本地 `PUB_HOSTED_URL` 指向其他镜像，在 PowerShell 中为当前终端临时对齐包源后重试，不要去掉 `--enforce-lockfile` 或重写锁文件：

```powershell
$env:PUB_HOSTED_URL = 'https://pub.dev'
fvm flutter pub get --enforce-lockfile
```

### Gradle 下载过慢

可以在本地临时切换 Gradle wrapper 镜像或配置网络代理，但环境相关地址不应提交到仓库。提交前应确认 `gradle-wrapper.properties` 没有混入本地镜像改动。
