# Downloads and missing-page repair

“Continue past unavailable images” is off by default in an image task's menu. Its default for new tasks can be changed under Settings → App → Local Storage and Downloads. Existing and restored tasks keep their own option. When enabled, exhausted connection failures, HTTP 404/410 and unsupported image data are recorded as missing pages while other pages continue. Authentication, certificate, cancellation and local write failures still stop the task.

Incomplete tasks enter “Waiting for missing pages” and allow the queue to continue. The local library displays the missing-page count and lets you read completed pages, with placeholders preserving original page numbers. Use “Retry missing images” in the task or local comic menu to repair only missing pages. Options and missing positions survive restart; restored tasks stay paused.

Removing an incomplete task keeps its local pages. A repair task can still be created from the local comic menu. If the source page list has changed, download the affected chapter again. Export and archive operations require all missing pages to be repaired first.

User-started Android downloads use a foreground service with progress notifications and a notification pause action. Temporary connection failures have bounded exponential backoff; validated connectivity and foreground events can wake an existing wait. User-paused tasks are not restarted. The service shares the app process lifetime; force-stop and manufacturer power restrictions can still interrupt downloads.
