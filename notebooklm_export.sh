#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: bash notebooklm_export.sh [--type 理論|計算|all]
  --type: 論点タイプで絞り込みます。省略時は all（両方出力）。
USAGE
}

TYPE_FILTER="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --type の値が不足しています" >&2
        usage
        exit 1
      fi
      TYPE_FILTER="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "エラー: 不明な引数です: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$TYPE_FILTER" != "理論" && "$TYPE_FILTER" != "計算" && "$TYPE_FILTER" != "all" ]]; then
  echo "エラー: --type は 理論 / 計算 / all のいずれかを指定してください" >&2
  exit 1
fi

VAULT="${VAULT:-$HOME/vault/houjinzei}"
export VAULT TYPE_FILTER

python3 - <<'PY'
import json
import os
import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path

VAULT = Path(os.environ["VAULT"])
TYPE_FILTER = os.environ["TYPE_FILTER"]
TOPIC_DIR = VAULT / "10_論点"
OUTPUT_DIR = VAULT / "50_エクスポート"
TARGET_TYPES = ["理論", "計算"] if TYPE_FILTER == "all" else [TYPE_FILTER]


def eprint(msg: str) -> None:
    print(msg, file=os.sys.stderr)


def read_frontmatter_and_body(md_text: str):
    lines = md_text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, md_text

    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_idx = i
            break

    if end_idx is None:
        return {}, md_text

    fm_lines = lines[1:end_idx]
    body = "\n".join(lines[end_idx + 1 :]).strip()

    fm = {}
    for line in fm_lines:
        m = re.match(r"^([A-Za-z0-9_\-]+)\s*:\s*(.*)$", line.strip())
        if not m:
            continue
        key = m.group(1)
        value = m.group(2).strip()
        if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
            value = value[1:-1].strip()
        fm[key] = value

    return fm, body


def parse_type_array(raw_value: str):
    if not raw_value:
        return []
    try:
        parsed = json.loads(raw_value)
    except json.JSONDecodeError:
        return []

    if not isinstance(parsed, list):
        return []

    result = []
    for item in parsed:
        if isinstance(item, str):
            s = item.strip()
            if s:
                result.append(s)
    return result


def has_substantive_content(body: str) -> bool:
    for line in body.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("#"):
            continue
        if re.fullmatch(r"[-*_]{3,}", s):
            continue
        return True
    return False


if not TOPIC_DIR.exists():
    eprint(f"エラー: 論点ディレクトリが見つかりません: {TOPIC_DIR}")
    raise SystemExit(1)

all_topics = []
for md_path in sorted(TOPIC_DIR.rglob("*.md")):
    text = md_path.read_text(encoding="utf-8", errors="ignore")
    fm, body = read_frontmatter_and_body(text)

    type_values = parse_type_array(fm.get("type", ""))
    if not type_values:
        continue

    category = fm.get("category", "").strip() or "未分類"
    topic_name = fm.get("topic", "").strip() or md_path.stem

    all_topics.append(
        {
            "path": md_path,
            "types": type_values,
            "category": category,
            "topic": topic_name,
            "body": body,
        }
    )

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
summary = {}

for t in TARGET_TYPES:
    out_path = OUTPUT_DIR / f"notebooklm_{t}.md"
    matched = [x for x in all_topics if t in x["types"]]
    matched.sort(key=lambda x: (x["category"], x["topic"]))

    filtered = [x for x in matched if has_substantive_content(x["body"])]
    grouped = defaultdict(list)
    for item in filtered:
        grouped[item["category"]].append(item)

    lines = []
    lines.append(f"# 法人税法 {t} まとめ")
    lines.append("")
    lines.append(f"生成日時: {now_str}")
    lines.append("")
    lines.append("## 目次")
    lines.append("")

    if filtered:
        for category in sorted(grouped.keys()):
            lines.append(f"- {category}")
            for item in grouped[category]:
                lines.append(f"  - {item['topic']}")
    else:
        lines.append("- 対象トピックはありません")

    lines.append("")
    lines.append("## 本文")
    lines.append("")

    if filtered:
        current_category = None
        for item in filtered:
            if item["category"] != current_category:
                current_category = item["category"]
                lines.append(f"## {current_category}")
                lines.append("")

            lines.append(f"### {item['topic']}")
            lines.append("")
            lines.append(item["body"].rstrip())
            lines.append("")
            lines.append("---")
            lines.append("")
    else:
        lines.append("対象トピックはありません。")
        lines.append("")

    lines.append(f"総トピック数: {len(filtered)}")
    lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")
    summary[t] = {"count": len(filtered), "path": out_path}

print("NotebookLMエクスポートが完了しました。")
for t in ["理論", "計算"]:
    if t in summary:
        print(f"- {t}: {summary[t]['count']}件 -> {summary[t]['path']}")
PY
