import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Iterable, Iterator, Sequence
from pathlib import Path


PUBSPEC_PATH = Path(__file__).resolve().parents[2] / "pubspec.yaml"
APP_NAME = "VeneraPlus"
ARCHITECTURES = ("arm64", "x86_64")
MAIN_EXECUTABLE = Path("Contents/MacOS") / APP_NAME
BUNDLE_SUFFIXES = {".framework", ".xpc", ".appex", ".app"}
MACHO_MAGICS = {
    0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA,
    0xFEEDFACE, 0xCEFAEDFE, 0xFEEDFACF, 0xCFFAEDFE,
}
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?")


class PackagingError(RuntimeError):
    pass


def parse_version(value: str) -> str:
    version = value.strip().partition("+")[0]
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"应用版本号格式无效：{value!r}")
    return version


def read_pubspec_version(path: Path) -> str:
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if line.startswith("version:"):
            value = line.partition(":")[2].partition("#")[0].strip()
            if value[:1] in {"'", '"'} and value[:1] == value[-1:]:
                value = value[1:-1]
            return parse_version(value)
    raise PackagingError(f"未找到版本号字段：{path}")


def dmg_filename(version: str, arch: str) -> str:
    return f"{APP_NAME}-{version}-macos-{arch}.dmg"


def has_macho_magic(header: bytes) -> bool:
    return len(header) == 4 and int.from_bytes(header, "big") in MACHO_MAGICS


def signing_order(paths: Iterable[Path]) -> list[Path]:
    return sorted(paths, key=lambda path: (-len(path.parts), path.as_posix()))


def bundle_paths(directory: Path) -> Iterator[Path]:
    for path in directory.iterdir():
        if path.is_symlink():
            continue
        yield path
        if path.is_dir():
            yield from bundle_paths(path)


def macho_architectures(path: Path) -> set[str] | None:
    with path.open("rb") as binary:
        if not has_macho_magic(binary.read(4)):
            return None

    result = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    if result.returncode != 0:
        # Java 类文件与部分 Fat 二进制共享魔数。
        file_type = subprocess.run(
            ["file", "-b", path], check=True, capture_output=True, text=True
        ).stdout
        if "Mach-O" not in file_type:
            return None
        raise PackagingError(f"无法读取 Mach-O 架构：{path}\n{result.stderr.strip()}")

    architectures = set(result.stdout.split())
    if not architectures:
        raise PackagingError(f"lipo 未返回 Mach-O 架构：{path}")
    return architectures


def iter_macho_files(app: Path) -> Iterator[tuple[Path, set[str]]]:
    for path in bundle_paths(app):
        if path.is_file():
            architectures = macho_architectures(path)
            if architectures is not None:
                yield path, architectures


def thin_binary(path: Path, arch: str) -> None:
    with tempfile.NamedTemporaryFile(prefix=".venera-thin-", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
    try:
        subprocess.run(["lipo", "-thin", arch, path, "-output", temporary], check=True)
        shutil.copymode(path, temporary)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def thin_app(app: Path, arch: str) -> None:
    for binary, architectures in iter_macho_files(app):
        if arch not in architectures:
            raise PackagingError(
                f"Mach-O 缺少 {arch} 架构（实际为 {', '.join(sorted(architectures))}）：{binary}"
            )
        if len(architectures) > 1:
            thin_binary(binary, arch)


def framework_binary(framework: Path) -> Path:
    for directory in (framework, framework / "Versions/Current", framework / "Versions/A"):
        binary = directory / framework.stem
        if binary.is_file():
            return binary
    raise PackagingError(f"缺少框架二进制文件：{framework}")


def verify_architectures(app: Path, arch: str) -> set[Path]:
    app = app.resolve()
    verified = set()
    for binary, architectures in iter_macho_files(app):
        if architectures != {arch}:
            raise PackagingError(
                f"Mach-O 应仅包含 {arch}（实际为 {', '.join(sorted(architectures))}）：{binary}"
            )
        verified.add(binary)

    frameworks = app / "Contents/Frameworks"
    required = (
        app / MAIN_EXECUTABLE,
        frameworks / "libvenera_openlist.dylib",
        framework_binary(frameworks / "App.framework"),
        framework_binary(frameworks / "FlutterMacOS.framework"),
    )
    for binary in required:
        if not binary.is_file() or binary.stat().st_size == 0:
            raise PackagingError(f"关键二进制文件缺失或为空：{binary}")
        if binary.resolve() not in verified:
            raise PackagingError(f"关键二进制文件未通过 {arch} 架构校验：{binary}")
    return verified


def sign_app(app: Path, binaries: set[Path], entitlements: Path) -> None:
    sign = ["codesign", "--force", "--sign", "-", "--timestamp=none"]
    # 外层主程序由最后一次 App 签名处理，并写入 Release entitlements。
    main = (app / MAIN_EXECUTABLE).resolve()
    for binary in signing_order(binaries - {main}):
        subprocess.run([*sign, binary], check=True)

    bundles = (
        path
        for path in bundle_paths(app / "Contents")
        if path.suffix in BUNDLE_SUFFIXES and path.is_dir()
    )
    for bundle in signing_order(bundles):
        subprocess.run([*sign, bundle], check=True)

    subprocess.run([*sign, "--entitlements", entitlements, app], check=True)
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", app], check=True
    )


