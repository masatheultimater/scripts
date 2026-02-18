#!/bin/bash

set -euo pipefail

VAULT="$HOME/vault/houjinzei"
TOPIC_ROOT="$VAULT/10_論点"
LOG_ROOT="$VAULT/20_演習ログ/計算演習"

usage() {
  echo "使い方: bash log.sh <topic_id_or_keyword> <problem_number> <result> [memo]"
  echo "例: bash log.sh 減価償却_普通 3-2 ○"
  echo "例: bash log.sh 交際費 8 × '接待飲食費の判定を間違えた'"
}

if [ "$#" -lt 3 ]; then
  usage
  exit 1
fi

TOPIC_INPUT="$1"
PROBLEM_NUMBER="$2"
RESULT="$3"
MEMO="${4:-}"

if [ "$RESULT" != "○" ] && [ "$RESULT" != "×" ]; then
  echo "エラー: result は ○ または × を指定してください。"
  exit 1
fi

if [ ! -d "$TOPIC_ROOT" ]; then
  echo "エラー: 論点ディレクトリが見つかりません: $TOPIC_ROOT"
  exit 1
fi

escape_table_cell() {
  local s="$1"
  s="${s//|/\\|}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

TOPIC_PATH=""
TOPIC_NAME=""

mapfile -t EXACT_MATCHES < <(find "$TOPIC_ROOT" -type f -name "${TOPIC_INPUT}.md" | sort)

if [ "${#EXACT_MATCHES[@]}" -eq 1 ]; then
  TOPIC_PATH="${EXACT_MATCHES[0]}"
elif [ "${#EXACT_MATCHES[@]}" -gt 1 ]; then
  echo "複数の論点ファイルが完全一致しました。topic_id を具体化してください。"
  for p in "${EXACT_MATCHES[@]}"; do
    echo "- $p"
  done
  exit 1
else
  mapfile -t FUZZY_MATCHES < <(python3 - "$TOPIC_ROOT" "$TOPIC_INPUT" <<'PY'
import os
import sys

import yaml

root = sys.argv[1]
keyword = sys.argv[2]


def extract_topic(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""

    if not text.startswith("---\n"):
        return ""
    end = text.find("\n---\n", 4)
    if end == -1:
        return ""
    try:
        fm = yaml.safe_load(text[4:end]) or {}
    except yaml.YAMLError:
        return ""
    topic = fm.get("topic")
    return str(topic).strip() if isinstance(topic, str) and topic.strip() else ""

for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not name.endswith(".md") or name in ("README.md", "CLAUDE.md"):
            continue
        path = os.path.join(dirpath, name)
        topic = extract_topic(path)
        if keyword in topic:
            print(f"{path}\t{topic}")
PY
)

  if [ "${#FUZZY_MATCHES[@]}" -eq 0 ]; then
    echo "エラー: 該当する論点が見つかりませんでした: $TOPIC_INPUT"
    exit 1
  elif [ "${#FUZZY_MATCHES[@]}" -gt 1 ]; then
    echo "複数の論点が見つかりました。より具体的に指定してください。"
    for row in "${FUZZY_MATCHES[@]}"; do
      path="${row%%$'\t'*}"
      name="${row#*$'\t'}"
      if [ "$path" = "$name" ]; then
        name="(topic未設定)"
      fi
      echo "- ${name}: ${path}"
    done
    exit 1
  else
    TOPIC_PATH="${FUZZY_MATCHES[0]%%$'\t'*}"
    TOPIC_NAME="${FUZZY_MATCHES[0]#*$'\t'}"
    if [ "$TOPIC_PATH" = "$TOPIC_NAME" ]; then
      TOPIC_NAME=""
    fi
  fi
fi

if [ ! -f "$TOPIC_PATH" ]; then
  echo "エラー: 論点ファイルが見つかりません: $TOPIC_PATH"
  exit 1
fi

if [ -z "$TOPIC_NAME" ]; then
  TOPIC_NAME="$(python3 - "$TOPIC_PATH" <<'PY'
import os
import sys

import yaml

path = sys.argv[1]

topic = ""
try:
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            fm = yaml.safe_load(text[4:end]) or {}
            t = fm.get("topic")
            if isinstance(t, str) and t.strip():
                topic = t.strip()
except Exception:
    pass

if not topic:
    topic = os.path.splitext(os.path.basename(path))[0]

print(topic)
PY
)"
fi

# ファイルロック（並行実行対策）
LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; exit 1; }

TODAY="$(date +%F)"
NOW="$(date +%H:%M)"
LOG_FILE="$LOG_ROOT/${TODAY}.md"

mkdir -p "$LOG_ROOT"
if [ ! -f "$LOG_FILE" ]; then
  cat > "$LOG_FILE" <<LOGEOF
