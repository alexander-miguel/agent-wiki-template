#!/usr/bin/env python3
"""Check structural invariants for the agent-wiki Markdown vault."""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from collections import Counter
from pathlib import Path

import yaml


ALLOWED_TYPES = {"source", "concept", "goal", "list", "overview"}
FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---(?:\n|\Z)", re.DOTALL)
WIKILINK_RE = re.compile(r"\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "repo",
        nargs="?",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="repository root (defaults to the parent of infra/)",
    )
    parser.add_argument(
        "--strict-orphans",
        action="store_true",
        help="treat pages with no incoming related link as errors",
    )
    return parser.parse_args()


def wikilink_target(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    match = WIKILINK_RE.fullmatch(value)
    return match.group(1) if match else None


def main() -> int:
    args = parse_args()
    wiki = args.repo.resolve() / "wiki"
    if not wiki.is_dir():
        print(f"ERROR: wiki directory not found: {wiki}", file=sys.stderr)
        return 2

    pages = {
        path.stem: path
        for path in sorted(wiki.glob("*.md"))
        if path.name not in {"index.md", "log.md"}
    }
    metadata: dict[str, dict[str, object]] = {}
    errors: list[str] = []
    warnings: list[str] = []

    for slug, path in pages.items():
        text = path.read_text(encoding="utf-8")
        match = FRONTMATTER_RE.match(text)
        if not match:
            errors.append(f"{path.name}: missing or malformed YAML frontmatter")
            continue
        try:
            value = yaml.safe_load(match.group(1))
        except yaml.YAMLError as exc:
            errors.append(f"{path.name}: invalid YAML: {exc}")
            continue
        if not isinstance(value, dict):
            errors.append(f"{path.name}: frontmatter must be a mapping")
            continue
        metadata[slug] = value

        page_type = value.get("type")
        if page_type not in ALLOWED_TYPES:
            errors.append(f"{path.name}: invalid type {page_type!r}")
        if not isinstance(value.get("tags"), list):
            errors.append(f"{path.name}: tags must be a list")
        if not isinstance(value.get("related"), list):
            errors.append(f"{path.name}: related must be a list")
        for field in ("created", "updated"):
            date_value = value.get(field)
            if not isinstance(date_value, (dt.date, str)):
                errors.append(f"{path.name}: {field} must be an ISO date")
                continue
            try:
                dt.date.fromisoformat(str(date_value))
            except ValueError:
                errors.append(f"{path.name}: {field} must be an ISO date")

    incoming = Counter({slug: 0 for slug in pages})
    related_targets: dict[str, list[str]] = {}
    for slug, value in metadata.items():
        targets: list[str] = []
        for item in value.get("related", []) if isinstance(value.get("related"), list) else []:
            target = wikilink_target(item)
            if target is None:
                errors.append(f"{pages[slug].name}: malformed related entry {item!r}")
                continue
            targets.append(target)
            if target == slug:
                errors.append(f"{pages[slug].name}: self-link in related")
            elif target not in pages:
                errors.append(f"{pages[slug].name}: related target does not exist: {target}")
            else:
                incoming[target] += 1
        duplicates = sorted(name for name, count in Counter(targets).items() if count > 1)
        if duplicates:
            errors.append(f"{pages[slug].name}: duplicate related links: {', '.join(duplicates)}")
        related_targets[slug] = targets

    for source, targets in related_targets.items():
        for target in targets:
            if target in pages and source not in related_targets.get(target, []):
                errors.append(f"{source}.md -> {target}.md: missing reverse related link")

    index_path = wiki / "index.md"
    if not index_path.is_file():
        errors.append("wiki/index.md is missing")
    else:
        index_targets = WIKILINK_RE.findall(index_path.read_text(encoding="utf-8"))
        index_counts = Counter(index_targets)
        missing = sorted(set(pages) - set(index_targets))
        stale = sorted(set(index_targets) - set(pages))
        duplicates = sorted(name for name, count in index_counts.items() if count > 1)
        if missing:
            errors.append(f"wiki/index.md: missing pages: {', '.join(missing)}")
        if stale:
            errors.append(f"wiki/index.md: links to missing pages: {', '.join(stale)}")
        if duplicates:
            errors.append(f"wiki/index.md: duplicate page entries: {', '.join(duplicates)}")

    orphans = sorted(slug for slug, count in incoming.items() if count == 0)
    if orphans:
        message = f"orphan pages (no incoming related link): {', '.join(orphans)}"
        (errors if args.strict_orphans else warnings).append(message)

    for message in errors:
        print(f"ERROR: {message}")
    for message in warnings:
        print(f"WARNING: {message}")

    types = Counter(value.get("type") for value in metadata.values())
    summary = ", ".join(
        f"{name}={count}"
        for name, count in sorted(types.items(), key=lambda item: str(item[0]))
    )
    print(
        f"Checked {len(pages)} pages ({summary}); "
        f"errors={len(errors)}, warnings={len(warnings)}"
    )
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
