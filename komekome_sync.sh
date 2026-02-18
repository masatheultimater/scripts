#!/usr/bin/env bash
# ============================================================
# コメコメ Gist 同期スクリプト
# 使い方: bash komekome_sync.sh push|pull|status
#   push   - komekome_import.json を Gist にアップロード
#   pull   - Gist から komekome_results.json をダウンロードし writeback 実行
#   status - meta.json を表示
# ============================================================

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${VAULT:-$HOME/vault/houjinzei}"
EXPORT_DIR="$VAULT/50_エクスポート"
CONF="$SCRIPTS_DIR/komekome_gist.conf"

if [[ ! -f "$CONF" ]]; then
  echo "エラー: 設定ファイルが見つかりません: $CONF" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONF"

if [[ -z "${GIST_ID:-}" ]]; then
  echo "エラー: GIST_ID が設定されていません" >&2
  exit 1
fi

usage() {
  echo "使い方: bash komekome_sync.sh push|pull|status"
}

# ── push: import.json → Gist ──
do_push() {
  local import_file="$EXPORT_DIR/komekome_import.json"
  if [[ ! -f "$import_file" ]]; then
    echo "エラー: $import_file が見つかりません" >&2
    return 1
  fi

  # Gist API用のリクエストボディを Python で構築し直接 gh api に渡す
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  python3 - "$import_file" "$GIST_ID" "$now" <<'PYEOF' | gh api --method PATCH "gists/$GIST_ID" --input - > /dev/null
import json, sys, subprocess

import_file, gist_id, now = sys.argv[1], sys.argv[2], sys.argv[3]

with open(import_file, encoding='utf-8') as f:
    import_data = json.load(f)

import_date = import_data.get('generated_date', '')

# 既存 meta を取得して更新
try:
    r = subprocess.run(
        ['gh', 'api', f'gists/{gist_id}', '--jq', '.files["meta.json"].content'],
        capture_output=True, text=True, check=True
    )
    meta = json.loads(r.stdout)
except Exception:
    meta = {}

meta['import_updated_at'] = now
meta['import_date'] = import_date

body = {
    "files": {
        "komekome_import.json": {"content": json.dumps(import_data, ensure_ascii=False, indent=2)},
        "meta.json": {"content": json.dumps(meta, ensure_ascii=False)},
    }
}
print(json.dumps(body))
PYEOF

  echo "push 完了: komekome_import.json → Gist ($now)"
}

# ── pull: Gist → results.json + writeback ──
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

  # Gist全体をtempファイルに保存（大きなJSONをシェル変数に入れない）
  local gist_tmp
  gist_tmp=$(mktemp)
  trap "rm -f '$gist_tmp'" RETURN

  gh api "gists/$GIST_ID" > "$gist_tmp"

  # Python で結果チェック・ファイル保存・API更新ペイロード生成を一括処理
  local api_payload_file
  api_payload_file=$(mktemp)

  python3 - "$gist_tmp" "$results_file" "$backup_dir" "$timestamp" "$now" "$api_payload_file" <<'PYEOF'
import json, sys

gist_file, results_file, backup_dir, timestamp, now, payload_file = sys.argv[1:7]

with open(gist_file, encoding='utf-8') as f:
    gist = json.load(f)

# results.json の内容を取得
results_content = gist['files'].get('komekome_results.json', {}).get('content', '{}')
try:
    results_data = json.loads(results_content)
except json.JSONDecodeError:
    results_data = {"session_date": None, "session_id": None, "results": []}

results_list = results_data.get('results', [])
if not results_list:
    with open(payload_file, 'w') as f:
        f.write("__SKIP__")
    sys.exit(0)

# バックアップ保存
backup_path = f"{backup_dir}/komekome_results_{timestamp}.json"
with open(backup_path, 'w', encoding='utf-8') as f:
    json.dump(results_data, f, ensure_ascii=False, indent=2)

# メインファイル保存
with open(results_file, 'w', encoding='utf-8') as f:
    json.dump(results_data, f, ensure_ascii=False, indent=2)

# meta 更新
meta_content = gist['files'].get('meta.json', {}).get('content', '{}')
try:
    meta = json.loads(meta_content)
except json.JSONDecodeError:
    meta = {}
meta['results_consumed_at'] = now

# Gist 更新用ペイロード
empty_results = {"session_date": None, "session_id": None, "results": []}
body = {
    "files": {
        "komekome_results.json": {"content": json.dumps(empty_results, ensure_ascii=False)},
        "meta.json": {"content": json.dumps(meta, ensure_ascii=False)},
    }
}
with open(payload_file, 'w') as f:
    json.dump(body, f)
PYEOF

  local payload_content
  payload_content=$(cat "$api_payload_file")
  rm -f "$api_payload_file"

  if [[ "$payload_content" == "__SKIP__" ]]; then
    echo "pull: 未処理の結果なし（スキップ）"
    return 0
  fi

  echo "pull: results.json を取得しました"

  # writeback 実行
  bash "$SCRIPTS_DIR/komekome_writeback.sh" "$results_file"

  # Gist の results.json をクリア & meta 更新
  echo "$payload_content" | gh api --method PATCH "gists/$GIST_ID" --input - > /dev/null

  echo "pull 完了: writeback 実行済み、Gist results クリア ($now)"
}

# ── status: meta.json 表示 ──
do_status() {
  echo "=== コメコメ Gist 同期ステータス ==="
  echo "GIST_ID: $GIST_ID"
  echo ""

  gh api "gists/$GIST_ID" | python3 -c "
import json, sys
gist = json.load(sys.stdin)

meta_str = gist['files'].get('meta.json', {}).get('content', '{}')
meta = json.loads(meta_str)
print('meta.json:')
for k, v in meta.items():
    print(f'  {k}: {v}')

results_str = gist['files'].get('komekome_results.json', {}).get('content', '{}')
results = json.loads(results_str)
count = len(results.get('results', []))
print(f'\n未処理 results: {count}件')
"
}

# ── main ──
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  push)   do_push ;;
  pull)   do_pull ;;
  status) do_status ;;
  *)
    echo "エラー: 不明なコマンド: $1" >&2
    usage
    exit 1
    ;;
esac
