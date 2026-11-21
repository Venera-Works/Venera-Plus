# Automatic reading and reading information

[中文](automatic_reading.zh.md) · [Reader Side Margins](reader_width.en.md)

## Start and configure automatic reading

Start automatic reading in the reader menu or assign it to the long-press action. Gallery modes turn pages at the configured interval; continuous and waterfall modes support smooth or stepped scrolling.

Image waiting and screen-awake options are on Settings → Reading and the in-reader settings panel. Comic-specific and device-specific preferences take precedence when enabled.

Images are awaited by default. Enable “Skip unavailable images during automatic reading” to advance past failed images at the normal reading pace and move past loading images after a configurable timeout. The default is 10 seconds, adjustable from 1 to 60 seconds. Only unobstructed foreground time counts. Touch, long press, menus and the background pause advancement. Chapter loading errors still require a retry.

Continuous and waterfall reading can keep scrolling after a zoom gesture ends. Speed is measured in screen pixels, and the enlarged tail of the final page is read before stopping or crossing chapters. Gallery modes pause while actively zoomed.

For aggregated cloud works, automatic reading continues only within the current edition group and stops at its end. Select another edition explicitly through the chapter list.

On Android and iOS, automatic reading keeps the screen awake by default. This can be disabled in reader settings. Stopping, backgrounding or leaving restores system sleep. Image waiting, screen-awake and original pixel dimension settings inherit global, device and comic preferences.

## Manual page turns and two-page reading

In vertical continuous and waterfall modes, tapping a page-turn region or using a page-turn key moves about 90% of the visible height in either direction. The overlap makes it easier to follow dialogue through a tall image. Volume-key page turns use the same distance when enabled.

In a horizontal gallery, set the image count for the current screen orientation to 2. Facing pages keep their proportions and line up at the top and bottom. An image wider than it is tall occupies a spread by itself. Square pages can pair with their neighbors. Enable “Show single image on first page” to display the cover on its own.

Use the sort button in the comic details or reader chapter list to select “Volume and chapter ascending”, “Volume and chapter descending”, or the original source order. For example, ascending order places `第1话`, `2`, `Chapter 3`, and `第10话` in that sequence. Equal numbers keep their original order. Read markers, bookmarks and chapter links follow the original chapter.

## Reading information

“Settings → Browsing and Favorites → Show detailed reading progress” adds chapter and page totals to history and enabled history badges on comic cards. Chapter and group names are saved during normal reading. Older records fall back to ordinal positions without extra network requests. Grouped chapter totals refer to the current group.

## Reading statistics

Open reading statistics from Library → Reading Records to see total reading time, the number of tracked comics, and time by comic. Deleting, clearing, or automatically expiring reading history preserves these statistics. Reading the same comic from the same source again continues its accumulated time, independently of reading progress.

Use the clear action at the top right of the statistics page to reset all statistics while keeping history and progress. Upgrading migrates reading time from remaining history; previously deleted time cannot be recovered without a backup. Statistics are included in full app-data backups and synchronization. Restoring a backup restores its statistics; older backups can only provide time still present in their history.

## Reading diagnostics

Choose “Reading diagnostics” from the reader menu to start a manual capture of up to 45 seconds. Browse pages and quickly revisit them, then reopen the dialog to stop, preview and copy the report. Backgrounding, changing reading modes or leaving stops capture. Reports are cleared when the reader closes; capture is off by default and nothing is uploaded.

Reports contain anonymous image numbers, numeric timings, cache state and basic reader options, excluding comic content, titles, paths, URLs, accounts, scripts and error text. Read, processing, decoding and display waits help locate delays but are not CPU timings. Frame samples are not measured session FPS. Work completed before capture, including preloading, may have no stage samples.
