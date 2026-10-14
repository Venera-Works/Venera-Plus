#!/usr/bin/env python3
"""Build the pinned embedded OpenList core for one host platform in CI."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


PIN = "482464c2affc5eeba5d4a25bb272aeb352ec5918"
GOMOBILE = "v0.0.0-20260908204917-8b95e45f8d3e"
ANDROID_API = "24"
ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "native" / "openlist_core"
WORK = ROOT / "build" / "openlist-core"


def run(*args: str, cwd: Path, env: dict[str, str] | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True, env=env)


def remove_worktree(path: Path) -> None:
    """Remove only a generated child of build/openlist-core."""
    resolved = path.resolve()
    work = WORK.resolve()
    if resolved.parent != work:
        raise RuntimeError(f"refusing to remove outside generated work directory: {resolved}")
    shutil.rmtree(resolved)


def source_tree() -> Path:
    source = WORK / "upstream"
    if source.exists():
        remove_worktree(source)
    source.parent.mkdir(parents=True, exist_ok=True)
    run("git", "clone", "--no-checkout", "https://github.com/OpenListTeam/OpenList.git", str(source), cwd=ROOT)
    run("git", "checkout", "--detach", PIN, cwd=source)
    return source


def prepare() -> Path:
    source = source_tree()
    output = WORK / "source"
    run(sys.executable, str(OVERLAY / "scripts" / "prepare_openlist_core.py"), "--source", str(source), "--output", str(output), "--overlay", str(OVERLAY), cwd=ROOT)
    return output


def test_core(source: Path) -> None:
    run("go", "test", "./native/openlist_core/...", cwd=source)


def smoke_desktop(library: Path) -> None:
    run(sys.executable, str(ROOT / ".github" / "scripts" / "check_openlist_core.py"), str(library), cwd=ROOT)


def verify_android_binding(archive: Path) -> None:
    with zipfile.ZipFile(archive) as bundle:
        names = set(bundle.namelist())
        if "classes.jar" not in names:
            raise RuntimeError("gomobile Android binding did not contain classes.jar")
        with tempfile.TemporaryDirectory(prefix="openlist-aar-") as directory:
            classes = Path(directory) / "classes.jar"
            classes.write_bytes(bundle.read("classes.jar"))
            output = subprocess.check_output(
                ("javap", "-classpath", str(classes), "openlistcore.Openlistcore"),
                text=True,
            )
    if "public static java.lang.String invoke(java.lang.String);" not in output:
        raise RuntimeError("gomobile Android binding did not export Openlistcore.invoke")


def verify_ios_binding(framework: Path) -> None:
    headers = list(framework.rglob("*.h"))
    if not any("OpenlistcoreInvoke" in header.read_text(encoding="utf-8") for header in headers):
        raise RuntimeError("gomobile iOS binding did not export OpenlistcoreInvoke")


def verify_macos_architectures(library: Path) -> None:
    architectures = subprocess.check_output(("lipo", "-archs", str(library)), text=True).split()
    if set(architectures) != {"arm64", "x86_64"}:
        raise RuntimeError(f"unexpected macOS architectures: {architectures}")
    for architecture in architectures:
        load_commands = subprocess.check_output(("otool", "-arch", architecture, "-l", str(library)), text=True)
        if not re.search(r"cmd LC_BUILD_VERSION.*?minos 13\.", load_commands, re.DOTALL):
            raise RuntimeError(f"OpenList {architecture} library must require macOS 13 or later")


def install_gomobile(source: Path) -> None:
    run("go", "get", "-tool", f"golang.org/x/mobile/cmd/gomobile@{GOMOBILE}", cwd=source)
    run("go", "get", "-tool", f"golang.org/x/mobile/cmd/gobind@{GOMOBILE}", cwd=source)
    run("go", "install", f"golang.org/x/mobile/cmd/gomobile@{GOMOBILE}", cwd=source)
    run("go", "install", f"golang.org/x/mobile/cmd/gobind@{GOMOBILE}", cwd=source)
    run("gomobile", "init", cwd=source)


def bind_android(source: Path, archive: Path) -> None:
    run(
        "gomobile",
        "bind",
        "-target=android/arm,android/arm64,android/amd64",
        f"-androidapi={ANDROID_API}",
        "-o",
        str(archive),
        "./native/openlist_core",
        cwd=source,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=("android", "ios", "windows", "macos", "linux"))
    args = parser.parse_args()
    source = prepare()
    test_core(source)
    if args.platform in {"android", "ios"}:
        install_gomobile(source)
    if args.platform == "android":
        output = ROOT / "android" / "app" / "libs"
        output.mkdir(parents=True, exist_ok=True)
        archive = output / "openlistcore.aar"
        bind_android(source, archive)
        verify_android_binding(archive)
    elif args.platform == "ios":
        output = ROOT / "ios" / "Frameworks"
        output.mkdir(parents=True, exist_ok=True)
        framework = output / "Openlistcore.xcframework"
        run("gomobile", "bind", "-target=ios", "-o", str(framework), "./native/openlist_core", cwd=source)
        verify_ios_binding(framework)
        shutil.copyfile(source / "LICENSE", output / "LICENSE.OpenList.txt")
    else:
        filename = {
            "windows": "venera_openlist.dll",
            "macos": "libvenera_openlist.dylib",
            "linux": "libvenera_openlist.so",
        }[args.platform]
        output = ROOT / "native" / "openlist_core" / "artifacts" / args.platform
        output.mkdir(parents=True, exist_ok=True)
        if args.platform != "macos":
            run("go", "build", "-buildmode=c-shared", "-o", str(output / filename), "./native/openlist_core/cabi", cwd=source)
            smoke_desktop(output / filename)
            return
        arm64 = output / "arm64.dylib"
        amd64 = output / "amd64.dylib"
        for architecture, cgo_architecture, destination in (("arm64", "arm64", arm64), ("amd64", "x86_64", amd64)):
            environment = dict(os.environ)
            environment.update({
                "GOOS": "darwin",
                "GOARCH": architecture,
                "CGO_ENABLED": "1",
                "MACOSX_DEPLOYMENT_TARGET": "13.0",
                "CGO_CFLAGS": f"-arch {cgo_architecture} -mmacosx-version-min=13.0",
                "CGO_LDFLAGS": f"-arch {cgo_architecture} -mmacosx-version-min=13.0",
            })
            run("go", "build", "-buildmode=c-shared", "-o", str(destination), "./native/openlist_core/cabi", cwd=source, env=environment)
        run("lipo", "-create", "-output", str(output / filename), str(arm64), str(amd64), cwd=source)
        arm64.unlink()
        amd64.unlink()
        (output / "arm64.h").unlink(missing_ok=True)
        (output / "amd64.h").unlink(missing_ok=True)
        verify_macos_architectures(output / filename)
        smoke_desktop(output / filename)


if __name__ == "__main__":
    main()
