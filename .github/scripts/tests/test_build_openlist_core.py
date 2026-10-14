import sys
import unittest
from pathlib import Path
from unittest.mock import call, patch


SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from build_openlist_core import GOMOBILE, install_gomobile


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


if __name__ == "__main__":
    unittest.main()
