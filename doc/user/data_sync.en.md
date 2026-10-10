# App Data Synchronization

中文版本：[data_sync.zh.md](data_sync.zh.md)

Navigation: **Settings → Storage and Sync → Data Sync** (or click the top-bar sync button when not configured). Enter your WebDAV directory URL, username, password, and device name; directory letter case must match the server. The default name comes from hardware metadata: Android prefers the market model (such as `Xiaomi15Pro`), Windows uses the manufacturer brand (such as `Lenovo`), iOS/macOS use the hardware model, and Linux uses the hardware vendor/model. Hostnames and user-configured iOS device names are no longer used. Unavailable hardware metadata falls back to an OS label. Names remain editable; existing saved names are retained to avoid replacing custom names. The configuration is local, but remote directories and device metadata carry the name, so avoid sensitive information. Use **Test Connection** to check access first.

## Multi-Device Merge and Scope

The new protocol merges **business records and fields using causal relationships**, rather than asking you to choose between complete local and cloud snapshots. Independent favorites, history records, read chapters, or favorite images added on offline devices can coexist after synchronization. Non-conflicting fields of the same record can also merge. Business adapters apply the resulting records to their databases and files; synchronization does not download an entire database to overwrite the local one.

| Domain | Merge granularity and boundaries |
|---|---|
| Favorite folders and comics | Folders have stable identities that survive renaming. Favorites are identified by folder, comic, and source type; names, ordering, and comic metadata merge as separate fields. Independent folders with the same name are not forcibly combined; local display names can distinguish them. The role shared by Home and automatic update checks (`reading`) binds to a folder identity. It is unbound by default and can be assigned to any local favorites folder. |
| Reading history | Identified by comic and source type. Metadata fields merge separately; **current progress**, including chapter, page, group, and time, is one indivisible candidate. Positions are not spliced together or resolved by taking the highest page. Same-position candidates differing only in valid timestamps merge to the newer timestamp; different positions follow the automatic cloud/local policy below. Refreshing the timestamp without moving, even alongside increased reading duration, does not register a new position edit. Reading an earlier chapter again is valid; verified reread provenance survives subsequent timestamp refreshes, restart, and interrupted-apply recovery. |
| Read chapters and favorite images | Each read chapter and each favorite image is an independent record. Concurrent additions of different chapters or images coexist rather than competing over one whole episode array. Field differences between images of the same comic are retained, rather than overwritten because local display data shares an aggregate row. |
| Reading duration | A shared migrated legacy duration base is deduplicated, not added once per copy. New positive contributions from each device are added; this is **not the maximum of total durations**. Resets, reductions, and incompatible bases follow the policy below. A tracked manual local contribution can choose the accumulated total only when it matches the actual local duration. |
| Settings | Allowed settings merge by key and nested object leaf; lists remain whole values. Concurrent edits to the same setting can still conflict. Filtering is described below. |
| Search history | Membership and stable ordering are retained per keyword. Adding or searching a keyword again updates only that keyword, without renumbering untouched entries and creating false conflicts. Concurrent new keywords with equal order are displayed deterministically by keyword. The interface shows at most 50 entries; hidden overflow is not treated as deletion. |
| Cookies | A complete cookie session merges atomically per normalized domain; cookies from separate logins are not mixed individually. |
| Comic source scripts and sessions | Each source script revision is atomic, as is each source's `.data` session. Script bodies and login states are not spliced together. Local equal-content aliases of the same source identity collapse into a single canonical physical file without fake conflicts; differing contents are preserved as durable candidates before stale runtime aliases are deleted; source `.data` sessions are not cleared by normalization. |
| Bangumi | Access Token, username, sync preferences, and comic bindings participate in settings sync. Bindings include subject metadata, episode/volume progress, and ratings. Pending submissions and failed retry queues stay on-device and are not transferred through WebDAV. |

Local comic image files, downloaded comic archives, and images in the online library are not included. Comic archive backups and the online WebDAV comic library remain separate features.

