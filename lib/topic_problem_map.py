"""論点→問題マッピングモジュール。

論点ノートの topic フィールドと problems_master.json の normalized_topics を接合する。
3段階フォールバック: normalized_topic一致 → parent_category一致 → titleキーワード部分一致
"""

from __future__ import annotations

import json
from pathlib import Path

from lib.houjinzei_common import VaultPaths, atomic_json_write, read_frontmatter
from lib.topic_normalize import get_parent_category, normalize_topic


def _build_reverse_indexes(problems: dict) -> tuple[dict[str, list[str]], dict[str, list[str]]]:
    """problems dict から逆引きインデックスを構築する。"""
    norm_to_pids: dict[str, list[str]] = {}
    cat_to_pids: dict[str, list[str]] = {}

    for pid, prob in problems.items():
        for nt in prob.get("normalized_topics", []):
            norm_to_pids.setdefault(nt, []).append(pid)
        pcat = prob.get("parent_category", "")
        if pcat:
            cat_to_pids.setdefault(pcat, []).append(pid)

    return norm_to_pids, cat_to_pids


def _match_by_normalized(topic_name: str, norm_to_pids: dict[str, list[str]]) -> list[str]:
    """Strategy 1: topic名を正規化して normalized_topics と照合。"""
    matched: list[str] = []
    seen: set[str] = set()

    # full topic name + underscore-separated parts
    candidates = [topic_name]
    parts = topic_name.split("_")
    if len(parts) > 1:
        candidates.extend(parts)

    for candidate in candidates:
        normalized = normalize_topic(candidate)
        for pid in norm_to_pids.get(normalized, []):
            if pid not in seen:
                matched.append(pid)
                seen.add(pid)

    return matched


def _match_by_category(topic_name: str, cat_to_pids: dict[str, list[str]]) -> list[str]:
    """Strategy 2: parent_category で照合。"""
    parent_cat = get_parent_category(topic_name)
    if parent_cat == "その他":
        return []
    return list(dict.fromkeys(cat_to_pids.get(parent_cat, [])))


def _match_by_keyword(topic_name: str, problems: dict) -> list[str]:
    """Strategy 3: topic名のキーワードで問題titleを部分一致検索。"""
    parts = topic_name.split("_")
    keywords = [p for p in parts if len(p) >= 2]
    if not keywords:
        keywords = [topic_name]

    matched: list[str] = []
    seen: set[str] = set()
    for pid, prob in problems.items():
        title = prob.get("title", "")
        if any(kw in title for kw in keywords):
            if pid not in seen:
                matched.append(pid)
                seen.add(pid)
    return matched


def build_topic_problem_map(
    vault_root: Path | str,
    problems_master_path: Path | str | None = None,
) -> dict:
    """論点→問題マッピングを構築する。

    Returns:
        dict with keys: mappings, stats
    """
    vp = VaultPaths(vault_root)

    if problems_master_path is None:
        problems_master_path = vp.export / "problems_master.json"

    with open(problems_master_path, encoding="utf-8") as f:
        master = json.load(f)
    problems = master.get("problems", {})

    norm_to_pids, cat_to_pids = _build_reverse_indexes(problems)

    mappings: dict[str, list[str]] = {}
    unmapped: list[str] = []
    total_topics = 0

    topic_root = vp.topics
    if not topic_root.exists():
        return {"mappings": {}, "stats": {"total_topics": 0, "mapped": 0, "unmapped_topics": [], "coverage_pct": 0}}

    for md in sorted(topic_root.rglob("*.md")):
        if md.name in ("README.md", "CLAUDE.md"):
            continue

        try:
            fm, _ = read_frontmatter(md)
        except Exception:
            continue

        if not fm or not isinstance(fm, dict):
            continue

        rel = md.relative_to(topic_root).as_posix()
        topic_id = rel[:-3] if rel.endswith(".md") else rel
        topic_name = str(fm.get("topic", "") or "").strip()

        if not topic_name:
            continue

        total_topics += 1

        # 3段階フォールバック
        matched = _match_by_normalized(topic_name, norm_to_pids)
        if not matched:
            matched = _match_by_category(topic_name, cat_to_pids)
        if not matched:
            matched = _match_by_keyword(topic_name, problems)

        if matched:
            mappings[topic_id] = matched
        else:
            unmapped.append(topic_id)

    mapped = total_topics - len(unmapped)
    coverage_pct = round(mapped / total_topics * 100) if total_topics > 0 else 0

    return {
        "mappings": mappings,
        "stats": {
            "total_topics": total_topics,
            "mapped": mapped,
            "unmapped_topics": unmapped,
            "coverage_pct": coverage_pct,
        },
    }


def save_topic_problem_map(
    vault_root: Path | str,
    problems_master_path: Path | str | None = None,
) -> dict:
    """マッピングを構築し、JSONファイルに保存する。"""
    result = build_topic_problem_map(vault_root, problems_master_path)
    vp = VaultPaths(vault_root)
    output_path = vp.export / "topic_problem_map.json"
    atomic_json_write(output_path, result)
    return result


def load_topic_problem_map(vault_root: Path | str) -> dict:
    """保存済みマッピングをロードする。"""
    vp = VaultPaths(vault_root)
    map_path = vp.export / "topic_problem_map.json"
    if not map_path.exists():
        return {"mappings": {}, "stats": {}}
    with open(map_path, encoding="utf-8") as f:
        return json.load(f)
