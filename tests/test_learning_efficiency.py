from datetime import datetime, timedelta

from lib.learning_efficiency import (
    build_category_dashboard,
    calc_priority_score,
    estimate_topic_graduation_probability,
    get_frequency_score,
    is_focus_active,
)
from lib.topic_normalize import PARENT_CATEGORIES


def test_frequency_score_map_a_b_c_default():
    assert get_frequency_score("A") == 3
    assert get_frequency_score("B") == 2
    assert get_frequency_score("C") == 1
    assert get_frequency_score("Z") == 1
    assert get_frequency_score("") == 1


def test_focus_active_within_24h():
    now = datetime(2026, 2, 21, 10, 0, 0)
    assert is_focus_active("2026-02-21T11:00:00", now) is True


def test_focus_expired_after_24h():
    now = datetime(2026, 2, 21, 10, 0, 0)
    assert is_focus_active("2026-02-21T09:59:59", now) is False


def test_priority_score_prefers_high_frequency():
    now = datetime(2026, 2, 21, 10, 0, 0)
    rec_a = {"importance": "A", "calc_correct": 0, "calc_wrong": 0}
    rec_b = {"importance": "B", "calc_correct": 0, "calc_wrong": 0}
    assert calc_priority_score(rec_a, 2, now) > calc_priority_score(rec_b, 2, now)


def test_topic_graduation_probability_bounds():
    now = datetime(2026, 2, 21, 10, 0, 0)
    low = estimate_topic_graduation_probability(
        {"status": "学習中", "interval_index": 0, "calc_correct": 0, "calc_wrong": 100},
        now,
    )
    assert 0.05 <= low <= 0.95

    high = estimate_topic_graduation_probability(
        {"status": "学習中", "interval_index": 4, "calc_correct": 100, "calc_wrong": 0},
        now,
    )
    assert 0.05 <= high <= 0.95


def test_category_probability_frequency_weighted():
    generated_at = datetime(2026, 2, 21, 10, 32, 15)
    records = [
        {
            "topic_name": "交際費等",
            "category": "損金算入",
            "status": "学習中",
            "stage": "学習中",
            "importance": "A",
            "frequency_score": 3,
            "interval_index": 4,
            "calc_correct": 10,
            "calc_wrong": 0,
        },
        {
            "topic_name": "交際費等",
            "category": "損金算入",
            "status": "学習中",
            "stage": "学習中",
            "importance": "C",
            "frequency_score": 1,
            "interval_index": 0,
            "calc_correct": 0,
            "calc_wrong": 10,
            "focus_until_at": (generated_at + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%S"),
        },
    ]
    data = build_category_dashboard(records, generated_at)
    row = next(c for c in data["categories"] if c["name"] == "損金算入")

    # A(重み3)の高確率寄与が大きいため 0.5 を上回る
    assert row["graduation_probability"] > 0.5


def test_dashboard_contains_all_15_categories():
    data = build_category_dashboard([], datetime(2026, 2, 21, 10, 32, 15))
    names = [c["name"] for c in data["categories"]]
    assert len(names) == 15
    assert names == list(PARENT_CATEGORIES)
