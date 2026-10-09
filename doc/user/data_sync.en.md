# App Data Synchronization

中文版本：[data_sync.zh.md](data_sync.zh.md)

Navigation: **Settings → Storage and Sync → Data Sync** (or click the top-bar sync button when not configured). Enter your WebDAV directory URL, username, password, and device name; directory letter case must match the server. The name defaults to the Android model, iOS device name, or desktop hostname and can be edited. Its configuration is local, but the remote directory and device metadata carry the name, so do not put sensitive information in it. Use **Test Connection** to check access first.

## Multi-Device Merge and Scope

The new protocol merges **business records and fields using causal relationships**, rather than asking you to choose between complete local and cloud snapshots. Independent favorites, history records, read chapters, or favorite images added on offline devices can coexist after synchronization. Non-conflicting fields of the same record can also merge. Business adapters apply the resulting records to their databases and files; synchronization does not download an entire database to overwrite the local one.

| Domain | Merge granularity and boundaries |
|---|---|
| Favorite folders and comics | Folders have stable identities that survive renaming. Favorites are identified by folder, comic, and source type; names, ordering, and comic metadata merge as separate fields. Independent folders with the same name are not forcibly combined; local display names can distinguish them. The role shared by Home and automatic update checks (`reading`) binds to a folder identity. It is unbound by default and can be assigned to any local favorites folder. |
| Reading history | Identified by comic and source type. Metadata fields merge separately; **current progress**, including chapter, page, group, and time, is one indivisible candidate. Positions are not spliced together or resolved by taking the highest page. Candidates at the same position with otherwise identical contents and only different valid timestamps merge to the newer timestamp; actual position differences still require a choice. Reading an earlier chapter again is a valid edit. |
| Read chapters and favorite images | Each read chapter and each favorite image is an independent record. Concurrent additions of different chapters or images coexist rather than competing over one whole episode array. Field differences between images of the same comic are retained, rather than overwritten because local display data shares an aggregate row. |
| Reading duration | A shared migrated legacy duration base is deduplicated, not added once per copy. New positive contributions from each device are then added; this is **not the maximum of total durations**. Resets, reductions, or incompatible legacy bases retain candidates requiring a choice instead of silently disappearing. |
| Settings | Allowed settings merge by key and nested object leaf; lists remain whole values. Concurrent edits to the same setting can still conflict. Filtering is described below. |
| Search history | Membership and stable ordering are retained per keyword. Adding or searching a keyword again updates only that keyword, without renumbering untouched entries and creating false conflicts. Concurrent new keywords with equal order are displayed deterministically by keyword. The interface shows at most 50 entries; hidden overflow is not treated as deletion. |
| Cookies | A complete cookie session merges atomically per normalized domain; cookies from separate logins are not mixed individually. |
| Comic source scripts and sessions | Each source script revision is atomic, as is each source's `.data` session. Script bodies and login states are not spliced together. Local equal-content aliases of the same source identity collapse into a single canonical physical file without fake conflicts; differing contents are preserved as durable candidates before stale runtime aliases are deleted; source `.data` sessions are not cleared by normalization. |
| Bangumi | Access Token, username, sync preferences, and comic bindings participate in settings sync. Bindings include subject metadata, episode/volume progress, and ratings. Pending submissions and failed retry queues stay on-device and are not transferred through WebDAV. |

Local comic image files, downloaded comic archives, and images in the online library are not included. Comic archive backups and the online WebDAV comic library remain separate features.

### Category Scope

Settings provides seven independently configurable groups, all enabled by default. Existing optional WebDAV-credential switches remain off by default:

| Category | Contents |
|---|---|
| Settings | Application settings allowed to synchronize |
| Favorites | Folders, comic favorites, and folder-role bindings as one group |
| Reading history | Progress, duration, and read chapters as one group |
| Favorite images | Image-favorite records, not the original image files |
| Search history | Keywords and ordering |
| Source scripts | Comic source script revisions |
| Login state | Cookies and comic source `.data` sessions as one group |

Disabling a category stops new capture and remote application for that domain. It is **not a deletion instruction** and does not retract already captured pending content or erase old cloud candidates. Scope is device-local. The login-state group does not include settings such as the Bangumi Token; see the secrets section below.

