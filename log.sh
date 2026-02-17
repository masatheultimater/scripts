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
import re
import sys

root = sys.argv[1]
keyword = sys.argv[2]


def extract_topic(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return ""

    if not lines or lines[0].strip() != "---":
        return ""

    for line in lines[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^topic:\s*(.*)$", line.strip())
        if m:
            value = m.group(1).strip()
            if (value.startswith("\"") and value.endswith("\"")) or (value.startswith("'") and value.endswith("'")):
                value = value[1:-1]
            return value
    return ""

for dirpath, _, filenames in os.walk(root):
    for name in filenames:
        if not name.endswith(".md"):
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
import re
import sys

path = sys.argv[1]

topic = ""
try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    if lines and lines[0].strip() == "---":
        for line in lines[1:]:
            if line.strip() == "---":
                break
            m = re.match(r"^topic:\s*(.*)$", line.strip())
            if m:
                topic = m.group(1).strip().strip("'\"")
                break
except OSError:
    pass

if not topic:
    topic = os.path.splitext(os.path.basename(path))[0]

print(topic)
PY
)"
fi

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
import yaml

path = sys.argv[1]
result = sys.argv[2]
memo = sys.argv[3]
today = sys.argv[4]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

lines = text.splitlines(keepends=True)
fm_data = {}
body = text

if lines and lines[0].strip() == "---":
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is not None:
        fm_text = "".join(lines[1:end])
        parsed = yaml.safe_load(fm_text) if fm_text.strip() else {}
        fm_data = parsed if isinstance(parsed, dict) else {}
        body = "".join(lines[end + 1:])


def as_int(v):
    try:
        return int(v)
    except Exception:
        return 0

calc_correct = as_int(fm_data.get("calc_correct", 0))
calc_wrong = as_int(fm_data.get("calc_wrong", 0))

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

attempts = calc_correct + calc_wrong
if attempts == 0:
    stage = "未着手"
elif attempts <= 3:
    stage = "学習中"
else:
    stage = "復習中"
fm_data["stage"] = stage

topic = fm_data.get("topic")
if not isinstance(topic, str) or not topic.strip():
    topic = os.path.splitext(os.path.basename(path))[0]

dumped = yaml.safe_dump(
    fm_data,
    allow_unicode=True,
    sort_keys=False,
    default_flow_style=False,
).rstrip()

new_text = f"---\n{dumped}\n---\n{body}"
with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)

print(f"{topic}\t{calc_correct}\t{calc_wrong}\t{attempts}\t{stage}")
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