def build_dmg(
    source_app: Path, entitlements: Path, image: Path, arch: str, volume_name: str
) -> None:
    print(f"正在为 {arch} 瘦身、校验并重签 macOS 应用。", flush=True)
    with tempfile.TemporaryDirectory(prefix=f"venera-macos-{arch}-") as temporary:
        contents = Path(temporary) / "dmg_contents"
        contents.mkdir()
        app = contents / f"{APP_NAME}.app"
        subprocess.run(["ditto", source_app, app], check=True)
        thin_app(app, arch)
        binaries = verify_architectures(app, arch)
        sign_app(app, binaries, entitlements)
        (contents / "Applications").symlink_to("/Applications", target_is_directory=True)
        subprocess.run(
            [
                "hdiutil", "create", "-volname", volume_name, "-srcfolder", contents,
                "-ov", "-format", "UDZO", image,
            ],
            check=True,
        )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as image:
        for chunk in iter(lambda: image.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="将 Universal macOS 应用打包为单架构 DMG。")
    parser.add_argument("--app", type=Path, required=True, help="源 Universal 应用的路径")
    parser.add_argument("--entitlements", type=Path, required=True, help="外层应用签名的权限文件")
    parser.add_argument("--output-dir", type=Path, required=True, help="DMG 输出目录")
    parser.add_argument(
        "--arch", action="append", choices=ARCHITECTURES,
        help="目标架构，可重复指定不同架构，默认打包 arm64 和 x86_64",
    )
    parser.add_argument("--version", help="应用版本，默认读取仓库根目录 pubspec.yaml")
    parser.add_argument("--volume-name", default=APP_NAME, help="DMG 卷名，默认 VeneraPlus")
    args = parser.parse_args(argv)
    args.arch = args.arch or list(ARCHITECTURES)
    if len(args.arch) != len(set(args.arch)):
        parser.error("--arch 不能重复指定同一架构")
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        version = (
            read_pubspec_version(PUBSPEC_PATH)
            if args.version is None
            else parse_version(args.version)
        )
        source_app = args.app.resolve()
        entitlements = args.entitlements.resolve()
        if not source_app.is_dir():
            raise PackagingError(f"找不到源应用目录：{source_app}")
        if not entitlements.is_file() or entitlements.stat().st_size == 0:
            raise PackagingError(f"签名权限文件缺失或为空：{entitlements}")

        output_dir = args.output_dir.resolve()
        output_dir.mkdir(parents=True, exist_ok=True)
        # 各架构打包全部成功后，再将产物移入输出目录。
        with tempfile.TemporaryDirectory(prefix=".venera-macos-", dir=output_dir) as staging:
            artifacts = []
            for arch in args.arch:
                image = Path(staging) / dmg_filename(version, arch)
                build_dmg(source_app, entitlements, image, arch, args.volume_name)
                if not image.is_file() or image.stat().st_size == 0:
                    raise PackagingError(f"DMG 产物缺失或为空：{image.name}")
                artifacts.append((image, image.stat().st_size, sha256(image)))
            for image, size, digest in artifacts:
                image.replace(output_dir / image.name)
                print(f"{image.name} {size} 字节，SHA-256 {digest}", flush=True)
    except (PackagingError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"macOS DMG 打包失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
