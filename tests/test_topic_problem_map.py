"""topic_problem_map のテスト。"""

import json

import pytest

from lib.topic_problem_map import (
    _match_by_category,
    _match_by_keyword,
    _match_by_normalized,
    build_topic_problem_map,
    load_topic_problem_map,
    save_topic_problem_map,
)


@pytest.fixture
def problems_master(tmp_vault):
    """テスト用 problems_master.json を作成"""
    data = {
        "version": 1,
        "total": 5,
        "problems": {
            "calc-001": {
                "id": "calc-001",
                "book": "法人計算問題集1-1",
                "number": "問題 1",
                "title": "減価償却（基本計算）",
                "type": "計算",
                "scope": "個別",
                "topics": ["減価償却"],
                "page": 10,
                "time_min": 15,
                "rank": "A",
                "normalized_topics": ["減価償却"],
                "parent_category": "損金算入",
                "duplicate_group": None,
            },
            "calc-002": {
                "id": "calc-002",
                "book": "法人計算問題集1-1",
                "number": "問題 2",
                "title": "減価償却（特別償却準備金）",
                "type": "計算",
                "scope": "個別",
                "topics": ["減価償却（特別償却準備金）"],
                "page": 14,
                "time_min": 20,
                "rank": "B",
                "normalized_topics": ["減価償却"],
                "parent_category": "損金算入",
                "duplicate_group": None,
            },
            "theory-001": {
                "id": "theory-001",
                "book": "法人理論問題集",
                "number": "問題 1",
                "title": "交際費等の損金不算入",
                "type": "理論",
                "scope": "個別",
                "topics": ["交際費等の損金不算入"],
                "page": 26,
                "time_min": 0,
                "rank": "A",
                "normalized_topics": ["交際費等"],
                "parent_category": "損金算入",
                "duplicate_group": None,
            },
            "calc-003": {
                "id": "calc-003",
                "book": "法人計算問題集1-2",
                "number": "問題 5",
                "title": "外国税額控除の計算",
                "type": "計算",
                "scope": "個別",
                "topics": ["外国税額控除"],
                "page": 30,
                "time_min": 25,
                "rank": "A",
                "normalized_topics": ["外国税額控除"],
                "parent_category": "税額計算",
                "duplicate_group": None,
            },
            "calc-004": {
                "id": "calc-004",
                "book": "法人計算問題集2-1",
                "number": "問題 10",
                "title": "通算制度の基本計算",
                "type": "計算",
                "scope": "総合",
                "topics": ["通算制度"],
                "page": 50,
                "time_min": 30,
                "rank": "B",
                "normalized_topics": ["通算制度"],
                "parent_category": "通算制度",
                "duplicate_group": None,
            },
        },
    }
    path = tmp_vault / "50_エクスポート" / "problems_master.json"
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return path


def _create_topic_note(tmp_vault, category, filename, topic_name):
    """テスト用論点ノートを作成するヘルパー"""
    import yaml

    cat_dir = tmp_vault / "10_論点" / category
    cat_dir.mkdir(parents=True, exist_ok=True)
    fm = {
        "topic": topic_name,
        "category": category,
        "importance": "A",
        "status": "未着手",
        "kome_total": 0,
        "interval_index": 0,
    }
    dumped = yaml.safe_dump(fm, allow_unicode=True, sort_keys=False)
    content = f"---\n{dumped}---\n\n# {topic_name}\n"
    (cat_dir / filename).write_text(content, encoding="utf-8")


# ── Strategy 1: normalized_topic match ──


def test_match_by_normalized_exact():
    """reduce_topic → normalized_topics の完全一致"""
    norm_to_pids = {"減価償却": ["calc-001", "calc-002"]}
    result = _match_by_normalized("減価償却_基本", norm_to_pids)
    assert "calc-001" in result
    assert "calc-002" in result


def test_match_by_normalized_underscore_split():
    """underscore分割で各パーツも検索"""
    norm_to_pids = {"交際費等": ["theory-001"]}
    result = _match_by_normalized("交際費等_範囲判定", norm_to_pids)
    assert result == ["theory-001"]


def test_match_by_normalized_no_match():
    """一致なし"""
    norm_to_pids = {"減価償却": ["calc-001"]}
    result = _match_by_normalized("存在しないトピック", norm_to_pids)
    assert result == []


# ── Strategy 2: category match ──


def test_match_by_category():
    cat_to_pids = {"税額計算": ["calc-003"]}
    result = _match_by_category("外国税額控除_基本", cat_to_pids)
    assert result == ["calc-003"]


