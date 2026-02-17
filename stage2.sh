#!/bin/bash
# ============================================================
# STAGE 2: Claude Code によるノート生成
# 使い方: bash stage2.sh [--dry-run] <SAFE_NAME> [SOURCE_TYPE]
# ingest.sh から呼ばれる。単独実行も可（STAGE 1 のリカバリ用）
# ============================================================

set -euo pipefail

VAULT="$HOME/vault/houjinzei"
LOG_DIR="$VAULT/logs"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/stage2_${RUN_TS}.log"

usage() {
  echo "使い方: bash stage2.sh [--dry-run] <SAFE_NAME> [SOURCE_TYPE]"
  echo "例1:   bash stage2.sh 計算問題集①"
  echo "例2:   bash stage2.sh 計算問題集① 計算問題集"
  echo "例3:   bash stage2.sh --dry-run 計算問題集①"
  echo "例4:   bash stage2.sh 計算問題集① --dry-run"
}

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
on_exit() {
  local exit_code=$?
  local end_time
  end_time="$(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  echo "終了時刻: $end_time"
  echo "終了コード: $exit_code"
  echo "ログ: $LOG_FILE"
}
trap on_exit EXIT

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi
if [ "${2:-}" = "--dry-run" ]; then
  DRY_RUN=true
  if [ $# -ge 3 ]; then
    set -- "$1" "$3"
  else
    set -- "$1"
  fi
fi

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

if [ $# -gt 2 ]; then
  usage
  exit 1
fi

SAFE_NAME="$1"
SOURCE_TYPE="${2:-}"
TOPICS_FILE="$VAULT/02_extracted/${SAFE_NAME}_topics.json"

echo "開始時刻: $START_TIME"
echo "入力ファイル: $TOPICS_FILE"
if [ -n "$SOURCE_TYPE" ]; then
  echo "教材タイプ: $SOURCE_TYPE"
fi
echo "ドライラン: $DRY_RUN"
echo ""

if [ ! -f "$TOPICS_FILE" ]; then
  echo "❌ topics.json が見つかりません: $TOPICS_FILE"
  exit 1
fi

echo "📝 Claude Code でノート生成開始..."
echo "   入力: $TOPICS_FILE"
echo ""

SOURCE_TYPE_PROMPT=""
if [ -n "$SOURCE_TYPE" ]; then
  SOURCE_TYPE_PROMPT="
## 教材タイプ（指定あり）
$SOURCE_TYPE

### 教材タイプの反映
- 論点ノートの本文（概要・計算手順・判断ポイント）の書きぶりは、この教材タイプに合わせて調整する"
fi

if [ "$DRY_RUN" = true ]; then
  echo "🔎 DRY RUN: claude -p は実行しません"
  python3 << PYEOF
import json
import os
import sys

topics_file = "$TOPICS_FILE"
vault = "$VAULT"

with open(topics_file, "r", encoding="utf-8") as f:
    data = json.load(f)

if isinstance(data, dict):
    topics = data.get("topics", [])
elif isinstance(data, list):
    topics = data
else:
    print("❌ topics.json の形式が不正です")
    sys.exit(1)

if not isinstance(topics, list):
    print("❌ topics.json の topics が配列ではありません")
    sys.exit(1)

create_notes = []
update_notes = []
topic_ids = []

for t in topics:
    if not isinstance(t, dict):
        continue
    topic_id = str(t.get("topic_id", "")).strip()
    category = str(t.get("category", "その他")).strip() or "その他"
    if not topic_id:
        continue
    topic_ids.append(topic_id)
    note_path = os.path.join(vault, "10_論点", category, f"{topic_id}.md")
    if os.path.exists(note_path):
        update_notes.append(note_path)
    else:
        create_notes.append(note_path)

print(f"対象topic数: {len(topic_ids)}")
print("topic_id一覧:")
for tid in topic_ids:
    print(f"  - {tid}")

print("")
print(f"新規作成予定ノート: {len(create_notes)}")
for path in create_notes:
    print(f"  + {path}")

print("")
print(f"更新予定ノート: {len(update_notes)}")
for path in update_notes:
    print(f"  * {path}")

print("")
print("ソースマップ:")
print(f"  - {vault}/30_ソース別/ 配下をClaudeが source_name に基づき生成/更新")
PYEOF

  echo ""
  echo "✅ STAGE 2 DRY RUN 完了"
  exit 0
fi

python3 << PYEOF
import datetime
import json
import os
import re
import sys

topics_file = "$TOPICS_FILE"
vault = "$VAULT"
source_type_prompt = """$SOURCE_TYPE_PROMPT"""

def ensure_list(value):
    if isinstance(value, list):
        return value
    if value in (None, ""):
        return []
    return [value]

def yaml_inline(value):
    return json.dumps(value, ensure_ascii=False)

def sanitize_path_name(name: str) -> str:
    return re.sub(r'[\\\\/:*?"<>|]+', "_", str(name)).strip() or "unknown"

def append_source_frontmatter_only(note_path: str, source_entry: str) -> bool:
    with open(note_path, "r", encoding="utf-8") as f:
        content = f.read()

    if not content.startswith("---\n"):
        return False

    lines = content.splitlines(keepends=True)
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end_idx = i
            break
    if end_idx is None:
        return False

    fm_lines = lines[1:end_idx]
    body_lines = lines[end_idx + 1:]

    source_line = f"  - '{source_entry}'\n"
    src_idx = None
    for i, line in enumerate(fm_lines):
        if line.strip() == "sources:":
            src_idx = i
            break

    changed = False
    if src_idx is None:
        insert_idx = len(fm_lines)
        for i, line in enumerate(fm_lines):
            if re.match(r"^(keywords|related|kome_total|calc_correct|calc_wrong|last_practiced|stage|status|pdf_refs|mistakes|extracted_from):", line.strip()):
                insert_idx = i
                break
        fm_lines[insert_idx:insert_idx] = ["sources:\n", source_line]
        changed = True
    else:
        j = src_idx + 1
        existing_sources = []
        while j < len(fm_lines):
            raw = fm_lines[j]
            stripped = raw.strip()
            if stripped.startswith("- "):
                item = stripped[2:].strip().strip("'\"")
                existing_sources.append(item)
                j += 1
                continue
            if stripped == "":
                j += 1
                continue
            break
        if source_entry not in existing_sources:
            fm_lines.insert(j, source_line)
            changed = True

    if changed:
        new_content = "".join(["---\n"] + fm_lines + ["---\n"] + body_lines)
        with open(note_path, "w", encoding="utf-8") as f:
            f.write(new_content)
    return changed

with open(topics_file, "r", encoding="utf-8") as f:
    data = json.load(f)

if isinstance(data, dict):
    topics = data.get("topics", [])
else:
    topics = data

if not isinstance(topics, list):
    print("❌ topics.json の topics が配列ではありません")
    sys.exit(1)

publisher = ""
source_name = ""
source_type = ""
total_problems = 0
short_source_name = ""

if isinstance(data, dict):
    publisher = str(data.get("publisher", "")).strip()
    source_name = str(data.get("source_name", "")).strip()
    source_type = str(data.get("source_type", "")).strip()
    total_problems = data.get("total_problems", 0)
    short_source_name = str(
        data.get("short_source_name", "") or data.get("source_short_name", "") or source_name
    ).strip()

if not source_type and source_type_prompt.strip():
    for line in source_type_prompt.splitlines():
        s = line.strip()
        if s and not s.startswith("#") and not s.startswith("-"):
            source_type = s
            break

publisher_folder = sanitize_path_name(publisher or "不明出版社")
safe_source_name = sanitize_path_name(source_name or "unknown_source")
source_entry = f"{publisher} {short_source_name}".strip()
today = datetime.date.today().isoformat()

created_count = 0
updated_count = 0
mapping_rows = []

for topic in topics:
    if not isinstance(topic, dict):
        continue

    topic_id = str(topic.get("topic_id", "")).strip()
    if not topic_id:
        continue

    topic_name = str(topic.get("name", topic_id)).strip() or topic_id
    category = str(topic.get("category", "その他")).strip() or "その他"
    subcategory = str(topic.get("subcategory", "")).strip()
    topic_type = ensure_list(topic.get("type", []))
    importance = str(topic.get("importance", "")).strip()
    conditions = ensure_list(topic.get("conditions", []))
    keywords = ensure_list(topic.get("keywords", []))
    related = ensure_list(topic.get("related", []))
    problem_numbers = ensure_list(topic.get("problem_numbers", []))

    safe_topic_id = topic_id.replace("/", "_")
    category_dir = os.path.join(vault, "10_論点", category)
    os.makedirs(category_dir, exist_ok=True)
    note_path = os.path.join(category_dir, f"{safe_topic_id}.md")

    if os.path.exists(note_path):
        if append_source_frontmatter_only(note_path, source_entry):
            updated_count += 1
    else:
        frontmatter_lines = [
            "---",
            f"topic: {topic_id}",
            f"category: {category}",
            f"subcategory: {subcategory}",
            f"type: {yaml_inline(topic_type)}",
            f"importance: {importance}",
            f"conditions: {yaml_inline(conditions)}",
            "sources:",
            f"  - '{source_entry}'",
            f"keywords: {yaml_inline(keywords)}",
            f"related: {yaml_inline(related)}",
            "kome_total: 0",
            "calc_correct: 0",
            "calc_wrong: 0",
            "last_practiced:",
            "stage: 未着手",
            "status: 未着手",
            "pdf_refs: []",
            "mistakes: []",
            f"extracted_from: 'Gemini {today}'",
            "---",
            "",
        ]
        body_lines = [
            f"# {topic_name}",
            "## 概要",
            "## 計算手順",
            "## 判断ポイント",
            "## 間違えやすいポイント",
            "## 関連条文",
            "",
        ]
        content = "\n".join(frontmatter_lines + body_lines)
        with open(note_path, "w", encoding="utf-8") as f:
            f.write(content)
        created_count += 1

    if problem_numbers:
        for p in problem_numbers:
            mapping_rows.append((str(p).strip(), topic_name, topic_id))
    else:
        mapping_rows.append(("", topic_name, topic_id))

source_map_dir = os.path.join(vault, "30_ソース別", publisher_folder)
os.makedirs(source_map_dir, exist_ok=True)
source_map_path = os.path.join(source_map_dir, f"{safe_source_name}.md")

header_lines = [
    "---",
    f"source_name: {source_name}",
    f"source_type: {source_type}",
    f"publisher: {publisher}",
    f"total_problems: {total_problems}",
    "covered: 0",
    "---",
    "",
    f"# {source_name or safe_source_name}",
    "",
    "## 問題 → 論点 マッピング",
    "",
    "| 問題番号 | 論点 | リンク |",
    "|---|---|---|",
]

row_lines = [
    f"| {problem_no} | {topic_name} | [[{topic_id}]] |"
    for problem_no, topic_name, topic_id in mapping_rows
]
source_map_content = "\n".join(header_lines + row_lines + [""])
with open(source_map_path, "w", encoding="utf-8") as f:
    f.write(source_map_content)

print(f"作成ノート数: {created_count}")
print(f"更新ノート数: {updated_count}")
print(f"ソースマップ: {source_map_path}")
PYEOF

echo ""
echo "✅ STAGE 2 完了"
