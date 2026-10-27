# Downloads and missing-page repair

“Continue past unavailable images” is off by default in an image task's menu. When enabled, exhausted connection failures, HTTP 404/410 and unsupported image data are recorded as missing pages while other pages continue. Authentication, certificate, cancellation and local write failures still stop the task.

Incomplete tasks stay in the queue and are not registered as complete local comics. Their details list missing chapters and page numbers. Starting again repairs missing pages without downloading successful images again. The option and missing pages survive queue restoration, which remains paused after restart.

User-started Android downloads use a foreground service with progress notifications and a notification pause action. Temporary connection failures have bounded exponential backoff; validated connectivity and foreground events can wake an existing wait. User-paused tasks are not restarted. The service shares the app process lifetime; force-stop and manufacturer power restrictions can still interrupt downloads.
