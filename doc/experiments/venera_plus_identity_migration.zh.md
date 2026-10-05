# VeneraPlus 品牌与应用身份迁移计划

本文档记录 VeneraPlus 全面品牌、仓库信息、应用安装身份与新 Logo 的迁移计划、规范约定、兼容性边界与验证要求。本文档属于实验与技术跟踪记录，不作为公开商业承诺。

---

## 1. 迁移目标与背景

为了建立更加清晰、独立的品牌标识与工程治理边界，本项目正式由历史的 Venera-Next / 个人分支迁移为托管于 **Venera-Works** 组织的独立项目 **VeneraPlus**（代码仓库名为 `Venera-Works/Venera-Plus`）。

用户明确选定并补充以下关键原则：
1. **应用名称确认为 `VeneraPlus`**（无连字符）；代码仓库名保持 `Venera-Plus`，避免破坏已有远程与外部链接；
2. **全新独立应用策略**：新版本使用全新的应用身份、包标识、安装目录与本地数据目录，与旧版（原 Venera 及各阶段 Venera-Next）在安装身份与默认本地数据目录上彼此隔离，支持在同一系统中共存安装；新版本**不自动读取、不搬迁、不复制、不删除**旧版本数据、配置文件或安装目录，亦不自动处理中间开发状态的数据目录；
3. **严格构建许可边界**：未经用户明确允许，不可进行任何应用构建与隐式编译验证。

---

## 2. 权威规范值（Canonical Values）

本次迁移已确认并冻结的标准元数据如下，明确区分显示名、仓库名与工程包标识：

| 维度 | 标准配置值 | 说明与生效范围 |
|---|---|---|
| **产品 / 应用显示名** | `VeneraPlus` | 应用标题栏、关于页面、桌面快捷方式、Windows & Apple 产品名、导出 Producer |
| **项目仓库名 / URL** | `Venera-Plus` / `https://github.com/Venera-Works/Venera-Plus` | 官方代码仓库与项目主页（默认分支 `main`，当前版本 `2.2.3+19`） |
| **组织 / Publisher** | `Venera-Works` | GitHub 组织全名 `Venera-Works/Venera-Plus`，仓库 description 更新为 `VeneraPlus` |
| **Dart Package** | `venera_plus` | `pubspec.yaml` name，全局源码及测试 `package:venera_plus/...` imports |
| **Android Namespace / App ID** | `com.github.veneraworks.veneraplus` | `android/app/build.gradle` 中的 namespace 与 applicationId，Kotlin 源码包路径 |
| **iOS / macOS Bundle ID** | `com.github.veneraworks.veneraplus` | `project.pbxproj` 中的 `PRODUCT_BUNDLE_IDENTIFIER`，RunnerTests 附加 `.RunnerTests` |
| **macOS 产品名 / App** | `VeneraPlus` / `VeneraPlus.app` | product、app 与 scheme 更新为 `VeneraPlus`，保持 Runner target 名不变 |
| **Linux GTK App ID** | `com.github.veneraworks.veneraplus` | `linux/CMakeLists.txt` 中的 `APPLICATION_ID` 标识 |
| **Linux 二进制与包名** | `venera-plus` | Linux 二进制文件名、Debian/Arch 包名、desktop 文件（`venera-plus.desktop`）与图标 |
| **Linux DEB 安装路径** | `usr/local/lib/venera-plus` | `debian/build.py` 生成的 DEB 包安装目录 |
| **Windows 公司名** | `com.github.veneraworks` | `Runner.rc` CompanyName，决定 `%APPDATA%\com.github.veneraworks\` 存储前缀 |
| **Windows 产品名 / EXE** | `VeneraPlus` / `VeneraPlus.exe` | ProductName、FileDescription、InternalName、窗口标题与可执行文件输出名 |
| **Windows 数据目录** | `com.github.veneraworks/VeneraPlus` | 由 Windows path_provider 与系统公司名/产品名解析的本地存储目录 |
| **Windows Inno AppId (x64)** | `4F42C5DE-6674-479D-BB65-CBFC27A41210` | 独立的 64 位安装程序 GUID，默认安装至 `{autopf}\VeneraPlus` |
| **Windows Inno AppId (ARM64)**| `2A8A3BBE-F860-4D85-AB06-33C8EB51C2B9` | 独立的 ARM64 安装程序 GUID，默认安装至 `{autopf}\VeneraPlus` |
| **发布工件品牌前缀** | `VeneraPlus` | Windows/Android/macOS/iOS 发布打包工件前缀 |
| **品牌主视觉 SVG 资源** | `assets/Venera-Plus.svg` | 作为仓库既有资源路径保留，忠实采用黑底白色 V 图案 |
| **文档与应用图标** | `assets/readme_logo.png` / `assets/app_icon.png` | 文档与移动/桌面各平台图标均由黑底白 V 源图忠实生成 |

### 2.1 仓库可见性与发布更新说明

- 官方仓库 `Venera-Works/Venera-Plus` 当前在 GitHub 上已由用户调整为**公开仓库（Public）**；
- 此前曾设为私有仓库（Private）且未鉴权的匿名 GitHub REST API 请求会返回 `404 Not Found`，以及本次发布启动时 GitHub Release 列表为空，均作为启动阶段的历史事实记录，当前访问与克隆代码支持公开访问；
- 正式安装包与版本发布以 GitHub Releases 实际页面状态为准，不能仅从源码分支推断已发布或公网更新可用；应用未内置私有 Release 自定义鉴权扩展；
- 本次发布 v2.2.3 的实际发布工件可用性待 CI 构建完成后由父代理实测观察。

### 2.2 构建权限边界（Permission Boundary — MUST）

- **授权范围与边界**：用户现已通过明确选择授权『允许 CI 构建并发布』；该授权严格限定于 GitHub Actions CI 中执行应用构建、测试与多平台工件发布；本地环境仍严禁运行任何应用构建，包括 `flutter build`、`flutter run`、Gradle assemble/build、MSBuild/CMake 编译、会内部调用构建的打包入口、以及可能隐式编译应用或 native assets 的测试。
- **本地静态操作许可**：本地当前仅允许源文件修正和不触发构建的静态检查（语法分析、代码风格、依赖一致性检查与只读脚本测试），全部检查由父代理统一集成执行。
- **交付与验证约束**：严禁将本地构建权限作为本次源码交付的前提；严禁将重命名旧二进制当作新构建验证；根目录 `AGENTS.md` 已写入该长期操作边界规则。

---

## 3. 分阶段迁移计划

迁移分为规范冻结、四条并行实施分支与统一集成验收：

```text
阶段 0: 规范制定与标准值冻结 (已完成)
    ↓
