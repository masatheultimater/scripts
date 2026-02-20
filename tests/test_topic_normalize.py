"""topic_normalize のテスト。"""

import json
from pathlib import Path

from lib.topic_normalize import PARENT_CATEGORIES, get_parent_category, normalize_topic

MASTER_PATH = Path("/home/masa/vault/houjinzei/50_エクスポート/problems_master.json")


def _all_raw_topics() -> list[str]:
    data = json.loads(MASTER_PATH.read_text(encoding="utf-8"))
    topics = sorted({t for p in data["problems"].values() for t in (p.get("topics") or [])})
    return topics


def test_all_233_topics_can_be_normalized():
    topics = _all_raw_topics()
    assert len(topics) == 233

    normalized = [normalize_topic(topic) for topic in topics]
    assert all(isinstance(v, str) and v for v in normalized)


def test_normalized_topic_unique_count_is_reasonable():
    topics = _all_raw_topics()
    normalized = {normalize_topic(topic) for topic in topics}
    # 指定ルールを適用した現データの実測値は 88。
    assert len(normalized) <= 90


def test_all_normalized_topics_have_valid_parent_category():
    topics = _all_raw_topics()
    allowed = set(PARENT_CATEGORIES)

    for normalized in {normalize_topic(topic) for topic in topics}:
        category = get_parent_category(normalized)
        assert category in allowed


def test_variant_examples():
    assert normalize_topic("別表五㈠Ⅰ") == "別表五(一)"
    assert normalize_topic("別表五㈠Ⅰの作成") == "別表五(一)"
    assert normalize_topic("受取配当等の益金不算入（特別分配金）") == "受取配当等"
    assert normalize_topic("工事進行基準（一括評価金銭債権）") == "貸倒引当金_一括"
    assert get_parent_category("貸倒引当金_一括") == "引当金・準備金"
