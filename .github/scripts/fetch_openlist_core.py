#!/usr/bin/env python3
"""Fetch one immutable Venera OpenList Core release asset."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
import urllib.request
import uuid
import zipfile
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = ROOT / "native" / "openlist_core" / "core.lock.json"
TARGETS = (
    "android",
    "ios",
    "windows-x64",
    "macos-universal",
    "linux-x64",
    "linux-arm64",
)
EXPECTED_ARCHITECTURES = {
    "android": {"armeabi-v7a", "arm64-v8a", "x86_64"},
    "ios": {"arm64", "x86_64-simulator", "arm64-simulator"},
    "windows-x64": {"x86_64"},
    "macos-universal": {"arm64", "x86_64"},
    "linux-x64": {"x86_64"},
    "linux-arm64": {"arm64"},
}
PACKAGE_FILES = {
    "android": ("openlistcore.aar", "LICENSE.OpenList.txt"),
    "ios": ("Openlistcore.xcframework", "LICENSE.OpenList.txt"),
    "windows-x64": ("venera_openlist.dll", "LICENSE.OpenList.txt"),
    "macos-universal": ("libvenera_openlist.dylib", "LICENSE.OpenList.txt"),
    "linux-x64": ("libvenera_openlist.so", "LICENSE.OpenList.txt"),
    "linux-arm64": ("libvenera_openlist.so", "LICENSE.OpenList.txt"),
}


def load_lock(path: Path = LOCK_PATH) -> dict:
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise RuntimeError(f"OpenList core lock file is missing: {path}") from error
    except json.JSONDecodeError as error:
        raise RuntimeError(f"OpenList core lock file is invalid JSON: {path}") from error
    if not isinstance(lock, dict):
        raise RuntimeError("OpenList core lock must be an object")
    return lock


def selected_asset(lock: dict, target: str) -> dict:
    required = ("repository", "version", "tag", "sourceCommit", "rpcAbi", "assets")
    missing = [key for key in required if key not in lock]
    if missing:
        raise RuntimeError(f"OpenList core lock is missing: {', '.join(missing)}")
    if lock.get("schema") != 1:
        raise RuntimeError("OpenList core lock has an unsupported schema")
    if not all(isinstance(lock[key], str) and lock[key] for key in ("repository", "version", "tag", "sourceCommit")):
        raise RuntimeError("OpenList core lock is incomplete; publish the core release before fetching it")
    if lock["tag"] != f"core-v{lock['version']}":
        raise RuntimeError("OpenList core lock tag does not match its version")
    if not re.fullmatch(r"[0-9a-f]{40}", lock["sourceCommit"]):
        raise RuntimeError("OpenList core lock sourceCommit must be a full lowercase Git commit")
    if lock["rpcAbi"] != 1:
        raise RuntimeError("OpenList core lock has an unsupported RPC ABI")
    assets = lock["assets"]
    if not isinstance(assets, dict) or target not in assets:
        raise RuntimeError(f"OpenList core lock has no asset for {target}")
    asset = assets[target]
    if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
        raise RuntimeError(f"OpenList core lock asset for {target} is invalid")
    if asset["name"] != f"openlist-core-{target}.zip":
        raise RuntimeError(f"OpenList core lock asset for {target} has an unexpected name")
    digest = asset.get("sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise RuntimeError(f"OpenList core lock asset for {target} has no SHA-256")
    return asset


def asset_url(lock: dict, asset: dict) -> str:
    return f"https://github.com/{lock['repository']}/releases/download/{lock['tag']}/{asset['name']}"


def download_asset(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "VeneraPlus-OpenList-Core-Fetcher"})
    with urllib.request.urlopen(request) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def verify_digest(archive: Path, expected: str) -> None:
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != expected:
        raise RuntimeError(f"OpenList core asset SHA-256 mismatch for {archive.name}")


def safe_extract(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            path = PurePosixPath(member.filename)
            if (
                "\\" in member.filename
                or ":" in member.filename
                or path.is_absolute()
                or ".." in path.parts
                or not path.parts
            ):
                raise RuntimeError(f"OpenList core archive contains an unsafe path: {member.filename}")
            if member.external_attr >> 16 & 0o170000 == 0o120000:
                raise RuntimeError(f"OpenList core archive contains a symbolic link: {member.filename}")
            if member.is_dir():
                continue
            output = destination.joinpath(*path.parts)
            if not output.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError(f"OpenList core archive contains an unsafe path: {member.filename}")
            output.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(member) as source, output.open("wb") as target:
                shutil.copyfileobj(source, target)


def verify_metadata(directory: Path, lock: dict, target: str) -> None:
    try:
        metadata = json.loads((directory / "metadata.json").read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise RuntimeError("OpenList core asset is missing metadata.json") from error
    except json.JSONDecodeError as error:
        raise RuntimeError("OpenList core asset metadata.json is invalid") from error
    expected = {
        "version": lock["version"],
        "sourceCommit": lock["sourceCommit"],
        "rpcAbi": lock["rpcAbi"],
        "platform": target,
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise RuntimeError(f"OpenList core metadata {key} does not match the lock")
    architectures = metadata.get("architectures")
    if not isinstance(architectures, list) or set(architectures) != EXPECTED_ARCHITECTURES[target]:
        raise RuntimeError(f"OpenList core metadata architectures do not match {target}")


def verify_package(directory: Path, target: str) -> None:
    missing = [name for name in PACKAGE_FILES[target] if not (directory / name).exists()]
    if missing:
        raise RuntimeError(f"OpenList core asset is missing: {', '.join(missing)}")


def install_entries(root: Path, source: Path, target: str) -> list[tuple[Path, Path]]:
    if target == "android":
        return [
            (source / "openlistcore.aar", root / "android" / "app" / "libs" / "openlistcore.aar"),
            (source / "LICENSE.OpenList.txt", root / "android" / "app" / "src" / "main" / "assets" / "licenses" / "LICENSE.OpenList.txt"),
        ]
    if target == "ios":
        return [
            (source / "Openlistcore.xcframework", root / "ios" / "Frameworks" / "Openlistcore.xcframework"),
            (source / "LICENSE.OpenList.txt", root / "ios" / "Frameworks" / "LICENSE.OpenList.txt"),
        ]
    platform = "windows" if target == "windows-x64" else "macos" if target == "macos-universal" else "linux"
    return [
        (source / PACKAGE_FILES[target][0], root / "native" / "openlist_core" / "artifacts" / platform / PACKAGE_FILES[target][0]),
        (source / "LICENSE.OpenList.txt", root / "native" / "openlist_core" / "artifacts" / platform / "LICENSE.OpenList.txt"),
    ]


def replace_entries(entries: list[tuple[Path, Path]]) -> None:
    staged: list[tuple[Path, Path]] = []
    backups: dict[Path, Path] = {}
    installed: list[Path] = []
    try:
        for source, destination in entries:
            destination.parent.mkdir(parents=True, exist_ok=True)
            staging = destination.parent / f".{destination.name}.new-{uuid.uuid4().hex}"
            if source.is_dir():
                shutil.copytree(source, staging)
            else:
                shutil.copy2(source, staging)
            staged.append((staging, destination))
        for staging, destination in staged:
            if destination.exists():
                backup = destination.parent / f".{destination.name}.old-{uuid.uuid4().hex}"
                os.replace(destination, backup)
                backups[destination] = backup
            os.replace(staging, destination)
            installed.append(destination)
        for backup in backups.values():
            if backup.is_dir():
                shutil.rmtree(backup)
            else:
                backup.unlink()
    except Exception:
        for staging, _ in staged:
            if staging.exists():
                shutil.rmtree(staging) if staging.is_dir() else staging.unlink()
        for destination in reversed(installed):
            if destination.exists():
                shutil.rmtree(destination) if destination.is_dir() else destination.unlink()
            backup = backups.pop(destination, None)
            if backup and backup.exists():
                os.replace(backup, destination)
        for destination, backup in backups.items():
            if backup.exists() and not destination.exists():
                os.replace(backup, destination)
        raise


def install_target(target: str, lock: dict, root: Path = ROOT, downloader=download_asset) -> None:
    if target not in TARGETS:
        raise RuntimeError(f"unsupported OpenList core target: {target}")
    asset = selected_asset(lock, target)
    with tempfile.TemporaryDirectory(prefix="venera-openlist-core-") as temporary:
        temporary_path = Path(temporary)
        archive = temporary_path / asset["name"]
        downloader(asset_url(lock, asset), archive)
        verify_digest(archive, asset["sha256"])
        extracted = temporary_path / "extracted"
        safe_extract(archive, extracted)
        verify_metadata(extracted, lock, target)
        verify_package(extracted, target)
        replace_entries(install_entries(root, extracted, target))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=TARGETS)
    parser.add_argument("--lock", type=Path, default=LOCK_PATH)
    args = parser.parse_args()
    install_target(args.target, load_lock(args.lock))


if __name__ == "__main__":
    main()
