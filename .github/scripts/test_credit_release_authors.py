#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("credit_release_authors.py")
SPEC = importlib.util.spec_from_file_location("credit_release_authors", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CreditReleaseAuthorsTest(unittest.TestCase):
    @patch.object(MODULE, "commit_author", return_value="@jmagar")
    def test_credits_only_the_latest_changelog_section(self, _author) -> None:
        text = """# Changelog

## [1.6.0](compare)

* **ui:** facelift ([#33](issue)) ([fc95b61](https://github.com/unraid/ci-runner-farm/commit/fc95b614c61dc8dca99c68358e67ea428c4a0297))

## [1.5.1](compare)

* old fix ([#30](issue)) ([a605b80](https://github.com/unraid/ci-runner-farm/commit/a605b80193cd93ba37ee9849c8ea52ba3110cd45))
"""
        updated = MODULE.credit_release_section(text)
        self.assertIn("facelift (@jmagar) ([#33]", updated)
        self.assertIn("* old fix ([#30]", updated)

    @patch.object(MODULE, "commit_author", return_value="@jmagar")
    def test_is_idempotent(self, _author) -> None:
        line = "* fix (@jmagar) ([#1](issue)) ([abc1234](https://github.com/unraid/ci-runner-farm/commit/abcdefabcdefabcdefabcdefabcdefabcdefabcd))"
        self.assertEqual(MODULE.credit_line(line), line)

    @patch.object(MODULE.subprocess, "run")
    def test_uses_github_login_from_noreply_email(self, run) -> None:
        run.return_value.stdout = "jmagar\n38927646+jmagar@users.noreply.github.com\n"
        self.assertEqual(MODULE.commit_author("a" * 40), "@jmagar")

    @patch.object(MODULE.subprocess, "run")
    def test_falls_back_to_git_author_name(self, run) -> None:
        run.return_value.stdout = "Jane Contributor\njane@example.com\n"
        self.assertEqual(MODULE.commit_author("a" * 40), "Jane Contributor")


if __name__ == "__main__":
    unittest.main()
