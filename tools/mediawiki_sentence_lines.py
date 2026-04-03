#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Rewrite eligible MediaWiki prose paragraphs so each sentence ends on its own line."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import mwparserfromhell
from mwparserfromhell.nodes import Text

BLOCK_TAGS = {
    "blockquote",
    "gallery",
    "poem",
    "pre",
    "source",
    "syntaxhighlight",
}
SENTENCE_ENDINGS = ".?!"
WIKI_SUFFIX = ".wiki"
FRONTMATTER_OPEN_RE = re.compile(r"\A---\r?\n")
FRONTMATTER_CLOSE_RE = re.compile(r"\r?\n---\r?\n")
NEWLINE_RE = re.compile(r"\r\n|\n")
PARSER_TAG_START_RE = re.compile(
    r"^<(?P<tag>blockquote|gallery|poem|pre|source|syntaxhighlight)\b",
    re.IGNORECASE,
)


@dataclass
class FileSummary:
    files_scanned: int = 0
    files_changed: int = 0
    paragraphs_rewritten: int = 0
    sentences_split: int = 0

    def merge(self, other: "FileSummary") -> None:
        self.files_scanned += other.files_scanned
        self.files_changed += other.files_changed
        self.paragraphs_rewritten += other.paragraphs_rewritten
        self.sentences_split += other.sentences_split


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Rewrite eligible MediaWiki prose paragraphs so each sentence "
            "ends on its own line."
        ),
    )
    parser.add_argument("path", help="A .wiki file or a directory tree to scan.")
    parser.add_argument(
        "--write",
        action="store_true",
        help="Rewrite files in place instead of reporting only.",
    )
    return parser.parse_args()


def iter_wiki_paths(path: Path) -> Iterable[Path]:
    if path.is_file():
        yield path
        return

    for candidate in sorted(path.rglob(f"*{WIKI_SUFFIX}")):
        if candidate.is_file():
            yield candidate


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return handle.read()


def write_text(path: Path, text: str) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def split_fixture(text: str) -> tuple[str, str]:
    open_match = FRONTMATTER_OPEN_RE.match(text)
    if open_match is None:
        raise ValueError("Missing opening frontmatter delimiter")

    close_match = FRONTMATTER_CLOSE_RE.search(text, open_match.end())
    if close_match is None:
        raise ValueError("Missing closing frontmatter delimiter")

    body_start = close_match.end()
    return text[:body_start], text[body_start:]


def detect_newline(body: str) -> str:
    match = NEWLINE_RE.search(body)
    return match.group(0) if match is not None else "\n"


def split_lines(body: str) -> tuple[list[str], str]:
    newline = detect_newline(body)
    return NEWLINE_RE.split(body), newline


def is_blank(line: str) -> bool:
    return line == ""


def is_preformatted_line(line: str) -> bool:
    return line.startswith((" ", "\t"))


def is_heading_line(line: str) -> bool:
    return line.startswith("=")


def is_list_line(line: str) -> bool:
    return line.startswith(("*", "#", ":", ";"))


def is_horizontal_rule(line: str) -> bool:
    return line.startswith("----")


def is_table_line(line: str) -> bool:
    return line.startswith(("{|", "|}", "|-", "|+", "|", "!"))


def is_category_line(line: str) -> bool:
    return line.startswith("[[Category:")


def is_template_line(line: str) -> bool:
    return line.startswith(("{{", "}}"))


def is_parser_block_start(line: str) -> str | None:
    match = PARSER_TAG_START_RE.match(line)
    if match is None:
        return None
    return match.group("tag").lower()


def is_parser_block_end(line: str, tag: str) -> bool:
    return f"</{tag}>" in line.lower()


def is_single_line_protected(line: str) -> bool:
    if is_preformatted_line(line):
        return True
    if is_heading_line(line):
        return True
    if is_list_line(line):
        return True
    if is_horizontal_rule(line):
        return True
    if is_category_line(line):
        return True
    if line.startswith("<references"):
        return True
    return False


def starts_protected_block(line: str) -> bool:
    if is_single_line_protected(line):
        return True
    if is_table_line(line):
        return True
    if is_template_line(line):
        return True
    return is_parser_block_start(line) is not None


def template_depth_delta(line: str) -> int:
    opens = line.count("{{")
    closes = line.count("}}")
    return opens - closes


def consume_template_block(lines: list[str], start: int) -> int:
    depth = 0
    idx = start

    while idx < len(lines):
        depth += template_depth_delta(lines[idx])
        idx += 1
        if depth <= 0:
            break

    return idx


def consume_table_block(lines: list[str], start: int) -> int:
    idx = start
    while idx < len(lines):
        if idx != start and lines[idx].startswith("|}"):
            return idx + 1
        idx += 1
    return idx


