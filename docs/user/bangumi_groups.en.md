# Switching comic sources and Bangumi sync

中文版本：[bangumi_groups.zh.md](bangumi_groups.zh.md)

Home, local favorites, and reading history display each actual source with its own title and cover. Binding several sources to the same Bangumi subject does not combine their cards.

## Switching sources

1. Open a comic's details or reader and select **⋯ → Switch source**.
2. Search enabled sources that support searching, using the current title. Edit the query for alternate translations or names; a Bangumi binding is not required.
3. Open a result to preview its cover, description, chapter list, and information. A source's full search results are also available.
4. Select **Use this source** to apply the change. Previewing, returning, or cancelling does not replace the source.

Confirmation replaces the original comic in its local favorite folders while preserving folder membership, favorite time, and order. An existing target in the same folder is deduplicated. Home and update checks use the new source, including after restarting the app. Only the selected source identity is replaced; other comics with the same title or Bangumi subject are unaffected.

Switching from details opens the new details page. Switching from the reader resumes the target source's saved progress if available; otherwise it opens details to choose a chapter. The original history and downloads are retained. Chapter numbers and page numbers are not copied between sources.

## Sharing

Use **⋯ → Share** in details to share the current comic's title and link, or in the reader to share the current page image.

## Existing records and bindings

Previously grouped favorites and histories appear as separate source entries without deleting saved records. A replacement without a Bangumi binding inherits the original subject relationship and uses automatic chapter parsing. Existing target bindings are preserved.

## Bangumi synchronization

Choose a server from **Settings → Online Services → Bangumi → Website list**. The default is the official `bgm.tv` service; `bangumi.lat` and `anibt.net` mirrors are also included. The list shows a name or domain, with separate stored API, image proxy, and Access Token page addresses rather than inferred subdomains.

Custom entries require the actual API address; `https://` may be omitted. The name, image proxy, and Access Token page are optional. Empty image proxy settings preserve image URLs returned by the API, and an empty Token page uses the official application page. New entries append to the list; select an entry to switch servers. Custom entries can be edited or deleted, and deleting the active entry restores the official server. The selected API server receives your Access Token, so choose a service you trust.

Opening the list automatically tests every API, with a manual retest option. Latency measures one anonymous public API request from this device using the app's network settings; probes do not send your Token to the listed servers. Verification pages, timeouts, and incompatible responses have separate statuses. A working public endpoint does not verify account synchronization; use **Verify connection** for the selected account. Closing the list cancels remaining probes.

Bindings for the same subject share confirmed remote episode and volume progress, rating, and collection status. Updating one source also updates the other bindings' cached state. Progress parsing remains source-specific; local chapter and page positions are independent.

Manually lowering progress clears conflicting queued uploads for the same account, subject, and progress field, preventing older tasks from immediately restoring the previous value. Later reading may still generate new progress uploads. See [App Data Synchronization](data_sync.en.md) for cross-device snapshot behavior.
