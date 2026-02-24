#!/usr/bin/env bash
set -euo pipefail

# 使い方: bash generate_theory_ox.sh [--resume] [--categories "cat1,cat2"] [--sleep-sec N] [--max N]
# 充実済み論点ノートから理論○×問題を Claude CLI で生成する

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${VAULT:-/home/masa/vault/houjinzei}"
EXPORT_DIR="$VAULT/50_エクスポート"
TOPICS_DIR="$VAULT/10_論点"
LOG_DIR="$VAULT/logs"
OUTPUT="$EXPORT_DIR/theory_bank.json"
PROGRESS_FILE="$LOG_DIR/theory_ox_progress.json"
SLEEP_SEC=2
MAX_QUESTIONS=0
RESUME=false
CATEGORIES=""

usage() {
  echo "使い方: bash generate_theory_ox.sh [--resume] [--categories CAT1,CAT2,...] [--sleep-sec N] [--max N]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume)
      RESUME=true
      shift
      ;;
    --categories)
      CATEGORIES="${2:-}"
      shift 2
      ;;
    --sleep-sec)
      SLEEP_SEC="${2:-}"
      shift 2
      ;;
    --max)
      MAX_QUESTIONS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "エラー: 不明な引数です: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$SLEEP_SEC" =~ ^[0-9]+$ ]]; then
  echo "エラー: --sleep-sec は 0 以上の整数で指定してください" >&2
  exit 1
fi
if ! [[ "$MAX_QUESTIONS" =~ ^[0-9]+$ ]]; then
  echo "エラー: --max は 0 以上の整数で指定してください" >&2
  exit 1
fi

mkdir -p "$EXPORT_DIR" "$LOG_DIR"
export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"
unset CLAUDECODE 2>/dev/null || true

# 並行実行防止ロック
LOCKFILE="/tmp/houjinzei_theory_ox.lock"
exec 200>|"$LOCKFILE"
flock -n 200 || { echo "エラー: 別の generate_theory_ox.sh が実行中です" >&2; exit 1; }

export VAULT TOPICS_DIR EXPORT_DIR LOG_DIR OUTPUT PROGRESS_FILE SLEEP_SEC MAX_QUESTIONS RESUME CATEGORIES

echo "=== 理論○×問題生成 ==="
echo "日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo "レジューム: $RESUME"
echo "カテゴリ: ${CATEGORIES:-（指定なし）}"
echo "スリープ: ${SLEEP_SEC}秒"
echo "最大生成数: ${MAX_QUESTIONS}（0=無制限）"
echo ""

python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from lib.houjinzei_common import VaultPaths, atomic_json_write, extract_body_sections, read_frontmatter

VAULT = os.environ["VAULT"]
TOPICS_DIR = Path(os.environ["TOPICS_DIR"])
OUTPUT = Path(os.environ["OUTPUT"])
PROGRESS_FILE = Path(os.environ["PROGRESS_FILE"])
SLEEP_SEC = int(os.environ["SLEEP_SEC"])
MAX_QUESTIONS = int(os.environ["MAX_QUESTIONS"])
RESUME = os.environ["RESUME"] == "true"
CATEGORIES_FILTER = set(c.strip() for c in os.environ.get("CATEGORIES", "").split(",") if c.strip())

vp = VaultPaths(VAULT)


def now_iso() -> str:
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


def read_json(path: Path, default):
    if not path.exists():
        return default
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default


def normalize_progress(data):
    if not isinstance(data, dict):
        data = {}
    return {
        "started_at": str(data.get("started_at") or now_iso()),
        "last_updated": str(data.get("last_updated") or now_iso()),
        "completed_files": list(data.get("completed_files") or []),
        "total_generated": int(data.get("total_generated") or 0),
        "errors": list(data.get("errors") or []),
    }


def save_progress(progress):
    progress["last_updated"] = now_iso()
    atomic_json_write(PROGRESS_FILE, progress)


def nonempty_body_line_count(body: str) -> int:
    return sum(1 for line in body.splitlines() if line.strip())


def collect_body_content(body: str) -> str:
    sections = extract_body_sections(body)
    parts = []
    mapping = [
        ("概要", sections.get("summary", "")),
        ("計算手順", sections.get("steps", "")),
        ("判断ポイント", sections.get("judgment", "")),
        ("間違えやすいポイント", sections.get("mistakes", "")),
        ("関連条文", sections.get("statutes", "")),
    ]
    for heading, text in mapping:
        text = (text or "").strip()
        if not text:
            continue
        parts.append(f"## {heading}\n{text}")
    content = "\n\n".join(parts).strip()
    if len(content) > 3000:
        return content[:3000]
    return content


