#!/usr/bin/env bash
# ============================================================
# コメコメ Cloudflare Workers 同期スクリプト
# 使い方: bash komekome_sync.sh push|pull|push-topics|push-today|push-dashboard|push-schedule|pull-schedule|status
#   push        - komekome_import.json を Workers API にアップロード
#   pull        - Workers API から未処理結果をダウンロードし writeback 実行
#   push-topics - 充実済み論点ノートを Workers API にアップロード
#   push-today  - today_problems.json を Workers API にアップロード
#   push-dashboard - dashboard_data.json を Workers API にアップロード
#   push-schedule - weekly_schedule.json を Workers API にアップロード
#   pull-schedule - Workers API から weekly_schedule.json をダウンロード
#   status      - API のステータスを表示
# ============================================================

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${VAULT:-$HOME/vault/houjinzei}"
EXPORT_DIR="$VAULT/50_エクスポート"
CONF="$SCRIPTS_DIR/komekome_cf.conf"

if [[ ! -f "$CONF" ]]; then
  echo "エラー: 設定ファイルが見つかりません: $CONF" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONF"

# API_URL と API_TOKEN を検証
if [[ -z "${API_URL:-}" ]]; then
  echo "エラー: API_URL が設定されていません" >&2
  exit 1
fi

# トークンファイルから読み込み
TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/komekome/cf_token}"
if [[ -n "${API_TOKEN:-}" ]]; then
  : # conf に直接書かれている場合はそのまま
elif [[ -f "$TOKEN_FILE" ]]; then
  API_TOKEN="$(cat "$TOKEN_FILE")"
else
  echo "エラー: API_TOKEN が設定されていません（$CONF または $TOKEN_FILE）" >&2
  exit 1
fi

export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

usage() {
  echo "使い方: bash komekome_sync.sh push|pull|push-topics|push-today|push-dashboard|push-schedule|pull-schedule|status"
}

# ── push: problems_master.json → Workers API ──
do_push() {
  local master_file="$EXPORT_DIR/problems_master.json"
  if [[ ! -f "$master_file" ]]; then
    echo "エラー: $master_file が見つかりません" >&2
    return 1
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${API_URL}/api/komekome/problems" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: komekome-sync/1.0" \
    -d @"$master_file")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: push 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "push 完了: problems_master.json → Workers API ($now)"

  # 旧 import.json も互換のため push（存在する場合のみ）
  local import_file="$EXPORT_DIR/komekome_import.json"
  if [[ -f "$import_file" ]]; then
    curl -s -X POST \
      "${API_URL}/api/komekome/import" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "User-Agent: komekome-sync/1.0" \
      -d @"$import_file" > /dev/null 2>&1 || true
  fi

  # today_problems.json も push（存在する場合のみ）
  local today_file="$EXPORT_DIR/today_problems.json"
  if [[ -f "$today_file" ]]; then
    do_push_today || true
  fi
}

# ── pull: Workers API → results + writeback ──
do_pull() {
  # ファイルロック
  local LOCKFILE="/tmp/houjinzei_vault.lock"
  exec 200>"$LOCKFILE"
  flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; return 1; }

  local results_file="$EXPORT_DIR/komekome_results.json"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="$EXPORT_DIR/backup"
  mkdir -p "$backup_dir"

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 未処理結果を取得
  local response
  response=$(curl -s -w "\n%{http_code}" \
    "${API_URL}/api/komekome/result" \
    -H "Authorization: Bearer ${API_TOKEN}")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: pull 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  # Python で結果処理: マージ + writeback用ファイル生成
  python3 - "$body" "$results_file" "$backup_dir" "$timestamp" "$API_URL" "$API_TOKEN" <<'PYEOF'
import json, sys, urllib.request

body_str, results_file, backup_dir, timestamp, api_url, api_token = sys.argv[1:7]

data = json.loads(body_str)
all_results = data.get('results', [])

if not all_results:
    print("pull: 未処理の結果なし（スキップ）")
    sys.exit(0)

# 全セッションの results を1つにマージ
merged_results = []
session_ids = []
for session in all_results:
    session_ids.append(session.get('session_id', ''))
    for r in session.get('results', []):
        merged_results.append(r)

