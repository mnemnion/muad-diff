#!/usr/bin/env python3
"""Fetch every revision of English Wikipedia's Diff article into batched fixtures."""

from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import sys
from pathlib import Path
from typing import Any, Iterator

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "corpus" / "diff"
DEFAULT_STATE_NAME = ".fetch_state.json"
DEFAULT_ARTICLE_SLUG = "diff"
DEFAULT_ORIGIN = "wikipedia"
DEFAULT_LANGUAGE = "en"
DEFAULT_TITLE = "Diff"
DEFAULT_BATCH_SIZE = 100

SKILL_ROOT = (
    Path.home()
    / "Dropbox"
    / "deck"
    / "m"
    / "skills"
    / "wiki"
    / "wikipedia-corpus-fetch"
    / "scripts"
)
HISTORY_SCRIPT = SKILL_ROOT / "fetch_wikipedia_revision_history.py"
CONVERTER_SCRIPT = SKILL_ROOT / "convert_wikipedia_json_to_fixtures.py"


def load_module(path: Path, module_name: str):
    parent = str(path.parent)
    if parent not in sys.path:
        sys.path.insert(0, parent)

    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch the full English Wikipedia Diff article history into `.wiki` fixtures.",
    )
    parser.add_argument(
        "--output-root",
        default=str(DEFAULT_OUTPUT_ROOT),
        help=f"Root directory for emitted fixtures (default: {DEFAULT_OUTPUT_ROOT})",
    )
    parser.add_argument(
        "--state-file",
        default=None,
        help="Resume state path. Default: OUTPUT_ROOT/.fetch_state.json",
    )
    parser.add_argument(
        "--page-limit",
        type=int,
        default=None,
        help="Optional limit on fetched API pages for smoke tests or staged runs.",
    )
    parser.add_argument(
        "--rvlimit",
        type=int,
        default=50,
        help="Revisions per fetched API page (default: 50).",
    )
    parser.add_argument(
        "--maxlag",
        type=int,
        default=5,
        help="MediaWiki maxlag value to send during fetches (default: 5).",
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=5,
        help="Retry count for maxlag/transient fetch failures (default: 5).",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="Delete existing output/state before starting from the oldest revision.",
    )
    parser.add_argument(
        "--pages-jsonl",
        default=None,
        help="Read paged revision data from a local JSONL file instead of the network.",
    )
    parser.add_argument(
        "--title",
        default=DEFAULT_TITLE,
        help=f"Wikipedia article title (default: {DEFAULT_TITLE})",
    )
    parser.add_argument(
        "--language",
        default=DEFAULT_LANGUAGE,
        help=f"Wikipedia language code (default: {DEFAULT_LANGUAGE})",
    )
    parser.add_argument(
        "--article-slug",
        default=DEFAULT_ARTICLE_SLUG,
        help=f"Fixture article slug (default: {DEFAULT_ARTICLE_SLUG})",
    )
    parser.add_argument(
        "--origin",
        default=DEFAULT_ORIGIN,
        help=f"Fixture origin (default: {DEFAULT_ORIGIN})",
    )
    return parser.parse_args()


