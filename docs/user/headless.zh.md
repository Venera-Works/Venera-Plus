# VeneraPlus 无头命令模式

英文版本：[headless.en.md](headless.en.md)

VeneraPlus 的无头命令模式允许从命令行运行部分关键功能，适合自动化任务或与其他工具集成。本文档说明当前可用命令和输出格式。

## 使用方式

运行 VeneraPlus 可执行文件时添加 `--headless` 参数（Linux 命令为 `venera-plus`，Windows 为 `VeneraPlus.exe`），并跟随需要执行的命令。

```bash
venera-plus --headless <command> [subcommand] [options]
```

先在图形界面完成账号、同步目标、漫画源和主页收藏夹等所需配置，再使用对应命令。Windows PowerShell 可在已安装程序的目录中运行 `.\VeneraPlus.exe`，例如：

```powershell
.\VeneraPlus.exe --ignore-disheadless-log --headless webdav up
```

## 全局选项

- **`--ignore-disheadless-log`**：抑制应用日志，保留 `[CLI PRINT]` 结果。将此选项放在 `--headless` 前，避免它被当成命令参数。

## 命令

### `webdav`

命令名保留为 `webdav`，实际使用“设置 → 存储与同步 → 应用数据同步”中配置的统一网盘或 WebDAV 账号及目录，操作完整 `.venera` 快照。未配置同步目标时会报错。

- **`webdav up`**：上传当前本地完整快照。
- **`webdav down`**：手动下载并恢复按版本排序最新的远端完整快照，即使其版本低于本机；与自动下载的版本跳过规则不同。

只有 `up` 和 `down` 可用；网络或恢复失败会输出 `status: error` 并以非零退出码结束。

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

汇总的 `status: success` 表示批处理已经结束；仍需检查 `data.errors`，单个源失败不一定使该命令以非零退出码结束。

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

检查主页和自动追更使用的持久化收藏夹绑定。命令会等待待处理下载完成；未绑定或已删除的收藏夹会报错。

- **`updatesubscribe`**：检查主页绑定收藏夹内的漫画。
- **`updatesubscribe --update-comic-by-id-type <id> <type>`**：按 `id` 和 `type` 更新该收藏夹中的单个漫画。

**示例：**

```bash
# 更新绑定收藏夹中的全部漫画
venera-plus --headless updatesubscribe

# 更新单个漫画
venera-plus --headless updatesubscribe --update-comic-by-id-type "comic-id" "source-key"
```

## 输出格式

无头命令的结构化结果是带 `[CLI PRINT]` 前缀的 JSON 对象。脚本应筛选此前缀，再解析其后的 JSON，不将其他标准输出当作结果。对象始终包含 `status` 和 `message`，返回数据时还会包含 `data` 字段。

`webdav` 传输失败、无效命令和 `updatesubscribe` 检查错误使用非零退出码；`updatescript` 的逐项失败按上面的汇总规则判断。同步范围与快照恢复规则见[应用数据同步](data_sync.zh.md)。

### `updatesubscribe` 输出

`updatesubscribe` 会用 JSON 输出详细进度和最终结果。

**进度日志：**

更新过程中会收到 `Progress` 或 `ProgressError` 消息。

- **`Progress`**：表示更新流程中的一个步骤成功。
- **`ProgressError`**：表示更新某个漫画时发生错误。

进度和 `Update check complete.` 汇总中的 `data` 提供 `updated`、`unchanged`、`baseline`、`unknown`、`errors` 计数，以及本次发现的新增章节数 `newChapters`。首次获得比较依据计入 `baseline`；缺少可比较章节、页数和日期计入 `unknown`，不计为没有更新。单本进度还提供 `updateStatus`，值为 `updated`、`unchanged`、`baseline` 或 `unknown`；请求失败通过 `ProgressError` 和 `error` 字段报告，不重复计入 `unknown` 数量。

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

更新完成后会返回最终 JSON 对象，其中 `data` 是当前仍有待确认更新的漫画列表，包含此前检查发现且尚未读完或手动确认的更新。

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