An already-open comic details page refreshes when its history changes. **Continue** uses the latest chapter, page, and group rather than the pre-sync object. Explicit chapter and thumbnail-page selections still open the selected position; synchronization does not force an already-open reader to another page.

### Category Scope

Settings provides seven independently configurable groups, all enabled by default. WebDAV comic library configuration always synchronizes within the Settings category; archive backup credentials remain opt-in:

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

## Deletion and Automatic Conflict Handling

Deletions carry causal information too. A later deletion can supersede observed values; **deletion concurrent with an unseen edit on another device** creates a conflict handled by the automatic policy below. Deleting a parent history record must not clear chapters or favorite images concurrently added elsewhere.

Even explicitly choosing to delete a parent history record preserves read chapters added concurrently. Local metadata retained to display those chapters is not synchronized as a newly created history record; actually reading again creates a new reading edit.

Independent records and fields still merge causally. Conflicts in enabled, available domains are automatically resolved per field, **not by overwriting an entire database**. The policy covers settings, favorites, reading history, scripts, sessions, cookies, and deletions:

- **First synchronization with an endpoint, or an empty local field:** select the latest cloud candidate. Missing values, `null`, whitespace-only strings, empty lists, and empty objects are empty; `0` and `false` are not. An explicitly tracked manual deletion is not an uninitialized empty value.
- **Subsequent genuine manual local edits:** prefer the local candidate when its durable edit identity still matches both the active candidate and the actual value. Local record additions/edits can win against concurrent cloud deletion, and local deletion can win against cloud edits. Reading positions require verified actual-edit or explicit conflict-choice provenance. Timestamp refreshes neither create that provenance nor discard matching genuine reread provenance. Cloud imports and initial defaults are not marked manual. Edit markers, reading provenance, and completion state persist in the same local primary/replica transactions and survive restart.
- **Edits during network waiting:** capture again before application. Even on first sync, new local edits made during download are retained rather than overwritten by a stale target.
- **No matching manual local edit:** select the latest cloud candidate. Read each actor's highest valid causal checkpoint, then compare concurrent choices using the WebDAV server's commit modification time, never counters across different actors. Undated candidates do not outrank dated ones; equal or entirely missing times use stable actor/candidate identities. This is cloud publication time, not device edit time.

Automatic choices create causal edits and can be published bidirectionally; download-only never uploads them. Excluded or unavailable domains remain unapplied. A conflict without a usable cloud candidate or a provable manual local candidate stays pending. Older state without manual provenance cannot establish that a candidate was manually set; new genuine edits start tracking it. After the first-sync rules above, an older reading marker that still matches the current value but cannot prove a position edit rather than a timestamp refresh leaves its conflict pending for confirmation, without guessing local or cloud. Upgrading does not clear device identities, counters, or pending uploads. Progress incorrectly merged and published by an older version is not automatically undone: use a trusted record to set the correct reading position again, or restore a trusted business backup; do not clear synchronization state.

Pending conflicts can still be grouped, searched, and filtered to unselected items. Bulk-select matching local values or a specified device's candidates; missing matches are not guessed. Previews show device names, available times, and safe summaries, distinguishing field and record deletion. The old remembered ordinary-settings device preference has been removed so it cannot compete with the automatic policy.

**You do not need to select everything.** **Resolve Selected** submits only selected items. Selection itself applies or uploads nothing; closing discards unsubmitted choices, and changed candidates require reselection. The batch is validated before durable commit; later application/publication failures report recovery state rather than claiming rollback. Pending conflicts do not block unrelated records. **Successful transfer does not mean all conflicts are resolved.**

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

Startup recovery and configuration preloading also share an in-process initialization guard: operations for the same state directory and actor run in sequence, while different endpoints do not wait for each other. Configuration changes, local backup restoration, or disposal invalidate older initialization results. An obsolete task neither publishes its coordinator nor rolls restored preferences back to older values. Discarding a runtime view does not delete durable sync files.

## Offline Operation, Crashes, and Recovery

