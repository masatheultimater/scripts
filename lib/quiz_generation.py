"""Quiz generation helpers.

Shared logic for daily problem cap and carryover calculation.
"""

from __future__ import annotations

from collections import Counter
from datetime import date
from typing import Callable

from lib.houjinzei_common import parse_date


def build_carryover_topics(
    previous_today: dict,
    results_data: dict,
    base_date: date,
    max_carryover: int,
    expiry_days: int,
) -> tuple[list[dict], int]:
    """Build carryover topics from previous today payload and results."""
    if not isinstance(previous_today, dict):
        return [], 0

    generated_date_raw = previous_today.get("generated_date")
    if not generated_date_raw:
        return [], 0

    try:
        generated_date = parse_date(str(generated_date_raw))
    except ValueError:
        return [], 0

    age_days = (base_date - generated_date).days
    if age_days < 0 or age_days >= expiry_days:
        return [], 0

    answered_topic_ids = set()
    if isinstance(results_data, dict):
        raw_results = results_data.get("results", [])
        if isinstance(raw_results, list):
            for row in raw_results:
                if not isinstance(row, dict):
                    continue
                topic_id = str(row.get("topic_id", "")).strip()
                if topic_id:
                    answered_topic_ids.add(topic_id)

    carryover_topics: list[dict] = []
    carryover_count = 0
    remaining = max_carryover

    for topic in previous_today.get("topics", []):
        if remaining <= 0 or not isinstance(topic, dict):
            break
        topic_id = str(topic.get("topic_id", "")).strip()
        if not topic_id or topic_id in answered_topic_ids:
            continue

        problems = topic.get("problems", [])
        if not isinstance(problems, list) or not problems:
            continue

        selected_problems = problems[:remaining]
        if not selected_problems:
            continue

        carryover_topics.append(
            {
                "topic_id": topic_id,
                "topic_name": topic.get("topic_name", ""),
                "category": topic.get("category", ""),
                "reason": "繰越",
                "interval_index": topic.get("interval_index", 0),
                "importance": topic.get("importance", ""),
                "priority_bucket": topic.get("priority_bucket"),
                "priority_score": topic.get("priority_score", 0),
                "frequency_score": topic.get("frequency_score", 0),
                "weak_focus": topic.get(
                    "weak_focus",
                    {"active": False, "until_at": None, "trigger": "carryover"},
                ),
                "problems": selected_problems,
            }
        )
        carryover_count += len(selected_problems)
        remaining = max_carryover - carryover_count

    return carryover_topics, carryover_count


def add_priority_balanced_with_problem_cap(
    *,
    selected: list[dict],
    selected_ids: set[str],
    candidates: list[dict],
    reason: str,
    bucket: float,
    limit: int,
    max_category_ratio: float,
    category_count: Counter,
    mappings: dict,
    current_problem_count: int,
    max_daily_problems: int,
    selected_topic_count: int,
    priority_fn: Callable[[dict, float], float],
) -> tuple[int, int, bool]:
    """Add topics using category balance and problem-cap stop rule."""
    max_per_cat = max(2, int(limit * max_category_ratio))
    ordered = sorted(candidates, key=lambda r: (-priority_fn(r, bucket), r["topic_id"]))
    cap_reached = False

    for r in ordered:
        if len(selected) >= limit:
            break
        topic_id = r["topic_id"]
        if topic_id in selected_ids:
            continue
        cat = r["category"]
        if category_count[cat] >= max_per_cat:
            continue

        topic_problem_count = len(mappings.get(topic_id, []))
        if (
            current_problem_count + topic_problem_count > max_daily_problems
            and selected_topic_count > 0
        ):
            cap_reached = True
            break

        score = priority_fn(r, bucket)
        selected.append(
            {
                **r,
                "reason": reason,
                "priority_bucket": bucket,
                "priority_score": score,
            }
        )
        selected_ids.add(topic_id)
        category_count[cat] += 1
        current_problem_count += topic_problem_count
        selected_topic_count += 1

    return current_problem_count, selected_topic_count, cap_reached
