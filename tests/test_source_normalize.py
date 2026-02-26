"""Tests for lib/source_normalize.py."""

import pytest
from lib.source_normalize import SOURCES_MAP, normalize_source, normalize_sources_list


class TestSourcesMap:
    def test_all_values_differ_from_keys(self):
        for raw, fixed in SOURCES_MAP.items():
            assert raw != fixed, f"Identity mapping: {raw}"

    def test_no_double_publisher_in_values(self):
        for raw, fixed in SOURCES_MAP.items():
            parts = fixed.split(" ", 1)
            if len(parts) == 2:
                publisher = parts[0]
                rest = parts[1]
                assert not rest.startswith(publisher), (
                    f"Still duplicated in value: {fixed}"
                )

    def test_map_has_20_entries(self):
        assert len(SOURCES_MAP) == 20


class TestNormalizeSource:
    def test_known_duplicate(self):
        assert normalize_source(
            "税務研究会出版局 税務研究会出版局 法人税基本通達逐条解説"
        ) == "税務研究会出版局 法人税基本通達逐条解説"

    def test_tac_duplicate(self):
        assert normalize_source(
            "TAC TAC 法人税法 計算テキスト4"
        ) == "TAC 法人税法 計算テキスト4"

    def test_unknown_publisher(self):
        assert normalize_source(
            "不明 出版社 重点解説 法人税申告の実務(R7)"
        ) == "不明 重点解説 法人税申告の実務(R7)"

    def test_already_correct_passthrough(self):
        good = "資格の大原 法人税法 計算問題集 (一発合格) 1-1"
        assert normalize_source(good) == good

    def test_unknown_string_passthrough(self):
        assert normalize_source("some unknown source") == "some unknown source"


class TestNormalizeSourcesList:
    def test_normalizes_and_counts(self):
        sources = [
            "税務研究会出版局 税務研究会出版局 法人税基本通達逐条解説",
            "大原 大原 法人理論問題集",
        ]
        result, count = normalize_sources_list(sources)
        assert count == 2
        assert result == [
            "税務研究会出版局 法人税基本通達逐条解説",
            "大原 法人理論問題集",
        ]

    def test_deduplicates_after_normalization(self):
        sources = [
            "大原 大原 法人理論問題集",
            "大原 法人理論問題集",  # already correct, same as normalized above
        ]
        result, count = normalize_sources_list(sources)
        assert count == 1
        assert result == ["大原 法人理論問題集"]

    def test_empty_list(self):
        result, count = normalize_sources_list([])
        assert result == []
        assert count == 0

    def test_no_changes_needed(self):
        sources = ["foo", "bar"]
        result, count = normalize_sources_list(sources)
        assert result == ["foo", "bar"]
        assert count == 0
