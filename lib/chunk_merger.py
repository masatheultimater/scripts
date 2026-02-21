#!/usr/bin/env python3
"""Merge chunk-wise Gemini topics JSON files into one topics.json."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def _dedupe_list(values: list[Any]) -> list[Any]:
    out = []
    seen = set()
    for v in values:
        if isinstance(v, (dict, list)):
            key = json.dumps(v, ensure_ascii=False, sort_keys=True)
        else:
            key = str(v)
        if key in seen:
            continue
        seen.add(key)
        out.append(v)
    return out


def _parse_range(r: str) -> tuple[int, int] | None:
    if not isinstance(r, str):
        return None
    nums = [int(n) for n in re.findall(r"\d+", r)]
    if not nums:
        return None
    if len(nums) == 1:
        return nums[0], nums[0]
    return min(nums[0], nums[1]), max(nums[0], nums[1])


def _merge_page_range(a: Any, b: Any) -> str:
    if not a:
        return str(b or "")
    if not b:
        return str(a)
    ra = _parse_range(str(a))
    rb = _parse_range(str(b))
    if ra and rb:
        return f"{min(ra[0], rb[0])}-{max(ra[1], rb[1])}"
    if str(a) == str(b):
        return str(a)
    return f"{a} / {b}"


def _merge_topic(existing: dict[str, Any], new: dict[str, Any]) -> dict[str, Any]:
    merged = dict(existing)

    list_fields = ["keywords", "conditions", "related", "type", "practical_points"]
    for field in list_fields:
        vals = []
        for src in (existing, new):
            v = src.get(field)
            if isinstance(v, list):
                vals.extend(v)
            elif v not in (None, ""):
                vals.append(v)
        if vals:
            merged[field] = _dedupe_list(vals)

    merged["page_range"] = _merge_page_range(existing.get("page_range"), new.get("page_range"))

    # Prefer richer string values from new only when existing is missing.
    for field in ("name", "category", "subcategory", "importance"):
        if not merged.get(field) and new.get(field):
            merged[field] = new[field]

    # Preserve unknown keys from both, prioritizing existing for deterministic output.
    for key, value in new.items():
        if key not in merged:
            merged[key] = value

    return merged


def merge_payloads(payloads: list[dict[str, Any]]) -> dict[str, Any]:
    if not payloads:
        return {
            "source_name": "",
            "source_type": "",
            "publisher": "",
            "total_topics": 0,
            "topics": [],
        }

    first = payloads[0]
    merged_topics: dict[str, dict[str, Any]] = {}
    order: list[str] = []

    for payload in payloads:
        # Handle both dict {"topics": [...]} and bare list [...] formats
        if isinstance(payload, list):
            topics_list = payload
        else:
            topics_list = payload.get("topics", [])
        for topic in topics_list:
            topic_id = topic.get("topic_id")
            if not topic_id:
                continue
            if topic_id in merged_topics:
                merged_topics[topic_id] = _merge_topic(merged_topics[topic_id], topic)
            else:
                merged_topics[topic_id] = dict(topic)
                order.append(topic_id)

    topics = [merged_topics[topic_id] for topic_id in order]
    return {
        "source_name": first.get("source_name", ""),
        "source_type": first.get("source_type", ""),
        "publisher": first.get("publisher", ""),
        "total_topics": len(topics),
        "topics": topics,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Merge topics JSON files produced per chunk")
    parser.add_argument("--output", required=True, help="Output topics.json path")
    parser.add_argument("inputs", nargs="+", help="Input chunk topics json paths")
    args = parser.parse_args()

    payloads = []
    for p in args.inputs:
        path = Path(p)
        payloads.append(json.loads(path.read_text(encoding="utf-8")))

    merged = merge_payloads(payloads)
    Path(args.output).write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
