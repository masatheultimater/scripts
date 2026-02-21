from collections import Counter
from datetime import date, timedelta

from lib.quiz_generation import (
    add_priority_balanced_with_problem_cap,
    build_carryover_topics,
)


def _topic(topic_id: str, category: str = "catA") -> dict:
    return {
        "topic_id": topic_id,
        "topic_name": topic_id,
        "category": category,
        "importance": "A",
        "interval_index": 0,
    }


def _problems(n: int) -> list[dict]:
    return [{"problem_id": f"p{i+1}"} for i in range(n)]


def test_problem_cap_limits_total_problems_to_40():
    selected = []
    selected_ids = set()
    category_count = Counter()
    candidates = [_topic(f"t{i}") for i in range(1, 6)]
    mappings = {f"t{i}": [f"p{i}_{j}" for j in range(10)] for i in range(1, 6)}

    current_count, selected_topic_count, cap_reached = add_priority_balanced_with_problem_cap(
        selected=selected,
        selected_ids=selected_ids,
        candidates=candidates,
        reason="test",
        bucket=1,
        limit=20,
        max_category_ratio=0.4,
        category_count=category_count,
        mappings=mappings,
        current_problem_count=0,
        max_daily_problems=40,
        selected_topic_count=0,
        priority_fn=lambda r, b: 1.0,
    )

    assert len(selected) == 4
    assert current_count == 40
    assert selected_topic_count == 4
    assert cap_reached is True


def test_first_topic_is_kept_even_if_it_exceeds_problem_cap():
    selected = []
    selected_ids = set()
    category_count = Counter()
    candidates = [_topic("t1")]
    mappings = {"t1": [f"p{n}" for n in range(50)]}

    current_count, selected_topic_count, cap_reached = add_priority_balanced_with_problem_cap(
        selected=selected,
        selected_ids=selected_ids,
        candidates=candidates,
        reason="test",
        bucket=1,
        limit=20,
        max_category_ratio=0.4,
        category_count=category_count,
        mappings=mappings,
        current_problem_count=0,
        max_daily_problems=40,
        selected_topic_count=0,
        priority_fn=lambda r, b: 1.0,
    )

    assert len(selected) == 1
    assert current_count == 50
    assert selected_topic_count == 1
    assert cap_reached is False


def test_carryover_uses_unanswered_topics_from_previous_day():
    base_date = date(2026, 2, 21)
    previous_today = {
        "generated_date": (base_date - timedelta(days=1)).strftime("%Y-%m-%d"),
        "topics": [
            {"topic_id": "t1", "topic_name": "T1", "category": "C1", "problems": _problems(3)},
            {"topic_id": "t2", "topic_name": "T2", "category": "C2", "problems": _problems(3)},
        ],
    }
    results_data = {
        "session_date": "2026-02-20",
        "results": [{"topic_id": "t1", "kome_count": 0, "correct": True}],
    }

    carryover_topics, carryover_count = build_carryover_topics(
        previous_today=previous_today,
        results_data=results_data,
        base_date=base_date,
        max_carryover=15,
        expiry_days=2,
    )

    assert carryover_count == 3
    assert len(carryover_topics) == 1
    assert carryover_topics[0]["topic_id"] == "t2"
    assert carryover_topics[0]["reason"] == "繰越"


def test_carryover_expires_at_two_days_or_older():
    base_date = date(2026, 2, 21)
    previous_today = {
        "generated_date": (base_date - timedelta(days=2)).strftime("%Y-%m-%d"),
        "topics": [{"topic_id": "t1", "topic_name": "T1", "category": "C1", "problems": _problems(3)}],
    }

    carryover_topics, carryover_count = build_carryover_topics(
        previous_today=previous_today,
        results_data={},
        base_date=base_date,
        max_carryover=15,
        expiry_days=2,
    )

    assert carryover_topics == []
    assert carryover_count == 0


def test_carryover_is_capped_at_15_problems():
    base_date = date(2026, 2, 21)
    previous_today = {
        "generated_date": (base_date - timedelta(days=1)).strftime("%Y-%m-%d"),
        "topics": [{"topic_id": "t1", "topic_name": "T1", "category": "C1", "problems": _problems(20)}],
    }

    carryover_topics, carryover_count = build_carryover_topics(
        previous_today=previous_today,
        results_data={},
        base_date=base_date,
        max_carryover=15,
        expiry_days=2,
    )

    assert carryover_count == 15
    assert len(carryover_topics) == 1
    assert len(carryover_topics[0]["problems"]) == 15


def test_carryover_counts_toward_daily_problem_cap():
    selected = []
    selected_ids = set()
    category_count = Counter()
    candidates = [_topic(f"t{i}") for i in range(1, 5)]
    mappings = {f"t{i}": [f"p{i}_{j}" for j in range(10)] for i in range(1, 5)}

    current_count, selected_topic_count, cap_reached = add_priority_balanced_with_problem_cap(
        selected=selected,
        selected_ids=selected_ids,
        candidates=candidates,
        reason="test",
        bucket=1,
        limit=20,
        max_category_ratio=0.4,
        category_count=category_count,
        mappings=mappings,
        current_problem_count=15,
        max_daily_problems=40,
        selected_topic_count=1,
        priority_fn=lambda r, b: 1.0,
    )

    assert len(selected) == 2
    assert current_count == 35
    assert selected_topic_count == 3
    assert cap_reached is True