并行实施阶段:
  ├─ 源码与包名迁移 (Dart package / imports / 测试与代码门禁)
  ├─ 平台身份与安装配置迁移 (Android / iOS / macOS / Windows / Linux)
  ├─ 视觉资产与全平台图标生成 (黑底白 V 品牌主图与各平台多尺寸图标)
  └─ 工程文档与元数据规范同步 (README / CHANGELOG / 构建规范 / 依赖清单)
    ↓
统一集成阶段: 仅限静态检查门禁审查与证据记录 (无应用构建)
```

1. **阶段 0：规范冻结与实施边界确定**
   - 确立统一 Canonical Values 与文件所有权边界；
   - 明确显示名 `VeneraPlus` 与仓库名 `Venera-Plus` 的映射分工；
   - 确立零过渡 shim、不自动迁移旧数据、未经许可严禁构建的执行原则。

2. **阶段 1：并行实施分支**
   - **源码与包名**：
     - `pubspec.yaml` 包名更为 `venera_plus`；
     - 全局替换 `package:venera_next/` 为 `package:venera_plus/`；
     - 调整测试文件、检查工具及代码结构扫描脚本 `.github/scripts/check_structure_imports.py`；
     - 移除针对 Windows 旧目录自动迁移的测试与测试钩子，确认保留协议与格式字符串。
   - **原生平台配置**：
     - Android：更新 `android/app/build.gradle` 的 `applicationId`、`namespace`、Kotlin package、`AndroidManifest.xml` 与 proguard 配置；
     - iOS & macOS：更新 `PRODUCT_BUNDLE_IDENTIFIER` 为 `com.github.veneraworks.veneraplus`，macOS 更新 product、app 与 scheme 为 `VeneraPlus`（保持 Runner target 名不变），更新 plist 元数据；
     - Linux：更新 `linux/CMakeLists.txt` 中的 `APPLICATION_ID`、CMake 构建目标、desktop 文件与 `debian/build.py`；
     - Windows：更新 `Runner.rc`（公司名 `com.github.veneraworks`、产品名 `VeneraPlus`、EXE 名 `VeneraPlus.exe`）、更新 CMake 项目名；更新 Inno Setup 独立 AppId 与安装目录 `{autopf}\VeneraPlus`，移除删除旧版目录的安装脚本段。
   - **品牌视觉与图标**：
     - 导入源文件中的黑底白色 V 图案，生成新 `assets/Venera-Plus.svg`，移除旧 `assets/Venera-Next.svg`；
     - 重新生成全套图标：`assets/app_icon.png`、`assets/readme_logo.png`、`windows/runner/resources/app_icon.ico`、`debian/gui/venera-plus.png`；
     - 生成 Android 分层 Adaptive Icon（前景、背景、monochrome）并适配安全区，生成 iOS/macOS AppIcon 套件。
   - **工程文档与元数据**：
     - 更新根目录 `README.md`、`CONTRIBUTING.md`、`CONTRIBUTING.en.md`；
     - 更新 `doc/` 下的构建指南、依赖治理规范、命令行与使用手册；
     - 在 `CHANGELOG.md` 中为发布版本 `v2.2.3` 维护品牌迁移与独立身份说明；
     - 更新 `doc/development/git_dependencies.json` 中的项目职责声明，保留所有事实第三方依赖；
     - 更新根目录 `AGENTS.md` 写入构建许可边界规则。

3. **阶段 2：统一集成与静态验证**
   - 统一运行不触发构建的质量门禁（Dart 静态分析 `dart analyze` / `flutter analyze --no-pub`、只读结构检查、发布元数据校验、资源与 XML/JSON 解析）；
   - 在未获用户许可前，不执行任何应用构建、测试运行或端到端实机验证。

---

## 4. 独立安装身份与兼容性影响

### 4.1 为什么选择独立安装身份与目录隔离？

自动迁移旧数据看似方便，但在跨平台桌面和移动环境中存在严重隐患：
1. **数据损坏风险**：如果旧版数据损坏或正在被旧版本实例写入，自动复制可能导致两边数据不一致或同步状态混乱；
2. **不可逆覆盖**：如果用户想保留旧版用于对比测试，新版的静默清理或占用会直接破坏旧版环境；
3. **平台权限割裂**：在 Android 和 macOS 沙盒环境下，不同 Bundle ID / Package Name 之间无法直接跨沙盒读取彼此的私有存储目录。

因此，本项目彻底采用**独立安装身份**：
- Windows 下分别安装至 `Program Files\VeneraPlus` 与使用 `%APPDATA%\com.github.veneraworks\VeneraPlus`；
- Linux 下使用 `venera-plus` 命令，本地数据目录按平台 `path_provider` 解析，Linux 桌面 GUI 尚未实测；
- Android/iOS/macOS 作为两个独立 App 存在，系统图标分别显示；
- 新版安装器与运行时代码中彻底移除对旧版本路径的检测、移动、复制或静默删除逻辑；此前中间 Windows 运行可能在本地产生的 `com.github.veneraworks/Venera-Plus` 目录，新版同样不会自动搬动、覆盖或删除，由用户根据需要自行决定是否手动清理该中间目录，且绝不据此中间运行声称最终新名实机验收。

### 4.2 旧版用户数据手动迁移说明与风险边界

若用户希望将原 Venera 或 Venera-Next 中的配置与阅读记录转移到 VeneraPlus，可通过**标准备份导出/导入链路**手动迁移：

1. **导出旧版数据备份**：
   - 在旧版应用中打开 **设置 → 应用 → 导出应用数据**；
   - 选择保存路径，生成包含配置、历史与收藏的 `.venera` 数据备份文件（或通过 WebDAV 上传同步快照）。
2. **导入至 VeneraPlus 与人工核实**：
   - 打开全新安装的 VeneraPlus；
   - 进入 **设置 → 应用 → 导入应用数据**；
   - 选取之前导出的 `.venera` 文件进行恢复；
   - **手动导入不保证『完整还原』和『完全相同』兼容**：新旧版本间可能存在数据模型或配置项差异，导入前必须在旧版和外部存储中妥善保留原始备份文件，并在导入后人工逐项检查漫画源、收藏、历史与偏好设置的生效情况。
3. **共存边界与存储目录警示**：
   - 新旧应用并存仅指各自的安装目录与默认本地数据目录相互隔离；
   - **不保证**在两版间共享相同的 WebDAV 远端目录或同一个外部本地漫画目录时互不干扰；
   - 在两版同时运行或先后扫描时，可能发生并发写入、文件锁冲突或目录结构冲突。**严禁在未备份的情况下让新旧版本直接指向同一个工作漫画目录**，建议分别指定独立路径或在彻底验证后再做规划。
4. **WebDAV 凭据与安全边界准确说明**：
   - **数据同步（DataSync）凭据**：WebDAV 同步连接凭据（URL、用户名、密码）及当前设备同步调度模式属于**设备本地数据**，绝不会导出到 `.venera` 同步快照，也不会被远端下载快照覆盖；在新版中导入备份后，必须手动重新配置 WebDAV 连接。
   - **WebDAV 漫画库（Comic Library）配置**：若用户此前在“WebDAV 漫画库”设置中显式启用了“同步漫画库配置”开关，导出的 `.venera` 快照中**会包含**该漫画库的地址、用户名与密码等凭据，并在开启相同选项的对端设备导入。用户在导出和传输 `.venera` 备份包前必须知晓此差异与风险，不能将包含漫画库凭据的快照当成无凭据包随意分享，不给虚假的安全承诺。

---

## 5. 协议、格式与历史来源保留边界

本次迁移属于**工程与产品层面的品牌更名**，坚决不破坏任何协议契约与数据互操作性：

1. **数据与文件格式保留**：
   - 保留 `.venera` 作为应用数据备份与 WebDAV 快照的格式扩展名；
   - 保留 `.venera-comics` 作为批量漫画导出归档的格式扩展名；
   - 保留 WebDAV 默认远程路径 `/venera_backup/` 与 `/venera_comics/`；
   - 保留单本 CBZ 解压元数据 `metadata.json` 与 `ComicInfo.xml` 的格式结构；
   - 本次更名仅不改变对应格式与通道协议，不保证全部旧版历史数据无条件兼容。
2. **通信与系统协议保留**：
   - 保留平台原生通信 MethodChannel / EventChannel 内部前缀 `venera/...`（避免移动端原生插件通信出现断裂）；
   - 保留现有的 deep link URI scheme 与系统分享契约。
3. **历史来源与版权事实**：
   - 坚决保留原项目（`venera-app/venera`）与历史分支（`CyrilPeng/Venera-Next`、`miludeshiji/Venera-Next`）的来源事实与致谢；
   - 绝不篡改历史 CHANGELOG 章节中的既有名词与版本事实；
   - 绝不替换第三方依赖（如 `venera-app/flutter_qjs`、`venera-app/photo_view` 等）的真实 Git 仓库 URL 与固定 commit SHA。

---

## 6. 验证事实与验收记录

根据用户关于**未经许可禁止构建**的硬性约束，本次最终验收**仅报告不触发应用构建的纯静态检查实测**，对历史中间状态及未验证范围进行诚实、客观的记录：

### 6.1 最终静态检查与源元数据校验结论

- **代码结构边界检查**：
  ```bash
  python .github/scripts/check_structure_imports.py
  ```
  结论：Pass，实际输出 `Structure import boundaries are clean.`，结构边界 clean，零受限 import/export 违规。
- **发布元数据静态验证**：
  ```bash
  python .github/scripts/validate_release.py --tag v2.2.2
  ```
  结论：Pass，实际输出 `Release metadata for v2.2.2 is valid`，`release.json`（2.2.2+18）与 `pubspec.yaml`、相关配置文件及发布 tag 完全一致。
- **Git 依赖清单门禁**：
  ```bash
  dart --disable-dart-dev tool/check_git_dependencies.dart
  ```
  结论：Pass，实际输出 `Git dependency inventory matches declarations and lockfile.`。禁用 DartDev，仅执行只读依赖校验脚本，核对 Git 依赖声明、锁文件与审查清单，不进入 Flutter 应用或原生资产构建流程。
- **Dart 静态代码分析**：
  ```bash
  dart analyze
  ```
  结论：输出 24 条既有遗留 info，0 error / 0 warning。不宣称 clean lint 或零 issues。
- **全项目旧标识清理检索**：
  - 在操作源代码、测试、原生平台与 CI 作用域检索旧标识（`VeneraNext`、`venera_next`、`com.github.miludeshiji`、`cyrilpeng`），结果为 0 匹配无残留；
  - 历史来源事实与 CHANGELOG 旧版历史章节按规范忠实保留，不作替换。
- **平台源码元数据只读校验**：
  - **Android**：`AndroidManifest.xml` 中应用 label 正确配置为 `VeneraPlus`；
  - **iOS**：`Info.plist` 中 Bundle Name 与 Display Name 正确配置为 `VeneraPlus`；
  - **macOS**：Product Name（`VeneraPlus`）、Bundle Identifier（`com.github.veneraworks.veneraplus`）与 app/scheme 正确无误；
  - **Windows**：`Runner.rc` 中 ProductName 与 EXE 输出名为 `VeneraPlus` / `VeneraPlus.exe`；x64 与 ARM64 两套 Inno Setup 脚本的 ProductName、EXE、项目 URL（`https://github.com/Venera-Works/Venera-Plus`）与独立 GUID 校验无误；
  - **Linux**：`debian/gui/venera-plus.desktop` 中 Name 正确为 `VeneraPlus`，Icon 保持 `venera-plus`。
