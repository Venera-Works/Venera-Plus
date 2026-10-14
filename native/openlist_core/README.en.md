# Embedded OpenList core

This directory contains VeneraPlus's OpenList core lock data and runtime
interface. It does not run an OpenList HTTP server. The independent
`Venera-Works/Venera-OpenList-Core` repository builds and releases the core;
application builds use `.github/scripts/fetch_openlist_core.py` to download the
platform asset fixed in `core.lock.json`. `cache/Venera-OpenList-Core` is the
core repository's development workspace.

## RPC ABI

The desktop library exports `OpenListAllocate(int) -> void*`,
`OpenListInvoke(const char*) -> char*`, and `OpenListFree(void*)`. Requests and
responses are UTF-8 JSON:

```json
{"method":"list","arguments":{}}
```

```json
{"data":{},"error":{"code":"...","message":"..."}}
```

Mobile platforms use the `venera/openlist` channel's `invoke` method with the
same JSON string. Transfers return a `taskId`; callers use `taskStatus`,
`cancel`, and `releaseTask` to manage it.

Only BaiduNetdisk, QuarkOpen, 115 Open, 123 Open, Onedrive, and GoogleDrive are
registered. Credentials are supplied only through `saveAccount.addition`; the
bridge disables log output and redacts recognized credential values in errors.

## CI builds

Application CI downloads Android AAR, iOS XCFramework, and desktop C ABI
libraries. It no longer installs Go or compiles the core in this repository.
To upgrade the core, update `core.lock.json` with a released version, source
commit, and every asset digest, then run the affected platform CI. The downloaded
core installs its license into each platform package.

Go 1.27 requires macOS 13 or later. The app continues to support macOS 12, but
the macOS native channel reports `isOpenListSupported` as false there and Dart
must not load the dylib. macOS 12 therefore keeps local and WebDAV storage only.
See the [Go 1.27 release notes](https://go.dev/doc/go1.27).
