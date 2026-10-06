# VeneraPlus 无头命令模式

英文版本：[headless.en.md](headless.en.md)

VeneraPlus 的无头命令模式允许从命令行运行部分关键功能，适合自动化任务或与其他工具集成。本文档说明当前可用命令和输出格式。

## 使用方式

运行 VeneraPlus 可执行文件时添加 `--headless` 参数（Linux 命令为 `venera-plus`，Windows 为 `VeneraPlus.exe`），并跟随需要执行的命令。

```bash
venera-plus --headless <command> [subcommand] [options]
```

## 全局选项

- **`--ignore-disheadless-log`**：抑制日志输出，使脚本解析输出时更干净。

## 命令

### `webdav`

管理 WebDAV 数据同步。

- **`webdav up`**：上传完整本地应用数据快照；仅下载方向下拒绝执行。
- **`webdav down`**：下载最新远端应用数据快照（双向方向下仅下载更新版本）；仅上传方向下拒绝执行。

命令等待已有同步/配置操作结束，并以非零退出码报告实际操作失败，不能绕过方向限制。下载拒绝有歧义的最新版本，并保护网络等待期间新增的本地修改。整包快照与 ETag 限制见[应用数据同步](data_sync.zh.md)。

**示例：**

```bash
venera-plus --headless webdav up
```

### `updatescript`

更新漫画源脚本。

- **`updatescript all`**：检查并应用所有可用的漫画源脚本更新。

**示例：**

```bash
venera-plus --headless updatescript all
```

**输出格式：**

`updatescript` 会输出详细进度和最终汇总。

**进度日志：**

- **`Progress`**：单个脚本更新成功。
- **`ProgressError`**：某个脚本更新失败。

**`Progress` 日志示例：**

```json
{
  "status": "running",
  "message": "Progress",
  "data": {
    "current": 1,
    "total": 5,
    "source": {
      "key": "source-key",
      "name": "Source Name",
      "version": "1.0.0",
      "url": "https://example.com/source.js"
    }
  }
}
```

**最终汇总：**

命令结束时会输出脚本总数、更新数量和失败数量。

```json
{
  "status": "success",
  "message": "All scripts updated.",
  "data": {
    "total": 5,
    "updated": 4,
    "errors": 1
  }
}
```

### `updatesubscribe`

使用与主页和自动追踪一致的持久化**在读**收藏角色。命令先等待待处理下载，再解析角色绑定；在读被删除或未绑定时返回错误，不会改扫其他收藏夹。

- **`updatesubscribe`**：检查绑定在读收藏夹内的漫画。
- **`updatesubscribe --update-comic-by-id-type <id> <type>`**：按 `id` 和 `type` 更新该收藏夹中的单个漫画。

**示例：**

```bash
# 更新全部在读漫画
venera-plus --headless updatesubscribe

# 更新单个漫画
venera-plus --headless updatesubscribe --update-comic-by-id-type "comic-id" "source-key"
```

## 输出格式

所有无头命令都会输出带 `[CLI PRINT]` 前缀的 JSON 对象。该结构便于自动化脚本解析。JSON 对象始终包含 `status` 和 `message`，返回数据时还会包含 `data` 字段。

### `updatesubscribe` 输出

`updatesubscribe` 会用 JSON 输出详细进度和最终结果。

**进度日志：**

更新过程中会收到 `Progress` 或 `ProgressError` 消息。

- **`Progress`**：表示更新流程中的一个步骤成功。
- **`ProgressError`**：表示更新某个漫画时发生错误。

**`Progress` 日志示例：**

```json
{
  "status": "running",
  "message": "Progress",
  "data": {
    "current": 1,
    "total": 10,
    "comic": {
      "id": "some-comic-id",
      "name": "Some Comic Name",
      "coverUrl": "https://example.com/cover.jpg",
      "author": "Author Name",
      "type": "source-key",
      "updateTime": "2023-10-27T12:00:00Z",
      "tags": ["tag1", "tag2"]
    }
  }
}
```

**`ProgressError` 日志示例：**

```json
{
  "status": "running",
  "message": "ProgressError",
  "data": {
    "current": 2,
    "total": 10,
    "comic": {
      "id": "another-comic-id",
      "name": "Another Comic Name"
    },
    "error": "Error message here"
  }
}
```

**最终输出：**

更新完成后会返回最终 JSON 对象，其中 `data` 是本次检测到更新的漫画列表。

```json
{
  "status": "success",
  "message": "Updated comics list.",
  "data": [
    {
      "id": "some-comic-id",
      "name": "Some Comic Name",
      "coverUrl": "https://example.com/cover.jpg",
      "author": "Author Name",
      "type": "source-key",
      "updateTime": "2023-10-27T12:00:00Z",
      "tags": ["tag1", "tag2"]
    }
  ]
}
```
