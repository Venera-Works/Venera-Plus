import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import call, patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from build_openlist_core import (
    ANDROID_API,
    GOMOBILE,
    PIN,
    ROOT,
    bind_android,
    install_gomobile,
    verify_android_binding,
)

class BuildOpenListCoreTest(unittest.TestCase):
    @patch("build_openlist_core.run")
    def test_installs_pinned_gomobile_tools_as_module_tools(self, mock_run):
        source = Path("generated-openlist")

        install_gomobile(source)

        mock_run.assert_has_calls(
            [
                call(
                    "go",
                    "get",
                    "-tool",
                    f"golang.org/x/mobile/cmd/gomobile@{GOMOBILE}",
                    cwd=source,
                ),
                call(
                    "go",
                    "get",
                    "-tool",
                    f"golang.org/x/mobile/cmd/gobind@{GOMOBILE}",
                    cwd=source,
                ),
                call(
                    "go",
                    "install",
                    f"golang.org/x/mobile/cmd/gomobile@{GOMOBILE}",
                    cwd=source,
                ),
                call(
                    "go",
                    "install",
                    f"golang.org/x/mobile/cmd/gobind@{GOMOBILE}",
                    cwd=source,
                ),
                call("gomobile", "init", cwd=source),
            ]
        )

    @patch("build_openlist_core.run")
    def test_android_binding_uses_the_application_minimum_api(self, mock_run):
        source = Path("generated-openlist")
        archive = Path("openlistcore.aar")

        bind_android(source, archive)

        mock_run.assert_called_once_with(
            "gomobile",
            "bind",
            "-target=android/arm,android/arm64,android/amd64",
            f"-androidapi={ANDROID_API}",
            "-o",
            str(archive),
            "./native/openlist_core",
            cwd=source,
        )

    def test_ios_podspec_references_generated_text_license(self):
        podspec = (ROOT / "ios" / "OpenListCore.podspec").read_text(encoding="utf-8")

        self.assertIn("Frameworks/LICENSE.OpenList.txt", podspec)
        self.assertIn("https://github.com/OpenListTeam/OpenList.git", podspec)
        self.assertIn(PIN, podspec)

    def test_android_binding_accepts_generated_native_invoke_signature(self):
        self._verify_android_binding(
            "public static native java.lang.String invoke(java.lang.String);"
        )

    def test_android_binding_rejects_wrong_invoke_signature(self):
        for signature in (
            "public static native java.lang.String call(java.lang.String);",
            "public static native java.lang.String invoke(int);",
            "public static native void invoke(java.lang.String);",
        ):
            with self.subTest(signature=signature):
                with self.assertRaisesRegex(RuntimeError, "did not export Openlistcore.invoke"):
                    self._verify_android_binding(signature)

    def _verify_android_binding(self, javap_output):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "openlistcore.aar"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("classes.jar", b"classes")
            with patch(
                "build_openlist_core.subprocess.check_output",
                return_value=javap_output,
            ):
                verify_android_binding(archive)


if __name__ == "__main__":
    unittest.main()