def build_prompt(topic_name: str, category: str, importance: str, body_content: str) -> str:
    return f"""以下の法人税法の論点について、○×問題を3〜5問生成してください。

【論点】{topic_name}
【カテゴリ】{category}
【重要度】{importance}

【内容】
{body_content}

【出力形式】以下のJSON配列のみを出力してください。説明文やマークダウンは不要です。
[
  {{
    "question": "○×問題の文章（1文で、○か×で答えられる断定文）",
    "answer": true または false,
    "explanation": "解説（1〜2文）",
    "difficulty": 1〜3（1=基本, 2=応用, 3=引っかけ）
  }}
]

【ルール】
- 「間違えやすいポイント」の×パターンを引っかけ問題として活用する
- 金額・期間・割合など具体的な数値を含む問題を入れる
- 条文番号を問う問題は避ける（暗記ではなく理解を問う）
- 微妙に間違った記述（×の問題）を必ず2問以上含める
- JSON配列のみ出力。```json```タグ等は付けない"""


def run_claude(prompt: str):
    commands = [
        ["claude", "-p", "--output-format", "json"],
        ["claude", "-p"],
    ]
    last_err = None
    for idx, cmd in enumerate(commands):
        try:
            res = subprocess.run(
                cmd,
                input=prompt,
                capture_output=True,
                text=True,
                timeout=300,
            )
        except FileNotFoundError:
            return None, "claude コマンドが見つかりません"
        except subprocess.TimeoutExpired:
            return None, "claude 実行がタイムアウトしました"

        if res.returncode == 0:
            return res.stdout.strip(), None

        stderr = (res.stderr or "").strip()
        stdout = (res.stdout or "").strip()
        last_err = f"claude 失敗 (code {res.returncode})"
        if stderr:
            last_err += f": {stderr[:300]}"
        elif stdout:
            last_err += f": {stdout[:300]}"

        # 1回目(--output-format json) が失敗した場合はフォールバック継続
        if idx == 0:
            continue
    return None, last_err or "claude 実行に失敗しました"


def extract_json_array_from_text(text: str):
    s = text.strip()
    if not s:
        raise ValueError("空の応答")

    try:
        parsed = json.loads(s)
    except json.JSONDecodeError:
        parsed = None

    if isinstance(parsed, list):
        return parsed
    if isinstance(parsed, dict):
        # Claude の JSON wrapper に対応
        for key in ("result", "content", "data", "questions"):
            v = parsed.get(key)
            if isinstance(v, list):
                return v
            if isinstance(v, str):
                try:
                    sub = json.loads(v)
                except json.JSONDecodeError:
                    sub = None
                if isinstance(sub, list):
                    return sub

    start = s.find("[")
    end = s.rfind("]")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("JSON配列を検出できません")
    return json.loads(s[start:end + 1])


