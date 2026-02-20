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

python3 - <<'PY'
import json
import os
from datetime import date, datetime, timedelta
from pathlib import Path
from collections import Counter

from lib.houjinzei_common import (
    VaultPaths,
    INTERVAL_DAYS,
    eprint,
    extract_body_sections,
    parse_date,
    read_frontmatter,
    to_int,
)

DATE_ARG = os.environ.get("DATE_ARG", "").strip()
LIMIT = int(os.environ["LIMIT_ARG"])

vp = VaultPaths(os.environ["VAULT"])
TOPIC_ROOT = vp.topics
OUTPUT_PATH = vp.export / "komekome_import.json"


def parse_frontmatter(md_path: Path) -> dict:
    try:
        fm, _ = read_frontmatter(md_path)
        return fm
    except Exception:
        return {}


def extract_body(md_path: Path) -> dict:
    """論点ノートの本文から各セクションを抽出する。"""
    _, body = read_frontmatter(md_path)
    return extract_body_sections(body)


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
    topic_type = fm.get("type", [])
    if isinstance(topic_type, str):
        topic_type = [topic_type]
    sources = fm.get("sources", [])
    if isinstance(sources, str):
        sources = [sources]
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

    body = extract_body(md)

    # 本文が空テンプレートのノートはスキップ（出題しても意味がない）
    if not body["summary"] and not body["mistakes"]:
        eprint(f"  スキップ（空テンプレート）: {topic_name}")
        continue

    records.append(
        {
            "topic_id": topic_id,
            "topic_name": topic_name,
            "category": category,
            "importance": importance,
            "type": topic_type,
            "sources": sources,
            "stage": stage,
            "status": status,
            "last_practiced": last_practiced,
            "calc_correct": to_int(fm.get("calc_correct", 0)),
            "calc_wrong": to_int(fm.get("calc_wrong", 0)),
            "kome_total": to_int(fm.get("kome_total", 0)),
            "interval_index": interval_index,
            "display_name": body["display_name"],
            "summary": body["summary"],
            "steps": body["steps"],
            "judgment": body["judgment"],
            "mistakes": body["mistakes"],
            "mistake_items": body["mistake_items"],
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
            "type": r["type"],
            "sources": r["sources"],
            "reason": reason,
            "calc_correct": r["calc_correct"],
            "calc_wrong": r["calc_wrong"],
            "intervalIndex": r["interval_index"],
            "display_name": r["display_name"],
            "summary": r["summary"],
            "steps": r["steps"],
            "judgment": r["judgment"],
            "mistakes": r["mistakes"],
            "mistake_items": r["mistake_items"],
        }
        selected.append(item)
        selected_ids.add(r["topic_id"])


def review_due(days: int):
    """last_practiced から days 日以上経過した論点を返す。"""
    cutoff = base_date - timedelta(days=days)
    return [r for r in records if r["last_practiced"] is not None
            and r["last_practiced"] <= cutoff]


def interval_review_due():
    """interval_index ベースで復習期日に達した論点を返す。

    interval_index に対応する INTERVAL_DAYS の日数が last_practiced から
    経過していれば復習対象。interval_index が範囲外（未設定含む）の場合は
    レガシーロジックに委ねるためスキップ。
    """
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

add_priority(
    selected,
    selected_ids,
    [r for r in records if r["stage"] == "未着手" and r["importance"] == "A"],
    "新規A論点",
)

# interval_index ベース復習（優先）
interval_due = interval_review_due()
if interval_due:
    interval_due.sort(key=lambda r: r["interval_index"], reverse=True)
    add_priority(selected, selected_ids, interval_due, "間隔復習")

# レガシー復習（interval_index 未設定のノート向け、>= で取りこぼし防止）
add_priority(selected, selected_ids, review_due(3), "3日後復習")
add_priority(selected, selected_ids, review_due(7), "7日後復習")
add_priority(selected, selected_ids, review_due(14), "14日後復習")
add_priority(selected, selected_ids, review_due(28), "28日後復習")

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
    "generated_date": base_date.strftime("%Y-%m-%d"),
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

# Cloudflare Workers同期（失敗してもquiz生成は成功扱い）
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPTS_DIR/komekome_sync.sh" ]] && bash "$SCRIPTS_DIR/komekome_sync.sh" push 2>&1 || true
