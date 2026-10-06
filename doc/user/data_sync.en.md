# App Data Synchronization

中文版本：[data_sync.zh.md](data_sync.zh.md)

Navigation: **Settings → Storage and Sync → Data Sync** (or click the top-bar sync button to guide configuration when not yet configured). Enter your WebDAV directory URL, username, and password. Match the server directory's exact letter case. You can use **Test Connection** to verify directory accessibility.

App data includes settings, favorites, history, cookies, and comic source script files; it does not include local comic images. Comic archive backups and the online WebDAV comic library are configured separately.

## Direction and Timing

The Home sync icon runs the configured direction and rotates for actual queued work. If WebDAV is not configured, it opens settings. Direction and timing are independent:

| Direction | Behavior |
|---|---|
| Bidirectional (default) | Compares local changes with the last verified remote snapshot. Uploads local-only changes, downloads remote-only changes, and asks for a snapshot choice when both changed or the baseline is unknown. An empty server is seeded from local data. |
| Upload only | Publishes a local snapshot; never downloads. |
| Download only | Applies the latest remote snapshot; never uploads. This explicitly treats the server as authoritative. |

| Timing | Trigger |
|---|---|
| Manual | Only an explicit sync or command initiates a transfer. |
| Real-time | Local changes trigger sync unless direction is download-only; startup and resume also check the server (resume checks are at least ten minutes apart). |
| Scheduled | Syncs at 5, 15, 30, 60, 180, or 360 minute intervals (default 30). |

Scheduled changes are batched until the interval expires. Upload-time edits remain pending. Failures retain pending edits and wait for the next interval. Timers operate only while the app process runs; they do not wake the OS after exit. Overdue checks run at startup/resume. Mobile background suspension can delay them. Attempts reset the interval from completion.

All transfers, including a confirmed initial configuration transfer and headless commands, share one serialized queue. Opposite-direction requests do not share results. User edits remain tracked while a download waits, extracts, and stages its files. After staging on the destination volume and waiting for pending history writes, sync checks the local generation again immediately before the synchronous file-replacement section. New edits before that boundary abort the import instead of replacing the local databases. This is an in-process commit boundary, not a cross-process filesystem transaction.

Synchronization replaces complete snapshots; it does **not** merge independently edited databases. A zero local version does not prove that local favorites/history are empty. Unknown baselines require an explicit upload-local or download-remote choice. Multiple newest files with the same numeric version cannot be resolved by arbitrarily downloading one; select the desired file on the server or publish an explicit local snapshot.

Uploads create a monotonically increasing version using streaming, conditional `PUT` (`If-None-Match: *`); a concurrent collision is a conflict, not success. Strong ETags bind conditional downloads to the inspected bytes. Servers without strong ETags can still be used for an explicit download or download-only direction, but that download does not establish a trusted automatic bidirectional baseline. New edits during its network wait are still protected.

Cleanup retains the original same-day/ten-snapshot intent but only considers older files seen before the upload, never colliding versions or newly discovered concurrent snapshots. Deletes require a strong ETag and `If-Match`; changed files are kept. Servers without these validators may retain more snapshots and need manual storage maintenance.

## Device-Local Boundaries and Credentials

To ensure security and multi-device autonomy, the following items are strictly **device-local** and are never exported into remote sync snapshots (`.venera`) or overwritten by remote downloads:

- **WebDAV Sync Credentials & Connection Info**: WebDAV URL, username, and password.
- **Current Device Sync Preferences**: Direction, timing, and scheduled interval.
- **Local Sync State**: Pending changes, attempt timestamps, and the endpoint-bound verified baseline.
- **Local Storage Path**: Configured local comics storage path (`local_path`).
- **Bangumi Local Queues**: Pending Bangumi progress submissions and local background retry queues.

Remote sync snapshots only contain: `history.db`, `local_favorite.db`, `appdata.json` (filtered of device-local settings and paths), `cookie.db`, and installed comic source scripts (`comic_source/`).

> **WebDAV Comic Library Configuration Sync**:
> In "WebDAV Comic Library" settings, the "Sync Comic Library Config" option is disabled by default. Only when explicitly enabled on both devices will library connection endpoints and credentials be included in the snapshot. Credentials reside inside the remote snapshot; only enable this on trusted WebDAV servers.

## Saving Settings and Migration

For real-time or scheduled timing, confirm an initial upload or download with **Continue** (one-way directions determine the operation). Merely editing dropdowns does not transfer data. The new configuration is committed only after its initial transfer and persistence succeed; failure restores previous connection/preferences/baseline/conflict state and releases busy state. A completed remote write or successful data import is not undone merely because saving preferences later fails. Manual timing saves preferences without an initial transfer.

Changing timing/interval reschedules work. Clearing all connection fields disconnects synchronization. Legacy auto-sync enabled maps to real-time and disabled to manual; an existing scheduled mode remains scheduled. Legacy keys are removed once even when new preferences already exist. Direction defaults to bidirectional.