Persistent local state is bound to the WebDAV endpoint and retains device identity, causal candidates, observed records, and the upload queue (outbox). Captured edits are saved before network publication. An application target (`pendingApply`), its applicable domains, and merge metadata are saved atomically before writing business databases and files. Startup recovers unfinished application first, preserving edits in actual local data before continuing capture and synchronization. Blocked domains retain each record's original causal observation; observing later edits from the same actor in another domain does not prematurely supersede unseen source candidates.

Merge metadata uses record-oriented SQLite storage. The outbox references immutable manifests and compressed objects rather than rewriting one giant state JSON on every save. Primary and recovery databases receive incremental updates in a shared SQLite attached-database transaction; ordinary commits do not copy the entire database. File-level repair is limited to initialization or recovery. Old local JSON state is imported read-only and retained.

Loading genuinely fresh empty state creates no SQLite database or empty revision. The first business capture persists initialization, including for an empty profile, so later new readings are not mistaken for an original-profile baseline. Repeating an identical initialized empty capture does not increase the revision. Valid old JSON primary, backup, and temporary recovery files still migrate instead of being mistaken for a fresh installation.

Existing sync state continues from its durable revision and actor clock; an empty upload queue does not make it a new device. The application's IO adapter fixes asynchronous file-type lookup incorrectly reporting existing SQLite or legacy JSON files as absent, while preserving symbolic-link detection semantics. For example, an actor counter of 4 continues at 5 for the next real edit rather than allocating 1 again. Correcting this discovery error does not require deleting the sync directory or generating a new actor; actual corruption and replica divergence still fail safely.

Commits check the live primary, recovery replica, and loaded view, rather than relying solely on an in-memory counter. One actor/counter slot belongs to exactly one immutable batch; replacing an old batch does not permit different content to reuse that counter. Equal `revision` values with different causal records, observations, outbox contents, or other critical state stop recovery and preserve both files, rather than blindly selecting the primary or overwriting the replica.

Corrupt metadata is not silently reset to empty state. Recovery validates revisions and actor identity and may require remote verification to prevent counter regression. Failed verification reports an error rather than continuing unsafely. This primary/replica transaction is **not** a global transaction across favorites, history, preferences, and source files; business application still relies on the persistent recovery journal.

Before restoring the primary from its replica, recovery persists `merge_store.sqlite3.reconcile`. This marker survives process restarts until the required own remote commits and their referenced Packs are verified and the allocation floor and verification results are committed successfully. Missing files, corrupt content, or HTTP failures preserve both the original outbox and the verification obligation; filenames alone never raise the counter, and new events cannot be captured or published prematurely.

Authentication, network, and application failures report failure and retain unfinished publication/application work. If some remote publications or local business commits already succeeded, a later failure **does not pretend to roll those committed changes back**. Retries continue from persistent state rather than treating committed work as if it never happened.

Local comic source normalization is similarly protected by the persistent journal: when old aliases coexist with new canonical files, recovery is idempotent and does not resurrect explicitly resolved candidates. Normalization respects direction boundaries and does not import unapplied remote business values under restricted modes such as upload-only. Actual business commit failures still report failure and retain pending recovery state.

When startup proves that an advanced disk revision made the loaded view stale (`SYNC_STATE_CHANGED`), it discards runtime caches and uncommitted batches, reloads and validates durable state, and recaptures actual business data at most once. Lazy outbox manifest/object reads also check the revision in a consistent read transaction, rather than treating a replaced batch as current. Further competition or an unproven safe advance still fails. Other startup or local metadata failures require correcting the issue before initiating sync again. Upload, download, and conflict handling wait for successful recovery. Restoring an original local `.venera` archive also invalidates the old sync view: the next capture reloads durable counters first, without resetting actor identity or clocks.

Unrecoverable consistency errors (`SYNC_OUTBOX_COUNTER_CONFLICT`, `SYNC_STATE_DIVERGED`, and `SYNC_STATE_INVALID`) pause automatic synchronization for that endpoint while retaining pending edits. After repairing the state, manual sync revalidates it. Automatic recovery never bypasses a conflict by ignoring an insert, renumbering counters, generating a random actor, or clearing the queue. Diagnostics retain necessary codes, actor identities, counters, batch identifiers, and phases, not raw SQL parameters, full manifests, or secret bodies.

