#!/Users/atman/Dropbox/deck/m/skills/.venv/bin/python
"""Refresh checked-in corpus fixtures from Wikipedia JSON snapshots."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CORPUS_ROOT = REPO_ROOT / "corpus"
SKILLS_VENV_PYTHON = Path("/Users/atman/Dropbox/deck/m/skills/.venv/bin/python")
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
CONVERT_SCRIPT = (
    Path.home()
    / "Dropbox"
    / "deck"
    / "m"
    / "skills"
    / "wiki"
    / "wikipedia-corpus-fetch"
    / "scripts"
    / "convert_wikipedia_json_to_fixtures.py"
)


def load_converter_write_revision_file():
    spec = importlib.util.spec_from_file_location(
        "convert_wikipedia_json_to_fixtures",
        CONVERT_SCRIPT,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load converter script: {CONVERT_SCRIPT}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.write_revision_file


write_revision_file = load_converter_write_revision_file()

FIXTURES = [
    {"slug": "unicode", "language": "en", "title": "Unicode"},
    {"slug": "greek-language", "language": "el", "title": "Ελληνική γλώσσα"},
    {"slug": "hanzi", "language": "zh", "title": "汉字"},
    {"slug": "japanese-language", "language": "ja", "title": "日本語"},
]
REVISION_COUNT = 5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Refresh checked-in corpus fixtures from Wikipedia JSON snapshots.",
    )
    return parser.parse_args()


def fetch_fixture(entry: dict, temp_dir: Path) -> Path:
    output_path = temp_dir / f"{entry['slug']}.json"
    cmd = [
        str(SKILLS_VENV_PYTHON),
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


def emit_wikipedia_fixtures(temp_dir: Path, corpus_root: Path) -> None:
    for entry in FIXTURES:
        payload_path = fetch_fixture(entry, temp_dir)
        target_dir = corpus_root / "wiki" / entry["language"]
        cmd = [
            str(SKILLS_VENV_PYTHON),
            str(CONVERT_SCRIPT),
            "--input",
            str(payload_path),
            "--output-dir",
            str(target_dir),
            "--article-slug",
            entry["slug"],
        ]
        subprocess.run(cmd, check=True)


def emit_emoji_fixture(corpus_root: Path) -> None:
    target_dir = corpus_root / "synth"
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
    _ = parse_args()

    if not FETCH_SCRIPT.exists():
        raise SystemExit(f"Missing fetch script: {FETCH_SCRIPT}")
    if not CONVERT_SCRIPT.exists():
        raise SystemExit(f"Missing convert script: {CONVERT_SCRIPT}")

    with tempfile.TemporaryDirectory() as tmp:
        temp_root = Path(tmp)
        fresh_corpus_root = temp_root / "corpus"
        fresh_corpus_root.mkdir(parents=True, exist_ok=True)

        emit_wikipedia_fixtures(temp_root, fresh_corpus_root)
        emit_emoji_fixture(fresh_corpus_root)

        if CORPUS_ROOT.exists():
            shutil.rmtree(CORPUS_ROOT)
        shutil.move(str(fresh_corpus_root), str(CORPUS_ROOT))

    print(f"Refreshed corpus fixtures under {CORPUS_ROOT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
