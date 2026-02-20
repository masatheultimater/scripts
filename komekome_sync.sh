#!/usr/bin/env bash
# ============================================================
# コメコメ Cloudflare Workers 同期スクリプト
# 使い方: bash komekome_sync.sh push|pull|status
#   push   - komekome_import.json を Workers API にアップロード
#   pull   - Workers API から未処理結果をダウンロードし writeback 実行
#   status - API のステータスを表示
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

usage() {
  echo "使い方: bash komekome_sync.sh push|pull|status"
}

# ── push: import.json → Workers API ──
do_push() {
  local import_file="$EXPORT_DIR/komekome_import.json"
  if [[ ! -f "$import_file" ]]; then
    echo "エラー: $import_file が見つかりません" >&2
    return 1
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local response
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "${API_URL}/api/komekome/import" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d @"$import_file")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" != "200" ]]; then
    echo "エラー: push 失敗 (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "push 完了: komekome_import.json → Workers API ($now)"
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
        headers={'Authorization': f'Bearer {api_token}', 'Content-Type': 'application/json'},
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
    bash "$SCRIPTS_DIR/komekome_writeback.sh" "$results_file"
    echo "pull 完了: writeback 実行済み ($now)"
  fi
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
