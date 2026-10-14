# OpenList 嵌入内核

此目录保存 VeneraPlus 使用的 OpenList 内核锁定信息和运行时接口，而不是一个 OpenList HTTP 服务。
内核由独立的 `Venera-Works/Venera-OpenList-Core` 仓库构建并发布；应用构建通过
`.github/scripts/fetch_openlist_core.py` 下载 `core.lock.json` 固定版本的对应平台产物。
`cache/Venera-OpenList-Core` 是内核仓库的开发工作区，发布内核时应在该仓库中构建。

## RPC ABI

桌面动态库导出 `OpenListAllocate(int) -> void*`、`OpenListInvoke(const char*) -> char*` 与
`OpenListFree(void*)`。请求为 UTF-8 JSON：`{"method":"list","arguments":{...}}`；响应为
`{"data":...,"error":{"code":"...","message":"..."}}`。移动端通过 `venera/openlist` 的
`invoke` 方法传递同一请求和响应。传输请求返回 `taskId`，以 `taskStatus` 轮询并以 `cancel` 取消。

所有远端路径都是账号根目录下的绝对路径。账号只接受 `BaiduNetdisk`、`QuarkOpen`、`115 Open`、
`123 Open`、`Onedrive`、`GoogleDrive` 六个驱动。Token 等授权字段只出现在 `saveAccount` 的
`addition` 中；日志关闭，错误响应也会清理常见凭据字段。

## 构建

应用 CI 下载 Android AAR、iOS XCFramework，以及 Windows、macOS、Linux 的 C ABI 动态库；不再在
VeneraPlus 工作流中安装 Go 或编译内核。升级内核时只更新 `core.lock.json` 中已发布的版本、源码提交和
各资产摘要，再运行对应平台 CI。许可证随下载的内核产物安装到各平台打包目录。

Go 1.27 仅支持 macOS 13 及以上。应用本身继续支持 macOS 12；原生
`venera/method_channel` 的 `isOpenListSupported` 在 macOS 12 返回 `false`，Dart
不得加载动态库。因此 macOS 12 仅提供本地和 WebDAV 存储。依据见
[Go 1.27 release notes](https://go.dev/doc/go1.27)。
