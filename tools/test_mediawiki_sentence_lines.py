#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Tests for mediawiki_sentence_lines."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("mediawiki_sentence_lines.py")
SPEC = importlib.util.spec_from_file_location("mediawiki_sentence_lines", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def fixture(body: str) -> str:
    return (
        "---\n"
        'origin = "wikipedia"\n'
        'article_slug = "diff"\n'
        'language = "en"\n'
        'title = "Diff"\n'
        "---\n"
        f"{body}"
    )


class MediaWikiSentenceLinesTests(unittest.TestCase):
    def test_plain_paragraph_splits_sentences(self) -> None:
        text = fixture("One.  Two?  Three!\n")

        normalized = MODULE.process_file_text(text)

        self.assertIn("One.\nTwo?\nThree!\n", normalized)

    def test_existing_internal_newlines_are_collapsed_before_split(self) -> None:
        text = fixture("One line.\nStill same paragraph.  Next sentence.\n")

        normalized = MODULE.process_file_text(text)

        self.assertIn("One line. Still same paragraph.\nNext sentence.\n", normalized)

    def test_protected_line_forms_stay_unchanged(self) -> None:
        body = (
            "== Heading ==\n\n"
            "* Bullet.  Keep as is.\n\n"
            "  code sample.  Keep as is.\n\n"
            "[[Category:Unix software]]\n"
        )

        normalized = MODULE.process_file_text(fixture(body))

        self.assertIn(body, normalized)

    def test_template_table_and_parser_blocks_are_preserved(self) -> None:
        body = (
            "{{Infobox software\n"
            "| name = diff\n"
            "}}\n\n"
            "{| class=\"wikitable\"\n"
            "| row.  stays.\n"
            "|}\n\n"
            "<syntaxhighlight lang=\"text\">\n"
            "One.  Two.\n"
            "</syntaxhighlight>\n"
        )

        normalized = MODULE.process_file_text(fixture(body))

        self.assertIn(body, normalized)

    def test_inline_ref_tags_do_not_block_split(self) -> None:
        text = fixture("Sentence.<ref>Source.  Not prose.</ref>  Next sentence.\n")

        normalized = MODULE.process_file_text(text)

        self.assertIn("Sentence.<ref>Source.  Not prose.</ref>\nNext sentence.\n", normalized)

    def test_crlf_is_preserved(self) -> None:
        text = fixture("One.  Two.\r\n").replace("\n", "\r\n", 5)

        normalized = MODULE.process_file_text(text)

        self.assertIn("One.\r\nTwo.\r\n", normalized)

    def test_end_to_end_directory_processing(self) -> None:
        body = (
            "Plain sentence.\nNext one.  Third one.\n\n"
            "<pre>\n"
            "Code.  Leave it.\n"
            "</pre>\n"
        )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "sample.wiki"
            target.write_text(fixture(body), encoding="utf-8", newline="")

            summary = MODULE.process_path(root, write=True)

            self.assertEqual(summary.files_scanned, 1)
            self.assertEqual(summary.files_changed, 1)
            self.assertEqual(summary.paragraphs_rewritten, 1)
            self.assertEqual(summary.sentences_split, 1)
            with target.open("r", encoding="utf-8", newline="") as handle:
                written = handle.read()
            self.assertIn("Plain sentence. Next one.\nThird one.\n", written)
            self.assertIn("<pre>\nCode.  Leave it.\n</pre>\n", written)


if __name__ == "__main__":
    unittest.main()
