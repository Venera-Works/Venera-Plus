<div align="center">
  <img src="assets/readme_logo.png" alt="VeneraPlus" width="200" />

  # VeneraPlus

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![GitHub](https://img.shields.io/badge/GitHub-Venera--Works%2FVenera--Plus-181717?logo=github&style=flat-square)](https://github.com/Venera-Works/Venera-Plus)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
</div>

VeneraPlus 是一款支持 Android、iOS、Windows、macOS 和 Linux 的跨平台漫画阅读器。支持多种阅读版式、丰富的本地漫画格式导入、WebDAV 数据同步与远端漫画库、Bangumi 进度与元数据联动，以及灵活的 JavaScript 漫画源扩展。

当前最新版本为 [2.2.3](https://github.com/Venera-Works/Venera-Plus/releases/tag/v2.2.3)。预编译安装包以 [GitHub Releases](https://github.com/Venera-Works/Venera-Plus/releases) 实际发布状态为准，完整变更记录请参阅 [更新日志](CHANGELOG.md)。

---

## 核心功能概览

### 阅读模式与阅读辅助
- **丰富阅读版式**：支持画廊翻页（单页/双页、支持从左到右与从右到左翻页）、连续滚动（纵向从上到下、横向左右滚动）以及纵向瀑布流模式。
- **双页自动拆分**：在画廊单图模式下可开启横向大图/跨页自动拆分为两个独立视觉页，并按阅读方向自动调整翻阅顺序。
- **条漫左右边距**：纵向连续和纵向瀑布流模式支持每侧 0%～30% 边距调节，在大屏设备上避免条漫过宽，图片居中等比缩放。
- **阅读体验辅助**：支持跨章节无缝阅读、夜间调光/阅读亮度调节、单手操作翻页、图片宽度限制、自动翻页与全屏阅读。

### 本地导入与文档支持
- **本地目录导入**：支持直接扫描或导入本地漫画文件夹（兼容包含章节子目录或单章节无子目录结构）。
- **多种压缩包归档**：支持 `.cbz`、`.cb7`、`.zip`、`.7z` 等 Comic Book Archive 格式漫画导入与归档。
- **PDF 与图片型 EPUB 转换**：
  - PDF 漫画支持多选批量导入，后台异步队列逐本解析入库，进度可收起并在前台自由浏览其他内容。
  - 支持固定版式图片型 EPUB 导入，提取栅格图片并在存在有效目录导航时保留分章。
- **下载扫描与归档恢复**：支持扫描本地存储路径恢复下载记录，支持 `.venera-comics` 漫画归档包导入与导出。

### 收藏、历史、下载与追更
- **收藏夹管理**：支持自定义收藏夹分类、排序与收藏夹内漫画拖拽排序。
- **阅读历史与时长**：自动记录阅读进度、上次阅读章节与阅读时长统计。
- **离线下载管理**：支持章节批量离线下载，提供下载任务队列管理、暂停/恢复与失败重试。
- **漫画追更检测**：支持已收藏漫画批量更新检查与新章节标记。

### WebDAV 数据同步与远端漫画库
- **应用数据同步**：
  - 支持设置、收藏、历史、Cookie 和已安装漫画源扩展的应用数据同步（不包含本地漫画图片文件）。
  - 提供**手动同步**、**实时同步**（本地修改触发上传，启动/恢复前台检查远端）与**定时同步**（5～360 分钟间隔合并上传）三种模式。
  - 定时调度由应用进程内计时器驱动（仅在应用运行期间调度，非系统后台保活服务，启动与恢复前台时自动补做到期任务）。
  - 同步采用整包快照机制；WebDAV 凭据、同步调度模式、本地待同步状态等设备敏感信息严格保留在本地，不随快照上传或被覆盖。
- **WebDAV 在线漫画库**：
  - 支持直接将 WebDAV 作为远端漫画书库在线流式阅读，按需拉取目录与图片，无需全量下载。
  - 支持普通图片目录结构、带有 `metadata.json` 标记的多层目录结构，以及解压后的 CBZ 漫画目录。
  - 「同步漫画库配置」选项默认独立关闭，仅在可信网络且两端主动开启时随数据快照加密同步。

### Bangumi 元数据与阅读进度
- **账号与条目关联**：支持配置 Bangumi Access Token 关联账号，可在漫画详情页手动搜索并绑定 Bangumi 条目。
- **WebDAV 自动刮削**：WebDAV 漫画库自动刮削功能默认关闭；按需启用后，可在同步时为缺少元数据的漫画自动匹配 Bangumi 条目并补充标题、作者、简介与标签。
- **进度单向同步**：漫画阅读完成后可单向更新 Bangumi 条目的阅读状态与卷数/话数进度，支持本地失败重试队列。

### JavaScript 漫画源扩展
- **轻量扩展运行时**：内置 JavaScript 运行时环境，支持通过 JS 脚本扩展更多网络漫画源。
- **源管理与调试**：支持漫画源仓库订阅、检查更新、本地预览安装、单源调试与安装回滚。
- **排版与网络适配**：支持漫画源根据阅读器视口排版请求自适应图片尺寸，支持自定义 Header 与 User-Agent 安全回退。
- *声明：本项目仅提供扩展运行环境与接口规范，不内置、不提供、不维护、不推荐任何第三方漫画源。*

---

## 下载与快速入门

### 获取应用
前往 [GitHub Releases](https://github.com/Venera-Works/Venera-Plus/releases) 下载适用于对应平台的安装包或便携包。

### 数据迁移（可选）
VeneraPlus 与旧版 Venera / VeneraNext 互为独立应用，可并存安装使用。如需从旧版迁移数据：
1. 在旧版应用中打开 **设置 → 应用 → 导出应用数据**，导出 `.venera` 数据备份文件。
2. 在 VeneraPlus 中打开 **设置 → 应用 → 导入应用数据**，选取备份文件恢复收藏与历史。

### 快速上手
- **本地阅读**：打开「本地」页面，通过导入入口即可导入漫画目录、压缩包（CBZ/ZIP/7Z）或批量导入 PDF。
- **数据同步**：前往「设置 → 应用 → 数据同步」，配置 WebDAV 服务端信息并选择同步模式。
- **远端漫画库**：前往「设置 → 应用 → WebDAV 漫画库」配置远端漫画库路径，并在「探索 → WebDAV 漫画库」中在线浏览与阅读。

---

## 反馈与支持

- **提交问题**：如遇到阅读器本体的缺陷或有功能建议，欢迎在 [GitHub Issues](https://github.com/Venera-Works/Venera-Plus/issues) 提交反馈。提交时请附带系统平台、应用版本、复现步骤及相关日志。
- **漫画源相关问题**：本仓库只维护阅读器本体，不处理第三方漫画源的图源失效、更新缺失、搜索内容或版权问题。相关问题请向对应漫画源作者或网络服务方反馈。

## 文档索引

- **用户使用指南**：
  - [本地漫画导入指南](doc/user/import_comic.zh.md)
  - [应用数据同步说明](doc/user/data_sync.zh.md)
  - [条漫左右边距说明](doc/user/reader_width.zh.md)
- **开发与贡献**：
  - [项目完整文档索引](doc/README.md)
  - [构建与开发指南](doc/development/build.zh.md)
  - [贡献指南](CONTRIBUTING.md)

---

## 开发与构建

本项目基于 **Flutter 3.41.4** 开发。

环境准备、依赖锁定、各平台构建步骤与贡献规范请参阅上方的 [构建与开发指南](doc/development/build.zh.md) 及 [贡献指南](CONTRIBUTING.md)。

---

## 许可与历史来源致谢

本项目遵循 [GPL-3.0](LICENSE) 许可证开源。

### 历史来源与致谢
- [venera-app/venera](https://github.com/venera-app/venera)
- [CyrilPeng/Venera-Next](https://github.com/CyrilPeng/Venera-Next)

感谢原项目与历史维护者的架构设计与开源奉献。