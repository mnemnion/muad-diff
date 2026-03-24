#!/usr/bin/env python3
"""Refresh checked-in corpus fixtures from Wikipedia JSON snapshots."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CORPUS_ROOT = REPO_ROOT / "testdata" / "corpus"
FETCH_SCRIPT = (
    Path.home()
    / "Dropbox"
    / "deck"
    / "m"
    / "skills"
    / "wiki"
    / "wikipedia-corpus-fetch"
    / "scripts"
    / "fetch_wikipedia_revisions.py"
)

FIXTURES = [
    {"slug": "unicode", "language": "en", "title": "Unicode"},
    {"slug": "greek-language", "language": "el", "title": "Ελληνική γλώσσα"},
    {"slug": "hanzi", "language": "zh", "title": "汉字"},
    {"slug": "japanese-language", "language": "ja", "title": "日本語"},
]
REVISION_COUNT = 5


def escape_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def write_revision_file(
    directory: Path,
    *,
    article_slug: str,
    origin: str,
    language: str,
    title: str,
    revision: dict,
) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    revid = revision["revid"]
    timestamp = revision["timestamp"]
    safe_stamp = timestamp.replace(":", "").replace("-", "")
    path = directory / f"{safe_stamp}_{revid}.wiki"

    lines = [
        "---",
        f'origin = {escape_string(origin)}',
        f'article_slug = {escape_string(article_slug)}',
        f'language = {escape_string(language)}',
        f'title = {escape_string(title)}',
        f"revid = {revid}",
        f"parentid = {revision.get('parentid', 'null') if revision.get('parentid') is not None else 'null'}",
        f'timestamp = {escape_string(timestamp)}',
        f'user = {escape_string(revision.get("user", ""))}',
        f'comment = {escape_string(revision.get("comment", ""))}',
        f"size = {revision.get('size', len(revision.get('content', '')))}",
        f"minor = {'true' if revision.get('minor', False) else 'false'}",
        "---",
        revision.get("content", ""),
    ]
    path.write_text("\n".join(lines), encoding="utf-8")


def fetch_fixture(entry: dict, temp_dir: Path) -> Path:
    output_path = temp_dir / f"{entry['slug']}.json"
    cmd = [
        sys.executable,
        str(FETCH_SCRIPT),
        "--title",
        entry["title"],
        "--source-language",
        entry["language"],
        "--languages",
        entry["language"],
        "--count",
        str(REVISION_COUNT),
        "--output",
        str(output_path),
    ]
    subprocess.run(cmd, check=True)
    return output_path


def emit_wikipedia_fixtures(temp_dir: Path) -> None:
    for entry in FIXTURES:
        payload_path = fetch_fixture(entry, temp_dir)
        payload = json.loads(payload_path.read_text(encoding="utf-8"))
        result = payload["results"][entry["language"]]
        target_dir = CORPUS_ROOT / "wikipedia" / entry["language"] / entry["slug"]
        for revision in reversed(result["revisions"]):
            write_revision_file(
                target_dir,
                article_slug=entry["slug"],
                origin="wikipedia",
                language=entry["language"],
                title=result["title"],
                revision=revision,
            )


def emit_emoji_fixture() -> None:
    target_dir = CORPUS_ROOT / "synthetic" / "emoji-evolution"
    revisions = [
        {
            "revid": 900001,
            "parentid": None,
            "timestamp": "2024-01-01T00:00:00Z",
            "user": "fixture-bot",
            "comment": "seed revision",
            "size": 47,
            "minor": False,
            "content": "== Emoji log ==\n😀 starts the page.\n",
        },
        {
            "revid": 900002,
            "parentid": 900001,
            "timestamp": "2024-01-02T00:00:00Z",
            "user": "fixture-bot",
            "comment": "add supplemental symbols",
            "size": 77,
            "minor": False,
            "content": "== Emoji log ==\n😀 starts the page.\nRocket: 🚀\nSparkles: ✨\n",
        },
        {
            "revid": 900003,
            "parentid": 900002,
            "timestamp": "2024-01-03T00:00:00Z",
            "user": "fixture-bot",
            "comment": "mix scripts and emoji",
            "size": 106,
            "minor": False,
            "content": "== Emoji log ==\n😀 starts the page.\nRocket: 🚀\nSparkles: ✨\nGreek: αλφα 😄\n",
        },
        {
            "revid": 900004,
            "parentid": 900003,
            "timestamp": "2024-01-04T00:00:00Z",
            "user": "fixture-bot",
            "comment": "introduce CJK and astral pairings",
            "size": 133,
            "minor": False,
            "content": "== Emoji log ==\n😀 starts the page.\nRocket: 🚀\nSparkles: ✨\nGreek: αλφα 😄\nKanji: 漢字 🧠\n",
        },
        {
            "revid": 900005,
            "parentid": 900004,
            "timestamp": "2024-01-05T00:00:00Z",
            "user": "fixture-bot",
            "comment": "final multicodepoint mix",
            "size": 171,
            "minor": False,
            "content": "== Emoji log ==\n😀 starts the page.\nRocket: 🚀\nSparkles: ✨\nGreek: αλφα 😄\nKanji: 漢字 🧠\nFamily: 👨‍👩‍👧‍👦\nFlags: 🇯🇵 🇬🇷\n",
        },
    ]

    for revision in revisions:
        write_revision_file(
            target_dir,
            article_slug="emoji-evolution",
            origin="synthetic",
            language="emoji",
            title="Emoji evolution",
            revision=revision,
        )


def main() -> int:
    if not FETCH_SCRIPT.exists():
        raise SystemExit(f"Missing fetch script: {FETCH_SCRIPT}")

    if CORPUS_ROOT.exists():
        shutil.rmtree(CORPUS_ROOT)
    CORPUS_ROOT.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        emit_wikipedia_fixtures(Path(tmp))

    emit_emoji_fixture()
    print(f"Refreshed corpus fixtures under {CORPUS_ROOT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