## Deletion and Batch Conflict Selection

Deletions carry causal information too. A later deletion can supersede values already observed by that device; **deletion concurrent with an unseen edit on another device** retains a conflict. Deleting a parent history record must not simply clear chapters or favorite images concurrently added elsewhere.

Even explicitly choosing to delete a parent history record preserves read chapters added concurrently. Local metadata retained to display those chapters is not synchronized as a newly created history record; actually reading again creates a new reading edit.

Compatible field values merge automatically. Incompatible concurrent values remain durable candidates, with an existing local active candidate preferred until explicitly handled. The dialog groups conflicts by category and supports search and an unselected-only filter. Bulk-select matching local values or a specified device's candidates within the current filter; items without a matching candidate are not guessed. Candidates show device names, available timestamps, and safe previews, distinguishing field deletion from whole-record deletion.

**You do not need to select everything.** **Resolve Selected** submits only selected items and leaves the rest for later batches. Selection itself does not apply or upload anything; closing discards unsubmitted choices. Changed candidates require a new selection rather than silently acknowledging newly arrived edits. The selected batch is validated before one durable commit; subsequent application/publication failures report recovery status rather than claiming rollback. Unresolved conflicts do not block unrelated conflict-free records. **Successful transfer does not mean all conflicts are resolved.**

After selecting a device in bulk, you may explicitly remember it as the preferred candidate for ordinary settings. This is off by default. The preference applies only when that device has a candidate for an ordinary setting; it does not automatically resolve secrets, deletions, scripts, sessions, or differing reading positions, and is not a universal latest-timestamp policy. Open conflict review from sync settings to clear the preference, even when no conflicts remain. Arbitrary concurrent settings, ordering, scripts, and sessions cannot always merge automatically without conflict.

The conflict title, instructions, and candidate list scroll together. On narrow screens or with enlarged text, footer actions wrap while Close and Resolve remain accessible.

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
| Real-time | Real local edits are coalesced for upload; unchanged saves, simple page switches, and device-local-only saves do not publish checkpoints. Remote checks are independent, approximately every ten minutes while running, with overdue checks on startup/resume. Download-only never uploads because of local edits. |
| Scheduled | Runs every 5, 15, 30, 60, 180, or 360 minutes (default 30). |

Real-time uploading waits **10 seconds** after the latest edit, with at least **60 seconds** between automatic upload attempts. Continuous editing schedules a batch within **2 minutes** under normal runnable conditions. Leaving the reader or entering the background requests a flush, without bypassing direction, minimum intervals, or failure backoff and without guaranteeing continued OS execution. Manual sync immediately joins the serialized queue and bypasses these automatic timing delays.

When local capture confirms that an ordinary real-time notification has no actual changes or queued uploads and no independent remote check is needed, synchronization only clears the pending flag; it does not start remote sync or update attempt/success times. This also applies to upload-only mode. Startup initialization, scheduled tasks, and manual sync may still perform necessary migration, verification, and first publication.

Scheduled mode batches edits within its interval, measured from attempt completion. Changes made during transfer remain pending. Automatic failures use increasing backoff; authentication errors pause automatic retries until credentials are corrected and configuration is saved or a manual retry is made. Timers run only with the application process, not as an OS background keep-alive service. They do not wake the OS after exit; startup/resume catch up overdue work, and suspension can delay execution.

Settings shows actual pending record and conflict counts, the latest successful time, trigger reason, last sync duration, and uploaded/downloaded bytes and data-block counts for the operation. Blocks count physical Packs or legacy compressed objects, not logical shards. It also offers manual sync and confirmed legacy-change import. Counts do not require displaying secret bodies, and pending records are not queue-batch counts; before capture completes, the durable queue count does not represent all unsaved UI edits.

Synchronization, explicit upload/download, configuration, and conflict handling use one serialized queue. Commands cannot bypass direction restrictions. Local edits continue to be tracked during network reads and file staging; synchronization captures them again and checks for changes before committing, so a stale target does not replace edits made while waiting for the network.

## Offline Operation, Crashes, and Recovery

