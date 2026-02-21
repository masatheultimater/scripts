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
from datetime import date, datetime, timedelta
from pathlib import Path
from collections import Counter

from lib.houjinzei_common import (
    VaultPaths,
    CARRYOVER_EXPIRY_DAYS,
    INTERVAL_DAYS,
    MAX_CARRYOVER,
    MAX_DAILY_PROBLEMS,
    atomic_json_write,
    eprint,
    parse_date,
    read_frontmatter,
    to_int,
)
from lib.learning_efficiency import (
    build_category_dashboard,
    calc_priority_score,
    get_frequency_score,
    is_focus_active,
    parse_dt_or_none,
)
from lib.quiz_generation import (
    add_priority_balanced_with_problem_cap,
    build_carryover_topics,
)
from lib.topic_problem_map import load_topic_problem_map

DATE_ARG = os.environ.get("DATE_ARG", "").strip()
LIMIT = int(os.environ["LIMIT_ARG"])

vp = VaultPaths(os.environ["VAULT"])
TOPIC_ROOT = vp.topics
TODAY_OUTPUT = vp.export / "today_problems.json"
COMPAT_OUTPUT = vp.export / "komekome_import.json"
DASHBOARD_OUTPUT = vp.export / "dashboard_data.json"
RESULTS_OUTPUT = vp.export / "komekome_results.json"

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


def load_json_or_default(path: Path, default):
    if not path.exists():
        return default
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return default


if not TOPIC_ROOT.exists():
    eprint(f"エラー: 論点ディレクトリが見つかりません: {TOPIC_ROOT}")
    raise SystemExit(1)

base_date = date.today() if not DATE_ARG else parse_date(DATE_ARG)
runtime_now = datetime.now()
base_datetime = runtime_now if not DATE_ARG else datetime.combine(base_date, runtime_now.time())

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
            "frequency_score": get_frequency_score(importance),
            "focus_until_at": fm.get("focus_until_at"),
        }
    )

all_records = list(records)

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
    due = []
    for r in records:
        if r["last_practiced"] is None or r["last_practiced"] > cutoff:
            continue
        overdue = max((base_date - r["last_practiced"]).days - days, 0)
        due.append({**r, "overdue_days": overdue})
    return due


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
            overdue = max((base_date - r["last_practiced"]).days - required_days, 0)
            due.append({**r, "overdue_days": overdue})
    return due


selected = []
selected_ids = set()

MAX_CATEGORY_RATIO = 0.4
category_count = Counter()
selection_stopped_by_problem_cap = False

previous_today = load_json_or_default(TODAY_OUTPUT, {})
results_data = load_json_or_default(RESULTS_OUTPUT, {})
carryover_topics, carryover_count = build_carryover_topics(
    previous_today=previous_today,
    results_data=results_data,
    base_date=base_date,
    max_carryover=MAX_CARRYOVER,
    expiry_days=CARRYOVER_EXPIRY_DAYS,
)

selected_problem_count = carryover_count
selected_topic_count = len(carryover_topics)


def add_priority_balanced(selected, selected_ids, candidates, reason, bucket, mappings):
    global selected_problem_count, selected_topic_count, selection_stopped_by_problem_cap
    if selection_stopped_by_problem_cap:
        return
    selected_problem_count, selected_topic_count, selection_stopped_by_problem_cap = add_priority_balanced_with_problem_cap(
        selected=selected,
        selected_ids=selected_ids,
        candidates=candidates,
        reason=reason,
        bucket=bucket,
        limit=LIMIT,
        max_category_ratio=MAX_CATEGORY_RATIO,
        category_count=category_count,
        mappings=mappings,
        current_problem_count=selected_problem_count,
        max_daily_problems=MAX_DAILY_PROBLEMS,
        selected_topic_count=selected_topic_count,
        priority_fn=lambda r, b: calc_priority_score(r, b, base_datetime),
    )


# ---- 優先度0: 卒業後定期復習 (最大2問) ----
if graduated_review:
    ordered_graduated = sorted(
        graduated_review,
        key=lambda r: (-calc_priority_score(r, 0, base_datetime), r["topic_id"]),
    )
    for r in ordered_graduated[:2]:
        if len(selected) >= LIMIT or selection_stopped_by_problem_cap:
            break
        if r["topic_id"] in selected_ids:
            continue
        topic_problem_count = len(mappings.get(r["topic_id"], []))
        if (
            selected_problem_count + topic_problem_count > MAX_DAILY_PROBLEMS
            and selected_topic_count > 0
        ):
            selection_stopped_by_problem_cap = True
            break
        if len(selected) < LIMIT and r["topic_id"] not in selected_ids:
            selected.append(
                {
                    **r,
                    "reason": "卒業後復習",
                    "priority_bucket": 0,
                    "priority_score": calc_priority_score(r, 0, base_datetime),
                }
            )
            selected_ids.add(r["topic_id"])
            category_count[r["category"]] += 1
            selected_problem_count += topic_problem_count
            selected_topic_count += 1

# ---- 優先度1: 弱点集中24h ----
focus_24h = [
    r for r in records
    if is_focus_active(r.get("focus_until_at"), base_datetime)
    and r["stage"] in ("学習中", "復習中")
]
add_priority_balanced(selected, selected_ids, focus_24h, "弱点集中24h", 1, mappings)

