#!/bin/bash
# ============================================================
# cron ラッパー: ログ付きでスクリプトを実行
# 使い方: bash cron_wrapper.sh <script_name> [args...]
# crontab から呼ばれる。直接実行も可。
# ============================================================

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/vault/houjinzei/logs/cron"
mkdir -p "$LOG_DIR"

if [ $# -lt 1 ]; then
  echo "使い方: bash cron_wrapper.sh <script_name> [args...]"
  exit 1
fi

SCRIPT_NAME="$1"
shift
SCRIPT_PATH="$SCRIPTS_DIR/$SCRIPT_NAME"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo "エラー: スクリプトが見つかりません: $SCRIPT_PATH"
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/${SCRIPT_NAME%.sh}_${TIMESTAMP}.log"

echo "=== cron実行開始: $SCRIPT_NAME ===" > "$LOG_FILE"
echo "日時: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "引数: $*" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

EXIT_CODE=0
bash "$SCRIPT_PATH" "$@" >> "$LOG_FILE" 2>&1 || EXIT_CODE=$?

echo "" >> "$LOG_FILE"
echo "=== 終了コード: $EXIT_CODE ===" >> "$LOG_FILE"
echo "終了日時: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"

# 失敗時: Windows トースト通知
if [ $EXIT_CODE -ne 0 ] && command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -Command "
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    \$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    \$xml.LoadXml('<toast><visual><binding template=\"ToastText02\"><text id=\"1\">cron失敗: $SCRIPT_NAME</text><text id=\"2\">終了コード $EXIT_CODE - ログ: $LOG_FILE</text></binding></visual></toast>')
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('法人税学習').Show(\$xml)
  " 2>/dev/null || true
fi

# 30日以上前のログを削除
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true

exit $EXIT_CODE