Persistent local state is bound to the WebDAV endpoint and retains device identity, causal candidates, observed records, and the upload queue (outbox). Captured edits are saved before network publication. An application target (`pendingApply`), its applicable domains, and merge metadata are saved atomically before writing business databases and files. Startup recovers unfinished application first, preserving edits in actual local data before continuing capture and synchronization. Blocked domains retain each record's original causal observation; observing later edits from the same actor in another domain does not prematurely supersede unseen source candidates.

Merge metadata uses record-oriented SQLite storage. The outbox references immutable manifests and compressed objects rather than rewriting one giant state JSON on every save. Primary and recovery databases receive incremental updates in a shared SQLite attached-database transaction; ordinary commits do not copy the entire database. File-level repair is limited to initialization or recovery. Old local JSON state is imported read-only and retained.

Corrupt metadata is not silently reset to empty state. Recovery validates revisions and actor identity and may require remote verification to prevent counter regression. Failed verification reports an error rather than continuing unsafely. This primary/replica transaction is **not** a global transaction across favorites, history, preferences, and source files; business application still relies on the persistent recovery journal.

Authentication, network, and application failures report failure and retain unfinished publication/application work. If some remote publications or local business commits already succeeded, a later failure **does not pretend to roll those committed changes back**. Retries continue from persistent state rather than treating committed work as if it never happened.

Local comic source normalization is similarly protected by the persistent journal: when old aliases coexist with new canonical files, recovery is idempotent and does not resurrect explicitly resolved candidates. Normalization respects direction boundaries and does not import unapplied remote business values under restricted modes such as upload-only. Actual business commit failures still report failure and retain pending recovery state.

After startup recovery or a local metadata transaction fails, correcting the issue and initiating sync again reloads durable state and retries recovery. Restarting or clearing state is not required to bypass a cached failure. Upload, download, and conflict handling wait for successful recovery.

## Source Issues and Partial Synchronization

Empty scripts, syntax damage, unresolved identities, and corrupt sessions are reported as source issues, not interpreted as deletions. Incomplete `source` (script) or `sourceSession` (session) domains pause capture and application while retaining their previous observations. Complete domains such as settings, favorites, and history can still synchronize. The toolbar and settings page report **partial synchronization**; a successful transfer does not mean every source has recovered.

Script and session completeness are assessed independently. If only a `.data` session is corrupt, valid scripts can still participate in synchronization; dependent runtime reload waits until the session recovers. Different login states are not mixed, and sessions are not cleared merely to hide an error.

Automatic recovery only uses valid local scripts, verified backups, or applied records proven to share the stable source identity. It does not infer identity from filenames such as `komiic.js` or `jm(0).js`. The isolated probe provides only pure random-number and UUID helpers, with no real network, file, or session access. Probe environment limitations are reported separately from file corruption and do not trigger automatic replacement. Without trusted recovery content, the original file remains in place and its domain stays paused.

The source-issue dialog can accept a trusted replacement for a script, session, or metadata file. Replacement validates the content, checks for concurrent edits, preserves immutable original-file evidence, and then commits. Invalid replacements do not overwrite existing content. Available original backups can be exported for safekeeping, but a damaged backup is not a valid script to restore blindly. A message that the file was saved but runtime recovery is pending means the file commit succeeded; repair the dependency and retry rather than assuming a later sync failure rolled the file back.

If a recovery journal is corrupt or incomplete, export the original files and backups, restore a complete journal matching the current quarantine records, and retry. **Do not delete journals, clear synchronization state, or reinstall sources to bypass validation.** Missing proof does not authorize replacement or publication of deletions.

## Cloud Format and Integrity

The new protocol lives under **`VeneraPlus/sync-v5/<device-name>/`** inside the configured WebDAV directory, isolated from read-only legacy checkpoints and `sync-v4`:

```text
VeneraPlus/sync-v5/
  archive-v4.json
  archive-v4-imports/<inventory-SHA256>.json
  <device-name>/
    device.json
    commits/<counter>-<manifest-SHA256>.json
    packs/<Pack-SHA256>.pack
```

