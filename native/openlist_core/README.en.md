# Embedded OpenList core

This directory contains VeneraPlus's embedded OpenList bridge. It does not run
an OpenList HTTP server. The preparation script exports the pinned upstream
revision `482464c2affc5eeba5d4a25bb272aeb352ec5918` into the build directory,
applies the tracked patches, then copies the bridge. Changes in `cache/OpenList`
are therefore never part of a release build.

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

CI builds Android AAR, iOS XCFramework, and desktop C ABI libraries. It pins Go
`1.27.1` and gomobile `v0.0.0-20260908204917-8b95e45f8d3e`. Desktop CI loads the
compiled library through `ctypes`, initializes it, verifies the six-driver
surface, and closes and reopens it. The iOS package includes OpenList's
AGPL-3.0-or-later license copied from the pinned upstream source.

Go 1.27 requires macOS 13 or later. The app continues to support macOS 12, but
the macOS native channel reports `isOpenListSupported` as false there and Dart
must not load the dylib. macOS 12 therefore keeps local and WebDAV storage only.
See the [Go 1.27 release notes](https://go.dev/doc/go1.27).
