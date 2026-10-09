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

- **`webdav sync`**：立即按当前配置方向同步：双向合并并发布，仅上传只发布，仅下载合并但不发布。顶层 **`sync`** 命令执行相同操作。
- **`webdav up`**：发布本地完整因果检查点，不应用远端业务数据；仅下载方向下拒绝执行。不是上传数据库整包覆盖云端。
- **`webdav down`**：合并远端有效检查点，保留本地修改候选，不发布；仅上传方向下拒绝执行。不是强制下载覆写。
- **`webdav conflicts`**：读取当前本机已知的记录/字段冲突，不主动拉取新的远端内容；顶层 **`conflicts`** 命令相同。要查看远端最新冲突，请先执行允许读取远端的同步。
- **`webdav resolve`**：对一个记录的一个字段选择已有候选；顶层 **`resolve`** 命令相同。参数见下文。
- **`webdav backups`**：列出 WebDAV 根目录数字命名的原版备份；结果为 `data.count` 和 `data.backups`，每项只有 `name`、`day`、`version`。列表本身不读取备份正文。
- **`webdav import-backup <name> --confirm`**：因果合并明确选择的根目录原版备份，遵守当前方向；不是本地 ZIP 覆盖恢复。必须使用列表中的完整文件名并显式确认，缺少确认会在应用初始化前拒绝，不触发首次自动种子读取。

命令等待启动恢复及已有同步/配置操作结束。实际操作失败以 `status: error` 和非零退出码报告，不能绕过方向限制。认证、网络和应用错误不算成功，未完成工作留待重试；已经提交的远端或本地内容不会因后续失败被假回滚。协议、一次性旧档迁移及崩溃恢复边界见[应用数据同步](data_sync.zh.md)。

`webdav sync` / `sync` 完整传输成功时输出 `status: success`，`data.conflictCount` 和 `data.hasConflict` 表示仍需处理的冲突。**存在候选冲突仍可成功退出（退出码 0）**；成功不等于已经自动选定所有候选。源相关领域暂不可用但其他领域传输完成时，`sync`、`up`、`down` 输出 `status: partial`（退出码 0），并给出 `data.unavailableDomains` 与 `data.sourceIssues`；`sync` 仍附冲突计数。源摘要只包含文件名、安全原因及翻译、是否有备份和操作提示，不输出脚本、会话、源身份或私有备份路径。`repairAction` 区分应用内替换、重试恢复及“须先恢复完整日志”的前置条件，不将坏备份当作可直接恢复的数据。`up` / `down` 不附冲突列表，需另查 `conflicts`。

备份导入成功输出 `data.imported`：`true` 表示有新的种子领域导入，重复操作为 `false`，不是“传输成功”的别名。部分源异常时输出 `status: partial`（退出码 0）及安全的源摘要和不可用领域，仍保留 `data.imported`；实际错误以非零退出码报告。合法命令仍有普通应用启动恢复/首次自动种子的行为边界，不能把备份列表命令当成禁用启动同步的开关。

**示例：**

```bash
venera-plus --headless webdav up
```

**选择并确认原版根目录备份：**

```bash
venera-plus --headless webdav backups
venera-plus --headless webdav import-backup 20261008-1.venera --confirm
```

**逐项解决冲突：**

```bash
venera-plus --headless webdav sync
venera-plus --headless webdav conflicts

# 从 conflicts 的 JSON 输出复制值到变量；变量名仅为示意
venera-plus --headless webdav resolve --record-key "$RECORD_KEY" --field "$FIELD" --candidate-id "$CANDIDATE_ID"
```

`conflicts` 的成功输出中，`data.count` 是冲突数，`data.conflicts` 是数组，每项包含：

- `recordKey`：记录键字符串。其内容是 JSON 编码的身份数组，**不是点分路径**；用 JSON 解析器取出字符串值后完整传入，不自行拼造键或把外层 JSON 转义也一并传入。
- `field`：需处理的字段名，直接复制。
- `candidates`：候选数组，各项包含 `id`、`actor`、`counter`、`isDeleted` 和 `label`。`id` 是不透明候选 ID，可能包含特殊字符，直接复制，**不要按设备/计数器猜格式**；`isDeleted` 指示删除候选；`label` 是安全摘要，不含原始秘密候选值。

`resolve` 必须提供 `--record-key`（别名 `--key`）、`--field`、`--candidate-id`（别名 `--candidate`）。也可只提供恰好三个位置参数，依次为记录键、字段、候选 ID：

```bash
venera-plus --headless resolve "$RECORD_KEY" "$FIELD" "$CANDIDATE_ID"
```

请按所用 shell 的规则转义/引用这些值，尤其保留记录键内部的双引号。上面的双引号变量示例适用于 Bash 与 PowerShell，Windows `cmd.exe` 的变量和转义语法不同。选择过期或不存在的候选会报错，请重新读取 `conflicts`。

成功时 `data` 返回 `recordKey`、`field`、`candidateId` 和 `remainingConflicts`。选择产生新的因果修改：双向/仅上传可发布，仅下载只在本机保留待发布结果。上传失败可能发生在本地选择已持久提交之后，错误不意味着选择已经撤销。命令不提供全局“保留本地/云端整包”或强制覆写选项；手动 `.venera` 备份恢复仍独立。

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

使用与主页展示和自动追更一致的持久化收藏角色（`reading`）。用户在主页或书库中选择绑定收藏夹，默认未绑定，不会自动创建“在读”。命令先等待待处理下载，再解析角色绑定；绑定收藏夹被删除或未绑定时返回错误，不会改扫其他收藏夹。

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