Each manifest describes a **full causal checkpoint**, preserving records, candidates, and deletions. Logical objects retain the v4 gzip encoding: large collections such as favorites and history keep 64 stable identity-based buckets; scripts, sessions, and cookies are sharded per identity. The global causal clock lives in the manifest so a counter-only change does not invalidate every shard. Physical transfer combines multiple logical objects into deterministic, content-addressed Packs targeting 1 MiB; a larger individual object may occupy a larger Pack. Small shards no longer each require a remote file.

Up to **4 workers** upload and read back required Packs before publishing the immutable manifest. Downloads use the same bounded concurrency, and failure waits for in-flight requests to finish. Verified directories are reused within a task and revalidated on retry, never treated as permanent existence proof. New manifests reference unchanged old Packs and only package changed shards; editing one setting normally uploads one changed Pack and a new manifest, not unchanged history or scripts. No-change operations create neither a new Pack nor a new commit.

The bounded encoding cache includes full causal content and event digests, avoiding repeated gzip work while retaining identical v4 object bytes. Verified, endpoint-scoped Pack/publication caches survive restarts; the Pack disk cache defaults to **128 MiB**. Corrupt or unwritable caches fall back safely, and removing a cache does not lose business state. A full manifest may reference at most **256 MiB** of physical Packs. Sparse old references reaching this limit cause current shards to be repacked, not a full repack on every sync and not deletion of old remote Packs. Initial sync, cleared caches, or rebuilding trusted references still incur full packing/downloading and discovery costs.

Path separators, URL delimiters, and control characters in device names are replaced with underscores, and unsafe trailing dots/spaces are removed. Empty or dot-only names are rejected. If another actor owns the same name, a stable short identifier is appended to the directory instead of overwriting that actor. Renaming preserves the internal actor identity and counters; old directories remain discoverable, with checkpoints subject to the same read and safe-cleanup rules. Synchronization reads every device directory, not just this device's directory. Existing local sync state publishes a full checkpoint when this actor has no checkpoint in the new namespace, even without new local edits.

Reads verify the SHA-256 in the filename, content format, counter, and agreement between directory ownership and the payload actor. GET redirects or missing ETags can still be validated by the content hash. Corrupt or partial candidate files are not committed checkpoints and cannot hide an older valid checkpoint from that device; multiple files with the same counter cannot be resolved by arbitrarily choosing one. Authentication and network failures are actual errors, not evidence that the server has no data.

Uploads use conditional creation and read-back verification before acknowledgement. A Pack contains the `VNSPK001` magic, a 4-byte big-endian index length, a canonical JSON index, and original gzip object bytes. The index includes the protocol version, object paths, hashes, payload-relative offsets, compressed/expanded sizes, and codecs; gzip objects are not compressed twice. Reads verify the whole Pack and logical-object SHA-256, format, domain, unique keys, offset boundaries, and resource limits, then retain the original checkpoint's causal and `batchId` verification. A manifest with incomplete references is not usable. A bad file left by this device can only be repaired with verification and a strong ETag precondition, or superseded by a replacement preserving the intended changes. Unconditional overwrite, collisions, and truncation are not success. Unsupported HEAD or missing length falls back to GET verification, not an incomplete existence check.

Cleanup only considers **this device's old commit manifests** discovered before upload and proven causally covered by the new checkpoint. It requires a strong ETag and `If-Match`, protects v4 archive proofs, and retains one valid predecessor for recovery. Maintenance requires at least 3 own commits. The count threshold is 32, with at least 24 hours between count-triggered attempts; after a previous attempt, 7 days can also trigger maintenance. The first attempt uses the count threshold. Each attempt inspects at most 64 candidates with an approximately 2-second cooperative budget, still draining in-flight requests rather than leaving background deletions.

Other actors, concurrent new files, old-protocol checkpoints, and `.venera` archives are excluded. **Packs, legacy compressed objects, and causal deletion information are not automatically collected**: ordinary WebDAV cannot prove that a concurrent manifest will not reference content, and offline devices may still carry old values. Cloud usage is therefore not guaranteed to remain constant; missing strong conditional validators retain more manifests.

### Performance Diagnostics

Debug mode or the `VENERA_SYNC_DIAGNOSTICS=true` compile-time flag enables phase timings and aggregate transfer statistics; detailed logging is off in ordinary releases. Phases include `capture`, `legacyMigration`, `discover`, `download`, `merge`, `apply`, `upload`, `compact`, and `totalDurationMs`, alongside HTTP-method counts, bytes, physical blocks, and cache statistics. Nested phases can overlap and must not simply be summed into the total. UI duration and transfer summaries do not depend on detailed logging.

