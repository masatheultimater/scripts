"""Phase 5: compute_stage + normalize_stage + next_review_days + 定数テスト"""

from lib.houjinzei_common import (
    GRADUATION_INTERVAL_INDEX,
    GRADUATION_MIN_KOME,
    INTERVAL_DAYS,
    KOME_THRESHOLD_REVIEW,
    compute_stage,
    is_graduation_ready,
    next_review_days,
    normalize_stage,
)


# ─── compute_stage ───────────────────────────────────────

def test_stage_graduated():
    """status=="卒業" → stage=="卒業済" """
    assert compute_stage("卒業", 0, 0, 0) == "卒業済"


def test_stage_review_by_kome():
    """kome_total >= 16 → stage=="復習中" """
    assert compute_stage("学習中", KOME_THRESHOLD_REVIEW, 0, 0) == "復習中"


def test_stage_review_by_status():
    """status=="復習中" → stage=="復習中" （kome < 16でも）"""
    assert compute_stage("復習中", 5, 0, 0) == "復習中"


def test_stage_learning():
    """kome > 0 or attempts > 0 → stage=="学習中" """
    assert compute_stage("学習中", 1, 0, 0) == "学習中"
    assert compute_stage("未着手", 0, 1, 0) == "学習中"
    assert compute_stage("未着手", 0, 0, 1) == "学習中"


def test_stage_untouched():
    """全て0 → stage=="未着手" """
    assert compute_stage("未着手", 0, 0, 0) == "未着手"


def test_stage_boundary_kome_15():
    """kome=15 は "復習中" にならない（status が学習中の場合）"""
    assert compute_stage("学習中", 15, 0, 0) == "学習中"


def test_stage_boundary_kome_16():
    """kome=16 は "復習中" になる"""
    assert compute_stage("学習中", 16, 0, 0) == "復習中"


# ─── normalize_stage ─────────────────────────────────────

def test_normalize_valid_stage():
    """正常な stage 値はそのまま返る"""
    assert normalize_stage("未着手", "未着手") == "未着手"
    assert normalize_stage("学習中", "学習中") == "学習中"
    assert normalize_stage("復習中", "復習中") == "復習中"
    assert normalize_stage("卒業済", "卒業") == "卒業済"


def test_normalize_missing_stage():
    """stage欠損時にstatusから推定"""
    assert normalize_stage("", "卒業") == "卒業済"
    assert normalize_stage("", "学習中") == "学習中"
    assert normalize_stage("", "復習中") == "復習中"
    assert normalize_stage("", "未着手") == "未着手"
    assert normalize_stage("invalid", "未着手") == "未着手"
    assert normalize_stage("", "不明") == "未着手"


# ─── is_graduation_ready ─────────────────────────────────

def test_graduation_ready_both_conditions():
    """interval=4, kome=4 → True"""
    assert is_graduation_ready(GRADUATION_INTERVAL_INDEX, GRADUATION_MIN_KOME) is True


def test_graduation_not_ready_low_interval():
    """interval=3, kome=10 → False"""
    assert is_graduation_ready(GRADUATION_INTERVAL_INDEX - 1, 10) is False


def test_graduation_not_ready_low_kome():
    """interval=4, kome=3 → False"""
    assert is_graduation_ready(GRADUATION_INTERVAL_INDEX, GRADUATION_MIN_KOME - 1) is False


# ─── next_review_days ────────────────────────────────────

def test_review_days_index_0():
    """interval_index=0 → 3日"""
    assert next_review_days(0) == INTERVAL_DAYS[0]
    assert next_review_days(0) == 3


def test_review_days_index_3():
    """interval_index=3 → 28日"""
    assert next_review_days(3) == INTERVAL_DAYS[3]
    assert next_review_days(3) == 28


def test_review_days_overflow():
    """interval_index=5 → 28日（最大値）"""
    assert next_review_days(5) == 28


def test_review_days_negative():
    """interval_index=-1 → 3日（最小値）"""
    assert next_review_days(-1) == 3


# ─── 定数値の検証 ────────────────────────────────────────

def test_interval_days_tuple():
    """INTERVAL_DAYS は (3, 7, 14, 28)"""
    assert INTERVAL_DAYS == (3, 7, 14, 28)


def test_graduation_interval_index():
    """GRADUATION_INTERVAL_INDEX == 4"""
    assert GRADUATION_INTERVAL_INDEX == 4


def test_kome_threshold_review():
    """KOME_THRESHOLD_REVIEW == 16"""
    assert KOME_THRESHOLD_REVIEW == 16


def test_graduation_min_kome():
    """GRADUATION_MIN_KOME == 4"""
    assert GRADUATION_MIN_KOME == 4
