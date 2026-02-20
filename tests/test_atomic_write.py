"""Phase 1: atomic_json_write テスト"""

import json
import os
from pathlib import Path
from unittest.mock import patch

from lib.houjinzei_common import atomic_json_write


def test_atomic_write_creates_valid_json(tmp_path):
    """書き込んだJSONが正しく読み戻せる"""
    target = tmp_path / "test.json"
    data = {"processed": [{"filename": "test.pdf"}]}
    atomic_json_write(target, data)

    loaded = json.loads(target.read_text(encoding="utf-8"))
    assert loaded == data


def test_atomic_write_overwrites_existing(tmp_path):
    """既存ファイルを安全に上書きする"""
    target = tmp_path / "test.json"
    target.write_text('{"old": true}', encoding="utf-8")

    new_data = {"new": True, "items": [1, 2, 3]}
    atomic_json_write(target, new_data)

    loaded = json.loads(target.read_text(encoding="utf-8"))
    assert loaded == new_data


def test_atomic_write_no_partial_on_error(tmp_path):
    """書き込み中にエラーが発生しても元ファイルが破損しない"""
    target = tmp_path / "test.json"
    original = {"original": True}
    target.write_text(json.dumps(original), encoding="utf-8")

    # json.dump がシリアライズ不能なオブジェクトで失敗するケース
    class Unserializable:
        pass

    try:
        atomic_json_write(target, {"bad": Unserializable()})
    except (TypeError, ValueError):
        pass

    # 元ファイルが破損していないことを確認
    loaded = json.loads(target.read_text(encoding="utf-8"))
    assert loaded == original


def test_atomic_write_preserves_unicode(tmp_path):
    """日本語を含むJSONが正しく書き込まれる"""
    target = tmp_path / "test.json"
    data = {"論点": "減価償却", "ステータス": "学習中", "ソース": ["大原 法人税テキスト1"]}
    atomic_json_write(target, data)

    loaded = json.loads(target.read_text(encoding="utf-8"))
    assert loaded == data
    # ensure_ascii=False で日本語がそのまま保存されていることを確認
    raw = target.read_text(encoding="utf-8")
    assert "減価償却" in raw


def test_atomic_write_no_tmp_file_left(tmp_path):
    """成功時にtempfileが残らない"""
    target = tmp_path / "test.json"
    atomic_json_write(target, {"key": "value"})

    # tmp_path 内に .tmp ファイルが残っていないことを確認
    tmp_files = [f for f in tmp_path.iterdir() if f.suffix == ".tmp"]
    assert tmp_files == []
