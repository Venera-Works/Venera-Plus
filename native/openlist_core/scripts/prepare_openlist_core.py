#!/usr/bin/env python3
"""Prepare a reproducible OpenList source tree for the embedded-core builds."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tarfile
from pathlib import Path

PIN = "482464c2affc5eeba5d4a25bb272aeb352ec5918"


def run(*args: str, cwd: Path) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--overlay", required=True, type=Path)
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    overlay = args.overlay.resolve()
    actual = run("git", "rev-parse", "HEAD", cwd=source)
    if actual != PIN:
        raise SystemExit(f"OpenList revision must be {PIN}, got {actual}")
    repository = overlay.parents[1]
    safe_root = (repository / "build" / "openlist-core").resolve()
    if output == source or output == overlay or safe_root not in output.parents:
        raise SystemExit("output must be a child of build/openlist-core")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    archive = subprocess.check_output(("git", "archive", "--format=tar", PIN), cwd=source)
    with tarfile.open(fileobj=__import__("io").BytesIO(archive)) as bundle:
        for member in bundle.getmembers():
            destination = (output / member.name).resolve()
            if output not in destination.parents and destination != output:
                raise SystemExit("unsafe path in source archive")
        bundle.extractall(output, filter="data")
    relative_output = output.relative_to(repository).as_posix()
    for patch in sorted((overlay / "patches").glob("*.patch")):
        subprocess.run(("git", "apply", "--directory", str(relative_output), "--recount", "--whitespace=error", str(patch)), cwd=repository, check=True)
    driver_115 = (output / "drivers" / "115_open" / "driver.go").read_text(encoding="utf-8")
    if "d.client.SetHttpClient(&http.Client{Transport: embedded115Transport{}})" not in driver_115:
        raise SystemExit("embedded 115 proxy transport patch was not applied")
    bridge = output / "native" / "openlist_core"
    bridge.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(overlay / "bridge", bridge)


if __name__ == "__main__":
    main()
