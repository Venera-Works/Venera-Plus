<div align="center">
  <img src="assets/readme_logo.png" alt="VeneraPlus" width="200" />

  # VeneraPlus

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/Venera-Works/Venera-Plus?label=Release&color=10B981&style=flat-square)](https://github.com/Venera-Works/Venera-Plus/releases/latest)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
</div>

VeneraPlus 是一款在手机和电脑上使用的漫画阅读器，可以读本地文件、网盘漫画，也能通过漫画源扩展浏览在线内容。漫画内容和漫画源需自行准备。

## 能做什么

- **本地阅读**：导入图片文件夹、CBZ / CB7 / ZIP / 7Z 压缩包、PDF 和图片型 EPUB。
- **多种阅读方式**：单页、双页、连续滚动、瀑布流，支持左右翻页、自动翻页、亮度和条漫边距调节。
- **网盘漫画库**：连接百度网盘、夸克、115、123 云盘、OneDrive、Google Drive 或 WebDAV，按需加载漫画图片。
- **收藏与进度**：管理收藏、阅读记录和下载，可关联 Bangumi 条目并向 Bangumi 同步阅读进度。可为网盘漫画刮削元数据。
- **同步与备份**：在设备间同步收藏、设置和阅读记录，也可单独备份漫画文件。

## 下载安装

点击下表链接下载 **v3.1.3 正式版**，也可前往 [最新版发布页](https://github.com/Venera-Works/Venera-Plus/releases/latest) 查看更新：

| 设备 | 选择哪个文件 |
|---|---|
| Android 手机 / 平板 | 安卓设备可下载 [arm64](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/VeneraPlus-3.1.3-android-arm64-v8a.apk) 版本，，不清楚型号时安装 [通用版](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/VeneraPlus-3.1.3-android.apk) |
| Windows | [Windows-installer.exe](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/VeneraPlus-3.1.3-windows-installer.exe) 安装版，或 [Windows-portable.zip](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/VeneraPlus-3.1.3-windows-portable.zip) 解压便携版 |
| Linux | Ubuntu / Debian：[.deb（x64）](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/venera-plus_3.1.3_amd64.deb)、[.deb（ARM64）](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/venera-plus_3.1.3_arm64.deb)；Arch Linux：[.pkg.tar.zst（x64）](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/venera-plus-3.1.3-30-x86_64.pkg.tar.zst) |
| iPhone / iPad | [.ipa](https://github.com/Venera-Works/Venera-Plus/releases/download/v3.1.3/VeneraPlus-ios-3.1.3%2B30.ipa)，需自行签名安装 |
| macOS | 当前暂无正式安装包，可参阅[构建指南](docs/development/build.zh.md)自行构建 |

`Source code` 是源码，不是安装包。

## 第一次使用

1. **读本地漫画**：打开「书库 → 本地漫画 → 导入」，选择漫画文件夹、压缩包、PDF 或图片型 EPUB。
2. **读网盘漫画**：在「设置 → 存储与同步 → 网盘账号」添加账号，再到「在线漫画库」选择存放漫画的目录；回到「发现」选择该漫画库即可阅读。网盘里的压缩包需先解压为图片目录。
3. **使用漫画源**：在「设置 → 来源与服务 → 管理漫画源」安装自行获取的扩展，再到「发现」浏览或使用右上角搜索。

主页可以绑定常看的收藏夹。

## 同步、备份与迁移

以下入口都在「设置 → 存储与同步」中：

| 入口 | 用来做什么 |
|---|---|
| 应用数据同步 | 通过网盘或 WebDAV 上传、恢复设置、收藏和阅读记录等应用数据，不包含漫画图片；支持手动、实时和定时同步 |
| 漫画归档备份 | 将本地漫画文件备份到网盘或 WebDAV，需要时下载恢复 |
| 应用数据导入与导出 | 手动导出或导入 `.venera` 数据备份，方便迁移收藏、记录和设置 |

从 Venera 迁移时，先在旧版导出 `.venera`，再在新版「应用数据导入与导出」中导入；已下载的漫画文件需另行迁移。

同步下载会用云端的完整备份恢复本地数据，不会逐条合并。备份包含漫画库配置和账号登录信息，请使用可信的存储位置。

## 文档与反馈

- 使用说明：[本地漫画导入](docs/user/import_comic.zh.md) · [多网盘设置](docs/user/multi_cloud.zh.md) · [应用数据同步](docs/user/data_sync.zh.md) · [全部文档](docs/README.md)
- 遇到问题：在 [GitHub Issues](https://github.com/Venera-Works/Venera-Plus/issues) 附上系统、应用版本、复现步骤和日志。漫画源内容或失效问题请联系对应源作者。
- 开发与贡献：使用 **Flutter 3.41.4**，参阅[构建指南](docs/development/build.zh.md)和[贡献指南](CONTRIBUTING.md)。

## 许可与致谢

项目使用 [GPL-3.0](LICENSE) 许可证。感谢 [venera-app/venera](https://github.com/venera-app/venera) 、 [CyrilPeng/Venera-Next](https://github.com/CyrilPeng/Venera-Next) 、[OpenList](https://github.com/OpenListTeam/OpenList) 的开源贡献。
