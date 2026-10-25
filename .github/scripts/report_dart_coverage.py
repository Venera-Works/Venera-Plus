#!/usr/bin/env python3
"""Merge and summarize Flutter LCOV line coverage for CI."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def _read_lcov(paths: list[Path]) -> dict[str, dict[int, int]]:
    coverage: dict[str, dict[int, int]] = {}
    for path in paths:
        source = None
        has_lines = False
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            if raw_line.startswith("SF:"):
                source = raw_line[3:]
                coverage.setdefault(source, {})
            elif raw_line == "end_of_record":
                source = None
            elif raw_line.startswith("DA:"):
                if source is None:
                    raise ValueError("LCOV line record has no source file")
                fields = raw_line[3:].split(",")
                if len(fields) < 2:
                    raise ValueError(f"Invalid LCOV line record: {raw_line}")
                try:
                    line, count = int(fields[0]), int(fields[1])
                except ValueError as error:
                    raise ValueError(f"Invalid LCOV line record: {raw_line}") from error
                lines = coverage[source]
                lines[line] = lines.get(line, 0) + count
                has_lines = True
        if not has_lines:
            raise ValueError(f"LCOV report does not contain line coverage records: {path}")
    return coverage


def _line_totals(coverage: dict[str, dict[int, int]]) -> tuple[int, int]:
    hit = sum(count > 0 for lines in coverage.values() for count in lines.values())
    total = sum(len(lines) for lines in coverage.values())
    return hit, total


def read_line_coverage(path: Path) -> tuple[int, int]:
    return _line_totals(_read_lcov([path]))


def _write_lcov(path: Path, coverage: dict[str, dict[int, int]]) -> None:
    records = []
    for source, lines in sorted(coverage.items()):
        records.append(f"SF:{source}")
        records.extend(f"DA:{line},{count}" for line, count in sorted(lines.items()))
        records.extend(
            (
                f"LF:{len(lines)}",
                f"LH:{sum(count > 0 for count in lines.values())}",
                "end_of_record",
            )
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(records) + "\n", encoding="utf-8")


def format_summary(hit: int, total: int) -> str:
    percentage = hit / total * 100
    return f"Dart line coverage: {percentage:.2f}% ({hit}/{total})"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("lcov", type=Path, nargs="+")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--github-summary", action="store_true")
    args = parser.parse_args()

    coverage = _read_lcov(args.lcov)
    hit, total = _line_totals(coverage)
    if args.output:
        _write_lcov(args.output, coverage)
    summary = format_summary(hit, total)
    print(summary)

    if args.github_summary:
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if not summary_path:
            raise RuntimeError("GITHUB_STEP_SUMMARY is not set")
        with Path(summary_path).open("a", encoding="utf-8") as output:
            output.write(f"## Dart coverage\n\n{summary}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