if not merged_results:
    print("pull: 未処理の結果なし（スキップ）")
    sys.exit(0)

# writeback 用のフォーマットに変換
merged_data = {
    "session_date": all_results[-1].get('session_date'),
    "session_id": all_results[-1].get('session_id'),
    "results": merged_results,
}

# バックアップ保存
backup_path = f"{backup_dir}/komekome_results_{timestamp}.json"
with open(backup_path, 'w', encoding='utf-8') as f:
    json.dump(merged_data, f, ensure_ascii=False, indent=2)

# メインファイル保存
with open(results_file, 'w', encoding='utf-8') as f:
    json.dump(merged_data, f, ensure_ascii=False, indent=2)

print(f"pull: {len(merged_results)}件の結果を取得")

# 処理済みマークを設定
for sid in session_ids:
    if not sid:
        continue
    url = f"{api_url}/api/komekome/result/{sid}/processed"
    req = urllib.request.Request(url, method='PUT',
        headers={'Authorization': f'Bearer {api_token}', 'Content-Type': 'application/json',
                 'User-Agent': 'komekome-sync/1.0'},
        data=b'{}')
    try:
        urllib.request.urlopen(req)
    except Exception as e:
        print(f"警告: processed マーク失敗 ({sid}): {e}", file=sys.stderr)

print(f"pull: {len(session_ids)}セッションを処理済みにマーク")
PYEOF

  local py_exit=$?
  if [[ $py_exit -ne 0 ]]; then
    return 0  # "スキップ" の場合
  fi

  # results_file が存在する場合のみ writeback 実行
  if [[ -f "$results_file" ]]; then
    HOUJINZEI_LOCK_HELD=1 bash "$SCRIPTS_DIR/komekome_writeback.sh" "$results_file"
    echo "pull 完了: writeback 実行済み ($now)"
  fi

  # Pull schedule
  do_pull_schedule || true
}

# ── status: API ステータス表示 ──
do_status() {
  echo "=== コメコメ Workers API 同期ステータス ==="
  echo "API_URL: $API_URL"
  echo ""

  # import 状態を確認
  local import_resp
  import_resp=$(curl -s \
    "${API_URL}/api/komekome/import" \
    -H "Authorization: Bearer ${API_TOKEN}")

  echo "import データ:"
  echo "$import_resp" | python3 -c "
import json, sys
data = json.load(sys.stdin)
questions = data.get('questions', [])
date = data.get('generated_date', '不明')
print(f'  生成日: {date}')
print(f'  問題数: {len(questions)}')
"

  echo ""

  # 未処理結果を確認
  local result_resp
  result_resp=$(curl -s \
    "${API_URL}/api/komekome/result" \
    -H "Authorization: Bearer ${API_TOKEN}")

  echo "未処理 results:"
  echo "$result_resp" | python3 -c "
import json, sys
data = json.load(sys.stdin)
results = data.get('results', [])
total = sum(len(r.get('results', [])) for r in results)
print(f'  セッション数: {len(results)}')
print(f'  総件数: {total}')
"
}

