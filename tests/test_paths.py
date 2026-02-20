"""Phase 2: VaultPaths テスト"""

from pathlib import Path

from lib.houjinzei_common import VaultPaths


def test_vault_paths_default_structure(tmp_vault):
    """デフォルトの全ディレクトリパスが正しい"""
    vp = VaultPaths(tmp_vault)
    assert vp.root == tmp_vault
    assert vp.topics == tmp_vault / "10_論点"
    assert vp.sources == tmp_vault / "01_sources"
    assert vp.extracted == tmp_vault / "02_extracted"
    assert vp.exercise_log == tmp_vault / "20_演習ログ"
    assert vp.source_map == tmp_vault / "30_ソース別"
    assert vp.analysis == tmp_vault / "40_分析"
    assert vp.export == tmp_vault / "50_エクスポート"


def test_vault_paths_custom_root(tmp_path):
    """カスタムroot指定時にパスが正しく構築される"""
    custom = tmp_path / "my_vault"
    custom.mkdir()
    vp = VaultPaths(custom)
    assert vp.root == custom
    assert vp.topics == custom / "10_論点"


def test_vault_paths_topics_dir_name(tmp_vault):
    """topics ディレクトリ名が '10_論点' """
    vp = VaultPaths(tmp_vault)
    assert vp.topics.name == "10_論点"


def test_vault_paths_index_json_location(tmp_vault):
    """index_json が 01_sources/_index.json を指す"""
    vp = VaultPaths(tmp_vault)
    assert vp.index_json == tmp_vault / "01_sources" / "_index.json"


def test_vault_paths_all_dirs_exist(tmp_path):
    """ensure_dirs() で全必須ディレクトリが作成される"""
    root = tmp_path / "new_vault"
    # root 自体は存在しない状態から始める
    vp = VaultPaths(root)
    vp.ensure_dirs()

    assert root.exists()
    assert vp.topics.exists()
    assert vp.sources.exists()
    assert vp.extracted.exists()
    assert vp.exercise_log.exists()
    assert vp.source_map.exists()
    assert vp.analysis.exists()
    assert vp.export.exists()