---
date: ${TODAY}
type: 計算演習
---
# 計算演習ログ ${TODAY}

## 結果
| 時刻 | 論点 | 問題 | 結果 | メモ |
|------|------|------|------|------|
LOGEOF
fi

TOPIC_CELL="$(escape_table_cell "$TOPIC_NAME")"
PROBLEM_CELL="$(escape_table_cell "$PROBLEM_NUMBER")"
MEMO_CELL="$(escape_table_cell "$MEMO")"

printf '| %s | %s | %s | %s | %s |\n' "$NOW" "$TOPIC_CELL" "$PROBLEM_CELL" "$RESULT" "$MEMO_CELL" >> "$LOG_FILE"

UPDATE_OUTPUT="$(python3 - "$TOPIC_PATH" "$RESULT" "$MEMO" "$TODAY" <<'PY'
import os
import sys
import tempfile

import yaml

path = sys.argv[1]
result = sys.argv[2]
memo = sys.argv[3]
today = sys.argv[4]

# --- 定数（houjinzei_common.py と同一） ---
KOME_THRESHOLD = 16

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

fm_data = {}
body = text

if text.startswith("---\n"):
    end = text.find("\n---\n", 4)
    if end != -1:
        fm_text = text[4:end]
        parsed = yaml.safe_load(fm_text) if fm_text.strip() else {}
        fm_data = parsed if isinstance(parsed, dict) else {}
        body = text[end + 5:]


def as_int(v):
    try:
        return int(v)
    except (ValueError, TypeError):
        return 0

calc_correct = as_int(fm_data.get("calc_correct", 0))
calc_wrong = as_int(fm_data.get("calc_wrong", 0))
kome_total = as_int(fm_data.get("kome_total", 0))

if result == "○":
    calc_correct += 1
else:
    calc_wrong += 1

fm_data["calc_correct"] = calc_correct
fm_data["calc_wrong"] = calc_wrong
fm_data["last_practiced"] = today

if result == "×" and memo.strip():
    mistakes = fm_data.get("mistakes", [])
    if mistakes is None:
        mistakes = []
    elif not isinstance(mistakes, list):
        mistakes = [str(mistakes)]
    mistakes.append(memo.strip())
    fm_data["mistakes"] = mistakes

# --- stage / status 更新（卒業保護付き・kome_total 基準） ---
current_status = fm_data.get("status", "未着手")

if current_status == "卒業":
    # 卒業済みノートは stage/status を巻き戻さない
    stage = fm_data.get("stage", "卒業済")
else:
    # kome_total ベースで stage 判定（komekome_writeback.sh と同一基準）
    attempts = calc_correct + calc_wrong
    if kome_total >= KOME_THRESHOLD or current_status == "復習中":
        stage = "復習中"
    elif kome_total > 0 or attempts > 0:
        stage = "学習中"
    else:
        stage = "未着手"
    fm_data["stage"] = stage
    # status 更新（未着手→学習中への遷移のみ）
    if current_status == "未着手" and (kome_total > 0 or attempts > 0):
        fm_data["status"] = "学習中"

topic = fm_data.get("topic")
if not isinstance(topic, str) or not topic.strip():
    topic = os.path.splitext(os.path.basename(path))[0]

dumped = yaml.safe_dump(
    fm_data,
    allow_unicode=True,
    sort_keys=False,
    default_flow_style=False,
    width=10000,
).rstrip()

new_body = body if body.startswith("\n") else "\n" + body
new_text = f"---\n{dumped}\n---{new_body}"

# atomic write
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp", prefix=".log_")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise

print(f"{topic}\t{calc_correct}\t{calc_wrong}\t{calc_correct + calc_wrong}\t{stage}")
PY
)"

IFS=$'\t' read -r UPDATED_TOPIC_NAME CALC_CORRECT CALC_WRONG TOTAL_ATTEMPTS STAGE <<< "$UPDATE_OUTPUT"

if [ -n "$UPDATED_TOPIC_NAME" ]; then
  TOPIC_NAME="$UPDATED_TOPIC_NAME"
fi

echo "記録しました。"
echo "- 日付: $TODAY"
echo "- 時刻: $NOW"
echo "- 論点: $TOPIC_NAME"
echo "- 問題: $PROBLEM_NUMBER"
echo "- 結果: $RESULT"
if [ -n "$MEMO" ]; then
  echo "- メモ: $MEMO"
fi
echo "- 演習ログ: $LOG_FILE"
echo "- 論点ノート: $TOPIC_PATH"
echo "- 現在の統計: 正解 ${CALC_CORRECT} / 不正解 ${CALC_WRONG} / 合計 ${TOTAL_ATTEMPTS} / stage ${STAGE}"
