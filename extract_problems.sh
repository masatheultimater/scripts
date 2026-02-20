#!/usr/bin/env bash
set -euo pipefail

# 使い方: bash extract_problems.sh <pdf_path> <book_name> <type>
#   pdf_path:  PDFファイルのパス
#   book_name: 問題集名（例: "法人計算問題集4-1"）
#   type:      問題タイプ（計算 or 理論）
#
# オプション:
#   --dry-run   実際のAPI呼び出しをスキップ
#   -h, --help  使い方を表示

usage() {
  cat <<'EOF'
使い方:
  bash extract_problems.sh [--dry-run] <pdf_path> <book_name> <type>

引数:
  pdf_path   PDFファイルのパス
  book_name  問題集名（例: 法人計算問題集4-1）
  type       問題タイプ（計算 or 理論）

オプション:
  --dry-run      API push をスキップ
  -h, --help     使い方を表示
EOF
}

err() {
  echo "エラー: $*" >&2
}

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

VAULT="${VAULT:-$HOME/vault/houjinzei}"
EXPORT_DIR="$VAULT/50_エクスポート"
EXTRACTED_DIR="$VAULT/02_extracted"
MASTER_FILE="$EXPORT_DIR/problems_master.json"
LOCKFILE="/tmp/houjinzei_vault.lock"

DRY_RUN=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        POSITIONAL+=("$1")
        shift
      done
      ;;
    -*)
      err "不明なオプション: $1"
      usage
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

set -- "${POSITIONAL[@]}"

