# VeneraPlus Headless Mode

Default Chinese version: [headless.zh.md](headless.zh.md)

VeneraPlus's headless mode allows you to run key features from the command line, making it easy to automate tasks and integrate with other tools. This document outlines the available commands and their usage.

## How to Use

To activate headless mode, use the `--headless` flag when running the VeneraPlus executable (e.g. `venera-plus` on Linux or `VeneraPlus.exe` on Windows), followed by the desired command.

```bash
venera-plus --headless <command> [subcommand] [options]
```

## Global Options

- **`--ignore-disheadless-log`**: Suppresses log output, providing a cleaner output for scripting.

## Commands

### `webdav`

Manage WebDAV data synchronization.

- **`webdav sync`**: Runs immediately in the configured direction: bidirectional merges and publishes, upload-only publishes, and download-only merges without publishing. The top-level **`sync`** command does the same.
- **`webdav up`**: Publishes a full local causal checkpoint without applying remote business data. Rejected in download-only direction. This is not a whole-database upload overwriting the cloud.
- **`webdav down`**: Merges valid remote checkpoints, retaining local edit candidates, without publishing. Rejected in upload-only direction. This is not forced download overwrite.
- **`webdav conflicts`**: Reads record/field conflicts currently known locally; it does not fetch new remote content. Top-level **`conflicts`** does the same. To inspect up-to-date remote conflicts, first run synchronization in a direction allowing remote reads.
- **`webdav resolve`**: Selects an existing candidate for one field of one record. Top-level **`resolve`** does the same. Arguments are described below.

Commands wait for startup recovery and existing sync/configuration work. Actual operation failures report `status: error` and a nonzero exit code; commands cannot bypass direction restrictions. Authentication, network, and application errors are not success, and unfinished work is retained for retry. A later failure does not pretend to undo already committed remote or local changes. See [App Data Synchronization](data_sync.en.md) for protocol, one-time legacy migration, and crash-recovery boundaries.

Successful transfer through `webdav sync` / `sync` outputs `status: success`, with `data.conflictCount` and `data.hasConflict` describing conflicts still requiring attention. **Unresolved candidate conflicts can coexist with success (exit code 0).** Success does not mean every candidate was selected automatically. Successful `up` / `down` messages do not contain conflict lists; query `conflicts` separately.

**Example:**

```bash
venera-plus --headless webdav up
```

**Resolving individual conflicts:**

```bash
venera-plus --headless webdav sync
venera-plus --headless webdav conflicts

# Copy values from the conflicts JSON output into variables; names are illustrative
venera-plus --headless webdav resolve --record-key "$RECORD_KEY" --field "$FIELD" --candidate-id "$CANDIDATE_ID"
```

The successful `conflicts` response has `data.count` and a `data.conflicts` array. Each entry contains:

- `recordKey`: The record-key string. Its contents are a JSON-encoded identity array, **not a dot-separated path**. Extract the string with a JSON parser and pass it intact; do not construct your own key or pass the outer JSON escaping as part of the argument.
- `field`: The field requiring resolution; copy it directly.
- `candidates`: An array with `id`, `actor`, `counter`, `isDeleted`, and `label` per candidate. The `id` is opaque and may contain special characters. Copy it directly; **do not infer its format from actor/counter**. `isDeleted` marks deletion candidates. `label` is a safe summary, not a raw secret candidate value.

`resolve` requires `--record-key` (alias `--key`), `--field`, and `--candidate-id` (alias `--candidate`). Alternatively, pass exactly three positional arguments in record-key, field, candidate-ID order:

```bash
venera-plus --headless resolve "$RECORD_KEY" "$FIELD" "$CANDIDATE_ID"
```

Quote/escape values according to your shell, especially the double quotes inside a record key. The quoted-variable examples above apply to Bash and PowerShell; Windows `cmd.exe` has different variable/escaping syntax. Stale or nonexistent candidates fail; query `conflicts` again.

Success returns `recordKey`, `field`, `candidateId`, and `remainingConflicts` in `data`. Selection creates a new causal edit: bidirectional/upload-only can publish it, while download-only retains it locally for later publication. Upload can fail after the local choice has durably committed; an error does not mean that choice was undone. There is no global keep-local/keep-cloud snapshot selection or force-overwrite option. Manual `.venera` backup/restore remains separate.

### `updatescript`

Update comic source scripts.

- **`updatescript all`**: Checks for and applies all available updates for your comic source scripts.

**Example:**

```bash
venera-plus --headless updatescript all
```

**Output Format:**

The `updatescript` command provides detailed progress and a final summary.

**Progress Logs:**

- **`Progress`**: Indicates a successful update for a single script.
- **`ProgressError`**: Indicates a failure during a script update.

**Example `Progress` Log:**

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

**Final Summary:**

A summary is provided at the end, detailing the total number of scripts, how many were updated, and how many failed.

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

Checks the same persisted **Reading** favorites role used by Home and automatic tracking. The command waits for pending downloads before resolving the role; a deleted/unbound Reading folder is an error, not a reason to scan another folder.

- **`updatesubscribe`**: Checks comics in the bound Reading folder.
- **`updatesubscribe --update-comic-by-id-type <id> <type>`**: Updates one comic in that folder by `id` and `type`.

**Example:**

```bash
# Update all subscriptions
venera-plus --headless updatesubscribe

# Update a single comic
venera-plus --headless updatesubscribe --update-comic-by-id-type "comic-id" "source-key"
```

## Output Format

All headless commands output JSON objects prefixed with `[CLI PRINT]`. This structured format allows for easy parsing in automated scripts. The JSON object always contains a `status` and a `message`. For commands that return data, a `data` field will also be present.

### `updatesubscribe` Output

The `updatesubscribe` command provides detailed progress and final results in JSON format.

**Progress Logs:**

During an update, you will receive `Progress` or `ProgressError` messages.

- **`Progress`**: Indicates a successful step in the update process.
- **`ProgressError`**: Indicates an error occurred while updating a specific comic.

**Example `Progress` Log:**

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

**Example `ProgressError` Log:**

```json
{
  "status": "running",
  "message": "ProgressError",
  "data": {
    "current": 2,
    "total": 10,
    "comic": {
      "id": "another-comic-id",
      "name": "Another Comic Name",
      ...
    },
    "error": "Error message here"
  }
}
```

**Final Output:**

Once the update process is complete, a final JSON object is returned with a list of all comics that have been updated.

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
