# VeneraPlus Headless Mode

Default Chinese version: [headless.zh.md](headless.zh.md)

VeneraPlus's headless mode allows you to run key features from the command line, making it easy to automate tasks and integrate with other tools. This document outlines the available commands and their usage.

## How to Use

To activate headless mode, use the `--headless` flag when running the VeneraPlus executable (e.g. `venera-plus` on Linux or `VeneraPlus.exe` on Windows), followed by the desired command.

```bash
venera-plus --headless <command> [subcommand] [options]
```

First configure the accounts, sync destination, comic sources, and Home favorites folder needed by the command in the graphical app. In Windows PowerShell, run `.\VeneraPlus.exe` from the installed program directory, for example:

```powershell
.\VeneraPlus.exe --ignore-disheadless-log --headless webdav up
```

## Global Options

- **`--ignore-disheadless-log`**: Suppresses application logs while retaining `[CLI PRINT]` results. Place it before `--headless` so it is not parsed as a command argument.

## Commands

### `webdav`

The command retains the name `webdav`, but uses the shared cloud or WebDAV account and directory configured under Settings → Storage and Sync → App Data Sync. It transfers complete `.venera` snapshots and reports an error when no sync destination is configured.

- **`webdav up`**: Uploads the current local complete snapshot.
- **`webdav down`**: Manually downloads and restores the latest remote complete snapshot by version ordering, even if it is older than the local version; automatic version-skipping rules do not apply.

Only `up` and `down` are available. Network or restore failures print `status: error` and exit nonzero.

**Example:**

```bash
venera-plus --headless webdav up
```

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

The summary's `status: success` means the batch has finished; inspect `data.errors` too. An individual source failure does not necessarily give this command a nonzero exit code.

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

Checks the persisted favorites folder bound to Home and automatic update checks. The command waits for pending downloads before resolving that binding; an unbound or deleted folder is an error.

- **`updatesubscribe`**: Checks comics in the folder bound to Home.
- **`updatesubscribe --update-comic-by-id-type <id> <type>`**: Updates one comic in that folder by `id` and `type`.

**Example:**

```bash
# Update all comics in the bound folder
venera-plus --headless updatesubscribe

# Update a single comic
venera-plus --headless updatesubscribe --update-comic-by-id-type "comic-id" "source-key"
```

## Output Format

Structured results are JSON objects prefixed with `[CLI PRINT]`. Scripts should filter for that prefix and parse the following JSON rather than treating all standard output as results. Every object contains `status` and `message`, with `data` when returning a payload.

Failed `webdav` transfers, invalid commands, and `updatesubscribe` errors exit nonzero. Check individual `updatescript` failures through its summary as described above. See [App Data Synchronization](data_sync.en.md) for snapshot scope and restore behavior.

### `updatesubscribe` Output

The `updatesubscribe` command provides detailed progress and final results in JSON format.

**Progress Logs:**

During an update, you will receive `Progress` or `ProgressError` messages.

- **`Progress`**: Indicates a successful step in the update process.
- **`ProgressError`**: Indicates an error occurred while updating a specific comic.

Progress and `Update check complete.` payloads include counts for `updated`, `unchanged`, `baseline`, `unknown`, and `errors`, plus `newChapters` for newly discovered chapters in this check. The first usable comparison basis counts as `baseline`. Missing comparable chapters, page counts, and dates count as `unknown` rather than unchanged. Individual progress also includes `updateStatus`: `updated`, `unchanged`, `baseline`, or `unknown`. Request failures use `ProgressError` and the `error` field and are not counted again under `unknown`.

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
      "name": "Another Comic Name"
    },
    "error": "Error message here"
  }
}
```

**Final Output:**

Once checking completes, the final JSON object lists comics with updates still awaiting confirmation, including discoveries from earlier checks that have not been completed in the reader or explicitly marked as read.

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
