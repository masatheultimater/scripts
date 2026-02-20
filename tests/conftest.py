"""法人税学習システム テスト共通fixture"""

import json

import pytest
import yaml


@pytest.fixture
def tmp_vault(tmp_path):
    """テスト用の一時的なvaultディレクトリ構造を作成"""
    dirs = [
        "10_論点",
        "01_sources",
        "02_extracted",
        "20_演習ログ",
        "30_ソース別",
        "40_分析",
        "50_エクスポート",
    ]
    for d in dirs:
        (tmp_path / d).mkdir()
    # _index.json初期状態
    (tmp_path / "01_sources" / "_index.json").write_text(
        json.dumps({"processed": []}, ensure_ascii=False),
        encoding="utf-8",
    )
    return tmp_path


@pytest.fixture
def sample_note(tmp_vault):
    """サンプル論点ノートを作成するファクトリ"""

    def _create(filename, frontmatter_dict, body=""):
        dumped = yaml.safe_dump(
            frontmatter_dict,
            allow_unicode=True,
            sort_keys=False,
            default_flow_style=False,
            width=10000,
        )
        content = f"---\n{dumped}---\n{body}"
        note_path = tmp_vault / "10_論点" / filename
        note_path.write_text(content, encoding="utf-8")
        return note_path

    return _create
