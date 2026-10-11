# App Data Synchronization

Chinese: [data_sync.zh.md](data_sync.zh.md)

Open **Settings → Storage and Sync → Data Sync** and enter the WebDAV directory URL, username, and password. Directory letter case must match the server. When sync is not configured, the top-bar button opens this page; once configured, it lets you choose Upload or Download.

Synchronization uses complete snapshots in the WebDAV root directory, named `<day>-<dataVersion>.venera`. Upload replaces an earlier snapshot from the same day and keeps at most ten snapshots. A snapshot contains settings, favorites, reading history, cookies, and comic source files. It does not contain local comic images, downloaded archives, or remote comic-library contents. Downloads restore a newer remote snapshot over local data; there is no record merge or conflict resolution.

## Sync modes

| Mode | Behavior |
|---|---|
| Manual | Transfers only through Upload and Download in the top bar or CLI. |
| Real-time | Uploads after local changes; checks for downloads on startup and foreground resume, with resume checks at least ten minutes apart. |
| Scheduled | Synchronizes every 5, 15, 30, 60, 180, or 360 minutes; the default is 30 minutes. |

Automatic sync uploads first when local changes are pending. Otherwise it checks for and downloads a newer remote snapshot. Failed uploads keep the pending marker for the next automatic run. The timer runs only while the app process runs and does not wake the operating system.

When choosing real-time or scheduled mode, choose an initial upload or download. The new configuration is saved only after that transfer succeeds; a failure restores the prior connection, mode, interval, and exclusions. Manual mode saves directly. Upgrades map the former sync timing to manual, real-time, or scheduled mode and prioritize uploading current local data. Old protocol state and remote directories are neither read, converted, nor deleted.

## Sync boundaries

WebDAV connection information, mode, interval, pending state, local paths, and Bangumi local retry queues stay on this device. Settings listed in `disableSyncFields` are excluded. Comic-library configuration always participates in settings sync, including its connection information; use only a trusted WebDAV service.

Local imports and cloud downloads both restore complete `.venera` snapshots and roll back replaced files on failure. Restored data reloads databases, comic sources, and affected runtime services. Only a manual local import becomes a new local change for later sync; a cloud download never triggers an upload. An old snapshot without the Home favorites binding clears the previous local binding.