The UI shows stable state-error codes and actionable guidance; detailed diagnostics stay in the log. Initialization logs correlate phases with process, isolate, coordinator/Store/database instance, and load-attempt identifiers. They record the trigger, configuration generations, revisions, counters, queue size, elapsed time, and retry count. Endpoints, actor identities, and state directories are hashed; URLs, credentials, sessions, business bodies, and scripts are not logged.

For investigation, close the application before copying the entire `sync_state_*` directory, preserving the primary, `.bak` replica, `.reconcile` marker, old JSON, and SQLite journals. Do not overwrite one database or delete the state directory. These files may contain sessions, cookies, credentials, and scripts; do not upload or publish them without explicit consent. An ordinary `.venera` business backup is not a replacement for this sync-state copy.

If both replicas retain an event digest but lack its record context, deleting the digest or raising a counter is not a valid fix for `SYNC_STATE_INVALID`. Lossless recovery requires complete sync state or a verified cloud checkpoint matching the retained digests. An old business backup, current business values, or remote filenames alone cannot prove the missing event's content.

**A manual, lossy rebuild requires explicit user consent and is not automatic recovery.** Close the application, archive the entire affected sync-state directories and both `implicitData.json` copies, then establish a new sync identity while preserving library, history, settings, cookie, and source business files. This device identity is shared across local endpoints: check and archive all affected endpoints rather than changing the identity while leaving active state tied to the old actor. Rebuilding loses old deletion tombstones, unresolved conflicts, and unprovable pending edits. Start with **upload-only, manual sync** to publish the current local profile as a complete checkpoint under the new identity. Verify success before restoring bidirectional sync and the original timing, so the first merge cannot replace local values with older cloud data. The archive still contains sensitive data and must not be uploaded or published.

## Source Issues and Partial Synchronization

Empty scripts, syntax damage, unresolved identities, and corrupt sessions are reported as source issues, not interpreted as deletions. Incomplete `source` (script) or `sourceSession` (session) domains pause capture and application while retaining their previous observations. Complete domains such as settings, favorites, and history can still synchronize. The toolbar and settings page report **partial synchronization**; a successful transfer does not mean every source has recovered.

Script and session completeness are assessed independently. If only a `.data` session is corrupt, valid scripts can still participate in synchronization; dependent runtime reload waits until the session recovers. Different login states are not mixed, and sessions are not cleared merely to hide an error.

Automatic recovery only uses valid local scripts, verified backups, or applied records proven to share the stable source identity. It does not infer identity from filenames such as `komiic.js` or `jm(0).js`. The isolated probe provides only pure random-number and UUID helpers, with no real network, file, or session access. Probe environment limitations are reported separately from file corruption and do not trigger automatic replacement. Without trusted recovery content, the original file remains in place and its domain stays paused.

The source-issue dialog can accept a trusted replacement for a script, session, or metadata file. Replacement validates the content, checks for concurrent edits, preserves immutable original-file evidence, and then commits. Invalid replacements do not overwrite existing content. Available original backups can be exported for safekeeping, but a damaged backup is not a valid script to restore blindly. A message that the file was saved but runtime recovery is pending means the file commit succeeded; repair the dependency and retry rather than assuming a later sync failure rolled the file back.

If a recovery journal is corrupt or incomplete, export the original files and backups, restore a complete journal matching the current quarantine records, and retry. **Do not delete journals, clear synchronization state, or reinstall sources to bypass validation.** Missing proof does not authorize replacement or publication of deletions.

## Cloud Format and Integrity

Synchronization lives under **`VeneraPlus/<device-name>/`** inside the configured WebDAV directory. Normal synchronization uses only device metadata, Commits, and Packs:

```text
VeneraPlus/
  <device-name>/
    device.json
    commits/<counter>-<manifest-SHA256>.json
    packs/<Pack-SHA256>.pack
```

