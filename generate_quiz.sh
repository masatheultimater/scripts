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
LIMIT_ARG="${DEFAULT_QUIZ_LIMIT:-20}"

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

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VAULT DATE_ARG LIMIT_ARG PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

# ファイルロック（並行実行対策）
LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; exit 1; }

# Step 1: topic_problem_map.json を生成/更新
python3 -c "
from lib.topic_problem_map import save_topic_problem_map
import os
result = save_topic_problem_map(os.environ['VAULT'])
stats = result['stats']
print(f'マッピング更新: {stats[\"mapped\"]}/{stats[\"total_topics\"]}トピック ({stats[\"coverage_pct\"]}%)')
"

# Step 2: SRS選出 + today_problems.json 生成
python3 - <<'PY'
import json
import os
import random
from datetime import date, datetime, timedelta
from pathlib import Path
from collections import Counter

from lib.houjinzei_common import (
    VaultPaths,
    INTERVAL_DAYS,
    atomic_json_write,
    eprint,
    parse_date,
    read_frontmatter,
    to_int,
)
from lib.topic_problem_map import load_topic_problem_map

DATE_ARG = os.environ.get("DATE_ARG", "").strip()
LIMIT = int(os.environ["LIMIT_ARG"])

vp = VaultPaths(os.environ["VAULT"])
TOPIC_ROOT = vp.topics
TODAY_OUTPUT = vp.export / "today_problems.json"
COMPAT_OUTPUT = vp.export / "komekome_import.json"

# ── Load mapping + problems ──
topic_map = load_topic_problem_map(os.environ["VAULT"])
mappings = topic_map.get("mappings", {})

master_path = vp.export / "problems_master.json"
if master_path.exists():
    with open(master_path, encoding="utf-8") as f:
        problems_db = json.load(f).get("problems", {})
else:
    problems_db = {}


def parse_frontmatter(md_path: Path) -> dict:
    try:
        fm, _ = read_frontmatter(md_path)
        return fm
    except Exception:
        return {}


if not TOPIC_ROOT.exists():
    eprint(f"エラー: 論点ディレクトリが見つかりません: {TOPIC_ROOT}")
    raise SystemExit(1)

base_date = date.today() if not DATE_ARG else parse_date(DATE_ARG)

records = []
for md in sorted(TOPIC_ROOT.rglob("*.md")):
    if md.name in ("README.md", "CLAUDE.md"):
        continue
    fm = parse_frontmatter(md)
    if not fm:
        continue

    topic_name = str(fm.get("topic", "") or "").strip() or md.stem
    category = str(fm.get("category", "") or "").strip()
    importance = str(fm.get("importance", "") or "").strip()
    stage = str(fm.get("stage", "") or "").strip()
    last_practiced_raw = fm.get("last_practiced")
    status = str(fm.get("status", "") or "").strip()

    last_practiced = None
    if last_practiced_raw is not None:
        if isinstance(last_practiced_raw, date):
            last_practiced = last_practiced_raw
        else:
            try:
                last_practiced = parse_date(str(last_practiced_raw))
            except ValueError:
                last_practiced = None

    rel = md.relative_to(TOPIC_ROOT).as_posix()
    topic_id = rel[:-3] if rel.endswith(".md") else rel

    interval_index = to_int(fm.get("interval_index", 0))

    # マッピングなしの論点はスキップ
    if topic_id not in mappings:
        continue

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
            "interval_index": interval_index,
        }
    )


# 卒業済み論点: 30日以上経過したものだけ定期復習対象として残す
GRADUATION_REVIEW_DAYS = 30
active_records = []
graduated_review = []
for r in records:
    if r["status"] == "卒業":
        if r["last_practiced"] is not None:
            gap = (base_date - r["last_practiced"]).days
            if gap >= GRADUATION_REVIEW_DAYS:
                graduated_review.append(r)
    else:
        active_records.append(r)
records = active_records


def review_due(days: int):
    cutoff = base_date - timedelta(days=days)
    return [r for r in records if r["last_practiced"] is not None
            and r["last_practiced"] <= cutoff]


def interval_review_due():
    due = []
    for r in records:
        idx = r["interval_index"]
        if idx < 0 or idx >= len(INTERVAL_DAYS):
            continue
        if r["last_practiced"] is None:
            continue
        required_days = INTERVAL_DAYS[idx]
        if r["last_practiced"] <= base_date - timedelta(days=required_days):
            due.append(r)
    return due


selected = []
selected_ids = set()

MAX_CATEGORY_RATIO = 0.4
category_count = Counter()


def add_priority_balanced(selected, selected_ids, candidates, reason):
    max_per_cat = max(2, int(LIMIT * MAX_CATEGORY_RATIO))
    random.shuffle(candidates)
    for r in candidates:
        if len(selected) >= LIMIT:
            break
        if r["topic_id"] in selected_ids:
            continue
        cat = r["category"]
        if category_count[cat] >= max_per_cat:
            continue
        selected.append({**r, "reason": reason})
        selected_ids.add(r["topic_id"])
        category_count[cat] += 1


