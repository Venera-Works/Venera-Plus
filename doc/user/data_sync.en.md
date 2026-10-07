# App Data Synchronization

中文版本：[data_sync.zh.md](data_sync.zh.md)

Navigation: **Settings → Storage and Sync → Data Sync** (or click the top-bar sync button when not configured). Enter your WebDAV directory URL, username, and password; directory letter case must match the server. Use **Test Connection** to check access first.

## Multi-Device Merge and Scope

The new protocol merges **business records and fields using causal relationships**, rather than asking you to choose between complete local and cloud snapshots. Independent favorites, history records, read chapters, or favorite images added on offline devices can coexist after synchronization. Non-conflicting fields of the same record can also merge. Business adapters apply the resulting records to their databases and files; synchronization does not download an entire database to overwrite the local one.

| Domain | Merge granularity and boundaries |
|---|---|
| Favorite folders and comics | Folders have stable identities that survive renaming. Favorites are identified by folder, comic, and source type; names, ordering, and comic metadata merge as separate fields. Independent folders with the same name are not forcibly combined; local display names can distinguish them. The Reading role binds to a folder identity. |
| Reading history | Identified by comic and source type. Metadata fields merge separately; **current progress**, including chapter, page, group, and time, is one indivisible candidate. Positions from two devices are not spliced together or resolved by taking the highest page. Reading an earlier chapter again is a valid edit; concurrent positions require a candidate choice. |
| Read chapters and favorite images | Each read chapter and each favorite image is an independent record. Concurrent additions of different chapters or images coexist rather than competing over one whole episode array. Field differences between images of the same comic are retained, rather than overwritten because local display data shares an aggregate row. |
| Reading duration | A shared migrated legacy duration base is deduplicated, not added once per copy. New positive contributions from each device are then added; this is **not the maximum of total durations**. Resets, reductions, or incompatible legacy bases retain candidates requiring a choice instead of silently disappearing. |
| Settings | Allowed settings merge by key and nested object leaf; lists remain whole values. Concurrent edits to the same setting can still conflict. Filtering is described below. |
| Search history | Membership and stable ordering are retained per keyword. Adding or searching a keyword again updates only that keyword, without renumbering untouched entries and creating false conflicts. Concurrent new keywords with equal order are displayed deterministically by keyword. The interface shows at most 50 entries; hidden overflow is not treated as deletion. |
| Cookies | A complete cookie session merges atomically per normalized domain; cookies from separate logins are not mixed individually. |
| Comic source scripts and sessions | Each source script revision is atomic, as is each source's `.data` session. Script bodies and login states are not spliced together. Local equal-content aliases of the same source identity collapse into a single canonical physical file without fake conflicts; differing contents are preserved as durable candidates before stale runtime aliases are deleted; source `.data` sessions are not cleared by normalization. |

Local comic image files, downloaded comic archives, and images in the online library are not included. Comic archive backups and the online WebDAV comic library remain separate features.

## Deletion and Item-Level Conflicts

Deletions carry causal information too. A later deletion can supersede values already observed by that device; **deletion concurrent with an unseen edit on another device** retains a conflict. Deleting a parent history record must not simply clear chapters or favorite images concurrently added elsewhere.

Even explicitly choosing to delete a parent history record preserves read chapters added concurrently. Local metadata retained to display those chapters is not synchronized as a newly created history record; actually reading again creates a new reading edit.

Compatible field values merge automatically. Incompatible concurrent values remain durable candidates; an existing local active candidate is preferred until you explicitly handle the conflict. The conflict interface selects candidates by record and field, including explicit deletion candidates. A choice does not overwrite unrelated records globally. Unresolved conflicts do not prevent unrelated, conflict-free records from merging. **Successful transfer does not mean all conflicts are resolved.** Arbitrary concurrent edits to settings, ordering, scripts, or sessions are not guaranteed to merge automatically without conflict.

A choice creates a new causal edit. Bidirectional and upload-only directions can publish it. Download-only retains the choice locally for later publication; switch to a direction that allows uploading to share it. See [Headless Mode](headless.en.md) for command-line handling.

## Direction and Timing

The top-bar sync icon runs the selected direction and rotates during actual queued work. It opens settings if not configured. Direction and timing are independent:

| Direction | Behavior |
|---|---|
| Bidirectional (default) | Captures local edits, reads and merges remote checkpoints from devices, applies the business-record result, and publishes pending checkpoints. An empty server is initialized from local data. |
| Upload only | Publishes the local causal checkpoint without applying other devices' remote business data locally. Initial legacy migration may read old archives into merge metadata but still does not import their business data locally. Directory reads, verification, and recovery are not business downloads. |
| Download only | Reads and merges remote checkpoints without publishing local checkpoints. Local edits are still captured and retained as candidates; this is not a forced cloud overwrite. |

| Timing | Trigger |
|---|---|
| Manual | Explicit sync actions or commands trigger transfers; saving configuration does not itself trigger the first transfer. |
| Real-time | Local edits trigger synchronization except in download-only direction. Startup and resume also check the server; resume checks are at least ten minutes apart. |
| Scheduled | Runs every 5, 15, 30, 60, 180, or 360 minutes (default 30). |

Scheduled mode batches edits within the interval. New edits during a transfer remain pending. Failures retain unfinished work for retry or later scheduling. Timers run only with the application process; this is not an OS background keep-alive service and does not wake the OS after exit. Startup/resume catch up overdue work, and system suspension may cause delays. The interval restarts from attempt completion.

Synchronization, explicit upload/download, configuration, and conflict handling use one serialized queue. Commands cannot bypass direction restrictions. Local edits continue to be tracked during network reads and file staging; synchronization captures them again and checks for changes before committing, so a stale target does not replace edits made while waiting for the network.