Each manifest describes a **full causal checkpoint**, preserving records, candidates, and deletions. Logical objects use gzip encoding: large collections such as favorites and history keep 64 stable identity-based buckets; scripts, sessions, and cookies are sharded per identity. The global causal clock lives in the manifest so a counter-only change does not invalidate every shard. Physical transfer combines logical objects into deterministic, content-addressed Packs targeting 1 MiB; a larger individual object may occupy a larger Pack. Small shards no longer each require a remote file.

Up to **4 workers** upload and read back required Packs before publishing the immutable manifest. Downloads use the same bounded concurrency, and failure waits for in-flight requests to finish. Verified directories are reused within a task and revalidated on retry, never treated as permanent existence proof. New manifests reference unchanged old Packs and only package changed shards; editing one setting normally uploads one changed Pack and a new manifest, not unchanged history or scripts. No-change operations create neither a new Pack nor a new commit.

The bounded encoding cache includes full causal content and event digests, avoiding repeated gzip work. Verified Pack/publication caches are scoped to the endpoint and current namespace and survive restarts; the Pack disk cache defaults to **128 MiB**. Corrupt or unwritable caches fall back safely, and removing a cache does not lose business state. A full manifest may reference at most **256 MiB** of physical Packs. Sparse old references reaching this limit cause current shards to be repacked, not a full repack on every sync and not deletion of remote Packs. Initial sync, cleared caches, or rebuilding trusted references still incur full packing/downloading and discovery costs.

Path separators, URL delimiters, and control characters in device names are replaced with underscores, and unsafe trailing dots/spaces are removed. Empty or dot-only names are rejected. If another actor owns the same name, a stable short identifier is appended to the directory instead of overwriting that actor. Renaming preserves the internal actor identity and counters; old directories remain discoverable, with checkpoints subject to the same read and safe-cleanup rules. Synchronization reads every device directory, not just this device's directory. Existing local sync state publishes a full checkpoint when this actor has no checkpoint in the new namespace, even without new local edits.

Reads verify the SHA-256 in the filename, content format, counter, and agreement between directory ownership and the payload actor. GET redirects or missing ETags can still be validated by the content hash. Corrupt or partial candidate files are not committed checkpoints and cannot hide an older valid checkpoint from that device; multiple files with the same counter cannot be resolved by arbitrarily choosing one. Authentication and network failures are actual errors, not evidence that the server has no data.

**Own-counter verification after replica recovery** is a stricter exception: unavailable, corrupt, or unverified required own commits or Packs report `SYNC_RECOVERY_REMOTE_UNVERIFIED` and prevent allocating new events, rather than being skipped in favor of a possibly insufficient counter floor. Normal fallback to older valid checkpoints for other actors is unchanged.

Uploads use conditional creation and read-back verification before acknowledgement. A Pack contains the `VNSPK001` magic, a 4-byte big-endian index length, a canonical JSON index, and original gzip object bytes. The index includes the protocol version, object paths, hashes, payload-relative offsets, compressed/expanded sizes, and codecs; gzip objects are not compressed twice. Reads verify whole-Pack and logical-object SHA-256, format, domain, unique keys, offset boundaries, and resource limits, including causal and `batchId` verification. A manifest with incomplete references is not usable. Bad files can only be repaired with verification and a strong ETag precondition, or superseded by a checkpoint preserving the intended changes. Unconditional overwrite, collisions, and truncation are not success. **Matching HEAD length does not prove content integrity**: unless a Pack was already read back and verified in this task, reuse still requires GET and hash verification.

Cleanup only considers **this device's old commit manifests** discovered before upload and proven causally covered by the new checkpoint. It requires a strong ETag and `If-Match`, retaining one valid predecessor for recovery. Maintenance requires at least 3 own commits. The count threshold is 32, with at least 24 hours between count-triggered attempts; after a previous attempt, 7 days can also trigger maintenance. The first attempt uses the count threshold. Other actors are filtered out before the 64-own-candidate cap. An approximately 2-second cooperative budget still drains in-flight requests rather than leaving background deletions.