# ── push-topics: 充実済み論点ノート → Workers API ──
do_push_topics() {
  local topics_file="$EXPORT_DIR/topics_data.json"

  python3 - "$VAULT" "$topics_file" <<'PYEOF'
import json
import sys
from datetime import datetime
from pathlib import Path

from lib.houjinzei_common import read_frontmatter, extract_body_sections

vault_root = Path(sys.argv[1])
output_path = Path(sys.argv[2])
notes_root = vault_root / "10_論点"

topics = []
categories = set()

for path in sorted(notes_root.rglob("*.md")):
    if path.name in ("README.md", "CLAUDE.md"):
        continue

    try:
        fm, body = read_frontmatter(path)
    except Exception:
        continue

    if not fm or not isinstance(fm, dict):
        continue

    # 空テンプレートはスキップ（本文200文字未満）
    body_stripped = body.strip()
    if len(body_stripped) < 200:
        continue

    sections = extract_body_sections(body)
    # summaryが空なら充実されていない
    if not sections.get("summary"):
        continue

    rel = path.relative_to(notes_root).as_posix()
    topic_id = rel[:-3] if rel.endswith(".md") else rel
    category = fm.get("category", "その他")
    categories.add(category)

    topics.append({
        "topic_id": topic_id,
        "topic": fm.get("topic", ""),
        "category": category,
        "subcategory": fm.get("subcategory", ""),
        "type": fm.get("type", []),
        "importance": fm.get("importance", ""),
        "keywords": fm.get("keywords", []),
        "conditions": fm.get("conditions", []),
        "status": fm.get("status", "未着手"),
        "kome_total": fm.get("kome_total", 0),
        "interval_index": fm.get("interval_index", 0),
        "display_name": sections.get("display_name", ""),
        "summary": sections.get("summary", ""),
        "steps": sections.get("steps", ""),
        "judgment": sections.get("judgment", ""),
        "mistakes": sections.get("mistakes", ""),
        "mistake_items": sections.get("mistake_items", []),
        "related": fm.get("related", []),
        "statutes": sections.get("statutes", ""),
    })

data = {
    "version": 1,
    "generated": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "total": len(topics),
    "categories": sorted(categories),
    "topics": topics,
}

output_path.parent.mkdir(parents=True, exist_ok=True)
with open(output_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)

print(f"topics_data.json 生成: {len(topics)}件 ({len(categories)}カテゴリ)")
PYEOF

  if [[ ! -f "$topics_file" ]]; then
    echo "エラー: topics_data.json の生成に失敗しました" >&2
    return 1
  fi

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${API_URL}/api/komekome/topics" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: komekome-sync/1.0" \
    -d @"$topics_file")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: push-topics 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "push-topics 完了: topics_data.json → Workers API"
}

# ── push-today: today_problems.json → Workers API ──
do_push_today() {
  local today_file="$EXPORT_DIR/today_problems.json"
  if [[ ! -f "$today_file" ]]; then
    echo "エラー: $today_file が見つかりません" >&2
    return 1
  fi

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${API_URL}/api/komekome/today" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: komekome-sync/1.0" \
    -d @"$today_file")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: push-today 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "push-today 完了: today_problems.json → Workers API"
}

# ── push-dashboard: dashboard_data.json → Workers API ──
do_push_dashboard() {
  local dashboard_file="$EXPORT_DIR/dashboard_data.json"
  if [[ ! -f "$dashboard_file" ]]; then
    echo "エラー: $dashboard_file が見つかりません" >&2
    return 1
  fi

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${API_URL}/api/komekome/dashboard" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: komekome-sync/1.0" \
    -d @"$dashboard_file")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: push-dashboard 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "push-dashboard 完了: dashboard_data.json → Workers API"
}

# ── push-schedule: weekly_schedule.json → Workers API ──
do_push_schedule() {
  local schedule_file="$EXPORT_DIR/weekly_schedule.json"
  if [[ ! -f "$schedule_file" ]]; then
    echo "エラー: $schedule_file が見つかりません" >&2
    return 1
  fi

  local response
  response=$(curl -s -w "\n%{http_code}" -X PUT \
    "${API_URL}/api/komekome/schedule" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "User-Agent: komekome-sync/1.0" \
    -d @"$schedule_file")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: push-schedule 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "push-schedule 完了: weekly_schedule.json → Workers API"
}

# ── pull-schedule: Workers API → weekly_schedule.json ──
do_pull_schedule() {
  local schedule_file="$EXPORT_DIR/weekly_schedule.json"

  local response
  response=$(curl -s -w "\n%{http_code}" \
    "${API_URL}/api/komekome/schedule" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "User-Agent: komekome-sync/1.0")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: pull-schedule 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "$body" > "$schedule_file"
  echo "pull-schedule 完了: Workers API → weekly_schedule.json"
}

# ── main ──
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  push)        do_push ;;
  pull)        do_pull ;;
  push-topics) do_push_topics ;;
  push-today)  do_push_today ;;
  push-dashboard) do_push_dashboard ;;
  push-schedule) do_push_schedule ;;
  pull-schedule) do_pull_schedule ;;
  status)      do_status ;;
  *)
    echo "エラー: 不明なコマンド: $1" >&2
    usage
    exit 1
    ;;
esac
