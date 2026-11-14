# App Data Synchronization

Chinese: [data_sync.zh.md](data_sync.zh.md)

Open **Settings → Storage and Sync → App Data Sync** and choose a connected cloud or WebDAV account and a remote directory. You can also add an account from the selector and continue configuring sync. Directory letter case must match the server. When sync is not configured, the top-bar button opens this page; once configured, it lets you choose Upload or Download. Expand advanced field exclusions only when needed.

Synchronization uses complete snapshots named `<day>-<dataVersion>-<timestamp>-<uniqueId>.venera` in the selected remote directory, defaulting to `/VeneraPlus/`. Migrating existing WebDAV settings to shared accounts preserves the `VeneraPlus/` directory below the original URL. The first upload creates the directory automatically. Each upload advances beyond the known local and remote versions, and its unique suffix prevents concurrent uploads from overwriting each other. Failed uploads restore the local version counter. Successful uploads remove lower-version snapshots from the same day and normally retain at most ten snapshots. Concurrent snapshots with the same version are retained, so the count may temporarily exceed ten.

Downloads compare version numbers first, then dates and unique suffixes. A different file with the same version, or a legacy file whose server identity changed, is still downloaded. Automatic downloads skip lower versions and snapshots reliably identified as already synchronized. Legacy files without server identity metadata are downloaded again. Manual downloads can restore an older version. This release continues to read legacy `<day>-<dataVersion>.venera` files. Upgrade all devices sharing a directory together, since older releases cannot recognize the new filenames.

A snapshot contains settings, favorites, reading history, cookies, and comic source files. It does not contain local comic images, downloaded archives, or remote comic-library contents. Settings, favorite memberships, reading history, and other snapshot data are restored as a complete snapshot; concurrent changes are not merged record by record.

Comic update state is persisted per source and comic ID. Home, local favorites, network favorites, and details for tracked comics share comparison baselines and pending updates across page changes and restarts. Favoriting from details or switching sources establishes a baseline from the loaded catalog, page counts, and date. For older favorites without a comparison basis, the first check establishes one without reconstructing earlier additions. Added chapters, valid page growth, or a forward source update time can identify an update. Home displays the source update time, or unknown when no valid date is available. Entering the reader does not immediately clear the badge: completing a chapter or explicitly marking updates as read confirms the corresponding content.

Update state also synchronizes through a separate state file for each device. Uploads and downloads merge discoveries and confirmations for specific content versions even when the complete snapshot version is equal or older. One device confirming an old chapter does not remove a new chapter concurrently discovered by another. Check times stay local to each device.

## Sync modes

| Mode | Behavior |
|---|---|
| Manual | Transfers only through Upload and Download in the top bar or CLI. |
| Real-time | Uploads after local changes; checks for downloads on startup and foreground resume, with resume checks at least ten minutes apart. |
| Scheduled | Synchronizes every 5, 15, 30, 60, 180, or 360 minutes; the default is 30 minutes. |

Automatic sync uploads first when local changes are pending. Otherwise it checks remote snapshots. Reading progress, reading duration, history deletions, and image-favorite changes mark data as pending after persistence; refreshing a view alone does not trigger an upload. Failed uploads keep the pending marker for the next automatic run. The timer runs only while the app process runs and does not wake the operating system.

When choosing real-time or scheduled mode, choose an initial upload or download. The new configuration is saved only after that transfer succeeds; a failure restores the prior connection, mode, interval, and exclusions. Manual mode saves directly. Upgrades map the former sync timing to manual, real-time, or scheduled mode and prioritize uploading current local data. Old protocol state and remote directories are neither read, converted, nor deleted.

## Sync boundaries

The data-sync destination, mode, interval, pending state, local paths, and Bangumi local retry queues stay on this device. Settings listed in `disableSyncFields` are excluded. All cloud accounts and their credentials are included in settings sync, and comic-library configuration always participates; use only a trusted storage service.

Local imports and cloud downloads both restore complete `.venera` snapshots and roll back replaced files on failure. Cloud downloads merge local and remote comic update state; manual local imports restore update state from the selected backup. Restored data reloads databases, comic sources, and affected runtime services. Only a manual local import becomes a new local change for later sync; a cloud download never triggers an upload. An old snapshot without the Home favorites binding clears the previous local binding.

## Search history and keyword rules

The history-mode button on Search switches between keywords and detailed entries. The two histories are retained separately; deleting or clearing one mode leaves the other intact. Detailed entries remember the source, filters and last page actually viewed, with separate entries for different source/filter combinations. Numbered results restore directly; cursor results advance from the start with progress and cancellation. Removed sources can be replaced, while changed filters fall back to current defaults and page one. Existing keywords are preserved without inventing their former source or page.

Open **Settings → Browsing and Favorites → Keyword blocking** to add or edit comic and comment rules. Contains text suits phrases, Whole word avoids matching short abbreviations such as `BL` inside `black`, and Exact tag only checks comic tags. Each rule has a case option and a Try matching preview. Keywords are literal text, not regular expressions; whole-word matching does not segment Chinese text.

Click a list's keyword-hidden count to see the first matching rule, field and mode, and edit the rule directly. Reasons cover only comics already loaded in that list and keep hidden covers concealed; they are not a library-wide count.

Detailed history, the display mode and rule options are saved with app data. Existing comic words remain case-sensitive and existing comment words remain case-insensitive. Importing a backup with an old word list restores that list's original matching behavior; an omitted list is unaffected. Excluding `blockedWords` or `blockedCommentWords` also excludes its rule options. Devices sharing app data should use versions supporting these rules, since older versions cannot apply the new match modes.