Other actors, concurrent new files, historical protocol files, and root `.venera` archives are excluded. **Packs and causal deletion information are not automatically collected**: ordinary WebDAV cannot prove that a concurrent manifest will not reference content, and offline devices may still carry old values. Cloud usage is therefore not guaranteed to remain constant; missing strong conditional validators retain more manifests.

### Performance Diagnostics

Debug mode or the `VENERA_SYNC_DIAGNOSTICS=true` compile-time flag enables phase timings and aggregate transfer statistics; detailed logging is off in ordinary releases. Phases include `capture`, `legacyMigration`, `discover`, `download`, `merge`, `apply`, `upload`, `compact`, and `totalDurationMs`, alongside HTTP-method counts, bytes, physical blocks, and cache statistics. Nested phases can overlap and must not simply be summed into the total. UI duration and transfer summaries do not depend on detailed logging.

Request logs retain only the method, HTTP status, and endpoint origin, never endpoint paths, URL user information, queries/fragments, authorization headers, cookies, sessions, scripts, or request/response bodies. Disabling diagnostics does not weaken content verification.

### Loopback HTTP Verification and Performance Boundaries

The current layout was exercised with two independent SQLite synchronization states and real loopback WebDAV. Initial publication of 120 history records created only 1 Pack. Offline additions, a deletion, and a same-field conflict converged after reconnecting, retaining both candidates. The outbox survived restart, and unchanged old Packs were not uploaded again. Historical remote directories and root backups retained their original bytes, with no access to old-protocol content.

This is a functional smoke run on the Windows test host, not a timing benchmark for real NAS, Android, or two physical devices. The goal is fewer small files and round trips, not necessarily fewer bytes; integrity verification may still download existing Packs. Use phase timings, HTTP counts, and transfer statistics to assess your service rather than reusing timing tables from an earlier layout.

## Device-Local Fields and Secrets

The following do not participate in ordinary data synchronization and cannot be overwritten by remote content:

- Data-sync WebDAV URL, username, password, and connection preferences.
- This device's direction, timing, interval, device-name configuration, category scope, excluded fields, device identity, pending markers, manual-edit provenance, and merge/recovery metadata. Remote ownership and causal identity do not overwrite local configuration.
- Local comic storage path (`local_path`), device-specific settings, and filtered proxy/local security settings.
- Bangumi pending progress submissions and retry queues.

Excluded settings and optional settings whose sync switches are off are **out of scope**, not deletion instructions. Disabling a switch must not publish deletion of those settings to other devices, and remote imports do not replace locally excluded values.

Bangumi Access Token, username, and bindings synchronize by default; corresponding settings can be disabled through the excluded-field configuration. **The Access Token is stored in remote checkpoints**, so only use a trusted WebDAV service. UI and CLI token candidates are masked; this does not encrypt cloud files.

The WebDAV comic library URL, username, password, path, and automatic-update preferences **always participate in settings synchronization**. There is no library configuration sync switch; legacy disabled values and exclusions for library fields no longer block synchronization. Disabling the entire Settings category still stops its capture and remote application. Comic archive backup configuration remains opt-in, off by default, requiring both exporting and importing devices to enable it. **Library credentials, enabled archive credentials, cookies, and source sessions can contain secrets and reside in cloud objects.** Use a trusted, access-controlled service. UI and CLI show safe summaries rather than secret bodies. **Gzip is compression, not encryption.** Masking and disabling categories do not erase already stored secrets.

## Saving Configuration and Switching Versions

Saving configuration validates the connection and prepares endpoint state **without first uploading or importing business data**. Validation or pre-commit save failures retain the old connection, preferences, and local business data. A successful save means configuration has committed. Real-time or scheduled mode then queues the first sync as ordinary work; manual mode only saves configuration. A later transfer failure retains the saved configuration, unfinished work, and error state; it does not falsely roll back saved configuration or committed data.

Changing timing/interval reschedules work. Clear all connection fields and save to disconnect. Legacy auto-sync enabled maps to real-time, disabled to manual, and an existing scheduled mode is retained. Old keys are removed once. Direction defaults to bidirectional.

