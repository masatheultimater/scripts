#!/usr/bin/env python3
"""Deduplicate topic notes that exist in multiple category directories.

Keeper selection:
  1. CATEGORY_MAP canonical category match
  2. Longer body content
  3. Alphabetical path (tiebreaker)

Merges sources/keywords/related from loser into keeper before deletion.

Usage:
    python3 dedup_topics.py --dry-run   # preview
    python3 dedup_topics.py             # apply
"""

import argparse
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.houjinzei_common import VaultPaths, read_frontmatter, write_frontmatter
from lib.topic_normalize import get_parent_category


def find_duplicates(topics_dir: Path) -> dict[str, list[Path]]:
    """Find topic names that appear in multiple directories."""
    name_to_paths: dict[str, list[Path]] = defaultdict(list)
    for md in sorted(topics_dir.rglob("*.md")):
        if md.name == "CLAUDE.md":
            continue
        name_to_paths[md.stem].append(md)
    return {name: paths for name, paths in name_to_paths.items() if len(paths) > 1}


def choose_keeper(name: str, paths: list[Path], topics_dir: Path) -> tuple[Path, list[Path]]:
    """Select the keeper file; return (keeper, losers)."""

    # Try CATEGORY_MAP: the canonical category for this topic name
    canonical_cat = get_parent_category(name)

    candidates = []
    for p in paths:
        fm, body = read_frontmatter(p)
        cat_dir = p.parent.name
        fm_cat = fm.get("category", "")
        body_len = len(body.strip())
        candidates.append({
            "path": p,
            "fm": fm,
            "body": body,
            "cat_dir": cat_dir,
            "fm_cat": fm_cat,
            "body_len": body_len,
        })

    # Sort: canonical category match first, then body length desc, then path asc
    def sort_key(c):
        cat_match = 0 if c["fm_cat"] == canonical_cat else 1
        return (cat_match, -c["body_len"], str(c["path"]))

    candidates.sort(key=sort_key)
    keeper = candidates[0]["path"]
    losers = [c["path"] for c in candidates[1:]]
    return keeper, losers


def merge_list_field(keeper_fm: dict, loser_fm: dict, field: str) -> None:
    """Merge list field from loser into keeper, deduplicating."""
    keeper_list = keeper_fm.get(field, []) or []
    loser_list = loser_fm.get(field, []) or []
    if not isinstance(keeper_list, list):
        keeper_list = [keeper_list]
    if not isinstance(loser_list, list):
        loser_list = [loser_list]
    existing = set(str(x) for x in keeper_list)
    for item in loser_list:
        if str(item) not in existing:
            keeper_list.append(item)
            existing.add(str(item))
    keeper_fm[field] = keeper_list


def main():
    parser = argparse.ArgumentParser(description="Deduplicate topic notes across categories")
    parser.add_argument("--dry-run", action="store_true", help="Preview without changes")
    args = parser.parse_args()

    vault = VaultPaths()
    topics_dir = vault.topics
    duplicates = find_duplicates(topics_dir)

    if not duplicates:
        print("No duplicates found.")
        return

    total_deleted = 0
    for name, paths in sorted(duplicates.items()):
        keeper_path, loser_paths = choose_keeper(name, paths, topics_dir)

        keeper_rel = keeper_path.relative_to(topics_dir)
        print(f"\n{name} ({len(paths)} copies)")
        print(f"  KEEP: {keeper_rel}")
        for lp in loser_paths:
            print(f"  DEL:  {lp.relative_to(topics_dir)}")

        if not args.dry_run:
            # Read keeper
            keeper_fm, keeper_body = read_frontmatter(keeper_path)

            # Merge metadata from losers
            for lp in loser_paths:
                loser_fm, _ = read_frontmatter(lp)
                for field in ("sources", "keywords", "related"):
                    merge_list_field(keeper_fm, loser_fm, field)

            # Write merged keeper
            write_frontmatter(keeper_path, keeper_fm, keeper_body)

            # Delete losers
            for lp in loser_paths:
                lp.unlink()

        total_deleted += len(loser_paths)

    action = "Would delete" if args.dry_run else "Deleted"
    print(f"\n{action} {total_deleted} duplicate files ({len(duplicates)} topic groups)")


if __name__ == "__main__":
    main()
