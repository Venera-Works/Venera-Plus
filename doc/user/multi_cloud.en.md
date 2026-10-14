# Multi-cloud storage

VeneraPlus connects Baidu Netdisk, Quark, 115, 123 Cloud, OneDrive, and Google Drive through its embedded OpenList core. WebDAV remains available as a separate account type.

The embedded core is built independently by Venera-OpenList-Core and packaged with the app. The app uses a fixed released core version and does not download or run an OpenList service on the device.

Add accounts in Storage & Sync. Import the authorization data copied from the [OpenList Token page](https://api.oplist.org/) manually. The app does not expose an OpenList HTTP server.

Each comic library can select one account and one or more recognition directories. Results are combined, with duplicate full remote paths shown once and same-named comics in different paths kept separately. Data sync and comic archive backup each use one account and one directory.

Comic-library credentials are included in app-data snapshots. During restore, a still-valid local authorization is retained. The data-sync destination stays local; archive-backup configuration is synchronized only when its opt-in is enabled.

Native OpenList builds, platform loading, and real-provider checks have not been run locally. They are pending CI and dedicated test directories.

The macOS app continues to support macOS 12. Because of the Go 1.27 runtime requirement, the six OpenList providers require macOS 13 or later; WebDAV and local features remain available on macOS 12.