def sanitize_id_part(s: str) -> str:
    s = (s or "").strip()
    s = s.replace("/", "_").replace("\\", "_")
    s = re.sub(r"\s+", "_", s)
    s = re.sub(r"[^0-9A-Za-z_\-ぁ-んァ-ヶ一-龠々ー]", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s or "topic"


def infer_source_section(item: dict) -> str:
    raw = str(item.get("source_section", "") or "").strip()
    allowed = {"summary", "steps", "judgment", "mistakes", "statutes"}
    if raw in allowed:
        return raw
    return "mistakes" if item.get("answer") is False else "summary"


def validate_generated_items(items):
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        q = str(item.get("question", "") or "").strip()
        ans = item.get("answer")
        exp = str(item.get("explanation", "") or "").strip()
        diff = item.get("difficulty", 2)
        try:
            diff = int(diff)
        except (TypeError, ValueError):
            diff = 2
        if diff < 1 or diff > 3:
            diff = 2
        if not q or not isinstance(ans, bool) or not exp:
            continue
        out.append(
            {
                "question": q,
                "answer": ans,
                "explanation": exp,
                "difficulty": diff,
                "source_section": infer_source_section(item),
            }
        )
    return out


if not TOPICS_DIR.exists():
    print(f"エラー: 論点ディレクトリが見つかりません: {TOPICS_DIR}", file=sys.stderr)
    raise SystemExit(1)

progress = normalize_progress(read_json(PROGRESS_FILE, {})) if RESUME else normalize_progress({})

existing_data = {"version": 1, "generated": now_iso(), "total": 0, "questions": []}
if RESUME:
    loaded = read_json(OUTPUT, existing_data)
    if isinstance(loaded, dict) and isinstance(loaded.get("questions"), list):
        existing_data = loaded

questions = list(existing_data.get("questions") or [])
completed_files = set(progress.get("completed_files", []))
progress["completed_files"] = sorted(completed_files)

existing_per_topic = {}
for q in questions:
    if not isinstance(q, dict):
        continue
    topic_id = str(q.get("topic_id", "") or "")
    if not topic_id:
        continue
    existing_per_topic[topic_id] = existing_per_topic.get(topic_id, 0) + 1

targets = []
for path in sorted(TOPICS_DIR.rglob("*.md")):
    if path.name in ("README.md", "CLAUDE.md"):
        continue
    try:
        fm, body = read_frontmatter(path)
    except Exception:
        continue
    if not isinstance(fm, dict) or not fm:
        continue
    if nonempty_body_line_count(body) <= 5:
        continue
    category = str(fm.get("category", "") or "").strip()
    if CATEGORIES_FILTER and category not in CATEGORIES_FILTER:
        continue
    rel = path.relative_to(TOPICS_DIR).as_posix()
    if RESUME and rel in completed_files:
        continue
    targets.append((path, rel, fm, body))

print(f"対象ノート数: {len(targets)}件")
if CATEGORIES_FILTER:
    print(f"カテゴリ絞り込み: {', '.join(sorted(CATEGORIES_FILTER))}")
if RESUME and completed_files:
    print(f"レジューム済み件数: {len(completed_files)}件をスキップ")

generated_in_run = 0

for idx, (path, rel, fm, body) in enumerate(targets, start=1):
    if MAX_QUESTIONS > 0 and generated_in_run >= MAX_QUESTIONS:
        print(f"最大生成数に達したため終了: {generated_in_run}問")
        break

    topic_name = str(fm.get("topic", "") or path.stem).strip()
    category = str(fm.get("category", "") or "その他").strip() or "その他"
    importance = str(fm.get("importance", "") or "").strip()
    topic_id = rel[:-3] if rel.endswith(".md") else rel
    body_content = collect_body_content(body)

    if not body_content:
        msg = f"本文セクション抽出失敗のためスキップ: {rel}"
        print(f"[{idx}/{len(targets)}] {msg}")
        progress["errors"].append({"file": rel, "error": msg, "at": now_iso()})
        save_progress(progress)
        continue

    print(f"[{idx}/{len(targets)}] 生成中: {topic_name}")
    prompt = build_prompt(topic_name, category, importance or "未設定", body_content)
    raw, err = run_claude(prompt)

    if err:
        print(f"  エラー: {err}", file=sys.stderr)
        progress["errors"].append({"file": rel, "error": err, "at": now_iso()})
        save_progress(progress)
        if idx < len(targets) and SLEEP_SEC > 0:
            time.sleep(SLEEP_SEC)
        continue

    try:
        parsed_items = extract_json_array_from_text(raw or "")
    except Exception as e:
        err_msg = f"JSON解析失敗: {e}"
        print(f"  エラー: {err_msg}", file=sys.stderr)
        progress["errors"].append({"file": rel, "error": err_msg, "at": now_iso()})
        save_progress(progress)
        if idx < len(targets) and SLEEP_SEC > 0:
            time.sleep(SLEEP_SEC)
        continue

    valid_items = validate_generated_items(parsed_items)
    if not valid_items:
        err_msg = "有効な問題を抽出できませんでした"
        print(f"  エラー: {err_msg}", file=sys.stderr)
        progress["errors"].append({"file": rel, "error": err_msg, "at": now_iso()})
        save_progress(progress)
        if idx < len(targets) and SLEEP_SEC > 0:
            time.sleep(SLEEP_SEC)
        continue

    if MAX_QUESTIONS > 0:
        remain = MAX_QUESTIONS - generated_in_run
        if remain <= 0:
            break
        valid_items = valid_items[:remain]

    seq = existing_per_topic.get(topic_id, 0)
    topic_id_part = sanitize_id_part(topic_name)
    added = 0
    for item in valid_items:
        seq += 1
        questions.append(
            {
                "id": f"ox-{topic_id_part}-{seq:03d}",
                "topic_id": topic_id,
                "category": category,
                "importance": importance,
                "question": item["question"],
                "answer": item["answer"],
                "explanation": item["explanation"],
                "difficulty": item["difficulty"],
                "source_section": item["source_section"],
            }
        )
        added += 1

    existing_per_topic[topic_id] = seq
    generated_in_run += added
    progress["total_generated"] = int(progress.get("total_generated", 0)) + added
    completed_files.add(rel)
    progress["completed_files"] = sorted(completed_files)
    save_progress(progress)
    print(f"  生成完了: {added}問（累計追加 {generated_in_run}問）")

    if idx < len(targets) and SLEEP_SEC > 0:
        time.sleep(SLEEP_SEC)

output_data = {
    "version": 1,
    "generated": now_iso(),
    "total": len(questions),
    "questions": questions,
}

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
atomic_json_write(OUTPUT, output_data, indent=2)
save_progress(progress)

print("")
print(f"theory_bank.json 生成完了: {OUTPUT}")
print(f"総問題数: {len(questions)}問（今回追加 {generated_in_run}問）")
print(f"進捗ファイル: {PROGRESS_FILE}")
PY

echo ""
echo "=== 理論○×問題生成完了 ==="