## Offline Operation, Crashes, and Recovery

Persistent local state is bound to the WebDAV endpoint and retains device identity, causal candidates, observed records, and the upload queue (outbox). Captured edits are saved before network publication. An application target (`pendingApply`) is saved atomically with merge metadata before writing business databases and files. Startup recovers unfinished application first, preserving edits in the actual local data during recovery before continuing capture and synchronization.

State has a recoverable backup; corrupt metadata is not silently reset to a new empty state. Recovery from backup may require remote verification to prevent the device counter from regressing. Failed verification reports an error rather than continuing unsafely. This is not a single cross-process or cross-database/filesystem transaction; recovery relies on the persistent application journal.

Authentication, network, and application failures report failure and retain unfinished publication/application work. If some remote publications or local business commits already succeeded, a later failure **does not pretend to roll those committed changes back**. Retries continue from persistent state rather than treating committed work as if it never happened.

Local comic source normalization is similarly protected by the persistent journal: when old aliases coexist with new canonical files during recovery, journal recovery is idempotent and repeated recovery never resurrects explicitly resolved candidates. Local source normalization strictly respects sync direction boundaries and does not import unapplied remote business values under restricted modes (such as upload-only). Genuine filesystem failures and invalid script syntax errors still strictly fail and block.

If startup recovery fails, initiating sync again after correcting the issue re-executes recovery rather than permanently rejecting requests due to a cached startup error; subsequent upload, download, or conflict handling will not proceed until recovery succeeds.

## Cloud Format and Integrity

The new protocol uses a separate **`sync-v2/`** directory, with publications named `actor-counter-SHA256.json`. Each immutable file is a **full causal checkpoint**, including known records, candidates, and deletions. It is neither a raw database replacement archive nor **a network batch containing only changed fields**. Record-level merging does not imply uploading only a few fields each time; transfer size still depends on the full checkpoint.

Reads verify the SHA-256 in the filename, content format, and matching device/counter. GET redirects or missing ETags can still be validated by the content hash. Corrupt or partial candidate files are not committed checkpoints and cannot hide an older valid checkpoint from that device; multiple files with the same counter cannot be resolved by arbitrarily choosing one. Authentication and network failures are actual errors, not evidence that the server has no data.

Uploads use conditional creation and are read back and verified before acknowledgement. If a retry finds a bad file previously left by this device, repair requires verification and a strong ETag precondition, or publication of a replacement checkpoint preserving the intended changes. Unconditional overwrite is not allowed, and collisions or truncation are not success. Safe cleanup only considers **this device's** older files discovered before upload, proven causally covered by the new checkpoint, and protected by a strong ETag and `If-Match`. Other devices' files, concurrent new files, and legacy `.venera` archives are excluded. Servers without these conditional validators may retain more files.

## Device-Local Fields and Secrets

The following do not participate in ordinary data synchronization and cannot be overwritten by remote content:

- Data-sync WebDAV URL, username, password, and connection preferences.
- This device's direction, timing, interval, excluded-field configuration, device identity, pending markers, and merge/recovery metadata.
- Local comic storage path (`local_path`), device-specific settings, and filtered proxy/local security settings.
- Bangumi Access Token, username, pending progress submissions, and retry queues.

Excluded settings and optional settings whose sync switches are off are **out of scope**, not deletion instructions. Disabling a switch must not publish deletion of those settings to other devices, and remote imports do not replace locally excluded values.

WebDAV comic library configuration and comic archive backup WebDAV configuration have separate sync switches, off by default. Endpoints and credentials can transfer and apply only if the exporting and importing devices each explicitly enable the corresponding switch. The switches themselves remain local. **These optional credentials, cookies, and comic source sessions may contain secrets and reside in cloud checkpoints when allowed to sync.** Use a trusted, access-controlled WebDAV service. Conflict UI and CLI provide safe summaries rather than raw cookie/session values, script bodies, or sensitive setting candidates. Masked display is not cloud encryption.

## Saving Configuration and Upgrading the Legacy Protocol

Saving configuration validates the connection and prepares endpoint state **without first uploading or importing business data**. Validation or pre-commit save failures retain the old connection, preferences, and local business data. A successful save means configuration has committed. Real-time or scheduled mode then queues the first sync as ordinary work; manual mode only saves configuration. A later transfer failure retains the saved configuration, unfinished work, and error state; it does not falsely roll back saved configuration or committed data.

Changing timing/interval reschedules work. Clear all connection fields and save to disconnect. Legacy auto-sync enabled maps to real-time, disabled to manual, and an existing scheduled mode is retained. Old keys are removed once. Direction defaults to bidirectional.

On first use of an endpoint, legacy root `.venera` sync archives are **one-time migration seeds only**. They are verified in an isolated directory. All archives with the highest numeric version are read; different files with that version remain seeds/candidates rather than arbitrarily choosing one. Legacy archives are never deleted. Failed reads or verification do not mark migration complete. Later root writes from old clients do not automatically enter the new protocol.

Initial legacy migration enforces limits: 512 MiB downloaded per archive, 1 GiB total expanded content per archive, 256 MiB per database, 16 MiB per text file, 10,000 entries, and 8 MiB of central-directory metadata. Exceeding a limit explicitly fails the whole migration; it does not truncate data, import a partial seed, overwrite local data, or mark migration complete. Keep the original backup/archive; no user-facing option to raise these limits is provided.

**Every device sharing merge synchronization must upgrade to a client supporting `sync-v2`.** Old clients continue using the root whole-snapshot protocol; the two protocols do not continuously interoperate. You can manually export `.venera` backups before upgrading. Manual `.venera` import/export remains a separate backup/restore feature, not a synonym for forced upload/download overwrite or an alternative command for choosing an entire sync-conflict version.
