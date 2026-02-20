"""problems_master.json に正規化情報を付与して再生成する。"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from lib.houjinzei_common import atomic_json_write
from lib.topic_normalize import get_parent_category, normalize_topic

DUPLICATE_GROUP_BY_ID = {
    "theory-039": "dup-交換差益圧縮記帳",
    "theory-094": "dup-交換差益圧縮記帳",
    "theory-020": "dup-資産評価損益",
    "theory-087": "dup-資産評価損益",
    "theory-068": "dup-適格組織再編欠損金",
    "theory-096": "dup-適格組織再編欠損金",
}


DEFAULT_MASTER_PATH = Path("/home/masa/vault/houjinzei/50_エクスポート/problems_master.json")


def normalize_problems(master_path: Path, output_path: Path) -> dict:
    data = json.loads(master_path.read_text(encoding="utf-8"))
    problems = data.get("problems", {})

    for pid, problem in problems.items():
        topics = problem.get("topics") or []
        normalized_topics = [normalize_topic(topic) for topic in topics]
        parent_category = get_parent_category(normalized_topics[0]) if normalized_topics else "その他"

        problem["normalized_topics"] = normalized_topics
        problem["parent_category"] = parent_category
        problem["duplicate_group"] = DUPLICATE_GROUP_BY_ID.get(pid)

    atomic_json_write(output_path, data, indent=2)
    return data


def parse_args() -> argparse.Namespace:
    default_path = DEFAULT_MASTER_PATH
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=Path,
        default=default_path,
        help=f"入力 problems_master.json (default: {default_path})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=default_path,
        help="出力先 JSON (default: 入力ファイルを上書き)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    out = normalize_problems(args.input, args.output)
    print(f"normalized: {len(out.get('problems', {}))} problems -> {args.output}")


if __name__ == "__main__":
    main()
