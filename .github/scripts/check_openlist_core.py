#!/usr/bin/env python3
"""Exercise the desktop OpenList C ABI after CI compiles it."""

from __future__ import annotations

import ctypes
import json
import sys
import tempfile
from pathlib import Path


def invoke(library: ctypes.CDLL, request: dict[str, object]) -> dict[str, object]:
    raw = json.dumps(request).encode("utf-8")
    pointer = library.OpenListInvoke(raw)
    if not pointer:
        raise RuntimeError("OpenListInvoke returned null")
    try:
        return json.loads(ctypes.string_at(pointer).decode("utf-8"))
    finally:
        library.OpenListFree(pointer)


def main() -> None:
    library_path = Path(sys.argv[1]).resolve()
    if not library_path.is_file():
        raise SystemExit(f"missing OpenList library: {library_path}")
    library = ctypes.CDLL(str(library_path))
    library.OpenListAllocate.argtypes = [ctypes.c_int]
    library.OpenListAllocate.restype = ctypes.c_void_p
    library.OpenListFree.argtypes = [ctypes.c_void_p]
    library.OpenListInvoke.argtypes = [ctypes.c_char_p]
    library.OpenListInvoke.restype = ctypes.c_void_p
    allocated = library.OpenListAllocate(8)
    if not allocated:
        raise RuntimeError("OpenListAllocate returned null")
    library.OpenListFree(allocated)
    with tempfile.TemporaryDirectory(prefix="venera-openlist-") as data_dir:
        response = invoke(library, {"method": "initialize", "arguments": {"dataDir": data_dir, "proxy": ""}})
        if response.get("error") or response.get("data", {}).get("drivers") != ["BaiduNetdisk", "QuarkOpen", "115 Open", "123 Open", "Onedrive", "GoogleDrive"]:
            raise RuntimeError(f"initialize failed: {response}")
        accounts = invoke(library, {"method": "accounts", "arguments": {}})
        if accounts.get("error") or accounts.get("data", {}).get("accounts") != []:
            raise RuntimeError(f"unexpected initial accounts: {accounts}")
        closed = invoke(library, {"method": "close", "arguments": {}})
        if closed.get("error"):
            raise RuntimeError(f"close failed: {closed}")
        reopened = invoke(library, {"method": "initialize", "arguments": {"dataDir": data_dir, "proxy": ""}})
        if reopened.get("error"):
            raise RuntimeError(f"reopen failed: {reopened}")
        invoke(library, {"method": "close", "arguments": {}})


if __name__ == "__main__":
    main()
