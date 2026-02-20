"""Phase 3: Frontmatter I/O + extract_body_sections テスト"""

from pathlib import Path

import yaml

from lib.houjinzei_common import (
    extract_body_sections,
    read_frontmatter,
    split_frontmatter,
    write_frontmatter,
)


# ─── split_frontmatter ─────────────────────────────────

def test_split_normal():
    """正常なfrontmatterとbodyが分離される"""
    content = "---\ntopic: test\n---\n# Body\n"
    fm_text, body = split_frontmatter(content)
    assert fm_text == "topic: test"
    assert body == "# Body\n"


def test_split_no_frontmatter():
    """frontmatterなしの場合 (None, content) を返す"""
    content = "# Just a heading\nSome content"
    fm_text, body = split_frontmatter(content)
    assert fm_text is None
    assert body == content


def test_split_malformed_yaml():
    """不正なYAML構造（閉じ---なし）でも (None, content) を返す"""
    content = "---\ntopic: test\nNo closing marker"
    fm_text, body = split_frontmatter(content)
    assert fm_text is None
    assert body == content


def test_split_empty_body():
    """本文が空のノートを正しく処理"""
    content = "---\ntopic: test\n---\n"
    fm_text, body = split_frontmatter(content)
    assert fm_text == "topic: test"
    assert body == ""


# ─── read_frontmatter ──────────────────────────────────

def test_read_frontmatter_returns_dict(sample_note):
    """正常ノートからdictとbodyを返す"""
    path = sample_note("test.md", {"topic": "減価償却", "kome_total": 5}, "# 本文\n内容")
    fm, body = read_frontmatter(path)
    assert isinstance(fm, dict)
    assert fm["topic"] == "減価償却"
    assert fm["kome_total"] == 5
    assert "# 本文" in body


def test_read_frontmatter_yaml_error(tmp_vault):
    """不正YAMLで空dictを返す（raiseしない）"""
    bad = tmp_vault / "10_論点" / "bad.md"
    bad.write_text("---\n: [\ninvalid yaml\n---\n# Body\n", encoding="utf-8")
    fm, body = read_frontmatter(bad)
    assert fm == {}
    assert "# Body" in body


def test_read_frontmatter_missing_file():
    """存在しないファイルでFileNotFoundError"""
    import pytest
    with pytest.raises(FileNotFoundError):
        read_frontmatter(Path("/nonexistent/file.md"))


# ─── write_frontmatter ──────────────────────────────────

def test_write_frontmatter_roundtrip(sample_note):
    """read→write→readで内容が保持される"""
    original_data = {
        "topic": "交際費",
        "category": "損金算入",
        "kome_total": 10,
        "interval_index": 2,
    }
    path = sample_note("roundtrip.md", original_data, "# 本文\n詳細内容")
    fm, body = read_frontmatter(path)
    write_frontmatter(path, fm, body)
    fm2, body2 = read_frontmatter(path)
    assert fm2["topic"] == "交際費"
    assert fm2["kome_total"] == 10
    assert "# 本文" in body2


def test_write_frontmatter_preserves_unicode(sample_note):
    """日本語フィールドが化けない"""
    path = sample_note("unicode.md", {"topic": "寄附金", "category": "損金算入"}, "")
    fm, body = read_frontmatter(path)
    fm["subcategory"] = "グループ法人税制"
    write_frontmatter(path, fm, body)
    raw = path.read_text(encoding="utf-8")
    assert "寄附金" in raw
    assert "グループ法人税制" in raw


def test_write_frontmatter_atomic(sample_note):
    """書き込みが原子的（tempfile残骸なし）"""
    path = sample_note("atomic.md", {"topic": "test"}, "body")
    write_frontmatter(path, {"topic": "updated"}, "new body")
    # tempfileが残っていないことを確認
    tmp_files = [f for f in path.parent.iterdir() if f.suffix == ".tmp"]
    assert tmp_files == []


# ─── extract_body_sections ─────────────────────────────

def test_extract_sections_summary():
    """## 概要 セクションが正しく抽出される"""
    body = "# 減価償却\n## 概要\n法人税法における減価償却の概要。\n## 計算手順\n1. 取得価額\n"
    result = extract_body_sections(body)
    assert "減価償却の概要" in result["summary"]


def test_extract_sections_empty_template():
    """空テンプレート（見出しのみ）を検出"""
    body = "# 論点名\n## 概要\n## 計算手順\n## 判断ポイント\n## 間違えやすいポイント\n## 関連条文\n"
    result = extract_body_sections(body)
    assert result["summary"] == ""
    assert result["steps"] == ""


def test_extract_sections_steps():
    """## 計算手順 セクションが抽出される"""
    body = "# Test\n## 概要\n概要テキスト\n## 計算手順\n1. 手順A\n2. 手順B\n## 判断ポイント\n"
    result = extract_body_sections(body)
    assert "手順A" in result["steps"]
    assert "手順B" in result["steps"]


def test_extract_sections_mistake_items():
    """## 間違えやすいポイント からリスト項目が抽出される"""
    body = (
        "# Test\n## 間違えやすいポイント\n"
        "- **特別償却と割増償却の混同**: 両者は異なる制度\n"
        "- 耐用年数の適用誤り\n"
        "## 関連条文\n"
    )
    result = extract_body_sections(body)
    assert len(result["mistake_items"]) == 2
    assert "特別償却と割増償却の混同" in result["mistake_items"][0]