if [[ $# -ne 3 ]]; then
  usage
  exit 1
fi

PDF_INPUT="$1"
BOOK_NAME="$2"
TYPE="$3"

if [[ "$TYPE" != "計算" && "$TYPE" != "理論" ]]; then
  err "type は '計算' または '理論' を指定してください: $TYPE"
  exit 1
fi

if [[ ! -f "$PDF_INPUT" ]]; then
  err "PDFファイルが見つかりません: $PDF_INPUT"
  exit 1
fi

if ! command -v gemini >/dev/null 2>&1; then
  err "gemini コマンドが見つかりません"
  exit 1
fi

PDF_PATH="$(realpath "$PDF_INPUT")"
mkdir -p "$EXTRACTED_DIR" "$EXPORT_DIR"

exec 200>"$LOCKFILE"
if ! flock -n 200; then
  err "別のスクリプトが実行中です"
  exit 1
fi

echo "=========================================="
echo "PDF問題抽出パイプライン"
echo "=========================================="
echo "PDF:      $PDF_PATH"
echo "BOOK:     $BOOK_NAME"
echo "TYPE:     $TYPE"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "MODE:     dry-run"
fi
echo

# 共通定数を Python から取得
read -r PDF_SIZE_THRESHOLD TIMEOUT_SMALL TIMEOUT_LARGE < <(
  python3 - <<'PY'
from lib.houjinzei_common import PDF_TEXT_SIZE_THRESHOLD, GEMINI_TIMEOUT_SMALL, GEMINI_TIMEOUT_LARGE
print(PDF_TEXT_SIZE_THRESHOLD, GEMINI_TIMEOUT_SMALL, GEMINI_TIMEOUT_LARGE)
PY
)

# ID prefix を決定
ID_PREFIX=""
if [[ "$TYPE" == "理論" ]]; then
  ID_PREFIX="theory"
else
  if [[ "$BOOK_NAME" =~ ([0-9]+)[-ー−‐]([0-9]+) ]]; then
    ID_PREFIX="calc-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
  else
    err "計算の book_name から巻番号を抽出できませんでした（例: 法人計算問題集4-1）: $BOOK_NAME"
    exit 1
  fi
fi

BOOK_SAFE="$(echo "$BOOK_NAME" | tr ' /' '__')"
RAW_OUTPUT="$EXTRACTED_DIR/${BOOK_SAFE}_gemini_raw.txt"
PDF_TEXT_FILE="$EXTRACTED_DIR/${BOOK_SAFE}_pdf_text.txt"
EXTRACTED_JSON="$EXPORT_DIR/problems_${BOOK_NAME}.json"
NORMALIZED_JSON="$EXTRACTED_DIR/${BOOK_SAFE}_normalized.json"
TMP_EXTRACTED_JSON="$EXTRACTED_JSON.tmp"
TMP_NORMALIZED_JSON="$NORMALIZED_JSON.tmp"

# 1) pypdf でテキスト抽出（サイズ判定用）
echo "[1/5] PDFテキスト抽出量を計測中..."
if ! python3 - "$PDF_PATH" "$PDF_TEXT_FILE" <<'PY'
import sys
from pypdf import PdfReader

pdf_path, out_path = sys.argv[1], sys.argv[2]
reader = PdfReader(pdf_path)
with open(out_path, "w", encoding="utf-8") as f:
    for i, page in enumerate(reader.pages, start=1):
        text = page.extract_text() or ""
        if text.strip():
            f.write(f"--- ページ {i} ---\\n")
            f.write(text)
            f.write("\\n\\n")
print(len(reader.pages))
PY
then
  err "pypdf でテキスト抽出に失敗しました"
  exit 1
fi

PDF_TEXT_SIZE="$(wc -c < "$PDF_TEXT_FILE")"
echo "  抽出テキストサイズ: ${PDF_TEXT_SIZE} bytes"

PROMPT_CONTENT=$(cat <<EOF
以下のPDFは法人税法の${TYPE}問題集「${BOOK_NAME}」です。
各問題について以下のJSON配列を出力してください:
[
  {
    "id": "${ID_PREFIX}-NNN",
    "book": "${BOOK_NAME}",
    "number": "問題 N",
    "title": "問題タイトル",
    "type": "${TYPE}",
    "scope": "個別" or "総合",
    "topics": ["トピック名"],
    "page": ページ番号,
    "time_min": 目安時間(分),
    "rank": "A" or "B" or "C"
  }
]
IDプレフィックスは理論なら"theory"、計算なら"${ID_PREFIX}"とする。
出力はJSON配列のみ。説明不要。
EOF
)

# 2) Gemini 抽出
echo "[2/5] Gemini で問題リスト抽出中..."
if [[ "$PDF_TEXT_SIZE" -lt "$PDF_SIZE_THRESHOLD" ]]; then
  echo "  方式: PDF直接 (@構文, timeout=${TIMEOUT_SMALL}s)"
  PDF_RELPATH="$(realpath --relative-to="$VAULT" "$PDF_PATH")"
  if ! (cd "$VAULT" && timeout "$TIMEOUT_SMALL" gemini -p "$(printf '%s\n\n@%s' "$PROMPT_CONTENT" "$PDF_RELPATH")" --yolo -o text) >"$RAW_OUTPUT" 2>&1; then
    err "Gemini 実行に失敗しました（生出力: $RAW_OUTPUT）"
    exit 1
  fi
else
  echo "  方式: 抽出テキスト渡し (@構文, timeout=${TIMEOUT_LARGE}s)"
  PDF_TEXT_RELPATH="$(realpath --relative-to="$VAULT" "$PDF_TEXT_FILE")"
  if ! (cd "$VAULT" && timeout "$TIMEOUT_LARGE" gemini -p "$(printf '%s\n\n以下は教材PDFから抽出したテキストです:\n\n@%s' "$PROMPT_CONTENT" "$PDF_TEXT_RELPATH")" --yolo -o text) >"$RAW_OUTPUT" 2>&1; then
    err "Gemini 実行に失敗しました（生出力: $RAW_OUTPUT）"
    exit 1
  fi
fi

# 3) 抽出JSONを整形・検証して保存
echo "[3/5] Gemini出力をJSON整形中..."
if ! python3 - "$RAW_OUTPUT" "$TMP_EXTRACTED_JSON" "$BOOK_NAME" "$TYPE" "$ID_PREFIX" <<'PY'
import json
import re
import sys
from pathlib import Path

raw_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
book_name = sys.argv[3]
problem_type = sys.argv[4]
id_prefix = sys.argv[5]

required_keys = ("id", "book", "number", "title", "type", "scope", "topics", "page", "time_min", "rank")


def to_int(v, default=0):
    try:
        return int(str(v).strip())
    except Exception:
        return default


def extract_json_array(text: str):
    text = text.strip()

    # 1) そのまま JSON として解釈
    try:
        value = json.loads(text)
        if isinstance(value, list):
            return value
    except Exception:
        pass

    # 2) コードブロック内 JSON を探索
    for m in re.finditer(r"```(?:json)?\s*(.*?)\s*```", text, flags=re.DOTALL | re.IGNORECASE):
        chunk = m.group(1).strip()
        try:
            value = json.loads(chunk)
            if isinstance(value, list):
                return value
        except Exception:
            continue

    # 3) 先頭 '[' から raw_decode
    decoder = json.JSONDecoder()
    for i, ch in enumerate(text):
        if ch != "[":
            continue
        try:
            value, _ = decoder.raw_decode(text[i:])
            if isinstance(value, list):
                return value
        except Exception:
            continue

    raise ValueError("JSON配列を抽出できませんでした")


raw = raw_path.read_text(encoding="utf-8")
arr = extract_json_array(raw)
if not arr:
    raise ValueError("問題配列が空です")

problems = []
seen = set()

for idx, item in enumerate(arr, start=1):
    if not isinstance(item, dict):
        raise ValueError(f"{idx}件目がオブジェクトではありません")

    candidate_id = str(item.get("id", "")).strip()
    m = re.match(rf"^{re.escape(id_prefix)}-(\d+)$", candidate_id)
    if m:
        seq = int(m.group(1))
    else:
        seq = idx
    problem_id = f"{id_prefix}-{seq:03d}"

    if problem_id in seen:
        raise ValueError(f"抽出結果内でID重複: {problem_id}")
    seen.add(problem_id)

    title = str(item.get("title", "")).strip()
    number = str(item.get("number", f"問題 {idx}")).strip()

    scope = str(item.get("scope", "")).strip()
    if scope not in ("個別", "総合"):
        key = f"{number} {title}"
        scope = "総合" if "総合" in key else "個別"

    topics = item.get("topics")
    if not isinstance(topics, list):
        topics = []
    topics = [str(t).strip() for t in topics if str(t).strip()]

    rank = str(item.get("rank", "")).strip().upper()
    if rank not in ("A", "B", "C"):
        rank = ""

    problem = {
        "id": problem_id,
        "book": book_name,
        "number": number or f"問題 {idx}",
        "title": title,
        "type": problem_type,
        "scope": scope,
        "topics": topics,
        "page": max(0, to_int(item.get("page", 0), 0)),
        "time_min": max(0, to_int(item.get("time_min", 0), 0)),
        "rank": rank,
    }

    for k in required_keys:
        if k not in problem:
            raise ValueError(f"必須キー欠落: {k}")

    problems.append(problem)

out = {"book": book_name, "problems": problems}
out_path.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"extracted: {len(problems)}")
PY
then
  err "Gemini出力の整形に失敗しました（生出力: $RAW_OUTPUT）"
  exit 1
fi
mv "$TMP_EXTRACTED_JSON" "$EXTRACTED_JSON"

# 4) topic 正規化
echo "[4/5] topics 正規化中..."
if ! python3 - "$EXTRACTED_JSON" "$TMP_NORMALIZED_JSON" <<'PY'
import json
import sys
from pathlib import Path

from lib.topic_normalize import get_parent_category, normalize_topic

in_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

src = json.loads(in_path.read_text(encoding="utf-8"))
problems = src.get("problems", [])
if not isinstance(problems, list):
    raise ValueError("problems が配列ではありません")

for p in problems:
    topics = p.get("topics") or []
    normalized_topics = [normalize_topic(t) for t in topics]
    parent_category = get_parent_category(normalized_topics[0]) if normalized_topics else "その他"
    p["normalized_topics"] = normalized_topics
    p["parent_category"] = parent_category
    p["duplicate_group"] = None

out_path.write_text(json.dumps(src, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"normalized: {len(problems)}")
PY
then
  err "topics正規化に失敗しました"
  exit 1
fi
mv "$TMP_NORMALIZED_JSON" "$NORMALIZED_JSON"

# 5) master マージ（ID重複チェック）
echo "[5/5] problems_master.json へマージ中..."
if ! python3 - "$MASTER_FILE" "$NORMALIZED_JSON" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

from lib.houjinzei_common import atomic_json_write

master_path = Path(sys.argv[1])
new_path = Path(sys.argv[2])

if master_path.exists():
    master = json.loads(master_path.read_text(encoding="utf-8"))
else:
    master = {"version": 1, "generated": "", "total": 0, "problems": {}}

problems = master.get("problems")
if not isinstance(problems, dict):
    raise ValueError("master の problems がオブジェクトではありません")

new_data = json.loads(new_path.read_text(encoding="utf-8"))
new_problems = new_data.get("problems")
if not isinstance(new_problems, list):
    raise ValueError("新規データの problems が配列ではありません")

for p in new_problems:
    pid = p.get("id")
    if not pid:
        raise ValueError("id が空の問題があります")
    if pid in problems:
        raise ValueError(f"ID重複: {pid}")

for p in new_problems:
    problems[p["id"]] = p

master["problems"] = problems
master["total"] = len(problems)
master["generated"] = datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

atomic_json_write(master_path, master, indent=2)
print(f"merged: +{len(new_problems)} -> total={len(problems)}")
PY
then
  err "problems_master.json へのマージに失敗しました"
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "push は --dry-run によりスキップしました"
else
  echo "push 実行中..."
  if ! bash "$SCRIPTS_DIR/komekome_sync.sh" push; then
    err "komekome_sync.sh push に失敗しました"
    exit 1
  fi
fi

echo
echo "完了"
echo "  抽出JSON:   $EXTRACTED_JSON"
echo "  正規化JSON: $NORMALIZED_JSON"
echo "  マスタ:      $MASTER_FILE"
