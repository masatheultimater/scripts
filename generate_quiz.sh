#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: bash generate_quiz.sh [--date YYYY-MM-DD] [--limit N]
  --date   基準日 (例: 2026-02-17)。省略時は本日。
  --limit  出題数上限。省略時は 20。
USAGE
}

DATE_ARG=""
LIMIT_ARG="20"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --date の値が不足しています" >&2
        usage
        exit 1
      fi
      DATE_ARG="$2"
      shift 2
      ;;
    --limit)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --limit の値が不足しています" >&2
        usage
        exit 1
      fi
      LIMIT_ARG="$2"
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

if ! [[ "$LIMIT_ARG" =~ ^[0-9]+$ ]]; then
  echo "エラー: --limit は 0 以上の整数で指定してください" >&2
  exit 1
fi

VAULT="${HOME}/vault/houjinzei"
export VAULT DATE_ARG LIMIT_ARG

python3 - <<'PY'
import json
import os
import re
from datetime import date, datetime, timedelta
from pathlib import Path
from collections import Counter

VAULT = Path(os.environ["VAULT"])
DATE_ARG = os.environ.get("DATE_ARG", "").strip()
LIMIT = int(os.environ["LIMIT_ARG"])

TOPIC_ROOT = VAULT / "10_論点"
OUTPUT_PATH = VAULT / "50_エクスポート" / "komekome_import.json"


def eprint(msg: str) -> None:
    print(msg, file=os.sys.stderr)


def parse_date(s: str) -> date:
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise ValueError(f"日付形式エラー: {s} (YYYY-MM-DD で指定してください)")


def unquote(v: str) -> str:
    v = v.strip()
    if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
        return v[1:-1].strip()
    return v


def parse_frontmatter(md_path: Path) -> dict:
    text = md_path.read_text(encoding="utf-8", errors="ignore")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}

    fm = {}
    for i in range(1, len(lines)):
        line = lines[i]
        if line.strip() == "---":
            break
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z0-9_\-]+)\s*:\s*(.*)$", line)
        if not m:
            continue
        key = m.group(1).strip()
        value = unquote(m.group(2))
        fm[key] = value
    return fm


def to_int(v: str) -> int:
    try:
        return int(str(v).strip())
    except Exception:
        return 0


if not TOPIC_ROOT.exists():
    eprint(f"エラー: 論点ディレクトリが見つかりません: {TOPIC_ROOT}")
    raise SystemExit(1)

base_date = date.today() if not DATE_ARG else parse_date(DATE_ARG)

records = []
for md in sorted(TOPIC_ROOT.rglob("*.md")):
    fm = parse_frontmatter(md)
    if not fm:
        continue

    topic_name = fm.get("topic", "").strip() or md.stem
    category = fm.get("category", "").strip()
    importance = fm.get("importance", "").strip()
    stage = fm.get("stage", "").strip()
    last_practiced_raw = fm.get("last_practiced", "").strip()
    status = fm.get("status", "").strip()

    last_practiced = None
    if last_practiced_raw:
        try:
            last_practiced = parse_date(last_practiced_raw)
        except ValueError:
            last_practiced = None

    rel = md.relative_to(TOPIC_ROOT).as_posix()
    topic_id = rel[:-3] if rel.endswith(".md") else rel

    records.append(
        {
            "topic_id": topic_id,
            "topic_name": topic_name,
            "category": category,
            "importance": importance,
            "stage": stage,
            "status": status,
            "last_practiced": last_practiced,
            "calc_correct": to_int(fm.get("calc_correct", 0)),
            "calc_wrong": to_int(fm.get("calc_wrong", 0)),
            "kome_total": to_int(fm.get("kome_total", 0)),
        }
    )


# 卒業済み論点を出題候補から除外
records = [r for r in records if r["status"] != "卒業"]


def add_priority(selected, selected_ids, candidates, reason):
    for r in candidates:
        if len(selected) >= LIMIT:
            break
        if r["topic_id"] in selected_ids:
            continue
        item = {
            "topic_id": r["topic_id"],
            "topic_name": r["topic_name"],
            "category": r["category"],
            "importance": r["importance"],
            "reason": reason,
            "calc_correct": r["calc_correct"],
            "calc_wrong": r["calc_wrong"],
        }
        selected.append(item)
        selected_ids.add(r["topic_id"])


def due_days_ago(days: int):
    target = base_date - timedelta(days=days)
    return [r for r in records if r["last_practiced"] == target]


selected = []
selected_ids = set()

add_priority(
    selected,
    selected_ids,
    [r for r in records if r["stage"] == "未着手" and r["importance"] == "A"],
    "新規A論点",
)
add_priority(selected, selected_ids, due_days_ago(3), "3日後復習")
add_priority(selected, selected_ids, due_days_ago(7), "7日後復習")
add_priority(selected, selected_ids, due_days_ago(14), "14日後復習")
add_priority(selected, selected_ids, due_days_ago(28), "28日後復習")
add_priority(
    selected,
    selected_ids,
    [
        r
        for r in records
        if r["stage"] == "学習中" and r["calc_wrong"] > r["calc_correct"]
    ],
    "弱点補強",
)
add_priority(
    selected,
    selected_ids,
    [r for r in records if r["stage"] == "未着手" and r["importance"] == "B"],
    "新規B論点",
)

OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)

payload = {
    "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "total": len(selected),
    "questions": selected,
}

OUTPUT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")

reason_count = Counter(q["reason"] for q in selected)
print(f"生成完了: {OUTPUT_PATH}")
print(f"基準日: {base_date.strftime('%Y-%m-%d')}")
print(f"総問題数: {len(selected)} / 上限 {LIMIT}")
if reason_count:
    print("内訳:")
    for reason, cnt in reason_count.items():
        print(f"- {reason}: {cnt}")
else:
    print("内訳: 対象なし")
PY
