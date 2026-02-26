#!/usr/bin/env python3
"""Batch-normalize source names in all topic note frontmatter.

Usage:
    python3 normalize_sources.py --dry-run   # preview changes
    python3 normalize_sources.py             # apply changes
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.houjinzei_common import VaultPaths, read_frontmatter, write_frontmatter
from lib.source_normalize import normalize_sources_list


def main():
    parser = argparse.ArgumentParser(description="Normalize duplicate source names in topic notes")
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing")
    args = parser.parse_args()

    vault = VaultPaths()
    topics_dir = vault.topics

    files_changed = 0
    total_source_fixes = 0

    for md_path in sorted(topics_dir.rglob("*.md")):
        if md_path.name == "CLAUDE.md":
            continue

        fm, body = read_frontmatter(md_path)
        if not fm:
            continue

        sources = fm.get("sources", [])
        if not isinstance(sources, list) or not sources:
            continue

        normalized, changes = normalize_sources_list(sources)
        if changes == 0:
            continue

        files_changed += 1
        total_source_fixes += changes

        rel = md_path.relative_to(topics_dir)
        if args.dry_run:
            print(f"  {rel}")
            for old, new in zip(sources, normalized):
                if old != new:
                    print(f"    - {old}")
                    print(f"    + {new}")
        else:
            fm["sources"] = normalized
            write_frontmatter(md_path, fm, body)

    action = "Would fix" if args.dry_run else "Fixed"
    print(f"\n{action} {total_source_fixes} source entries in {files_changed} files")


if __name__ == "__main__":
    main()
