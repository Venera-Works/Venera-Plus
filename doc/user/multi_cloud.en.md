# Multi-cloud storage

VeneraPlus connects Baidu Netdisk, Quark, 115, 123 Cloud, OneDrive, and Google Drive through its embedded OpenList core. WebDAV remains available as a separate account type.

The embedded core is built independently by Venera-OpenList-Core and packaged with the app. The app uses a fixed released core version and does not download or run an OpenList service on the device.

Choose Add on the cloud account management page in Storage & Sync, then select a provider from its own page to open the matching account form. Enter credentials or authorize the account, then save and test the connection. Editing an existing account opens its form directly. Go back from the form to choose another provider, or go back from the provider list to cancel adding an account. For Baidu Netdisk, 115, 123 Cloud, and OneDrive, choose "Log in and authorize" to complete authorization in the app's WebView and fill the tokens automatically. Authorization and online token refresh continue to use the official OpenList API. The app does not expose an OpenList HTTP server.

Automatic token authorization always uses the parameters provided by OpenList: OAuth App verification for 115 and Baidu; official OAuth verification for 123 Cloud; and personal OAuth App authorization for OneDrive. No client ID or application secret is required from the user.

Quark uses the `Quark` Cookie driver. Choose "Log in and authorize" to sign in on Quark's official website inside the app's WebView. After confirming that the session can list drive files, the app reads the native cookie store, including HttpOnly cookies, and fills the Cookie field. You can also enter the Cookie manually. Save to test the connection. Existing `QuarkOpen` accounts require a new login; saving retains the account ID and configured directories, without the old tokens, AppID, or SignKey.

Google Drive still requires manual authorization on the [OpenList Token page](https://api.oplist.org/). Token-based providers also accept manually entered tokens. Baidu, 123 Cloud, OneDrive, and Google Drive require a refresh token; 115 requires both access and refresh tokens.

Settings → Storage and Sync groups cloud accounts, online comic libraries, app-data sync, and comic archive backup by purpose, showing the selected accounts, directories, and sync status. Authorize an account once and reuse it across purposes. You can add an account from any account selector and continue the current form. After connecting an account for the first time, you can also choose its purpose directly.

Settings → Sources and Services → Content Sources manages website sources and remote comic libraries in separate groups on one page. Choose Add and select a source type: install website sources from repositories or import a link or file; add remote libraries by selecting a cloud account and comic directories, with the option to create an account during setup. Online Comic Libraries in Storage and Sync and source-management actions in discovery and search open this same page.

Each online comic library can select one account and one or more recognition directories. Results are combined, with duplicate full remote paths shown once and same-named comics in different paths kept separately. App-data sync and comic archive backup each use one account and one directory: the former transfers settings, favorites, reading records, and other app data; the latter backs up and restores CBZ comic files.

Online libraries support image directories and remote ZIP/CBZ files. Each ZIP/CBZ appears as one comic and may contain a single top-level folder, chapter folders, and an optional `metadata.json`. The app reads the archive tail, central directory, and required images on demand. Covers load when displayed and are cached; reading pages reuse the image cache. See [comic import and online reading](import_comic.en.md#on-demand-zipcbz-reading) for layout examples and metadata rules.

On-demand ZIP/CBZ reading requires HTTP Range support from the actual file server. Servers that ignore Range, return the full file, or supply invalid partial responses cause an explicit failure without an automatic full download. This also applies to cloud download links, proxies, and redirects. The initial implementation supports ZIP/ZIP64 with Store/Deflate, excluding encrypted or split archives and other compression methods. 7z/CB7, PDF, and EPUB files cannot be read directly on demand from the cloud. Download them for local import, or extract comic images into a remote directory.

Existing WebDAV sync and archive settings are automatically added to the shared accounts while retaining their remote directories. Local comic paths, cache settings, and download threads are under Local Storage and Downloads; manual data transfer is under App Data Import and Export.

All saved cloud accounts and their credentials are included in app-data snapshots, including accounts not yet used by a comic library. During restore, a still-valid local authorization is retained. The data-sync destination stays local; archive-backup configuration is synchronized only when its opt-in is enabled.

Account names must be unique, ignoring leading and trailing whitespace and letter case. Use the same name for the same account on every device and different names for different accounts. Synchronization merges accounts with the same name and provider, updating library, sync, and backup references while retaining library IDs and favorite associations. Accounts with matching names but different providers are retained with a name suffix to distinguish them. Renaming an account retains its internal ID.

Native OpenList builds, platform loading, and real-provider checks have not been run locally. They are pending CI and dedicated test directories. End-to-end checks of on-demand ZIP/CBZ reading on platforms and real cloud providers have not been completed either. Range compatibility depends on the actual responses from the storage service.

The macOS app continues to support macOS 12. Because of the Go 1.27 runtime requirement, the six OpenList providers require macOS 13 or later; WebDAV and local features remain available on macOS 12.
