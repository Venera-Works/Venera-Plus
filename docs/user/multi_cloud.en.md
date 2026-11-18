# Multi-cloud storage

[中文](multi_cloud.zh.md) · [Documentation index](../README.en.md)

VeneraPlus connects Baidu Netdisk, Quark, 115, 123 Cloud, OneDrive, and Google Drive through its embedded OpenList core. WebDAV accounts are also supported.

The embedded core is built independently by Venera-OpenList-Core and packaged with the app. The app uses a fixed released core version and does not download or run an OpenList service on the device.

## Add and authorize accounts

Choose Add on the cloud account management page in Storage & Sync, then select a provider to open its account form. When adding Baidu Netdisk, Quark, 115, 123 Cloud, or OneDrive, the form contains only the name and "Log in and authorize" button. Successful authorization automatically saves the account and tests the connection, without manual token or Cookie entry or another Save action. A blank name uses the provider name; duplicate names must be changed before authorization starts. Canceling or failing authorization does not save an account and keeps the entered name. Editing an existing account opens its form directly, where you can still change its name and credentials and choose "Save and test connection". Go back from the form to choose another provider, or go back from the provider list to cancel adding an account. Baidu Netdisk, 115, 123 Cloud, and OneDrive authorization and online token refresh continue to use the official OpenList API. The app does not expose an OpenList HTTP server.

Automatic token authorization for 115, 123 Cloud, Baidu, and OneDrive uses the parameters provided by OpenList. This covers OAuth App verification for 115 and Baidu, official OAuth verification for 123 Cloud, and personal OAuth App authorization for OneDrive. No client ID or application secret is required from the user.

Quark uses the `Quark` Cookie driver. Choose "Log in and authorize" to sign in on Quark's official website inside the app's WebView. After confirming that the session can list drive files, the app reads the native cookie store, including HttpOnly cookies. New accounts are then saved and tested automatically. Existing `QuarkOpen` accounts require a new login; saving an edited account retains its ID and configured directories, without the old tokens, AppID, or SignKey.

Enter a server address, username, and password to save a WebDAV account. You can manually update tokens or Cookies when editing other cloud accounts. Baidu, 123 Cloud, and OneDrive require a refresh token. 115 requires both an access token and a refresh token.

### Google Drive authorization with your own OAuth client

