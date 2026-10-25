import tempfile
import unittest
import sys
import os
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from report_dart_coverage import format_summary, main, read_line_coverage


class DartCoverageTest(unittest.TestCase):
    def test_reads_line_records_across_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = Path(temp_dir) / "lcov.info"
            report.write_text(
                "SF:lib/a.dart\nDA:1,1\nDA:2,0\nend_of_record\n"
                "SF:lib/b.dart\nDA:5,3\nend_of_record\n",
                encoding="utf-8",
            )

            self.assertEqual(read_line_coverage(report), (2, 3))
            self.assertEqual(
                format_summary(2, 3),
                "Dart line coverage: 66.67% (2/3)",
            )

    def test_rejects_report_without_line_records(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = Path(temp_dir) / "lcov.info"
            report.write_text("SF:lib/a.dart\nend_of_record\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "line coverage records"):
                read_line_coverage(report)

    def test_merges_shards_by_source_and_line_and_updates_summary(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            first = root / "first.info"
            second = root / "second.info"
            merged = root / "coverage" / "lcov.info"
            summary = root / "summary.md"
            first.write_text(
                "SF:lib/shared.dart\nDA:1,1\nDA:2,0\nLF:2\nLH:1\nend_of_record\n"
                "SF:lib/other.dart\nDA:1,2\nend_of_record\n",
                encoding="utf-8",
            )
            second.write_text(
                "SF:lib/shared.dart\nDA:1,4\nDA:2,1\nDA:3,0\nLF:3\nLH:2\n"
                "end_of_record\n",
                encoding="utf-8",
            )

            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        "report_dart_coverage.py",
                        str(first),
                        str(second),
                        "--output",
                        str(merged),
                        "--github-summary",
                    ],
                ),
                patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}),
            ):
                self.assertEqual(main(), 0)

            self.assertEqual(read_line_coverage(merged), (3, 4))
            contents = merged.read_text(encoding="utf-8")
            self.assertEqual(contents.count("SF:lib/shared.dart\n"), 1)
            self.assertIn("DA:1,5\n", contents)
            self.assertIn("DA:2,1\n", contents)
            self.assertIn("LF:3\nLH:2\n", contents)
            self.assertIn("75.00% (3/4)", summary.read_text(encoding="utf-8"))

    def test_rejects_line_record_without_source(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = Path(temp_dir) / "lcov.info"
            report.write_text("DA:1,1\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "no source file"):
                read_line_coverage(report)

    def test_rejects_invalid_line_records(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            report = Path(temp_dir) / "lcov.info"
            for record in ("DA:1", "DA:invalid,1", "DA:1,invalid"):
                with self.subTest(record=record):
                    report.write_text(f"SF:lib/a.dart\n{record}\n", encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, "Invalid LCOV line record"):
                        read_line_coverage(report)

    def test_rejects_empty_shard_even_when_another_shard_has_coverage(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            first = Path(temp_dir) / "first.info"
            second = Path(temp_dir) / "second.info"
            first.write_text("SF:lib/a.dart\nDA:1,1\nend_of_record\n", encoding="utf-8")
            second.write_text("", encoding="utf-8")

            with (
                patch.object(sys, "argv", ["report_dart_coverage.py", str(first), str(second)]),
                self.assertRaisesRegex(ValueError, "line coverage records"),
            ):
                main()


if __name__ == "__main__":
    unittest.main()