**This cutover does not migrate old remote checkpoints.** Historical protocol directories, archive markers, and flat checkpoints are not read, updated, or deleted. Old and new clients do not continuously interoperate. Reading original root ZIP backups is separate compatibility, not a bridge for old live synchronization protocols.

Rollout order:

1. Export and keep `data.venera` from each device. With the app closed, also back up its complete local profile, including every `sync_state_*` state file. Do not reset these states or replace them with another device's identity.
2. Stop old clients from writing. Retrieve data present only in an old remote layout using an old client or an exported backup first; the new client will not read it.
3. Upgrade the device retaining complete, latest causal state first, preserving its profile and synchronization state. Synchronize in an upload-capable direction and verify a usable Commit and Pack under `VeneraPlus/<device-name>/`.
4. Upgrade the other devices and synchronize. Check favorites, history, scripts, deletions, and conflict candidates. Download-only cannot publish the initial checkpoint and must wait for another device to publish.

**`data.venera` does not retain complete synchronization clocks, deletion tombstones, or the outbox and cannot replace a full-profile backup.** Restoring only the ZIP loses that proof. Do not clear existing sync state to force initial publication, even if there are no new local edits.

### Original Root Backup Seeds

On first use of an endpoint, only numeric **`<day>-<dataVersion>.venera`** files in its root are recognized and verified in isolation. All archives with the highest numeric version are read as causal seeds; conflicts follow the automatic cloud/local policy above. Archives are neither rewritten nor deleted. Available business domains complete seed import independently while affected source domains remain pending recovery. Failed reads or integrity checks do not mark completion. Later root writes from old clients do not automatically enter the protocol.

To choose another backup, open the root backup list in Data Sync status, select a specific file, and confirm separately. The CLI equivalents are `webdav backups` and `webdav import-backup <name> --confirm`. This **causally merges** the selected backup instead of overwriting local data or reading an old live protocol. Archive SHA-256 and business-domain identity deduplicate seeds. Repeating a selection adds no duplicate seed. Upload-only does not import local business data; download-only does not publish; damaged source domains remain reported as partial synchronization. Repairing the selected archive only clears issues proven repaired, not pending issues belonging to other archives.

Automatic and explicit root seed reads enforce limits: 512 MiB downloaded per archive, 1 GiB total expanded content, 256 MiB per database, 16 MiB per text file, 10,000 entries, and 8 MiB of central-directory metadata. Exceeding a limit explicitly fails the read, without truncation, partial seed import, or marking completion. Keep the original archive; no user-facing option raises these limits. **These network-reader checks do not apply to the separate local overwrite import below.**

Legacy archives support native ZIP64 directory records and signed/unsigned 32-bit or 64-bit data descriptors while retaining CRC, local/central-header consistency, path, entry-boundary, and expansion-limit checks. ZIP64 compatibility does not admit damaged or truncated archives. Source repairs use a **persistent local override layer** bound to the original archive SHA-256 and entry path. Retries apply the override in isolation without rewriting the cloud `.venera` or its original verified backup, and only complete domains still awaiting migration.

## Independent Local Backup and Overwrite Restore

Backup & Restore still exports the original **`data.venera`** ZIP, separate from Pack publication:

```text
appdata.json
history.db
local_favorite.db
cookie.db
comic_source/<direct files>
```

Local `.venera` import follows the original overwrite order: history → local favorites → settings and search history → cookies → comic sources. Corresponding managers are reopened and the extraction directory is cleaned up. Search history is restored directly. Settings retain local `proxy`, `authorizationRequired`, `customImageProcessing`, `webdav`, `disableSyncFields`, `deviceId`, and user-excluded fields; independent synchronization configuration is not overwritten. `.picadata` retains its separate original import path.

**Overwrite restore is not causal merge and has no prevalidation, staging transaction, or automatic rollback.** A failure may leave some databases or files replaced. Import trusted backups only and save current data first. Applied restore changes notify synchronization; subsequent sync captures restored business state as new edits. Runtime refresh failure does not undo an overwrite. Keep original synchronization state rather than using ZIP import as deletion proof or full-profile migration.