In the Google Cloud console, enable the Google Drive API, configure the OAuth consent screen, and create a **Web application** OAuth client. Register your chosen callback as an authorized redirect URI. When adding or editing a Google Drive account in VeneraPlus, enter its `Client ID` and `Client Secret`. VeneraPlus refreshes tokens directly with Google. [Google Cloud console](https://console.cloud.google.com/)

- **Default OpenList callback.** Register the default address shown in the VeneraPlus callback setting in Google Cloud. Keep the default in VeneraPlus and choose **Try OpenList authorization in WebView**. VeneraPlus sends the client credentials to OpenList for the token exchange. On success, VeneraPlus reads the refresh token, saves the account, and tests the connection.
- **Manual authorization in the browser.** If Google displays `disallowed_useragent` in WebView, go back to the account page and choose **Open OpenList to get a refresh token**. On the OpenList page, select Google Drive and enter the same client credentials. After authorizing with Google, paste the `Refresh Token` back into VeneraPlus and choose **Save and test connection**. [OpenList instructions](https://doc.oplist.org/guide/drivers/google_drive)
- **Self-hosted callback.** Open **OAuth callback address**, enter the full HTTPS address of a callback that can return the authorization result to VeneraPlus, and confirm. Choose **Log in and authorize** to open Google in the system browser. After granting access, return to VeneraPlus. It obtains the refresh token, saves the account, and tests the connection automatically. Clear the callback field to restore the default.

#### Deploy a self-hosted callback

1. Run the [callback script](../examples/google_drive_callback.mjs) on your server with Node.js 22.1 or newer.

   ```sh
   node google_drive_callback.mjs
   ```

2. Reverse-proxy `/googleui/callback` on your HTTPS domain to `http://127.0.0.1:8787`. Forward GET requests with their query parameters and POST requests, and disable caching and access logging for this path. The script stores sessions in memory in a single process. Sessions expire after five minutes.
3. Enter the full address (for example, `https://drive.example.com/googleui/callback`) in both the Google Cloud console and VeneraPlus. The callback service relays a one-time authorization code. VeneraPlus exchanges it directly with Google. For a standard self-hosted OpenList APIPages instance, authorize in its web interface and paste its refresh token into VeneraPlus manually.

You can also enter an existing refresh token and save it. To obtain a token through [Google OAuth Playground](https://developers.google.com/oauthplayground/), register `https://developers.google.com/oauthplayground` as a redirect URI and enable **Use your own OAuth credentials**. Use `https://www.googleapis.com/auth/drive.readonly` for browsing and reading, or `https://www.googleapis.com/auth/drive` to write metadata, sync, or back up files.

If the account previously used shared OpenList credentials, edit the existing account and authorize with the same Google account to keep its library, sync, and backup directories. For an external OAuth app in **Testing**, add your Google account as a test user. Drive refresh tokens issued in this state expire after seven days.

## Configure uses and comic directories

Settings → Storage and Sync groups cloud accounts, online comic libraries, app-data sync, and comic archive backup by purpose, showing the selected accounts, directories, and sync status. Authorize an account once and reuse it across purposes. You can add an account from any account selector and continue the current form. After connecting an account for the first time, you can also choose its purpose directly.

Settings → Sources and Services → Content Sources manages website sources and remote comic libraries in separate groups on one page. Choose Add and select a source type: install website sources from repositories or import a link or file; add remote libraries by selecting a cloud account and comic directories, with the option to create an account during setup. Online Comic Libraries in Storage and Sync and source-management actions in discovery and search open this same page.

Each online comic library can select one account and one or more recognition directories. Results are combined, with duplicate full remote paths shown once and same-named comics in different paths kept separately. App-data sync and comic archive backup each use one account and one directory: the former transfers settings, favorites, reading records, and other app data; the latter backs up and restores CBZ comic files.

In the directory picker, choose a folder name to open it and use the checkbox at the end of its row to select it. The Current folder row also allows selecting the root or an empty folder. Selections remain checked when navigating between directories. The fixed bottom area shows the selected count, with Done on the right to return to configuration; going back cancels the selection changes. Libraries support multiple directories, while sync and backup allow one directory.

## Refresh, caches, and rate limits

Opening an online library first shows cached or newly discovered works. Covers, authors, tags, and other details are filled in progressively in the background. Opening comic details or selecting a volume reads the chapters and file content needed for that view. The library's refresh button requests remote directories again and updates the list as works are discovered or details become available. Use it after adding, deleting, or moving comics outside the app. Showing the first results does not mean the entire scan has finished.

New 115 libraries have Automatic library updates disabled by default; other providers default to enabled, and existing libraries keep their settings. Choose updates every 15 minutes, every hour, every six hours, or every day; the default is six hours. Checks run only while the app runs. Opening a library without an index still creates its first index even when automatic updates are disabled. This interval is separate from the app-data sync schedule.

Automatic scans reuse local directory listings for up to one hour on 115 and ten minutes on other providers. Listings survive restarts; manual refresh always requests remote directories again. Recognition directories are scanned independently: successful roots update their indexes, failed roots retain their previous indexes and record an error, and newly discovered works may already be visible. A failed directory read is not treated as an empty directory that removes existing works.

When rate limiting is detected, new directory, direct-link, metadata-write, image, and reading-range requests on the same account are paused while locally cached content remains available. The app follows the server's retry time, or waits fifteen minutes when none is provided. The cooldown is stored locally and applies to manual refresh and requests after a restart. Pending metadata writes also respect their retry time at startup.

## Online reading formats

Online libraries support image directories, remote ZIP/CBZ files, image-based EPUB files, and PDF files. Volume files belonging to one work can be aggregated; explicit edition folders and duplicate volumes become selectable reading groups, while non-overlapping volumes can mix formats. Volumes and covers are inspected and cached on demand, and sequential reading and preloading stop at edition boundaries. Independent ZIP/CBZ files retain chapter folders and groups, EPUB follows spine order and distinguishes chapters from page navigation, and PDF renders original pages with bookmark-based chapters. See [comic import and online reading](import_comic.en.md#on-demand-zipcbz-image-based-epub-and-pdf-reading) for layout examples and metadata rules.

On-demand cloud file reading requires HTTP Range support from the actual file server. Servers that ignore Range, return the full file, or supply invalid partial responses cause an explicit failure without an automatic full download. This also applies to cloud download links, proxies, and redirects. ZIP/CBZ reading supports ZIP/ZIP64 with Store/Deflate, excluding encrypted or split archives and other compression methods. Download 7z/CB7 files for local import, or extract their comic images into a remote directory.

## Cross-device configuration and legacy data

Existing WebDAV sync and archive settings are automatically added to the shared accounts while retaining their remote directories. Local comic paths, cache settings, and download threads are under Local Storage and Downloads; manual data transfer is under App Data Import and Export.

App-data snapshots include all saved cloud accounts and their credentials, including Google Drive client secrets and accounts not yet used by a comic library. For 123 Cloud, the access token, refresh token, absolute expiration time, and token update time are synchronized together. The newer authorization is used for the same account, and older snapshots cannot replace newer local tokens. New devices and restarts reuse the existing access token until it expires or the API rejects it. Legacy tokens without an expiration time are tried first. Importing them does not restart their lifetime. Other providers retain a still-valid local authorization during restore. The data-sync destination stays local. Archive-backup configuration is synchronized only when its opt-in is enabled.

123 Cloud refreshes can be retried after temporary network or service failures. An explicit `invalid_grant` retains the original error and marks the authorization invalid; sign in again or synchronize a newer authorization to recover. If the provider revokes old refresh tokens after rotation, devices that have not synchronized the new authorization may still need to sign in again.

Account names must be unique, ignoring leading and trailing whitespace and letter case. Use the same name for the same account on every device and different names for different accounts. Synchronization merges accounts with the same name and provider, updating library, sync, and backup references while retaining library IDs and favorite associations. Accounts with matching names but different providers are retained with a name suffix to distinguish them. Renaming an account retains its internal ID.

Snapshots contain account credentials. See [App Data Synchronization](data_sync.en.md#sync-boundaries) for included data and device-local settings. Directory indexes, image caches, and rate-limit cooldowns remain local.

## Platform support

The macOS app continues to support macOS 12. The core runtime requires macOS 13 or later for the six OpenList providers; WebDAV and local features remain available on macOS 12.
