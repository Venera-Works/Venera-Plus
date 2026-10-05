<div align="center">
  <img src="assets/readme_logo.png" alt="VeneraPlus" width="200" />

  # VeneraPlus

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![GitHub](https://img.shields.io/badge/GitHub-Venera--Works%2FVenera--Plus-181717?logo=github&style=flat-square)](https://github.com/Venera-Works/Venera-Plus)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
</div>

> [!CAUTION]
> **这是一个由个人/团队独立维护的项目，包含激进改动与实验性调整。**
>
> 本项目按维护者的设备、数据和使用习惯开发，可能大量使用生成式 AI 参与设计、编码、测试、审查和文档编写，也可能进行范围较大、节奏较快、未经长期验证的激进修改。
>
> 本项目不保证稳定性、向后兼容性或与历史来源仓库同步，不保证兼容旧版 VeneraNext、Venera、第三方扩展、既有配置、数据文件、备份或其他项目。切换版本、导入数据或连接 WebDAV 前，请自行备份重要数据并确认能够恢复。

## 项目定位

VeneraPlus 是托管于 [Venera-Works](https://github.com/Venera-Works) 组织（仓库名 `Venera-Plus`）的独立漫画阅读器项目，不再自称 VeneraNext 非官方 fork 发行版或通用下游分支。维护优先级取决于维护者的需求；功能、接口、数据结构和交互可能在没有长期过渡期的情况下发生调整。

本项目采用**全新独立的应用与安装身份**（可与旧版 Venera / VeneraNext 共存），新安装不会自动读取、搬迁、复制或删除旧版数据。如需从旧版迁移配置和阅读历史，请参阅 [VeneraPlus 品牌与应用身份迁移计划](doc/experiments/venera_plus_identity_migration.zh.md)。

> **仓库可见性与下载说明**：
> 官方仓库当前为公开仓库（Public；此前曾设为私有并在未鉴权请求时返回 404），克隆与访问代码支持公开访问。正式安装包与版本发布以 GitHub Releases 实际页面状态为准，不能仅从源码分支推断已发布或公网更新可用。

## 历史来源与致谢

本项目的历史继承谱系为：

```text
venera-app/venera
        ↓
CyrilPeng/Venera-Next
        ↓
原 miludeshiji/Venera-Next
        ↓
Venera-Works/Venera-Plus（代码仓库，应用名 VeneraPlus）
```

- 原始项目：[venera-app/venera](https://github.com/venera-app/venera)
- 历史直接上游：[CyrilPeng/Venera-Next](https://github.com/CyrilPeng/Venera-Next)
- 早期个人分支：`miludeshiji/Venera-Next`
- 当前独立项目：[Venera-Works/Venera-Plus](https://github.com/Venera-Works/Venera-Plus)（应用名：VeneraPlus）

感谢原项目和历史维护者的设计、实现与持续开源贡献。本项目中的大量基础能力源自上述项目。

**版权与维护边界声明**：
- 本项目忠实保留原作者的版权声明与 GPL-3.0 许可证，绝不冒认原项目版权。
- 历史项目仅作为来源事实记录；本项目独立演进，不承诺与历史来源同步，不向历史 upstream 提交 PR。
- 本项目的流程与反馈完全面向本仓库；请不要将本项目的改动向原上游项目反馈或索取支持，也不把向 upstream 复现作为本项目的必需支持路径。

## 当前修改与增强

当前项目在继承基础能力之上，重点维护和增强了以下能力：

- Bangumi 阅读进度同步：使用 Access Token 连接账号、绑定漫画条目，阅读完成单向上传并记录本地重试队列。
- 条漫左右边距调节：连续与瀑布流阅读器支持左右边距调节，并与图片自适应排版约束（`ComicImageLoadTarget`）及缓存键严格对齐。
- WebDAV 定时数据同步：支持多档定时同步调度与本地修改合并，规范敏感凭据与本地状态的设备隔离。
- 后台任务与存储保护：PDF 批量导入异步任务管理与存储锁机制。

完整变更见 [CHANGELOG.md](CHANGELOG.md)。

## 基础能力概览

本项目继承自 Venera 体系的主要阅读器能力，包括：

- Android、iOS、Windows、Linux 和 macOS 跨平台 Flutter 应用。
- 画廊、连续和瀑布流等阅读模式，以及跨章节阅读、双页拆分和阅读进度记录。
- 本地漫画目录及 CBZ、ZIP、7Z、PDF、图片型 EPUB 等导入能力。
- JavaScript 漫画源扩展运行环境。
- 收藏、历史、阅读时长、图片收藏、下载和追更。
- WebDAV 应用数据同步、漫画归档和远端漫画库。

这里仅列出能力范围，不代表本项目对所有平台、格式、扩展或服务均已完成生产环境长期验证。

## 使用与构建

本项目不承诺提供持续可用的公开安装包、自动更新或无缝升级支持。建议只在理解风险并完成数据备份后自行构建。

> [!IMPORTANT]
> **构建权限须知**：未经用户明确允许，禁止运行任何应用构建（包括 `flutter build`、`flutter run`、Gradle/CMake/MSBuild 编译、内部调用构建的打包入口及可能隐式编译的测试）；未经许可仅可进行不触发构建的静态检查。

项目当前要求 Flutter `3.41.4`，依赖必须按锁文件解析：

```bash
git clone https://github.com/Venera-Works/Venera-Plus.git
cd Venera-Plus
flutter pub get --enforce-lockfile
# 运行应用前须获得用户明确许可：
# flutter run
```

提交或维护代码前，至少运行：

```bash
python .github/scripts/check_structure_imports.py
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
dart tool/check_git_dependencies.dart
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

更完整的环境、构建和平台要求见：

- [构建与开发](doc/development/build.zh.md)
- [项目结构约定](doc/architecture/project_structure.zh.md)
- [依赖治理](doc/development/dependencies.zh.md)
- [VeneraPlus 品牌与应用身份迁移计划](doc/experiments/venera_plus_identity_migration.zh.md)
- [完整文档索引](doc/README.md)
- [本地漫画导入说明](doc/user/import_comic.zh.md)

## 反馈范围

可以提交与当前仓库直接相关、能够稳定复现的问题，也可以提交目标明确、范围较小的 Pull Request。但这是独立维护项目：是否处理、何时处理以及是否接受修改均由维护者决定。

请在反馈中提供：

- 当前 commit 或版本；
- 操作系统和 Flutter/应用环境；
- 最小复现步骤；
- 实际结果、预期结果和相关日志。

本仓库不提供、内置、托管、推荐或维护任何漫画源，也不处理源站内容、具体作品可用性、章节缺失、图片失效、账号限制或版权问题。此类问题应反馈给对应扩展、源站或服务提供者。

## 风险与数据

- AI 参与不代表代码已经得到完整人工审计或长期验证。
- 本项目包含独立修改与激进改动，可能产生语义变化或未发现的问题。
- WebDAV 同步可能传播配置和数据变更；试用前应保留独立备份。
- 全新独立安装身份不自动读取或迁移旧版数据；旧版数据迁移需通过手动导出/导入备份完成。
- 本仓库不对数据丢失、服务不可用、扩展失效或第三方兼容问题承担保证责任。

## 许可

本项目及其衍生修改遵循 [GPL-3.0](LICENSE) 许可。使用、修改和再分发时，请同时遵守原项目、直接上游及所用第三方依赖的许可要求。

软件按现状提供，不附带任何明示或默示担保。