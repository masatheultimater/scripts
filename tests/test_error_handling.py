"""Phase 6: エラーハンドリングテスト"""

import pytest

from lib.houjinzei_common import (
    atomic_json_write,
    parse_date,
    process_answer,
    read_frontmatter,
    to_int,
)


def test_read_frontmatter_corrupt_yaml(tmp_vault):
    """壊れたYAMLで例外を投げない"""
    bad = tmp_vault / "10_論点" / "corrupt.md"
    bad.write_text("---\n{{invalid: [yaml: broken\n---\n# Body\n", encoding="utf-8")
    fm, body = read_frontmatter(bad)
    assert fm == {}
    assert "# Body" in body


def test_atomic_write_readonly_dir(tmp_path):
    """書き込み不可ディレクトリで明確なエラー"""
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    target = readonly / "test.json"

    readonly.chmod(0o444)
    try:
        with pytest.raises((PermissionError, OSError)):
            atomic_json_write(target, {"key": "value"})
    finally:
        readonly.chmod(0o755)


def test_process_answer_none_fields():
    """frontmatter値がNoneでもクラッシュしない"""
    fm = {
        "topic": "テスト",
        "kome_total": None,
        "calc_correct": None,
        "calc_wrong": None,
        "interval_index": None,
        "status": None,
        "stage": None,
        "last_practiced": None,
        "mistakes": None,
    }
    # クラッシュしないことが重要
    result = process_answer(fm, correct=True, answer_date="2026-02-20")
    assert isinstance(result, dict)
    assert result["last_practiced"] == "2026-02-20"


def test_parse_date_invalid_format():
    """不正な日付文字列で明確なValueError"""
    with pytest.raises(ValueError):
        parse_date("not-a-date")


def test_to_int_various_inputs():
    """None, '', 'abc', '3.5' 全て0を返す"""
    assert to_int(None) == 0
    assert to_int("") == 0
    assert to_int("abc") == 0
    assert to_int("3.5") == 0
    assert to_int("42") == 42
    assert to_int(0) == 0