# ---- 優先度0: 卒業後定期復習 (最大2問) ----
if graduated_review:
    random.shuffle(graduated_review)
    for r in graduated_review[:2]:
        if len(selected) < LIMIT and r["topic_id"] not in selected_ids:
            selected.append({**r, "reason": "卒業後復習"})
            selected_ids.add(r["topic_id"])
            category_count[r["category"]] += 1

# ---- 優先度1: needs_focus (連続不正解トピック) ----
needs_focus = [
    r for r in records
    if r["calc_wrong"] >= 2
    and r["calc_wrong"] > r["calc_correct"]
    and r["stage"] in ("学習中", "復習中")
]
add_priority_balanced(selected, selected_ids, needs_focus, "弱点集中")

# ---- 優先度1.5: 失効検出 (期日7日以上超過) ----
lapsed = []
for r in records:
    if r["last_practiced"] is None or r["interval_index"] < 0:
        continue
    idx = r["interval_index"]
    if idx >= len(INTERVAL_DAYS):
        continue
    required_days = INTERVAL_DAYS[idx]
    overdue = (base_date - r["last_practiced"]).days - required_days
    if overdue >= 7:
        lapsed.append((overdue, r))
lapsed.sort(key=lambda x: -x[0])
add_priority_balanced(selected, selected_ids, [r for _, r in lapsed], "失効復習")

# ---- 優先度2: interval_index ベース復習 ----
interval_due = interval_review_due()
if interval_due:
    interval_due.sort(key=lambda r: r["interval_index"], reverse=True)
    add_priority_balanced(selected, selected_ids, interval_due, "間隔復習")

# ---- 優先度3: レガシー復習 ----
add_priority_balanced(selected, selected_ids, review_due(3), "3日後復習")
add_priority_balanced(selected, selected_ids, review_due(7), "7日後復習")
add_priority_balanced(selected, selected_ids, review_due(14), "14日後復習")
add_priority_balanced(selected, selected_ids, review_due(28), "28日後復習")

# ---- 優先度4: 弱点補強 ----
add_priority_balanced(
    selected, selected_ids,
    [r for r in records if r["stage"] in ("学習中", "復習中") and r["calc_wrong"] > r["calc_correct"]],
    "弱点補強",
)

# ---- 優先度5: 新規A論点 ----
add_priority_balanced(
    selected, selected_ids,
    [r for r in records if r["stage"] == "未着手" and r["importance"] == "A"],
    "新規A論点",
)

# ---- 優先度6: 新規B論点 ----
add_priority_balanced(
    selected, selected_ids,
    [r for r in records if r["stage"] == "未着手" and r["importance"] == "B"],
    "新規B論点",
)

# ── 出力: today_problems.json ──
total_problems = 0
topics_out = []
for s in selected:
    tid = s["topic_id"]
    problem_ids = mappings.get(tid, [])
    problems_out = []
    for pid in problem_ids:
        prob = problems_db.get(pid)
        if not prob:
            continue
        problems_out.append({
            "problem_id": pid,
            "book": prob.get("book", ""),
            "number": prob.get("number", ""),
            "page": prob.get("page", 0),
            "rank": prob.get("rank", ""),
            "type": prob.get("type", ""),
            "title": prob.get("title", ""),
            "time_min": prob.get("time_min", 0),
            "page_image_key": f"{prob.get('book', '')}/{prob.get('page', 0):03d}.webp" if prob.get("page") else None,
        })
    total_problems += len(problems_out)
    topics_out.append({
        "topic_id": tid,
        "topic_name": s["topic_name"],
        "category": s["category"],
        "reason": s["reason"],
        "interval_index": s["interval_index"],
        "importance": s["importance"],
        "problems": problems_out,
    })

TODAY_OUTPUT.parent.mkdir(parents=True, exist_ok=True)

payload = {
    "generated_date": base_date.strftime("%Y-%m-%d"),
    "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "total_topics": len(topics_out),
    "total_problems": total_problems,
    "topics": topics_out,
}

atomic_json_write(TODAY_OUTPUT, payload)

# 後方互換: 空の komekome_import.json を生成
compat_payload = {
    "generated_date": base_date.strftime("%Y-%m-%d"),
    "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "total": 0,
    "questions": [],
    "note": "Deprecated: use today_problems.json instead",
}
atomic_json_write(COMPAT_OUTPUT, compat_payload)

reason_count = Counter(t["reason"] for t in topics_out)
print(f"生成完了: {TODAY_OUTPUT}")
print(f"基準日: {base_date.strftime('%Y-%m-%d')}")
print(f"論点数: {len(topics_out)} / 上限 {LIMIT}")
print(f"問題数: {total_problems}")
if reason_count:
    print("内訳:")
    for reason, cnt in reason_count.items():
        print(f"  {reason}: {cnt}")
else:
    print("内訳: 対象なし")
PY

# Cloudflare Workers同期（失敗してもquiz生成は成功扱い）
SYNC_SCRIPT="$SCRIPTS_DIR/komekome_sync.sh"
if [[ -f "$SYNC_SCRIPT" ]]; then
  for cmd in push push-today push-topics; do
    if ! bash "$SYNC_SCRIPT" "$cmd" 2>&1; then
      echo "⚠️  sync $cmd 失敗（quiz生成は成功済み）" >&2
    fi
  done
else
  echo "⚠️  komekome_sync.sh が見つかりません: $SYNC_SCRIPT" >&2
fi