Request logs retain only the method, HTTP status, and endpoint origin, never endpoint paths, URL user information, queries/fragments, authorization headers, cookies, sessions, scripts, or request/response bodies. Disabling diagnostics does not weaken content verification.

### Transport Benchmark (Simulated WebDAV)

Windows desktop Dart VM, loopback WebDAV, 50/200/1000 history records, 5 tiny script records, and 1 setting. The server adds either no latency or 100 ms per request. Each v5 scenario has 5 samples; the table reports milliseconds as **p50 / p95**, with nearest-rank p95 (the maximum of 5 samples, including initial JIT overhead). Cold download uses a fresh client without object caches and verifies the complete causal checkpoint. These are synthetic transport measurements, excluding application startup, local capture/business application, and initial legacy migration, not real NAS or Android performance.

| History records | Added latency per request | First upload p50 / p95 | Cold download p50 / p95 | Setting-only edit p50 / p95 |
|---|---|---|---|---|
| 50 | 0 ms | 32 / 198 ms | 15 / 45 ms | 31 / 51 ms |
| 200 | 0 ms | 53 / 85 ms | 40 / 42 ms | 54 / 56 ms |
| 1000 | 0 ms | 136 / 150 ms | 130 / 140 ms | 134 / 147 ms |
| 200 | 100 ms | 1976 / 1990 ms | 680 / 686 ms | 1865 / 1897 ms |

The original single-sample v4 baseline versus v5 p50 for the same 200-record, 100-ms scenario (the old baseline is not a p50):

| Operation | Single v4 duration → v5 p50 | HTTP requests |
|---|---|---|
| First upload | 30,840 → 1,976 ms | 284 → 18 |
| Cold download | 7,827 → 680 ms | 72 → 6 |
| Setting-only edit | 23,369 → 1,865 ms | 216 → 17 |

The initial 67 logical objects drop from **69 physical files to 3**: device metadata, 1 Pack, and 1 manifest. First-upload `MKCOL` and `PROPFIND` counts each fall from 72 to 5. A setting-only edit still uploads just 1 changed Pack. Index and full-manifest metadata are the tradeoff: this tiny-object sample's cold-download file payload increases from 59,441 to 81,493 bytes, approximately 37%; HTTP headers and directory XML are excluded. The goal is fewer round trips and small files, not necessarily fewer bytes. Real SQLite and loopback HTTP also exercised migration, direction changes, explicit old-writer import, archive/acknowledgement restart recovery, and no-change operations with zero PUT and zero Pack GET.

## Device-Local Fields and Secrets

The following do not participate in ordinary data synchronization and cannot be overwritten by remote content:

- Data-sync WebDAV URL, username, password, and connection preferences.
- This device's direction, timing, interval, device-name configuration, category scope, excluded fields, remembered settings-conflict preference, device identity, pending markers, and merge/recovery metadata. Remote ownership and causal identity do not overwrite local configuration.
- Local comic storage path (`local_path`), device-specific settings, and filtered proxy/local security settings.
- Bangumi pending progress submissions and retry queues.

Excluded settings and optional settings whose sync switches are off are **out of scope**, not deletion instructions. Disabling a switch must not publish deletion of those settings to other devices, and remote imports do not replace locally excluded values.

Bangumi Access Token, username, and bindings synchronize by default; corresponding settings can be disabled through the excluded-field configuration. **The Access Token is stored in remote checkpoints**, so only use a trusted WebDAV service. UI and CLI token candidates are masked; this does not encrypt cloud files.

WebDAV comic library and comic archive backup configurations have independent sync switches, off by default. Endpoints and credentials transfer and apply only when both exporting and importing devices explicitly enable the corresponding switch; the switches themselves stay local. **These optional credentials, cookies, and source sessions can contain secrets and reside in cloud objects when synchronized.** Use a trusted, access-controlled service. Conflict UI and CLI show safe summaries, not raw cookie/session values, script bodies, or sensitive setting candidates. **Gzip is compression, not encryption.** Masked display and disabling a category do not erase secrets already stored remotely.

