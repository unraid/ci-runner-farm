#!/usr/bin/env python3
"""Restore commit-author credits that Release Please drops while parsing."""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


COMMIT_LINK = re.compile(
    r"\(\[[0-9a-f]{7,40}\]\(https://github\.com/[^/]+/[^/]+/commit/([0-9a-f]{40})\)\)"
)
NOREPLY_EMAIL = re.compile(
    r"^(?:[0-9]+\+)?([^@]+)@users\.noreply\.github\.com$", re.IGNORECASE
)
RELEASE_HEADING = re.compile(r"^## \[")


def commit_author(commit: str) -> str:
    result = subprocess.run(
        ["git", "show", "-s", "--format=%an%n%ae", commit],
        check=True,
        capture_output=True,
        text=True,
    )
    name, email = result.stdout.rstrip("\n").split("\n", 1)
    match = NOREPLY_EMAIL.match(email)
    return f"@{match.group(1)}" if match else name


def credit_line(line: str) -> str:
    match = COMMIT_LINK.search(line)
    if not match or not line.startswith("* "):
        return line

    author = commit_author(match.group(1))
    first_reference = line.find(" ([")
    if first_reference < 0:
        return line
    if line[:first_reference].endswith(f" ({author})"):
        return line
    return f"{line[:first_reference]} ({author}){line[first_reference:]}"


def credit_release_section(text: str) -> str:
    lines = text.splitlines(keepends=True)
    headings = [i for i, line in enumerate(lines) if RELEASE_HEADING.match(line)]
    if not headings:
        return text

    start = headings[0]
    end = headings[1] if len(headings) > 1 else len(lines)
    for index in range(start, end):
        newline = "\n" if lines[index].endswith("\n") else ""
        lines[index] = credit_line(lines[index].rstrip("\n")) + newline
    return "".join(lines)


def credit_all_release_lines(text: str) -> str:
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        newline = "\n" if line.endswith("\n") else ""
        lines[index] = credit_line(line.rstrip("\n")) + newline
    return "".join(lines)


def update(path: Path, transform) -> None:
    original = path.read_text()
    updated = transform(original)
    if updated != original:
        path.write_text(updated)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("changelog", type=Path)
    parser.add_argument("--pr-body", type=Path)
    args = parser.parse_args()

    update(args.changelog, credit_release_section)
    if args.pr_body:
        update(args.pr_body, credit_all_release_lines)


if __name__ == "__main__":
    main()