def consume_parser_block(lines: list[str], start: int, tag: str) -> int:
    idx = start
    while idx < len(lines):
        if idx != start and is_parser_block_end(lines[idx], tag):
            return idx + 1
        idx += 1
    return idx


def rewrite_text_node(text: str, previous_text_char: str | None) -> tuple[str, int]:
    parts: list[str] = []
    idx = 0
    split_count = 0

    if text.startswith("  ") and previous_text_char in SENTENCE_ENDINGS:
        parts.append("\n")
        idx = 2
        split_count += 1

    while idx < len(text):
        if text[idx] in SENTENCE_ENDINGS and text[idx + 1 : idx + 3] == "  ":
            parts.append(text[idx])
            parts.append("\n")
            idx += 3
            split_count += 1
            continue

        parts.append(text[idx])
        idx += 1

    return "".join(parts), split_count


def trailing_text_char(text: str) -> str | None:
    for char in reversed(text):
        if char != "\n":
            return char
    return None


def rewrite_paragraph(paragraph: str) -> tuple[str, int]:
    flattened = paragraph.replace("\n", " ")
    code = mwparserfromhell.parse(flattened)
    pieces: list[str] = []
    previous_text_char: str | None = None
    split_count = 0

    for node in code.nodes:
        if isinstance(node, Text):
            rewritten, node_splits = rewrite_text_node(str(node), previous_text_char)
            pieces.append(rewritten)
            split_count += node_splits
            node_tail = trailing_text_char(rewritten)
            if node_tail is not None:
                previous_text_char = node_tail
            continue

        pieces.append(str(node))

    return "".join(pieces), split_count


def consume_ordinary_paragraph(lines: list[str], start: int) -> int:
    idx = start
    while idx < len(lines):
        line = lines[idx]
        if is_blank(line):
            break
        if idx != start and starts_protected_block(line):
            break
        idx += 1
    return idx


def normalize_body(body: str) -> tuple[str, int, int]:
    lines, newline = split_lines(body)
    out_lines: list[str] = []
    idx = 0
    paragraphs_rewritten = 0
    sentences_split = 0

    while idx < len(lines):
        line = lines[idx]

        if is_blank(line):
            out_lines.append(line)
            idx += 1
            continue

        if is_single_line_protected(line):
            out_lines.append(line)
            idx += 1
            continue

        if is_table_line(line):
            end = consume_table_block(lines, idx)
            out_lines.extend(lines[idx:end])
            idx = end
            continue

        if is_template_line(line):
            end = consume_template_block(lines, idx)
            out_lines.extend(lines[idx:end])
            idx = end
            continue

        parser_tag = is_parser_block_start(line)
        if parser_tag is not None:
            if is_parser_block_end(line, parser_tag):
                out_lines.append(line)
                idx += 1
                continue

            end = consume_parser_block(lines, idx, parser_tag)
            out_lines.extend(lines[idx:end])
            idx = end
            continue

        end = consume_ordinary_paragraph(lines, idx)
        paragraph = newline.join(lines[idx:end])
        rewritten, split_count = rewrite_paragraph(paragraph)
        out_lines.extend(rewritten.split("\n"))
        if split_count != 0:
            paragraphs_rewritten += 1
            sentences_split += split_count
        idx = end

    return newline.join(out_lines), paragraphs_rewritten, sentences_split


def process_file(path: Path, write: bool) -> FileSummary:
    summary = FileSummary(files_scanned=1)
    original = read_text(path)
    prefix, body = split_fixture(original)
    rewritten_body, paragraphs_rewritten, sentences_split = normalize_body(body)
    rewritten = prefix + rewritten_body

    if rewritten != original:
        summary.files_changed = 1
        if write:
            write_text(path, rewritten)

    summary.paragraphs_rewritten = paragraphs_rewritten
    summary.sentences_split = sentences_split
    return summary


def process_file_text(text: str) -> str:
    prefix, body = split_fixture(text)
    rewritten_body, _, _ = normalize_body(body)
    return prefix + rewritten_body


def process_path(path: Path, write: bool) -> FileSummary:
    summary = FileSummary()
    for wiki_path in iter_wiki_paths(path):
        summary.merge(process_file(wiki_path, write))
    return summary


def main() -> int:
    args = parse_args()
    path = Path(args.path)
    summary = process_path(path, write=args.write)
    print(f"files scanned: {summary.files_scanned}")
    print(f"files changed: {summary.files_changed}")
    print(f"paragraphs rewritten: {summary.paragraphs_rewritten}")
    print(f"sentences split: {summary.sentences_split}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