- **工程配置与 CI 工作流解析**：
  - `pubspec.yaml` 与发布工作流解析：包名 `venera_plus`、Linux 产物 `venera-plus`、版本 `2.2.2+18` 与 GitHub 仓库 URL `Venera-Works/Venera-Plus` 完全一致；
  - 多语言文案：`zh_CN` 与 `zh_TW` 翻译字典中关于页面新名称 `VeneraPlus` 均已就绪。
- **多平台静态资源与格式校验**：
  - **iOS**：21 个 catalog 图片绑定正常；
  - **macOS**：10 个 catalog 绑定引用 7 个不同尺寸文件，全部文件均实际存在且可读；
  - **Windows ICO**：包含 16/24/32/48/64/128/256 共 7 档标准尺寸全部有效；
  - **品牌主视觉**：`assets/Venera-Plus.svg` XML 结构合法；
  - **临时文件清理**：临时调试文件 `android/key.properties` 确认不存在；
  - **文档本地链接**：扫描 28 个文档、117 个本地 Markdown 链接，Broken 数量为 0。

### 6.2 历史中间记录与构建/发布授权状态说明

- **未获许可的中间构建与运行说明**：父代理在构建许可约束明确前，曾运行过 Windows 与 Android 的中间构建，并已明确向用户承认未提前获得许可。该中间状态的构建与运行证据（当时仍带有旧连字符等过渡名）**属于失效的历史中间记录，绝不作为最终 `VeneraPlus` 的验收证据**；
- **历史中间测试与旧打包记录**：在此前中间状态下，专用 Flutter 3.41.4 执行的 `flutter test --no-pub`（1085 passed, 10 skipped）、WSL Debian 下 Python 脚本打包测试（24 passed）以及旧资源 alpha 通道验证，均属于中间过渡阶段的测试事实，不作为最终新名称实机产物的验收证明；
- **清理与复原措施**：父代理已主动关闭自己启动的 Windows 进程和只读 Android 模拟器，并彻底删除了临时生成的 `android/key.properties`；
- **环境变更事实**：开发环境中的全局 stable Cargo 实际由 `1.77.2` 更新至 `1.99.0`；项目自身指定的 `rust-toolchain`（`1.85.1`）以及 Dart/Flutter 依赖锁定文件均未发生改变，如实记录此项环境事实；
- **最终新名未重新构建（上一阶段历史检查状态）**：上一阶段在用户未许可应用构建时，最终新名称 `VeneraPlus` 严格遵守用户指示，本地未执行任何重新编译、重新构建、打包或运行；
- **构建与发布授权更新（本次 v2.2.3 发布）**：用户现已通过明确选择授权『允许 CI 构建并发布』；授权仅覆盖 GitHub Actions CI 中构建与测试，本地仍禁止任何应用构建、flutter run/test、Gradle/CMake/MSBuild 或会隐式构建的包装入口。本地仅限源码编辑与静态检查；
- **CI 发布状态与验证事实**：本次发布面向全新规范版本 `v2.2.3`（build 19），GitHub Actions CI 构建与发布流水线尚未触发与执行，不得预先声称构建或发布已完成；历史 `v2.2.2`（build 18）的验证输出绝不改写为 `v2.2.3` 已通过。经确认，仓库无继承的组织 Secrets、无发布 environments、项目亦无内置正式签名文件；用户已明确选择使用已有正式签名，目前尚需配置正式签名密钥（key.properties 本机路径或两个 Repo Secrets），未配置前不预先声称 CI 一定能完成 Android 等特定平台签名发布；后续实际 CI 运行结果与工件生成由父代理在工作流结束后补充观察记录，不预写任何占位成功结论；
- **未验证范围披露**：由于本地未执行构建且 GitHub Actions CI 发布尚未运行，最终 `VeneraPlus`（v2.2.3）的 Windows 桌面运行、Android 物理机运行、iOS 真机沙盒、macOS 原生打包与 Linux 桌面 GUI 均保持未实测状态，文档坚决不作未经观察的成功承诺。
