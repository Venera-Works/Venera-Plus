# Automatic reading and reading information

Start automatic reading in the reader menu or assign it to the long-press action. Gallery modes turn pages at the configured interval; continuous and waterfall modes support smooth or stepped scrolling.

Images are awaited by default. Enable “Skip unavailable images during automatic reading” to advance past failed images at the normal reading pace and move past loading images after a configurable timeout. The default is 10 seconds, adjustable from 1 to 60 seconds. Only unobstructed foreground time counts. Touch, long press, menus and the background pause advancement. Chapter loading errors still require a retry.

Continuous and waterfall reading can keep scrolling after a zoom gesture ends. Speed is measured in screen pixels, and the enlarged tail of the final page is read before stopping or crossing chapters. Gallery modes pause while actively zoomed.

On Android and iOS, automatic reading keeps the screen awake by default. This can be disabled in reader settings. Stopping, backgrounding or leaving restores system sleep. Image waiting, screen-awake and original pixel dimension settings inherit global, device and comic preferences.

“Browsing and Favorites → Show detailed reading progress” adds chapter and page totals to history and enabled history badges on comic cards. Chapter and group names are saved during normal reading. Older records fall back to ordinal positions without extra network requests. Grouped chapter totals refer to the current group.

## Reading diagnostics

Choose “Reading diagnostics” from the reader menu to start a manual capture of up to 45 seconds. Browse pages and quickly revisit them, then reopen the dialog to stop, preview and copy the report. Backgrounding, changing reading modes or leaving stops capture. Reports are cleared when the reader closes; capture is off by default and nothing is uploaded.

Reports contain anonymous image numbers, numeric timings, cache state and basic reader options, excluding comic content, titles, paths, URLs, accounts, scripts and error text. Read, processing, decoding and display waits help locate delays but are not CPU timings. Frame samples are not measured session FPS. Work completed before capture, including preloading, may have no stage samples.
