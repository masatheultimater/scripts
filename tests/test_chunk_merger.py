"""chunk_merger のテスト。"""

from lib.chunk_merger import merge_payloads


def test_merge_payloads_dedupes_and_expands_page_range():
    p1 = {
        "source_name": "出版社 書名",
        "source_type": "実務書",
        "publisher": "出版社",
        "topics": [
            {
                "topic_id": "減価償却_普通",
                "name": "減価償却（普通）",
                "category": "損金算入",
                "subcategory": "減価償却",
                "type": ["実務"],
                "conditions": ["法31"],
                "page_range": "10-15",
                "keywords": ["減価償却", "普通償却"],
                "importance": "A",
                "related": ["減価償却_特別"],
            }
        ],
    }
    p2 = {
        "source_name": "別の名前",
        "source_type": "実務書",
        "publisher": "別出版社",
        "topics": [
            {
                "topic_id": "減価償却_普通",
                "name": "減価償却（普通）",
                "category": "損金算入",
                "subcategory": "減価償却",
                "type": ["実務", "理論"],
                "conditions": ["法31", "令48"],
                "page_range": "20-22",
                "keywords": ["普通償却", "償却限度額"],
                "importance": "A",
                "related": ["減価償却_特別", "固定資産税"],
            }
        ],
    }

    merged = merge_payloads([p1, p2])

    assert merged["source_name"] == "出版社 書名"
    assert merged["publisher"] == "出版社"
    assert merged["total_topics"] == 1

    topic = merged["topics"][0]
    assert topic["page_range"] == "10-22"
    assert topic["conditions"] == ["法31", "令48"]
    assert topic["keywords"] == ["減価償却", "普通償却", "償却限度額"]
    assert topic["type"] == ["実務", "理論"]
    assert topic["related"] == ["減価償却_特別", "固定資産税"]


def test_merge_payloads_keeps_order_and_counts_topics():
    p1 = {
        "source_name": "A",
        "source_type": "実務書",
        "publisher": "P",
        "topics": [
            {"topic_id": "t1", "page_range": "1-2", "keywords": ["a"]},
            {"topic_id": "t2", "page_range": "3-4", "keywords": ["b"]},
        ],
    }
    p2 = {
        "source_name": "A",
        "source_type": "実務書",
        "publisher": "P",
        "topics": [
            {"topic_id": "t3", "page_range": "5-6", "keywords": ["c"]},
            {"topic_id": "t2", "page_range": "7-8", "keywords": ["d"]},
        ],
    }

    merged = merge_payloads([p1, p2])
    assert merged["total_topics"] == 3
    assert [t["topic_id"] for t in merged["topics"]] == ["t1", "t2", "t3"]
    assert merged["topics"][1]["page_range"] == "3-8"