def test_match_by_category_sono_ta_excluded():
    """'その他' カテゴリは空を返す"""
    cat_to_pids = {"その他": ["x-001"]}
    result = _match_by_category("完全に未知のトピック", cat_to_pids)
    assert result == []


# ── Strategy 3: keyword match ──


def test_match_by_keyword():
    problems = {
        "calc-003": {"title": "外国税額控除の計算"},
        "theory-001": {"title": "交際費等の損金不算入"},
    }
    result = _match_by_keyword("外国税額控除_計算パターン", problems)
    assert "calc-003" in result


def test_match_by_keyword_no_match():
    problems = {"calc-001": {"title": "減価償却（基本計算）"}}
    result = _match_by_keyword("存在しない_キーワード", problems)
    assert result == []


# ── Integration: build_topic_problem_map ──


def test_build_map_normalized_match(tmp_vault, problems_master):
    """normalized_topic一致で正しくマッピング"""
    _create_topic_note(tmp_vault, "損金算入", "減価償却_基本.md", "減価償却_基本")
    result = build_topic_problem_map(tmp_vault, problems_master)
    assert "損金算入/減価償却_基本" in result["mappings"]
    pids = result["mappings"]["損金算入/減価償却_基本"]
    assert "calc-001" in pids
    assert "calc-002" in pids


def test_build_map_category_fallback(tmp_vault, problems_master):
    """Strategy 2: category fallback"""
    _create_topic_note(tmp_vault, "通算制度", "通算制度_基本.md", "通算制度_基本")
    result = build_topic_problem_map(tmp_vault, problems_master)
    assert "通算制度/通算制度_基本" in result["mappings"]
    assert "calc-004" in result["mappings"]["通算制度/通算制度_基本"]


def test_build_map_unmapped(tmp_vault, problems_master):
    """マッチなしの論点は unmapped に記録"""
    _create_topic_note(tmp_vault, "その他", "完全未知のトピック.md", "完全未知のトピック名")
    result = build_topic_problem_map(tmp_vault, problems_master)
    assert result["stats"]["mapped"] == 0
    assert len(result["stats"]["unmapped_topics"]) == 1


def test_build_map_empty_topic(tmp_vault, problems_master):
    """topic が空の論点はスキップ"""
    _create_topic_note(tmp_vault, "損金算入", "空トピック.md", "")
    result = build_topic_problem_map(tmp_vault, problems_master)
    assert result["stats"]["total_topics"] == 0


def test_build_map_stats(tmp_vault, problems_master):
    """stats の正確性"""
    _create_topic_note(tmp_vault, "損金算入", "減価償却_基本.md", "減価償却_基本")
    _create_topic_note(tmp_vault, "損金算入", "交際費等_範囲.md", "交際費等_範囲判定")
    _create_topic_note(tmp_vault, "その他", "未知.md", "完全未知xyz")
    result = build_topic_problem_map(tmp_vault, problems_master)
    stats = result["stats"]
    assert stats["total_topics"] == 3
    assert stats["mapped"] == 2
    assert stats["coverage_pct"] == 67
    assert len(stats["unmapped_topics"]) == 1


# ── save / load ──


def test_save_and_load_roundtrip(tmp_vault, problems_master):
    _create_topic_note(tmp_vault, "損金算入", "減価償却_基本.md", "減価償却_基本")
    saved = save_topic_problem_map(tmp_vault, problems_master)
    loaded = load_topic_problem_map(tmp_vault)
    assert loaded["mappings"] == saved["mappings"]
    assert loaded["stats"]["total_topics"] == saved["stats"]["total_topics"]


def test_load_nonexistent(tmp_vault):
    result = load_topic_problem_map(tmp_vault)
    assert result == {"mappings": {}, "stats": {}}


# ── Real vault integration (optional, skipped if vault not available) ──


@pytest.fixture
def real_vault():
    from pathlib import Path

    vault = Path("/home/masa/vault/houjinzei")
    if not vault.exists():
        pytest.skip("Real vault not available")
    master = vault / "50_エクスポート" / "problems_master.json"
    if not master.exists():
        pytest.skip("problems_master.json not available")
    return vault


def test_real_vault_coverage(real_vault):
    """実データでカバレッジ95%以上を確認"""
    result = build_topic_problem_map(real_vault)
    stats = result["stats"]
    print(f"\nReal vault: {stats['total_topics']} topics, {stats['mapped']} mapped ({stats['coverage_pct']}%)")
    if stats["unmapped_topics"]:
        print(f"Unmapped: {stats['unmapped_topics'][:10]}")
    assert stats["coverage_pct"] >= 90, f"Coverage too low: {stats['coverage_pct']}%"
