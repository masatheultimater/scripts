"""Tests for schedule-based quiz generation split."""

from lib.quiz_generation import split_new_review_budget, filter_scope_candidates


def test_split_even_budget():
    new, review = split_new_review_budget(30, 0.5, 5, 5)
    assert new == 15
    assert review == 15


def test_split_small_budget_review_priority():
    new, review = split_new_review_budget(8, 0.5, 5, 5)
    # new=5, review=3 -> review < 5, so review=5, new=3
    assert review == 5
    assert new == 3


def test_split_zero_budget():
    new, review = split_new_review_budget(0, 0.5, 5, 5)
    assert new == 0
    assert review == 0


def test_split_very_small_budget():
    new, review = split_new_review_budget(3, 0.5, 5, 5)
    # new would need 5 but budget only 3, review gets all
    assert new == 0
    assert review == 3


def test_filter_scope_candidates():
    records = [
        {"topic_id": "t1", "category": "損金算入"},
        {"topic_id": "t2", "category": "益金不算入"},
        {"topic_id": "t3", "category": "所得計算"},
    ]
    result = filter_scope_candidates(records, ["損金算入", "益金不算入"])
    assert len(result) == 2
    assert result[0]["topic_id"] == "t1"
    assert result[1]["topic_id"] == "t2"


def test_filter_scope_empty_categories():
    records = [{"topic_id": "t1", "category": "損金算入"}]
    result = filter_scope_candidates(records, [])
    assert result == []