## Saving Configuration and Upgrading the Legacy Protocol

Saving configuration validates the connection and prepares endpoint state **without first uploading or importing business data**. Validation or pre-commit save failures retain the old connection, preferences, and local business data. A successful save means configuration has committed. Real-time or scheduled mode then queues the first sync as ordinary work; manual mode only saves configuration. A later transfer failure retains the saved configuration, unfinished work, and error state; it does not falsely roll back saved configuration or committed data.

Changing timing/interval reschedules work. Clear all connection fields and save to disconnect. Legacy auto-sync enabled maps to real-time, disabled to manual, and an existing scheduled mode is retained. Old keys are removed once. Direction defaults to bidirectional.

On first use of the new layout, old **`VeneraPlus/<device-name>/<counter>-<SHA256>.json`** causal checkpoints are verified and merged once, their inventory is recorded, and the result is published into `sync-v5` when uploading is allowed. Old files remain read-only and are not rewritten. An incomplete highest checkpoint or a failed read prevents marking migration complete. Download-only can retain a pending migration bridge but cannot upload it.

`sync-v4` is also migrated read-only: freeze its full inventory, merge each actor's highest complete checkpoints including same-counter candidates, independently read back a v5 bridge covering the old causal state, conditionally publish `archive-v4.json`, and only then acknowledge the local bridge. Archive or acknowledgement failures retain recoverable state; restart retries reuse the published commit. Download-only never publishes an archive marker; a later upload-capable direction finishes the bridge. Old v4 files are neither written nor deleted. Local-only uploads reuse completed migration state, while remote checks revalidate the inventory, preserving their independent cadence.

If a remote check detects new checkpoints from old clients after migration, ordinary sync pauses for review rather than silently combining two continuously written protocols. Upgrade or stop old clients first, then choose and confirm **Import Legacy Changes** in settings. This verifies and imports new legacy checkpoints and updates the migration inventory. Explicit v4 imports append v5-proof-backed receipts under `archive-v4-imports/` without rewriting the initial archive; fresh devices recognize those authorized imports too. Missing frozen files must be restored rather than treated as never migrated. With no new legacy checkpoint, the operation does not claim to have imported new data.

On first use of an endpoint, legacy root `.venera` sync archives are **one-time migration seeds only**. They are verified in an isolated directory. All archives with the highest numeric version are read; different files with that version remain seeds/candidates rather than arbitrarily choosing one. Legacy archives are never deleted. Available business domains complete migration independently, while affected source domains remain pending recovery. Failed reads or integrity checks do not mark migration complete. Later root writes from old clients do not automatically enter the new protocol.

Initial legacy migration enforces limits: 512 MiB downloaded per archive, 1 GiB total expanded content per archive, 256 MiB per database, 16 MiB per text file, 10,000 entries, and 8 MiB of central-directory metadata. Exceeding a limit explicitly fails the whole migration; it does not truncate data, import a partial seed, overwrite local data, or mark migration complete. Keep the original backup/archive; no user-facing option to raise these limits is provided.

Legacy archives support native ZIP64 directory records and signed/unsigned 32-bit or 64-bit data descriptors while retaining CRC, local/central-header consistency, path, entry-boundary, and expansion-limit checks. ZIP64 compatibility does not admit damaged or truncated archives. Source repairs use a **persistent local override layer** bound to the original archive SHA-256 and entry path. Retries apply the override in isolation without rewriting the cloud `.venera` or its original verified backup, and only complete domains still awaiting migration.

**All participating devices should upgrade to `VeneraPlus/sync-v5/<device-name>/`.** `sync-v4` and old `VeneraPlus/<device-name>/` causal checkpoints support the controlled read-only migration above; root `.venera` archives remain one-time seeds. Old `sync-v2/` is not read, migrated, or automatically deleted, and old clients do not continuously interoperate with the new layout. Export a `.venera` backup before upgrading. Data present only in `sync-v2/` must first be synchronized locally or exported with an old client. Manual `.venera` import/export remains a separate backup/restore feature, not forced upload/download overwrite or a replacement for choosing an entire conflict version.
