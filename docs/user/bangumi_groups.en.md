# Bangumi Work Groups

中文版本：[bangumi_groups.zh.md](bangumi_groups.zh.md)

Comics from different sources appear as one work on Home, in local favorites, and in reading history once they have saved bindings to the same Bangumi subject ID. Cards use the saved Bangumi title and cover when available and show the source count. Missing metadata falls back to the source's title or cover.

## Creating and removing groups

1. Open a comic's details, choose a subject in the Bangumi panel, and save the binding.
2. Bind the same work from another source to the same Bangumi ID.
3. Return to Home, favorites, or history to see the combined card.

Only valid saved bindings create groups. Similar titles, search results, and metadata suggestions do not. Removing or changing a binding updates the groups. Disabling automatic sync or disconnecting the Bangumi account preserves existing groups. Online libraries continue to respect the current library's binding scope.

Home groups only the sources in its assigned favorite folder. A regular local favorite folder also includes only its own members. All Favorites can combine records from multiple folders. Sidebar counts still represent source records; hover or long-press a count for its label. They can therefore exceed the number of work cards.

## Reading and choosing a source

- Continue reading uses the most recently read available source. If several sources have no history, choose a source first.
- Use Choose comic source in a card menu or comic details to switch explicitly. The chooser shows each source's reading progress, last-read marker, download status, and updates.
- Each source keeps its own chapters, pages, and reading position. A source without history opens its details and catalog; a downloaded copy can use the local reader when its source is unavailable.
- Unavailable sources without a downloaded copy are disabled in the chooser.

Switching sources does not transfer chapter numbers or page positions, or merge downloaded files. An update from any member marks the work card. Reading clears the corresponding source's reminder. Clear all source update reminders clears reminders for every source in the current group.

## Search, favorites, and history

Search matches the Bangumi title, original title, and any member's name or tags, keeping the full group when matched. Select All and Invert Selection use works visible after search, reading-status, and blocked-word filters. Reading status reflects the most recently read source's record, not completion of the entire work.

Copy, move, and delete operate on the group's members in the current folder. Sources that exist only in other folders are unaffected. Reordering moves work cards and saves their members as consecutive entries. Downloads still require a source choice. Binding or membership changes clear affected selections so a batch action cannot silently include new targets.

History keeps the original record for every source. Remove a work's complete history, or select and remove one source's record, including unavailable sources.

## Bangumi synchronization

Bindings for the same subject share confirmed remote episode and volume progress, rating, and collection status. Updating one source also updates the other bindings' cached state. Progress parsing remains source-specific; local chapter and page positions are independent.

Manually lowering progress clears conflicting queued uploads for the same account, subject, and progress field, preventing older tasks from immediately restoring the previous value. Later reading may still generate new progress uploads. See [App Data Synchronization](data_sync.en.md) for cross-device snapshot behavior.
