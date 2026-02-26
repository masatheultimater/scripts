#!/usr/bin/env python3
"""Remap theory_bank.json topic_ids after topic deduplication.

For each deleted topic (loser), remaps its questions to the keeper's topic_id.
Removes exact duplicate questions (same question text for same topic_id).

Usage:
    python3 cleanup_theory_bank.py --dry-run   # preview
    python3 cleanup_theory_bank.py             # apply
"""

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.houjinzei_common import VaultPaths, atomic_json_write


def build_remap_table(topics_dir: Path) -> dict[str, str]:
    """Build loser_topic_id → keeper_topic_id mapping.

    Scans for topic_ids in theory_bank that reference non-existent files,
    and maps them to the existing file with the same stem name.
    """
    # Build name → existing paths
    existing: dict[str, list[str]] = defaultdict(list)
    for md in topics_dir.rglob("*.md"):
        if md.name == "CLAUDE.md":
            continue
        cat = md.parent.name
        topic_id = f"{cat}/{md.stem}"
        existing[md.stem].append(topic_id)
    return existing


def main():
    parser = argparse.ArgumentParser(description="Remap theory_bank.json after dedup")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    vault = VaultPaths()
    theory_path = vault.export / "theory_bank.json"

    if not theory_path.exists():
        print("theory_bank.json not found")
        sys.exit(1)

    data = json.loads(theory_path.read_text(encoding="utf-8"))
    questions = data.get("questions", [])

    # Build set of existing topic_ids from vault
    topics_dir = vault.topics
    existing_ids: set[str] = set()
    stem_to_id: dict[str, str] = {}
    for md in sorted(topics_dir.rglob("*.md")):
        if md.name == "CLAUDE.md":
            continue
        cat = md.parent.name
        tid = f"{cat}/{md.stem}"
        existing_ids.add(tid)
        stem_to_id[md.stem] = tid  # last one wins (after dedup, only one per stem)

    # Find questions pointing to non-existent topic_ids and remap
    remapped = 0
    removed_dupes = 0
    seen: set[tuple[str, str]] = set()  # (topic_id, question_text) for dedup
    cleaned: list[dict] = []

    for q in questions:
        tid = q.get("topic_id", "")
        stem = tid.split("/", 1)[-1] if "/" in tid else tid

        # Remap if topic_id doesn't exist but stem does
        if tid not in existing_ids and stem in stem_to_id:
            new_tid = stem_to_id[stem]
            if args.dry_run:
                if remapped < 10:
                    print(f"  REMAP: {tid} → {new_tid}")
            q["topic_id"] = new_tid
            # Also update category to match
            new_cat = new_tid.split("/", 1)[0]
            q["category"] = new_cat
            remapped += 1
            tid = new_tid

        # Deduplicate by (topic_id, question)
        key = (tid, q.get("question", ""))
        if key in seen:
            removed_dupes += 1
            continue
        seen.add(key)
        cleaned.append(q)

    print(f"Remapped: {remapped} questions")
    print(f"Removed duplicates: {removed_dupes} questions")
    print(f"Total: {len(questions)} → {len(cleaned)}")

    if not args.dry_run:
        data["questions"] = cleaned
        data["total"] = len(cleaned)
        atomic_json_write(theory_path, data)
        print("Written to theory_bank.json")


if __name__ == "__main__":
    main()
