#!/bin/bash
# ============================================================
# PDF取り込みパイプライン
# 使い方: bash ingest.sh <PDFパス> <教材タイプ>
# 例:     bash ingest.sh ~/vault/houjinzei/01_sources/大原/計算問題集①.pdf 計算問題集
# ============================================================

set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"
INDEX_FILE="$VAULT/01_sources/_index.json"
EXTRACTED_DIR="$VAULT/02_extracted"

# --- 引数チェック ---
RESUME=false
args=()
for arg in "$@"; do
  case "$arg" in
    --resume) RESUME=true ;;
    *) args+=("$arg") ;;
  esac
done

if [ ${#args[@]} -lt 2 ]; then
  echo "使い方: bash ingest.sh <PDFパス> <教材タイプ> [--resume]"
  echo ""
  echo "教材タイプ:"
  echo "  計算テキスト / 計算問題集 / 理論テキスト / 確認テスト / 模試 / 法令"
  echo ""
  echo "オプション:"
  echo "  --resume  STAGE 1のGemini出力が既にある場合、パースから再開"
  exit 1
fi

PDF_PATH="$(realpath "${args[0]}")"
SOURCE_TYPE="${args[1]}"

# --- PDFの存在チェック ---
if [ ! -f "$PDF_PATH" ]; then
  echo "❌ ファイルが見つかりません: $PDF_PATH"
  exit 1
fi

# --- ファイル名からID生成（拡張子除去） ---
PDF_FILENAME="$(basename "$PDF_PATH" .pdf)"
SAFE_NAME="$(echo "$PDF_FILENAME" | tr ' ' '_')"

echo "=========================================="
echo "📄 PDF取り込みパイプライン"
echo "=========================================="
echo "PDF:  $PDF_PATH"
echo "タイプ: $SOURCE_TYPE"
echo "ID:   $SAFE_NAME"
echo ""

# --- 二重処理チェック ---
if grep -q "\"$PDF_FILENAME\"" "$INDEX_FILE" 2>/dev/null; then
  echo "⚠️  このPDFは取り込み済みです: $PDF_FILENAME"
  echo "   再処理する場合は $INDEX_FILE から該当エントリを削除してください。"
  exit 1
fi

# --- プロンプトファイルの存在チェック ---
PROMPT_FILE="$SCRIPTS_DIR/prompts/gemini_${SOURCE_TYPE}.md"
if [ ! -f "$PROMPT_FILE" ]; then
  echo "❌ プロンプトテンプレートがありません: $PROMPT_FILE"
  echo "   対応タイプ:"
  ls "$SCRIPTS_DIR/prompts/" | sed 's/gemini_//;s/\.md//' | sed 's/^/     /'
  exit 1
fi

# ==========================================
# STAGE 1: Gemini CLI — 構造分析
# ==========================================
echo "🔍 STAGE 1: Gemini CLI で構造分析中..."
echo ""

STRUCTURE_FILE="$EXTRACTED_DIR/${SAFE_NAME}_structure.md"
TOPICS_FILE="$EXTRACTED_DIR/${SAFE_NAME}_topics.json"
GEMINI_RAW="$EXTRACTED_DIR/${SAFE_NAME}_gemini_raw.md"

PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

# --- STAGE 1a: pdfminer.sixでテキスト事前抽出（CJKエンコーディング対応） ---
PDF_TEXT_FILE="$EXTRACTED_DIR/${SAFE_NAME}_text.txt"
echo "   テキスト抽出中..."
python3 - "$PDF_PATH" "$PDF_TEXT_FILE" <<'PYEOF'
import sys, io
from pdfminer.layout import LAParams
from pdfminer.pdfpage import PDFPage
from pdfminer.pdfinterp import PDFResourceManager, PDFPageInterpreter
from pdfminer.converter import TextConverter
from pdfminer.pdfdocument import PDFDocument
from pdfminer.pdfparser import PDFParser

pdf_path, out_path = sys.argv[1], sys.argv[2]
rsrcmgr = PDFResourceManager()
laparams = LAParams()
page_count = 0

with open(out_path, "w", encoding="utf-8") as outf:
    with open(pdf_path, "rb") as fp:
        parser = PDFParser(fp)
        document = PDFDocument(parser)
        for i, page in enumerate(PDFPage.create_pages(document)):
            buf = io.StringIO()
            device = TextConverter(rsrcmgr, buf, laparams=laparams)
            interpreter = PDFPageInterpreter(rsrcmgr, device)
            interpreter.process_page(page)
            text = buf.getvalue()
            device.close()
            if text.strip():
                outf.write(f"--- ページ {i+1} ---\n{text}\n\n")
            page_count += 1

print(f"   {page_count}ページ抽出完了 → {out_path}")
PYEOF

PDF_TEXT_SIZE=$(wc -c < "$PDF_TEXT_FILE")
echo "   テキストサイズ: ${PDF_TEXT_SIZE} bytes"

# --- STAGE 1b: Gemini CLI で構造分析（抽出テキストを渡す） ---
# テキストが大きい場合はチャプター/ページ単位に分割して処理
CHUNK_SIZE_THRESHOLD=1000000
PAGES_PER_CHUNK=50
TIMEOUT_SINGLE=1800
TIMEOUT_CHUNK=1200

# --resume: 既存の topics.json に有効なJSONがあれば STAGE 1bスキップ
SKIP_GEMINI=false
if $RESUME && [ -f "$TOPICS_FILE" ]; then
  if python3 -c "
import re, json, sys
with open(sys.argv[1], encoding='utf-8') as f: data = json.load(f)
topics = data.get('topics', [])
if isinstance(topics, list) and len(topics) > 0:
    sys.exit(0)
sys.exit(1)
" "$TOPICS_FILE" 2>/dev/null; then
    echo "   ⏩ --resume: 既存の topics.json を再利用"
    SKIP_GEMINI=true
  else
    echo "   ⚠️  既存の topics.json が不正または空、再実行します"
  fi
fi

extract_single_output() {
  export GEMINI_RAW TOPICS_FILE STRUCTURE_FILE
  python3 - <<'PYEOF'
import os
import re, json, sys
import tempfile

gemini_raw = os.environ["GEMINI_RAW"]
topics_file = os.environ["TOPICS_FILE"]
structure_file = os.environ["STRUCTURE_FILE"]

with open(gemini_raw, "r", encoding="utf-8") as f:
    raw = f.read()

json_match = re.search(r'```json\s*\n(.*?)\n```', raw, re.DOTALL)
if not json_match:
    print("JSONブロックが見つかりませんでした", file=sys.stderr)
    print(f"   Geminiの出力を確認: {gemini_raw}", file=sys.stderr)
    sys.exit(1)

json_str = json_match.group(1)
try:
    data = json.loads(json_str)
except json.JSONDecodeError as e:
    print(f"JSONパースエラー: {e}", file=sys.stderr)
    print(f"   手動で修正してください: {gemini_raw}", file=sys.stderr)
    with open(topics_file, "w", encoding="utf-8") as f:
        f.write(json_str)
    sys.exit(1)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(topics_file), suffix=".tmp", prefix=".aj_")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as tf:
        json.dump(data, tf, ensure_ascii=False, indent=2)
        tf.write("\n")
    os.replace(tmp, topics_file)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("topics.json 抽出成功")

md_content = re.sub(r'```json\s*\n.*?\n```', '', raw, flags=re.DOTALL).strip()
with open(structure_file, "w", encoding="utf-8") as f:
    f.write(md_content)
print("structure.md 抽出成功")
PYEOF
}

extract_chunk_output() {
  local raw_file="$1"
  local chunk_topics_file="$2"
  local chunk_structure_file="$3"
  export RAW_FILE="$raw_file" CHUNK_TOPICS_FILE="$chunk_topics_file" CHUNK_STRUCTURE_FILE="$chunk_structure_file"
  python3 - <<'PYEOF'
import os
import re
import json
import sys

raw_file = os.environ["RAW_FILE"]
chunk_topics_file = os.environ["CHUNK_TOPICS_FILE"]
chunk_structure_file = os.environ["CHUNK_STRUCTURE_FILE"]

with open(raw_file, "r", encoding="utf-8") as f:
    raw = f.read()

json_match = re.search(r'```json\s*\n(.*?)\n```', raw, re.DOTALL)
if not json_match:
    print(f"JSONブロックが見つかりませんでした: {raw_file}", file=sys.stderr)
    sys.exit(1)

json_str = json_match.group(1)
try:
    data = json.loads(json_str)
except json.JSONDecodeError as e:
    print(f"JSONパースエラー ({raw_file}): {e}", file=sys.stderr)
    sys.exit(1)

with open(chunk_topics_file, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")

md_content = re.sub(r'```json\s*\n.*?\n```', '', raw, flags=re.DOTALL).strip()
with open(chunk_structure_file, "w", encoding="utf-8") as f:
    f.write(md_content + "\n")
PYEOF
}

if ! $SKIP_GEMINI; then
  rm -f "$GEMINI_RAW" "$TOPICS_FILE" "$STRUCTURE_FILE"
  rm -f "$EXTRACTED_DIR/${SAFE_NAME}_chunk_"*_text.txt
  rm -f "$EXTRACTED_DIR/${SAFE_NAME}_chunk_"*_gemini_raw.md
  rm -f "$EXTRACTED_DIR/${SAFE_NAME}_chunk_"*_topics.json
  rm -f "$EXTRACTED_DIR/${SAFE_NAME}_chunk_"*_structure.md
  rm -f "$EXTRACTED_DIR/${SAFE_NAME}_chunk_manifest.json"

  if [ "$PDF_TEXT_SIZE" -le "$CHUNK_SIZE_THRESHOLD" ]; then
    echo "   方式: 単発処理（timeout=${TIMEOUT_SINGLE}s）"
    PDF_TEXT_RELPATH="$(realpath --relative-to="$VAULT" "$PDF_TEXT_FILE")"
    (cd "$VAULT" && timeout "$TIMEOUT_SINGLE" gemini -p "$(printf '%s\n\n以下は「%s」のテキスト抽出結果です:\n\n@%s' "$PROMPT_CONTENT" "$PDF_FILENAME" "$PDF_TEXT_RELPATH")" --yolo -o text) > "$GEMINI_RAW" 2>&1
    extract_single_output
  else
    echo "   方式: チャンク分割処理（閾値 ${CHUNK_SIZE_THRESHOLD} bytes 超）"
    CHUNK_MANIFEST="$EXTRACTED_DIR/${SAFE_NAME}_chunk_manifest.json"
    python3 "$SCRIPTS_DIR/lib/chunk_splitter.py" \
      --input "$PDF_TEXT_FILE" \
      --output-dir "$EXTRACTED_DIR" \
      --safe-name "$SAFE_NAME" \
      --manifest-out "$CHUNK_MANIFEST" \
      --pages-per-chunk "$PAGES_PER_CHUNK" >/dev/null

    CHUNK_COUNT="$(python3 - "$CHUNK_MANIFEST" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(int(data.get('chunk_count', 0)))
PYEOF
)"
    if [ "$CHUNK_COUNT" -le 0 ]; then
      echo "❌ チャンク生成に失敗しました: $CHUNK_MANIFEST"
      exit 1
    fi
    echo "   チャンク数: $CHUNK_COUNT"

    : > "$STRUCTURE_FILE"
    : > "$GEMINI_RAW"
    chunk_topics_files=()
    for i in $(seq 1 "$CHUNK_COUNT"); do
      CHUNK_TEXT_FILE="$EXTRACTED_DIR/${SAFE_NAME}_chunk_${i}_text.txt"
      CHUNK_RAW_FILE="$EXTRACTED_DIR/${SAFE_NAME}_chunk_${i}_gemini_raw.md"
      CHUNK_TOPICS_FILE="$EXTRACTED_DIR/${SAFE_NAME}_chunk_${i}_topics.json"
      CHUNK_STRUCTURE_FILE="$EXTRACTED_DIR/${SAFE_NAME}_chunk_${i}_structure.md"
      CHUNK_RELPATH="$(realpath --relative-to="$VAULT" "$CHUNK_TEXT_FILE")"

      echo "   Gemini実行: chunk ${i}/${CHUNK_COUNT}（timeout=${TIMEOUT_CHUNK}s）"
      CHUNK_OK=true
      if ! (cd "$VAULT" && timeout "$TIMEOUT_CHUNK" gemini -p "$(printf '%s\n\n以下は「%s」のテキスト抽出結果（チャンク %s/%s）です:\n\n@%s' "$PROMPT_CONTENT" "$PDF_FILENAME" "$i" "$CHUNK_COUNT" "$CHUNK_RELPATH")" --yolo -o text) > "$CHUNK_RAW_FILE" 2>&1; then
        echo "   ⚠️  chunk ${i} Gemini実行失敗（タイムアウトまたはエラー）、スキップ"
        CHUNK_OK=false
      fi

      if $CHUNK_OK; then
        if extract_chunk_output "$CHUNK_RAW_FILE" "$CHUNK_TOPICS_FILE" "$CHUNK_STRUCTURE_FILE"; then
          chunk_topics_files+=("$CHUNK_TOPICS_FILE")
        else
          echo "   ⚠️  chunk ${i} JSON抽出失敗、スキップ"
          CHUNK_OK=false
        fi
      fi

      {
        echo ""
        echo "# chunk ${i}/${CHUNK_COUNT}"
        echo ""
        cat "$CHUNK_RAW_FILE" 2>/dev/null
        echo ""
      } >> "$GEMINI_RAW"
      if $CHUNK_OK; then
        {
          echo ""
          echo "## チャンク ${i}/${CHUNK_COUNT}"
          echo ""
          cat "$CHUNK_STRUCTURE_FILE"
          echo ""
        } >> "$STRUCTURE_FILE"
      fi
    done

    if [ ${#chunk_topics_files[@]} -eq 0 ]; then
      echo "❌ 全チャンクのJSON抽出に失敗しました"
      exit 1
    fi
    echo "   成功チャンク: ${#chunk_topics_files[@]}/${CHUNK_COUNT}"
    python3 "$SCRIPTS_DIR/lib/chunk_merger.py" --output "$TOPICS_FILE" "${chunk_topics_files[@]}"
    echo "topics.json マージ成功"
  fi
fi

echo ""
echo "📂 出力:"
echo "   構造: $STRUCTURE_FILE"
echo "   論点: $TOPICS_FILE"
echo ""

# ==========================================
# STAGE 2: Claude Code — ノート生成
# ==========================================
echo "📝 STAGE 2: Claude Code でノート生成中..."
echo ""

bash "$SCRIPTS_DIR/stage2.sh" "$SAFE_NAME"

if [ $? -ne 0 ]; then
  echo "❌ STAGE 2 でエラーが発生しました。"
  exit 1
fi

# ==========================================
# 取り込み済みに記録
# ==========================================
export INDEX_FILE PDF_FILENAME SOURCE_TYPE SAFE_NAME
python3 - <<'PYEOF'
import json
import os
import sys
import tempfile
from datetime import datetime

index_file = os.environ["INDEX_FILE"]
pdf_filename = os.environ["PDF_FILENAME"]
source_type = os.environ["SOURCE_TYPE"]
safe_name = os.environ["SAFE_NAME"]

with open(index_file, "r", encoding="utf-8") as f:
    index = json.load(f)

index["processed"].append({
    "filename": pdf_filename,
    "source_type": source_type,
    "processed_at": datetime.now().isoformat(),
    "structure_file": f"{safe_name}_structure.md",
    "topics_file": f"{safe_name}_topics.json"
})

# atomic write
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(index_file), suffix=".tmp", prefix=".aj_")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as tf:
        json.dump(index, tf, ensure_ascii=False, indent=2)
        tf.write("\n")
    os.replace(tmp, index_file)
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PYEOF

echo ""
echo "=========================================="
echo "🎉 取り込み完了: $PDF_FILENAME"
echo "=========================================="
echo ""
echo "確認:"
echo "  Obsidianで 10_論点/ を開いてノートを確認"
echo "  30_ソース別/ にソースマップが作成されています"
