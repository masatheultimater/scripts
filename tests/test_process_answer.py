"""Phase 4: process_answer テスト"""

from datetime import date

from lib.houjinzei_common import (
    GRADUATION_INTERVAL_INDEX,
    GRADUATION_MIN_KOME,
    KOME_THRESHOLD_REVIEW,
    compute_stage,
    process_answer,
)


def _make_fm(**overrides):
    """テスト用のfrontmatter dictを生成する"""
    base = {
        "topic": "テスト論点",
        "category": "テスト",
        "kome_total": 0,
        "calc_correct": 0,
        "calc_wrong": 0,
        "interval_index": 0,
        "last_practiced": None,
        "status": "未着手",
        "stage": "未着手",
        "mistakes": [],
    }
    base.update(overrides)
    return base


# ─── interval_index 更新 ─────────────────────────────────

def test_correct_increments_interval():
    """正解でinterval_index +1"""
    fm = _make_fm(interval_index=1, status="学習中", stage="学習中")
    result = process_answer(fm, correct=True, answer_date="2026-02-20")
    assert result["interval_index"] == 2


def test_wrong_resets_interval():
    """不正解でinterval_index → 0"""
    fm = _make_fm(interval_index=2, status="学習中", stage="学習中")
    result = process_answer(fm, correct=False, answer_date="2026-02-20")
    assert result["interval_index"] == 0


def test_interval_caps_at_graduation():
    """interval_index は GRADUATION_INTERVAL_INDEX(4) を超えない"""
    fm = _make_fm(interval_index=3, status="復習中", stage="復習中", kome_total=3)
    result = process_answer(fm, correct=True, answer_date="2026-02-20")
    assert result["interval_index"] <= GRADUATION_INTERVAL_INDEX


# ─── kome_total 更新 ─────────────────────────────────────

def test_correct_increments_kome():
    """正解でkome_total +1（kome_delta指定時）"""
    fm = _make_fm(kome_total=5)
    result = process_answer(fm, correct=True, answer_date="2026-02-20", kome_delta=1)
    assert result["kome_total"] == 6


def test_wrong_does_not_decrement_kome():
    """不正解でkome_totalは変わらない（kome_delta=0時）"""
    fm = _make_fm(kome_total=5)
    result = process_answer(fm, correct=False, answer_date="2026-02-20", kome_delta=0)
    assert result["kome_total"] == 5


# ─── status 遷移 ─────────────────────────────────────────

def test_first_answer_sets_learning():
    """初回回答で status: 未着手 → 学習中"""
    fm = _make_fm()
    result = process_answer(fm, correct=True, answer_date="2026-02-20")
    assert result["status"] == "学習中"


def test_kome_threshold_sets_review():
    """kome_total >= 16 で status: 学習中 → 復習中"""
    fm = _make_fm(kome_total=KOME_THRESHOLD_REVIEW - 1, status="学習中", stage="学習中")
    result = process_answer(fm, correct=True, answer_date="2026-02-20", kome_delta=1)
    assert result["status"] == "復習中"


def test_status_review_not_downgraded():
    """不正解でも 復習中 → 学習中 にはならない"""
    fm = _make_fm(status="復習中", stage="復習中", kome_total=20, interval_index=2)
    result = process_answer(fm, correct=False, answer_date="2026-02-20")
    assert result["status"] == "復習中"


# ─── 卒業判定（二重条件） ────────────────────────────────

def test_graduation_by_interval():
    """interval_index == GRADUATION_INTERVAL_INDEX-1 から正解 && kome >= 4 → status: 卒業"""
    fm = _make_fm(
        interval_index=GRADUATION_INTERVAL_INDEX - 1,
        kome_total=GRADUATION_MIN_KOME,
        status="復習中",
        stage="復習中",
    )
    result = process_answer(fm, correct=True, answer_date="2026-02-20")
    assert result["status"] == "卒業"
    assert result["stage"] == "卒業済"


def test_graduation_by_legacy_gap():
    """gap >= 25日 && kome >= 4 → status: 卒業（レガシー条件）"""
    fm = _make_fm(
        kome_total=GRADUATION_MIN_KOME,
        status="復習中",
        stage="復習中",
        last_practiced="2026-01-01",
        interval_index=0,
    )
    # 25日以上のギャップ
    result = process_answer(fm, correct=True, answer_date="2026-02-01")
    assert result["status"] == "卒業"


def test_no_graduation_insufficient_kome():
    """interval_index == GRADUATION_INTERVAL_INDEX-1 でも kome < 4 なら卒業しない"""
    fm = _make_fm(
        interval_index=GRADUATION_INTERVAL_INDEX - 1,
        kome_total=GRADUATION_MIN_KOME - 1,
        status="復習中",
        stage="復習中",
    )
    result = process_answer(fm, correct=True, answer_date="2026-02-20")
    assert result["status"] != "卒業"


def test_graduated_not_rolled_back():
    """卒業済みノートは不正解でもステータスが戻らない"""
    fm = _make_fm(status="卒業", stage="卒業済", kome_total=20, interval_index=4)
    result = process_answer(fm, correct=False, answer_date="2026-02-20")
    assert result["status"] == "卒業"
    assert result["stage"] == "卒業済"


# ─── stage 更新 ──────────────────────────────────────────

def test_stage_matches_status():
    """process_answer後のstageがcompute_stage()と一致"""
    fm = _make_fm(kome_total=5, status="学習中", stage="学習中")
    result = process_answer(fm, correct=True, answer_date="2026-02-20", kome_delta=1)
    expected = compute_stage(result["status"], result["kome_total"],
                             result["calc_correct"], result["calc_wrong"])
    assert result["stage"] == expected


# ─── last_practiced 更新 ─────────────────────────────────

def test_last_practiced_updated():
    """回答日がlast_practicedに反映される"""
    fm = _make_fm()
    result = process_answer(fm, correct=True, answer_date="2026-02-20")
    assert result["last_practiced"] == "2026-02-20"


# ─── mistakes フィールド ─────────────────────────────────

def test_mistakes_appended_on_wrong():
    """不正解時にmistakesリストに追記"""
    fm = _make_fm(mistakes=["既存のミス"])
    result = process_answer(fm, correct=False, answer_date="2026-02-20",
                            mistake_text="新しいミス")
    assert "新しいミス" in result["mistakes"]
    assert "既存のミス" in result["mistakes"]


def test_mistakes_not_appended_on_correct():
    """正解時にmistakesは変更されない"""
    fm = _make_fm(mistakes=["既存のミス"])
    result = process_answer(fm, correct=True, answer_date="2026-02-20",
                            mistake_text="無視されるべき")
    assert len(result["mistakes"]) == 1