# ---- 優先度1.2: needs_focus (連続不正解トピック) ----
needs_focus = [
    r for r in records
    if r["calc_wrong"] >= 2
    and r["calc_wrong"] > r["calc_correct"]
    and r["stage"] in ("学習中", "復習中")
]
add_priority_balanced(selected, selected_ids, needs_focus, "弱点集中", 1.2, mappings)

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
        lapsed.append({**r, "overdue_days": overdue})
add_priority_balanced(selected, selected_ids, lapsed, "失効復習", 1.5, mappings)

# ---- 優先度2: interval_index ベース復習 ----
interval_due = interval_review_due()
if interval_due:
    add_priority_balanced(selected, selected_ids, interval_due, "間隔復習", 2, mappings)

# ---- 優先度3: レガシー復習 ----
add_priority_balanced(selected, selected_ids, review_due(3), "3日後復習", 3, mappings)
add_priority_balanced(selected, selected_ids, review_due(7), "7日後復習", 3, mappings)
add_priority_balanced(selected, selected_ids, review_due(14), "14日後復習", 3, mappings)
add_priority_balanced(selected, selected_ids, review_due(28), "28日後復習", 3, mappings)

# ---- 優先度4: 弱点補強 ----
add_priority_balanced(
    selected, selected_ids,
    [r for r in records if r["stage"] in ("学習中", "復習中") and r["calc_wrong"] > r["calc_correct"]],
    "弱点補強",
    4,
    mappings,
)

# ---- 優先度5: 新規A論点 ----
add_priority_balanced(
    selected, selected_ids,
    [r for r in records if r["stage"] == "未着手" and r["importance"] == "A"],
    "新規A論点",
    5,
    mappings,
)

# ---- 優先度6: 新規B論点 ----
add_priority_balanced(
    selected, selected_ids,
    [r for r in records if r["stage"] == "未着手" and r["importance"] == "B"],
    "新規B論点",
    6,
    mappings,
)

# ── 出力: today_problems.json ──
total_problems = carryover_count
topics_out = list(carryover_topics)


def focus_until_to_text(raw):
    dt = parse_dt_or_none(raw)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") if dt else None


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
    focus_until_at = focus_until_to_text(s.get("focus_until_at"))
    weak_focus_active = bool(
        focus_until_at
        and is_focus_active(focus_until_at, base_datetime)
        and s.get("stage") in ("学習中", "復習中")
    )
    topics_out.append({
        "topic_id": tid,
        "topic_name": s["topic_name"],
        "category": s["category"],
        "reason": s["reason"],
        "interval_index": s["interval_index"],
        "importance": s["importance"],
        "priority_bucket": s.get("priority_bucket"),
        "priority_score": s.get("priority_score", 0),
        "frequency_score": s.get("frequency_score", get_frequency_score(s.get("importance", ""))),
        "weak_focus": {
            "active": weak_focus_active,
            "until_at": focus_until_at,
            "trigger": "calc_wrong>=2",
        },
        "problems": problems_out,
    })

TODAY_OUTPUT.parent.mkdir(parents=True, exist_ok=True)

payload = {
    "generated_date": base_date.strftime("%Y-%m-%d"),
    "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "schema_version": 3,
    "selection_policy": "srs-v3-problemcap40-carryover",
    "dashboard_key": "learning_dashboard_v1",
    "carryover_count": carryover_count,
    "total_topics": len(topics_out),
    "total_problems": total_problems,
    "topics": topics_out,
}

atomic_json_write(TODAY_OUTPUT, payload)

dashboard_data = build_category_dashboard(all_records, datetime.now())
atomic_json_write(DASHBOARD_OUTPUT, dashboard_data)

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
print(f"繰越問題数: {carryover_count} / 上限 {MAX_CARRYOVER} (有効期限 {CARRYOVER_EXPIRY_DAYS}日)")
print(f"問題数: {total_problems} / 上限 {MAX_DAILY_PROBLEMS}")
print(f"ダッシュボード: {DASHBOARD_OUTPUT}")
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
  for cmd in push push-today push-topics push-dashboard; do
    if ! bash "$SYNC_SCRIPT" "$cmd" 2>&1; then
      echo "⚠️  sync $cmd 失敗（quiz生成は成功済み）" >&2
    fi
  done
else
  echo "⚠️  komekome_sync.sh が見つかりません: $SYNC_SCRIPT" >&2
fi

# Obsidianダッシュボード生成（失敗してもquiz生成は成功扱い）
DASHBOARD_SCRIPT="$SCRIPTS_DIR/dashboard.sh"
if [[ -f "$DASHBOARD_SCRIPT" ]]; then
  echo "ダッシュボード生成開始: $DASHBOARD_SCRIPT"
  bash "$DASHBOARD_SCRIPT" \
    && echo "ダッシュボード生成成功" \
    || { echo "⚠️  dashboard.sh 実行失敗（quiz生成は成功済み）" >&2; true; }
else
  echo "⚠️  dashboard.sh が見つかりません: $DASHBOARD_SCRIPT" >&2
fi
