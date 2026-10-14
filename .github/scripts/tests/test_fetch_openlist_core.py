import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from fetch_openlist_core import (
    EXPECTED_ARCHITECTURES,
    PACKAGE_FILES,
    install_target,
    safe_extract,
    selected_asset,
)


COMMIT = "a" * 40


class FetchOpenListCoreTest(unittest.TestCase):
    def lock(self, target, archive):
        return {
            "schema": 1,
            "repository": "Venera-Works/Venera-OpenList-Core",
            "version": "0.1.0-beta.1",
            "tag": "core-v0.1.0-beta.1",
            "sourceCommit": COMMIT,
            "rpcAbi": 1,
            "assets": {
                target: {
                    "name": f"openlist-core-{target}.zip",
                    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                },
            },
        }

    def archive(self, directory, target, *, metadata=None, files=None):
        archive = Path(directory) / f"{target}.zip"
        metadata = metadata or {
            "version": "0.1.0-beta.1",
            "sourceCommit": COMMIT,
            "rpcAbi": 1,
            "platform": target,
            "architectures": sorted(EXPECTED_ARCHITECTURES[target]),
        }
        files = files or PACKAGE_FILES[target]
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("metadata.json", json.dumps(metadata))
            for name in files:
                if name.endswith(".xcframework"):
                    bundle.writestr(f"{name}/Info.plist", "plist")
                else:
                    bundle.writestr(name, name)
        return archive

    def downloader(self, archive):
        urls = []

        def download(url, destination):
            urls.append(url)
            destination.write_bytes(archive.read_bytes())

        return download, urls

    def test_rejects_incomplete_initial_lock(self):
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            selected_asset(
                {
                    "schema": 1,
                    "repository": "Venera-Works/Venera-OpenList-Core",
                    "version": "0.1.0-beta.1",
                    "tag": "core-v0.1.0-beta.1",
                    "sourceCommit": None,
                    "rpcAbi": 1,
                    "assets": {},
                },
                "android",
            )

    def test_rejects_wrong_digest_before_install(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(directory, "android")
            lock = self.lock("android", archive)
            lock["assets"]["android"]["sha256"] = "0" * 64
            downloader, _ = self.downloader(archive)
            root = Path(directory) / "app"

            with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
                install_target("android", lock, root, downloader)

            self.assertFalse((root / "android" / "app" / "libs" / "openlistcore.aar").exists())

    def test_rejects_wrong_metadata_before_install(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(
                directory,
                "windows-x64",
                metadata={
                    "version": "0.1.0-beta.1",
                    "sourceCommit": COMMIT,
                    "rpcAbi": 1,
                    "platform": "linux-x64",
                    "architectures": ["x86_64"],
                },
            )
            root = Path(directory) / "app"

            with self.assertRaisesRegex(RuntimeError, "platform"):
                install_target("windows-x64", self.lock("windows-x64", archive), root, self.downloader(archive)[0])

            self.assertFalse((root / "native" / "openlist_core" / "artifacts" / "windows").exists())

    def test_rejects_unsafe_archive_path(self):
        with tempfile.TemporaryDirectory() as directory:
            for member in ("../outside", "C:/outside"):
                with self.subTest(member=member):
                    archive = Path(directory) / "unsafe.zip"
                    with zipfile.ZipFile(archive, "w") as bundle:
                        bundle.writestr(member, "bad")

                    with self.assertRaisesRegex(RuntimeError, "unsafe path"):
                        safe_extract(archive, Path(directory) / "out")

    def test_rejects_metadata_for_wrong_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(
                directory,
                "linux-arm64",
                metadata={
                    "version": "0.1.0-beta.1",
                    "sourceCommit": COMMIT,
                    "rpcAbi": 1,
                    "platform": "linux-arm64",
                    "architectures": ["x86_64"],
                },
            )

            with self.assertRaisesRegex(RuntimeError, "architectures"):
                install_target("linux-arm64", self.lock("linux-arm64", archive), Path(directory) / "app", self.downloader(archive)[0])

    def test_rejects_missing_platform_file(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(directory, "linux-arm64", files=("LICENSE.OpenList.txt",))

            with self.assertRaisesRegex(RuntimeError, "libvenera_openlist.so"):
                install_target("linux-arm64", self.lock("linux-arm64", archive), Path(directory) / "app", self.downloader(archive)[0])

    def test_selects_target_asset_and_installs_android_binary_and_license(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.archive(directory, "android")
            lock = self.lock("android", archive)
            downloader, urls = self.downloader(archive)
            root = Path(directory) / "app"

            install_target("android", lock, root, downloader)

            self.assertEqual(
                urls,
                [
                    "https://github.com/Venera-Works/Venera-OpenList-Core/releases/download/"
                    "core-v0.1.0-beta.1/openlist-core-android.zip"
                ],
            )
            self.assertEqual(
                (root / "android" / "app" / "libs" / "openlistcore.aar").read_text(),
                "openlistcore.aar",
            )
            self.assertEqual(
                (root / "android" / "app" / "src" / "main" / "assets" / "licenses" / "LICENSE.OpenList.txt").read_text(),
                "LICENSE.OpenList.txt",
            )


if __name__ == "__main__":
    unittest.main()