def batch_name_for_index(index: int) -> str:
    start = (index // DEFAULT_BATCH_SIZE) * DEFAULT_BATCH_SIZE
    end = start + DEFAULT_BATCH_SIZE - 1
    return f"{start:06d}-{end:06d}"


def next_batch_name(revisions_written: int) -> str:
    return batch_name_for_index(revisions_written)


def default_state(
    *,
    article_slug: str,
    origin: str,
    language: str,
    title: str,
) -> dict[str, Any]:
    return {
        "article_slug": article_slug,
        "origin": origin,
        "language": language,
        "title": title,
        "rvcontinue": None,
        "revisions_written": 0,
        "completed": False,
        "next_batch": next_batch_name(0),
    }


def load_state(state_path: Path, *, defaults: dict[str, Any]) -> dict[str, Any]:
    if not state_path.exists():
        return defaults.copy()

    state = json.loads(state_path.read_text(encoding="utf-8"))
    merged = defaults.copy()
    merged.update(state)
    return merged


def write_state(state_path: Path, state: dict[str, Any]) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(
        json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def ensure_clean_start(output_root: Path, state_path: Path, reset: bool) -> None:
    if reset and output_root.exists():
        shutil.rmtree(output_root)
    if reset and state_path.exists():
        state_path.unlink()

    if output_root.exists() and not state_path.exists():
        has_fixture = any(output_root.rglob("*.wiki"))
        if has_fixture:
            raise SystemExit(
                f"Refusing to resume without state: found fixtures under {output_root}. "
                "Use --reset to start over."
            )


def iter_pages_from_jsonl(
    jsonl_path: Path,
    *,
    start_rvcontinue: str | None,
    page_limit: int | None,
) -> Iterator[dict[str, Any]]:
    page_start: str | None = None
    found_start = start_rvcontinue is None
    yielded = 0

    with jsonl_path.open("r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue

            page = json.loads(line)
            if found_start or page_start == start_rvcontinue:
                found_start = True
                yield page
                yielded += 1
                if page_limit is not None and yielded >= page_limit:
                    return

            page_start = page.get("next_rvcontinue")

    if start_rvcontinue is not None and not found_start:
        raise SystemExit(f"Resume token not found in {jsonl_path}: {start_rvcontinue}")


def iter_pages(
    history_module,
    *,
    source_language: str,
    title: str,
    start_rvcontinue: str | None,
    page_limit: int | None,
    pages_jsonl: Path | None,
    rvlimit: int,
    maxlag: int,
    max_retries: int,
) -> Iterator[dict[str, Any]]:
    if pages_jsonl is not None:
        yield from iter_pages_from_jsonl(
            pages_jsonl,
            start_rvcontinue=start_rvcontinue,
            page_limit=page_limit,
        )
        return

    yield from history_module.iter_revision_pages(
        source_language=source_language,
        title=title,
        start_rvcontinue=start_rvcontinue,
        limit=rvlimit,
        maxlag=maxlag,
        max_retries=max_retries,
        page_limit=page_limit,
    )


def emit_revision_page(
    *,
    converter_module,
    output_root: Path,
    article_slug: str,
    origin: str,
    language: str,
    state: dict[str, Any],
    page: dict[str, Any],
) -> int:
    revisions = page.get("revisions", [])
    title = page.get("title", state["title"])
    start_index = int(state["revisions_written"])

    for offset, revision in enumerate(revisions):
        revision_index = start_index + offset
        batch_dir = output_root / batch_name_for_index(revision_index)
        converter_module.write_revision_file(
            batch_dir,
            article_slug=article_slug,
            origin=origin,
            language=language,
            title=title,
            revision=revision,
        )

    state["title"] = title
    return len(revisions)


def main() -> int:
    args = parse_args()
    if args.page_limit is not None and args.page_limit <= 0:
        raise SystemExit("--page-limit must be greater than 0")
    if args.rvlimit <= 0:
        raise SystemExit("--rvlimit must be greater than 0")
    if args.rvlimit > 50:
        raise SystemExit("--rvlimit may not exceed 50 when fetching revision content")
    if args.maxlag <= 0:
        raise SystemExit("--maxlag must be greater than 0")
    if args.max_retries < 0:
        raise SystemExit("--max-retries may not be negative")

    output_root = Path(args.output_root)
    state_path = Path(args.state_file) if args.state_file else output_root / DEFAULT_STATE_NAME
    pages_jsonl = Path(args.pages_jsonl) if args.pages_jsonl else None

    if not HISTORY_SCRIPT.exists():
        raise SystemExit(f"Missing history fetch script: {HISTORY_SCRIPT}")
    if not CONVERTER_SCRIPT.exists():
        raise SystemExit(f"Missing fixture converter script: {CONVERTER_SCRIPT}")
    if pages_jsonl is not None and not pages_jsonl.exists():
        raise SystemExit(f"Missing JSONL page source: {pages_jsonl}")

    ensure_clean_start(output_root, state_path, args.reset)
    output_root.mkdir(parents=True, exist_ok=True)

    history_module = load_module(HISTORY_SCRIPT, "fetch_wikipedia_revision_history")
    converter_module = load_module(CONVERTER_SCRIPT, "convert_wikipedia_json_to_fixtures")

    defaults = default_state(
        article_slug=args.article_slug,
        origin=args.origin,
        language=args.language,
        title=args.title,
    )
    state = load_state(state_path, defaults=defaults)

    if state["completed"]:
        print(
            f"History already complete under {output_root} "
            f"({state['revisions_written']} revision(s))."
        )
        return 0

    pages_fetched = 0
    for page in iter_pages(
        history_module,
        source_language=args.language,
        title=args.title,
        start_rvcontinue=state["rvcontinue"],
        page_limit=args.page_limit,
        pages_jsonl=pages_jsonl,
        rvlimit=args.rvlimit,
        maxlag=args.maxlag,
        max_retries=args.max_retries,
    ):
        revision_count = emit_revision_page(
            converter_module=converter_module,
            output_root=output_root,
            article_slug=args.article_slug,
            origin=args.origin,
            language=args.language,
            state=state,
            page=page,
        )
        state["revisions_written"] += revision_count
        state["rvcontinue"] = page.get("next_rvcontinue")
        state["completed"] = state["rvcontinue"] is None
        state["next_batch"] = next_batch_name(state["revisions_written"])
        write_state(state_path, state)
        pages_fetched += 1

        if state["completed"]:
            break

    if pages_fetched == 0:
        print(
            f"No new pages fetched; resume token remains {state['rvcontinue']!r} "
            f"after {state['revisions_written']} revision(s)."
        )
        return 0

    if state["completed"]:
        print(
            f"Fetched full history into {output_root} "
            f"({state['revisions_written']} revision(s))."
        )
    else:
        print(
            f"Fetched {pages_fetched} page(s) into {output_root}; "
            f"resume with token {state['rvcontinue']!r} "
            f"after {state['revisions_written']} revision(s)."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
