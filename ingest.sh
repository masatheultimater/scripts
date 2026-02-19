#!/bin/bash
# ============================================================
# PDF取り込みパイプライン
# 使い方: bash ingest.sh <PDFパス> <教材タイプ>
# 例:     bash ingest.sh ~/vault/houjinzei/01_sources/大原/計算問題集①.pdf 計算問題集
# ============================================================

set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEX_FILE="$VAULT/01_sources/_index.json"
EXTRACTED_DIR="$VAULT/02_extracted"

# --- 引数チェック ---
if [ $# -lt 2 ]; then
  echo "使い方: bash ingest.sh <PDFパス> <教材タイプ>"
  echo ""
  echo "教材タイプ:"
  echo "  計算テキスト / 計算問題集 / 理論テキスト / 確認テスト / 模試 / 法令"
  exit 1
fi

PDF_PATH="$(realpath "$1")"
SOURCE_TYPE="$2"

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

# --- STAGE 1a: pypdfでテキスト事前抽出（Gemini OCR回避で高速化） ---
PDF_TEXT_FILE="$EXTRACTED_DIR/${SAFE_NAME}_text.txt"
echo "   テキスト抽出中..."
python3 - "$PDF_PATH" "$PDF_TEXT_FILE" <<'PYEOF'
import sys
from pypdf import PdfReader

pdf_path, out_path = sys.argv[1], sys.argv[2]
reader = PdfReader(pdf_path)
with open(out_path, "w", encoding="utf-8") as f:
    for i, page in enumerate(reader.pages):
        text = page.extract_text() or ""
        if text.strip():
            f.write(f"--- ページ {i+1} ---\n{text}\n\n")
print(f"   {len(reader.pages)}ページ抽出完了 → {out_path}")
PYEOF

PDF_TEXT_SIZE=$(wc -c < "$PDF_TEXT_FILE")
echo "   テキストサイズ: ${PDF_TEXT_SIZE} bytes"

# --- STAGE 1b: Gemini CLI で構造分析（抽出テキストを渡す） ---
# 小さいPDF (<500KB text) は@構文でバイナリ直接渡し、大きいPDFはテキスト渡し
# タイムアウト: 小=600秒, 大=1200秒
if [ "$PDF_TEXT_SIZE" -lt 500000 ]; then
  echo "   方式: @構文（PDF直接, timeout=600s）"
  PDF_RELPATH="$(realpath --relative-to="$VAULT" "$PDF_PATH")"
  (cd "$VAULT" && timeout 600 gemini -p "$(printf '%s\n\n@%s' "$PROMPT_CONTENT" "$PDF_RELPATH")" --yolo -o text) > "$GEMINI_RAW" 2>&1
else
  echo "   方式: テキスト渡し（大容量PDF向け, timeout=1200s）"
  PDF_TEXT_RELPATH="$(realpath --relative-to="$VAULT" "$PDF_TEXT_FILE")"
  (cd "$VAULT" && timeout 1200 gemini -p "$(printf '%s\n\n以下は教材PDFから抽出したテキストです:\n\n@%s' "$PROMPT_CONTENT" "$PDF_TEXT_RELPATH")" --yolo -o text) > "$GEMINI_RAW" 2>&1
fi

# Geminiの出力からMarkdownとJSONを分離
# JSON部分を抽出（```json ... ``` ブロック）
export GEMINI_RAW TOPICS_FILE STRUCTURE_FILE
python3 - <<'PYEOF'
import os
import re, json, sys

gemini_raw = os.environ["GEMINI_RAW"]
topics_file = os.environ["TOPICS_FILE"]
structure_file = os.environ["STRUCTURE_FILE"]

with open(gemini_raw, "r", encoding="utf-8") as f:
    raw = f.read()

# JSONブロックを抽出
json_match = re.search(r'```json\s*\n(.*?)\n```', raw, re.DOTALL)
if json_match:
    json_str = json_match.group(1)
    # JSONとして有効か検証
    try:
        data = json.loads(json_str)
        with open(topics_file, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        print("topics.json 抽出成功")
    except json.JSONDecodeError as e:
        print(f"JSONパースエラー: {e}", file=sys.stderr)
        print(f"   手動で修正してください: {gemini_raw}", file=sys.stderr)
        with open(topics_file, "w", encoding="utf-8") as f:
            f.write(json_str)
        sys.exit(1)
else:
    print("JSONブロックが見つかりませんでした", file=sys.stderr)
    print(f"   Geminiの出力を確認: {gemini_raw}", file=sys.stderr)
    sys.exit(1)

# Markdown部分（JSONブロック以外）を structure.md として保存
md_content = re.sub(r'```json\s*\n.*?\n```', '', raw, flags=re.DOTALL).strip()
with open(structure_file, "w", encoding="utf-8") as f:
    f.write(md_content)
print("structure.md 抽出成功")
PYEOF

if [ $? -ne 0 ]; then
  echo ""
  echo "❌ STAGE 1 でエラーが発生しました。"
  echo "   Geminiの生出力: $GEMINI_RAW"
  echo "   手動で修正してから STAGE 2 を実行:"
  echo "   bash stage2.sh $SAFE_NAME"
  exit 1
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

with open(index_file, "w", encoding="utf-8") as f:
    json.dump(index, f, ensure_ascii=False, indent=2)
PYEOF

echo ""
echo "=========================================="
echo "🎉 取り込み完了: $PDF_FILENAME"
echo "=========================================="
echo ""
echo "確認:"
echo "  Obsidianで 10_論点/ を開いてノートを確認"
echo "  30_ソース別/ にソースマップが作成されています"
