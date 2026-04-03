#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Tests for the shared Wikipedia fixture converter."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(
    "/Users/atman/Dropbox/deck/m/skills/wiki/wikipedia-corpus-fetch/scripts/convert_wikipedia_json_to_fixtures.py"
)
SPEC = importlib.util.spec_from_file_location("convert_wikipedia_json_to_fixtures", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load converter module from {MODULE_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ConverterTests(unittest.TestCase):
    def test_normalize_fixture_body_strips_all_carriage_returns(self) -> None:
        self.assertEqual("alpha\nbeta", MODULE.normalize_fixture_body("alpha\r\nbeta\r"))

    def test_write_revision_file_emits_body_without_raw_carriage_returns(self) -> None:
        revision = {
            "revid": 123,
            "parentid": None,
            "timestamp": "2026-04-03T12:00:00Z",
            "user": "fixture-bot",
            "comment": 'keeps "quotes"',
            "size": 12,
            "minor": False,
            "content": "one\r\ntwo\rthree\n",
        }

        with tempfile.TemporaryDirectory() as tmp:
            target_dir = Path(tmp)
            MODULE.write_revision_file(
                target_dir,
                article_slug="diff",
                origin="wikipedia",
                language="en",
                title="Diff",
                revision=revision,
            )

            [fixture_path] = list(target_dir.glob("*.wiki"))
            written = fixture_path.read_text(encoding="utf-8")

        self.assertNotIn("\r", written)
        self.assertIn('comment = "keeps \\"quotes\\""', written)
        self.assertTrue(written.endswith("---\none\ntwothree\n"))


if __name__ == "__main__":
    unittest.main()
