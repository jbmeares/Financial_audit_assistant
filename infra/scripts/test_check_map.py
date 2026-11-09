#!/usr/bin/env python3
"""Tests for check-map. Run: python3 infra/scripts/test_check_map.py"""
import importlib.machinery
import importlib.util
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
_loader = importlib.machinery.SourceFileLoader("check_map", str(HERE / "check-map"))
_spec = importlib.util.spec_from_loader("check_map", _loader)
check_map = importlib.util.module_from_spec(_spec)
_loader.exec_module(check_map)

MAP = "# Map\n\n## Folders\n\n```text\nCLAUDE.md   map\npeople/     profiles\ndata/schema.md  guide\n```\n"


class CheckMapTest(unittest.TestCase):
    def make(self, folders, claude=MAP, readme=True):
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "CLAUDE.md").write_text(claude)
        for f in folders:
            (d / f).mkdir()
            if readme:
                (d / f / "README.md").write_text("x")
        (d / ".github").mkdir()  # hidden, ignored
        return d

    def test_ok(self):
        self.assertEqual(check_map.check(self.make(["people", "data"])), [])

    def test_missing_readme(self):
        self.assertIn("people/ has no README.md", check_map.check(self.make(["people", "data"], readme=False)))

    def test_unlisted_folder(self):
        self.assertIn("notes/ is not listed in CLAUDE.md under ## Folders",
                      check_map.check(self.make(["people", "data", "notes"])))

    def test_listed_but_missing(self):
        self.assertIn("CLAUDE.md lists data/ but the folder doesn't exist", check_map.check(self.make(["people"])))

    def test_no_folders_section(self):
        self.assertEqual(check_map.check(self.make([], claude="# Map\n")), ['CLAUDE.md has no "## Folders" section'])

    def test_real_repo(self):
        self.assertEqual(check_map.check(HERE.parent.parent), [])


if __name__ == "__main__":
    unittest.main()
