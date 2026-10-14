# OpenList 嵌入内核

此目录保存 VeneraPlus 的 OpenList 嵌入层，而不是一个 OpenList HTTP 服务。准备脚本把固定上游源码
`482464c2affc5eeba5d4a25bb272aeb352ec5918` 复制到构建目录，应用本目录的最小补丁后再复制 bridge。
因此 `cache/OpenList` 只是开发缓存，发布构建不依赖对该缓存的未跟踪修改。

## RPC ABI

桌面动态库导出 `OpenListAllocate(int) -> void*`、`OpenListInvoke(const char*) -> char*` 与
`OpenListFree(void*)`。请求为 UTF-8 JSON：`{"method":"list","arguments":{...}}`；响应为
`{"data":...,"error":{"code":"...","message":"..."}}`。移动端通过 `venera/openlist` 的
`invoke` 方法传递同一请求和响应。传输请求返回 `taskId`，以 `taskStatus` 轮询并以 `cancel` 取消。

所有远端路径都是账号根目录下的绝对路径。账号只接受 `BaiduNetdisk`、`QuarkOpen`、`115 Open`、
`123 Open`、`Onedrive`、`GoogleDrive` 六个驱动。Token 等授权字段只出现在 `saveAccount` 的
`addition` 中；日志关闭，错误响应也会清理常见凭据字段。

## 构建

CI 运行 `scripts/prepare_openlist_core.py`，其输出目录内执行以下目标：Android AAR、iOS
XCFramework，以及 Windows、macOS、Linux 的 C ABI 动态库。本地不运行这些编译命令。Go 版本固定为
`1.27.1`，gomobile 固定为 `v0.0.0-20260908204917-8b95e45f8d3e`。

Go 1.27 仅支持 macOS 13 及以上。应用本身继续支持 macOS 12；原生
`venera/method_channel` 的 `isOpenListSupported` 在 macOS 12 返回 `false`，Dart
不得加载动态库。因此 macOS 12 仅提供本地和 WebDAV 存储。依据见
[Go 1.27 release notes](https://go.dev/doc/go1.27)。
