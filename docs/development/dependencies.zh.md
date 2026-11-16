# 依赖治理

English version: [dependencies.en.md](dependencies.en.md)

本文记录 VeneraPlus 的直接依赖治理规则，重点说明不来自 pub.dev 的 Git 依赖。`pubspec.lock` 是构建复现依据，但不能替代依赖来源和维护责任说明。

## 基本规则

- 同时提交 `pubspec.yaml` 和 `pubspec.lock` 的相关变更。
- 直接依赖优先使用 pub.dev 的稳定版本；使用 Git fork 时必须说明原因。
- Git 依赖必须固定到不可变 commit，不能使用默认分支、`main` 或 `HEAD`。
- 不通过 `dart pub global activate -s git` 等方式绕过项目依赖清单安装 Git 工具；现有检查器会拒绝工作流中的此类安装。
- 升级依赖时检查上游变更、安全公告、许可证、平台构建和相关测试。
- 发布到 pub.dev 不能替代安全维护；发布前仍需完成差异审计和上游同步计划。

## 关键原生与平台依赖边界

- `sqlite3`: 迁移至 3.5.2（sqlite3 v3 架构）。v3 改由 Dart build hooks 负责原生二进制分发与构建绑定，移除了旧有插件 `sqlite3_flutter_libs` 及生成的原生注册逻辑。原生执行依赖预编译产物与 build hook，不使用系统全局或自行编译覆盖。
- `dynamic_color`: 保留 1.8.1。1.9.0 存在 AGP 8 构建回归问题；2.0.2 引入 `material_ui ^1.0.0`，其 SDK 约束要求 Flutter >= 3.44 / Dart >= 3.12，与本项目固定的 Flutter 3.41.4 / Dart 3.11.1 不兼容，因此暂不升级并保持 1.8.1 版本边界。
- `rhttp` / `flutter_rust_bridge`：当前 Dart 侧 `rhttp 0.15.1` 必须配套 `flutter_rust_bridge 2.11.1`，声明与覆盖配置均保持该版本。原生 Cargo 清单将桥接运行库及宏固定到上游提交 `d59f05b6b0da3606933385f80cbd9e21cc35b59c`，保持 `2.11.1` 绑定协议并修复取消后的迟到回调崩溃。Dependabot 忽略桥接库的独立升级，后续需随 `rhttp` 一并验证原生绑定与联网功能。
- `rhttp` 预编译由 `Venera-Works/Venera-Native-Prebuilts` 发布，`native/prebuilts/rhttp/` 固定源归档摘要、签名公钥、编译参数及 Cargo 清单和锁文件，四份文件与资源仓库同步。准备脚本在计算源码 hash 前应用原生依赖锁定，并只对当前版本应用经过摘要校验的 Cargokit 修改；产物缺失或验签失败即停止。新 hash 必须先完成完整预编译发布，再构建应用；升级时同步两仓库的配置及脚本中的源文件摘要。
- `rhttp` 原生依赖锁定到 `bytes 1.11.1`、`rustls 0.23.46`、`rustls-webpki 0.103.14` 和 `time 0.3.47`，修复内存边界、TLS 握手和会话机密、证书与 CRL 校验及 RFC 2822 解析漏洞。保留 `quinn-proto 0.11.19` 和 `quinn-udp 0.5.16` 的 QUIC 修复。使用已完成全平台签名发布的 [`precompiled_3aea817bfb329ec326ef4561451cab83`](https://github.com/Venera-Works/Venera-Native-Prebuilts/releases/tag/precompiled_3aea817bfb329ec326ef4561451cab83)，Rust 工具链统一升级至 `1.88.0`，满足 `time 0.3.47` 的最低版本要求；FRB 绑定保持 `2.11.1`。
- `image` / `archive`：升级至 `image 4.12.0` 和 `archive 4.6.0`，代码使用的 ZIP 解码接口要求 `archive >= 4.6.0`。本地 ZIP/CBZ 的 Dart 兜底解压通过 Latin-1 保留旧编码文件名的原始字节，先尝试 UTF-8，再复用 GBK 恢复逻辑；显式设置 `throwOnError: true`，保持损坏压缩数据的错误传播。
- `pdfrx` / `pdfium_dart`：云端 PDF 通过 `FPDFAvail` 检查所需字节，在两次原生调用之间读取有界 Range；原生回调只同步读取已有缓存，不能发起网络请求或因任务取消返回读取失败。所有 PDFium 操作复用 `PdfrxEntryFunctions.compute` 的串行 worker，文档关闭后才释放 availability、回调及缓存。直接声明现有锁定版本的 `ffi 2.2.0` 和 `pdfium_dart 0.2.5`，与 `pdfrx 2.4.7` 共用原生库。
- OpenList 内核由 `Venera-Works/Venera-OpenList-Core` 独立发布，当前锁定版本为 `0.1.0-beta.7`、RPC ABI 为 `1`。`native/openlist_core/core.lock.json` 固定 GitHub Release tag、源码提交和每个平台资产摘要；应用只下载锁定资产，不在应用工作流中安装 Go 或编译内核。升级必须先发布内核版本，再完整更新锁文件中的资产与许可证信息。

## 当前 Git 依赖

| 依赖 | 当前 commit | 上游 / 许可证 | 暂时保留定制仓库的直接原因 |
|---|---|---|---|
| `flutter_qjs` | `Venera-Works/Venera-flutter_qjs@8e7db82c57f2c780eebd4c7c6903d3aa41a65e2e` | `venera-app/flutter_qjs` / MIT | 由 Venera-Works 独立维护 TypedData 优化及 QuickJS-NG 核心补丁，保留原 API、FFI ABI 和平台构建方式 |
| `photo_view` | `a1255d1b5945aad4b7323303ec2ecdf0c90ffc4c` | 未记录 fork 上游 / MIT | 固定版本调整了 `PhotoViewCoreState` 动画位置修正，阅读器缩放和手势依赖该行为 |
| `scrollable_positioned_list` | `09e756b1f1b04e6298318d99ec20a787fb360f59` | `google/flutter.widgets` / BSD-3-Clause | 固定版本增加 `scrollControllerCallback` 和 `scrollBehavior`，连续阅读定位依赖这些接口 |
| `desktop_webview_window` | `7801fc582ecf5a7351632887891ecf309a7b2583` | `wgh136/flutter_desktop_webview` / 未声明 | 固定版本包含 Windows ARM64 构建修复，替换前需验证全部桌面平台 |
| `flutter_inappwebview` | `3ef899b3db57c911b080979f1392253b835f98ab` | `pichillilorenzo/flutter_inappwebview` / Apache-2.0 | 固定版本包含 `GraphicsContext` 释放修复；内嵌 WebView 和 Cloudflare 流程依赖该分支行为 |
| `lodepng_flutter` | `ac7d05dde32e8d728102a9ff66e6b55f05d94ba1` | 未记录 fork 上游 / 许可证文件仍为占位内容 | 固定版本包含 NDK r28 构建适配，图片处理链路仍依赖其原生插件 |
| `webdav_client` | `2f669c98fb81cff1c64fee93466a1475c77e4273` | `wgh136/webdav_client` / BSD-3-Clause | 固定版本增加多种认证方式支持，WebDAV 阅读和备份依赖该兼容性 |
| `flutter_saf` | `056a419a504258e6c6352871f9c888b3fd5bc2f4` | `venera-app/venera-prime` 的 `packages/flutter_saf`，源自 `venera-app/flutter_saf` / 插件许可证仍为占位内容 | 保留 `0.0.1` 插件接口与发布构建配置，获取目录句柄、JNI 生命周期和通用 DocumentsProvider 修复；详见依赖审计 |
| `flutter_7zip` | `b33344797f1d2469339e0e1b75f5f954f1da224c` | `wgh136/flutter_7zip` / 许可证文件仍为占位内容 | 固定版本修复编译错误，CBZ 和归档兼容回退链路依赖该插件 |

上表依据固定源码和提交说明记录保留定制依赖的原因。完整机器可读清单见 [git_dependencies.json](git_dependencies.json)，详细替换审计与责任边界见 [Git 依赖接管与替换审计](dependency_audit.zh.md)。每次升级 Git 依赖时，应在 PR 中补充上游仓库、对比范围、全部定制修改、上游 PR（如有）、安全影响和回滚方式。
`desktop_webview_window` 未声明许可证，`lodepng_flutter`、`flutter_saf` 和 `flutter_7zip` 的许可证文件仍是占位内容。这些是已知供应链债务：升级前必须向维护方核实许可证，无法确认时应迁移到许可证清晰的上游版本或替代包。

`flutter_qjs` 的源码与补丁在 [Venera-flutter_qjs](https://github.com/Venera-Works/Venera-flutter_qjs) 独立维护，[UPSTREAM.md](https://github.com/Venera-Works/Venera-flutter_qjs/blob/8e7db82c57f2c780eebd4c7c6903d3aa41a65e2e/UPSTREAM.md) 记录原始基线及回移范围。应用的声明、锁文件和来源清单固定同一完整提交。

## 上游化流程

1. 将当前 commit 与上游对应版本进行差异比较。
2. 将可通用的修改拆成最小 PR 提交上游。
3. 对无法上游化的修改补充本仓库维护说明和测试。
4. 上游发布安全修复后，先更新 fork，再更新本项目锁定 commit。
5. 连续失去维护且无法替代的依赖应记录风险，不应无声切换到浮动分支。

## 审查清单

- [ ] `pubspec.yaml` 使用固定 commit，未出现 `HEAD` 或默认分支。
- [ ] `pubspec.lock` 的 resolved commit 与声明一致。
- [ ] 已运行 `fvm dart tool/check_git_dependencies.dart`，工作流没有绕过清单全局安装 Git 工具。
- [ ] 依赖声明改动后已运行 `fvm flutter pub get --enforce-lockfile`，并对受影响模块执行 `fvm flutter analyze` 与相关 `fvm flutter test`。
- [ ] 需要的平台构建已在获授权的本机或 CI 中完成；未验证的平台与原因已说明，未把依赖准备成功视为运行验证。
- [ ] 已检查许可证、安全公告和上游变更记录。
