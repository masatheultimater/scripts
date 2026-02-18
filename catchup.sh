#!/usr/bin/env bash
# ============================================================
# キャッチアップスクリプト
# WSL起動時・ターミナル起動時に未実行ジョブを補完する。
# 冪等設計: 何度実行しても安全。
# ============================================================

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${VAULT:-$HOME/vault/houjinzei}"
CATCHUP_LOG="$VAULT/logs/cron/catchup_$(date +%Y%m%d).log"
mkdir -p "$(dirname "$CATCHUP_LOG")"

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$CATCHUP_LOG"
}

# --- 1. 今日の出題リスト（generate_quiz.sh） ---
TODAY="$(date +%Y-%m-%d)"
QUIZ_FILE="$VAULT/50_エクスポート/komekome_import.json"

if [[ -f "$QUIZ_FILE" ]]; then
  QUIZ_DATE="$(python3 -c "
import json, sys
try:
    d = json.load(open('$QUIZ_FILE', encoding='utf-8'))
    print(d.get('generated_date', d.get('date', '')))
except: print('')
" 2>/dev/null || echo "")"
else
  QUIZ_DATE=""
fi

if [[ "$QUIZ_DATE" != "$TODAY" ]]; then
  log "出題リストが未生成 → generate_quiz.sh を実行"
  bash "$SCRIPTS_DIR/cron_wrapper.sh" generate_quiz.sh 2>&1 | tail -3
  log "generate_quiz.sh 完了"
else
  log "出題リストは生成済み ($TODAY)"
fi

# --- 1.5. コメコメ Gist pull（未処理の結果があれば writeback） ---
if [[ -f "$SCRIPTS_DIR/komekome_sync.sh" ]]; then
  log "コメコメ Gist pull 開始"
  bash "$SCRIPTS_DIR/komekome_sync.sh" pull 2>&1 | tee -a "$CATCHUP_LOG" || true
  log "コメコメ Gist pull 完了"
fi

# --- 2. 週次バッチ（日曜に実行されるべき3スクリプト） ---
# 最新の週次レポートが7日以上前なら再実行
REPORT_DIR="$VAULT/40_分析/週次レポート"
if [[ -d "$REPORT_DIR" ]]; then
  LATEST_REPORT="$(ls -1 "$REPORT_DIR"/*.md 2>/dev/null | sort | tail -1 || echo "")"
  if [[ -n "$LATEST_REPORT" ]]; then
    REPORT_AGE=$(( ( $(date +%s) - $(stat -c %Y "$LATEST_REPORT" 2>/dev/null || echo 0) ) / 86400 ))
  else
    REPORT_AGE=999
  fi
else
  REPORT_AGE=999
fi

if [[ $REPORT_AGE -ge 8 ]]; then
  log "週次レポートが${REPORT_AGE}日前 → 週次バッチを実行"
  bash "$SCRIPTS_DIR/cron_wrapper.sh" weekly_report.sh 2>&1 | tail -2
  bash "$SCRIPTS_DIR/cron_wrapper.sh" coverage_analysis.sh 2>&1 | tail -2
  bash "$SCRIPTS_DIR/cron_wrapper.sh" notebooklm_export.sh 2>&1 | tail -2
  log "週次バッチ完了"
else
  log "週次レポートは最新 (${REPORT_AGE}日前)"
fi

# --- 3. 直近のcron失敗チェック ---
CRON_LOG_DIR="$VAULT/logs/cron"
FAIL_COUNT=0
if [[ -d "$CRON_LOG_DIR" ]]; then
  while IFS= read -r logfile; do
    if grep -q "終了コード: [1-9]" "$logfile" 2>/dev/null; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAIL_FILE="$logfile"
    fi
  done < <(find "$CRON_LOG_DIR" -name "*.log" -mtime -3 -not -name "catchup_*" 2>/dev/null | sort)
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  log "直近3日間にcronジョブが${FAIL_COUNT}件失敗しています"
  # Windows トースト通知（powershell経由）
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -Command "
      [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
      [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
      \$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
      \$xml.LoadXml('<toast><visual><binding template=\"ToastText02\"><text id=\"1\">法人税学習システム</text><text id=\"2\">cronジョブが${FAIL_COUNT}件失敗しています。ログを確認してください。</text></binding></visual></toast>')
      [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('法人税学習').Show(\$xml)
    " 2>/dev/null || true
  fi
fi

log "キャッチアップ完了"
