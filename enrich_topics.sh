#!/usr/bin/env bash
# ============================================================
# 論点ノート本文充実スクリプト
# 空テンプレートノートの本文を claude -p で自動生成する。
# 使い方: bash enrich_topics.sh [--dry-run] [--limit N] [--sleep-sec S]
# ============================================================

set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"
# claude -p のネストセッション検出を回避
unset CLAUDECODE 2>/dev/null || true
LOG_DIR="$VAULT/logs"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/enrich_topics_${RUN_TS}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

DRY_RUN=false
LIMIT=0
SLEEP_SEC=5
CATEGORIES=""
ENGINE="claude"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --sleep-sec)
      SLEEP_SEC="$2"
      shift 2
      ;;
    --categories)
      CATEGORIES="$2"
      shift 2
      ;;
    --engine)
      ENGINE="$2"
      shift 2
      ;;
    -h|--help)
      echo "使い方: bash enrich_topics.sh [--dry-run] [--limit N] [--sleep-sec S] [--categories CAT1,CAT2,...] [--engine claude|codex]"
      echo ""
      echo "オプション:"
      echo "  --dry-run        対象ノートの一覧を表示するのみ（実行しない）"
      echo "  --limit N        処理する最大件数（0 = 無制限）"
      echo "  --sleep-sec S    各ノート処理後のスリープ秒数（デフォルト: 5）"
      echo "  --categories C   カンマ区切りのカテゴリフィルタ（並列実行用）"
      echo "  --engine E       生成エンジン: claude (デフォルト) or codex"
      exit 0
      ;;
    *)
      echo "エラー: 不明な引数です: $1" >&2
      exit 1
      ;;
  esac
done

export VAULT DRY_RUN LIMIT SLEEP_SEC CATEGORIES ENGINE

# リファレンスノート（充実済み）のbody部分を取得
REFERENCE_NOTE="$VAULT/10_論点/損金算入/損金算入_寄附金_損金算入限度額.md"
if [[ ! -f "$REFERENCE_NOTE" ]]; then
  echo "警告: リファレンスノートが見つかりません: $REFERENCE_NOTE" >&2
fi

echo "=== 論点ノート本文充実 ==="
echo "日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo "ドライラン: $DRY_RUN"
echo "制限件数: $LIMIT"
echo "スリープ: ${SLEEP_SEC}秒"
echo "エンジン: $ENGINE"
echo ""

python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from lib.houjinzei_common import (
    VaultPaths,
    eprint,
    read_frontmatter,
)

DRY_RUN = os.environ["DRY_RUN"] == "true"
LIMIT = int(os.environ["LIMIT"])
SLEEP_SEC = int(os.environ["SLEEP_SEC"])
CATEGORIES_FILTER = set(
    c.strip() for c in os.environ.get("CATEGORIES", "").split(",") if c.strip()
)

vp = VaultPaths(os.environ["VAULT"])
TOPIC_DIR = vp.topics
REFERENCE_NOTE = vp.topics / "損金算入" / "損金算入_寄附金_損金算入限度額.md"

PLACEHOLDER_PATTERNS = [
    re.compile(r"[-*]\s*（.*?記入.*?）"),
    re.compile(r"[-*]\s*（.*?未記入.*?）"),
    re.compile(r"[-*]\s*TODO\b"),
    re.compile(r"[-*]\s*TBD\b"),
]


def read_note(md_path: Path):
    fm, body = read_frontmatter(md_path)
    if not fm:
        return None, body
    return fm, body


def is_empty_template(body: str) -> bool:
    """概要セクション以外に実質的な行が2行未満ならTrue。"""
    in_overview = False
    substantive_count = 0
    for line in body.splitlines():
        s = line.strip()
        if not s:
            continue
        if re.match(r"^#{1,6}\s+", s):
            in_overview = bool(re.match(r"^#{1,6}\s+概要", s))
            continue
        if re.fullmatch(r"[-*_]{3,}", s):
            continue
        if any(p.fullmatch(s) for p in PLACEHOLDER_PATTERNS):
            continue
        if in_overview:
            continue
        substantive_count += 1
        if substantive_count >= 2:
            return False
    return True


def get_reference_body() -> str:
    if not REFERENCE_NOTE.exists():
        return ""
    _, body = read_note(REFERENCE_NOTE)
    return body.strip()


def build_prompt(fm: dict, body: str, reference_body: str) -> str:
    topic = fm.get("topic", "不明")
    category = fm.get("category", "不明")
    subcategory = fm.get("subcategory", "")
    keywords = fm.get("keywords", [])
    if isinstance(keywords, str):
        try:
            keywords = json.loads(keywords)
        except json.JSONDecodeError:
            keywords = []
    related = fm.get("related", [])
    if isinstance(related, str):
        try:
            related = json.loads(related)
        except json.JSONDecodeError:
            related = []
    conditions = fm.get("conditions", [])
    if isinstance(conditions, str):
        try:
            conditions = json.loads(conditions)
        except json.JSONDecodeError:
            conditions = []

    kw_str = ", ".join(str(k) for k in keywords) if keywords else "なし"
    rel_str = ", ".join(str(r) for r in related) if related else "なし"
    cond_str = ", ".join(str(c) for c in conditions) if conditions else "なし"

    ref_section = ""
    if reference_body:
        # 参照ノートが長すぎるとタイムアウトするため、先頭800文字に制限
        trimmed = reference_body[:800]
        if len(reference_body) > 800:
            trimmed += "\n...(以下省略)"
        ref_section = f"""
## リファレンス（書式例）
以下の書式と充実度を目指してください。

```markdown
{trimmed}
```
"""

    return f"""あなたは法人税法の専門家です。以下の論点ノートの本文を充実させてください。

## 論点情報
- topic: {topic}
- category: {category}
- subcategory: {subcategory}
- keywords: {kw_str}
- related: {rel_str}
- conditions: {cond_str}
{ref_section}
## 出力ルール
1. frontmatter（---で囲まれた部分）は出力しないでください
2. 以下の見出し構成で本文のみを出力してください:
   - # {{論点名}}
   - ## 概要（1-3文で制度趣旨・概要を説明）
   - ## 計算手順（該当する場合、番号付きリストで手順を示す）
   - ## 判断ポイント（実務上の判断基準をリスト形式で）
   - ## 間違えやすいポイント（試験で間違えやすい点をリスト形式で）
   - ## 関連条文（条文番号と簡潔な説明）
3. 計算タイプの論点は計算手順を詳細に書いてください
4. 理論タイプの論点は制度趣旨と判断基準を重視してください
5. プレースホルダー（「（学習後に記入）」等）は使わないでください
6. Markdown形式で出力してください"""


ENGINE = os.environ.get("ENGINE", "claude")

MAX_RETRIES = 3
RETRY_BACKOFF = [10, 30, 60]  # seconds

# Progress file for resume capability (per-category for parallel runs)
_progress_suffix = ""
if CATEGORIES_FILTER:
    _progress_suffix = "_" + "_".join(sorted(CATEGORIES_FILTER))
PROGRESS_FILE = Path(os.environ["VAULT"]) / "logs" / f"enrich_progress{_progress_suffix}.json"


def load_progress() -> set:
    if PROGRESS_FILE.exists():
        try:
            data = json.loads(PROGRESS_FILE.read_text())
            return set(data.get("completed", []))
        except (json.JSONDecodeError, KeyError):
            pass
    return set()


def save_progress(completed: set):
    PROGRESS_FILE.parent.mkdir(parents=True, exist_ok=True)
    PROGRESS_FILE.write_text(json.dumps(
        {"completed": sorted(completed), "updated": time.strftime("%Y-%m-%d %H:%M:%S")},
        ensure_ascii=False, indent=2
    ))


def _run_claude(prompt: str, md_path: Path, attempt: int) -> str | None:
    """claude -p で生成。成功時は本文文字列、失敗時は None。"""
    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--output-format", "text", "--model", "claude-sonnet-4-5"],
            capture_output=True,
            text=True,
            timeout=300,
        )
    except FileNotFoundError:
        eprint("エラー: claude コマンドが見つかりません")
        return None
    except subprocess.TimeoutExpired:
        eprint(f"タイムアウト (試行 {attempt+1}/{MAX_RETRIES}): {md_path}")
        return None

    if result.returncode != 0:
        eprint(f"claude -p 失敗 (code {result.returncode}, 試行 {attempt+1}/{MAX_RETRIES}): {md_path}")
        if result.stderr:
            eprint(result.stderr[:500])
        return None

    return result.stdout.strip()


def _run_codex(prompt: str, md_path: Path, attempt: int) -> str | None:
    """codex exec で生成。プロンプトをファイル経由で渡し、出力ファイルから読み取る。"""
    work_dir = tempfile.mkdtemp(prefix="enrich_codex_")
    prompt_file = os.path.join(work_dir, "prompt.txt")
    output_file = os.path.join(work_dir, "output.md")

    try:
        with open(prompt_file, "w", encoding="utf-8") as f:
            f.write(prompt)

        codex_instruction = (
            f"Read the prompt in {prompt_file}. "
            f"Follow the instructions exactly and write ONLY the markdown output to {output_file}. "
            f"Do NOT include frontmatter (---). Output the markdown body only."
        )

        try:
            result = subprocess.run(
                ["codex", "exec", "--full-auto", "--skip-git-repo-check", "-C", work_dir, codex_instruction],
                capture_output=True,
                text=True,
                timeout=300,
            )
        except FileNotFoundError:
            eprint("エラー: codex コマンドが見つかりません")
            return None
        except subprocess.TimeoutExpired:
            eprint(f"codex タイムアウト (試行 {attempt+1}/{MAX_RETRIES}): {md_path}")
            return None

        if result.returncode != 0:
            eprint(f"codex 失敗 (code {result.returncode}, 試行 {attempt+1}/{MAX_RETRIES}): {md_path}")
            if result.stderr:
                eprint(result.stderr[:500])
            return None

        if not os.path.exists(output_file):
            eprint(f"codex 出力ファイルなし (試行 {attempt+1}/{MAX_RETRIES}): {md_path}")
            return None

        with open(output_file, "r", encoding="utf-8") as f:
            return f.read().strip()
    finally:
        import shutil
        shutil.rmtree(work_dir, ignore_errors=True)


def enrich_note(md_path: Path, fm: dict, body: str, reference_body: str) -> bool:
    prompt = build_prompt(fm, body, reference_body)

    runner = _run_codex if ENGINE == "codex" else _run_claude

    for attempt in range(MAX_RETRIES):
        new_body = runner(prompt, md_path, attempt)

        if not new_body or len(new_body) < 50:
            if new_body is not None:
                eprint(f"生成結果が短すぎます (試行 {attempt+1}/{MAX_RETRIES}): {md_path}")
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_BACKOFF[attempt])
                continue
            return False

        # Success - break out of retry loop
        break
    else:
        return False

    # frontmatter を保持して body だけ差し替え
    text = md_path.read_text(encoding="utf-8")
    end = text.find("\n---\n", 4)
    if end == -1:
        eprint(f"frontmatter解析失敗: {md_path}")
        return False
    fm_part = text[: end + 5]  # "---\n....\n---\n"

    new_content = fm_part + "\n" + new_body + "\n"

    # atomic write
    parent = md_path.parent
    fd, tmp_path = tempfile.mkstemp(dir=parent, suffix=".tmp", prefix=".enrich_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_content)
        os.replace(tmp_path, str(md_path))
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return True


# --- メイン処理 ---
if not TOPIC_DIR.exists():
    eprint(f"エラー: 論点ディレクトリが見つかりません: {TOPIC_DIR}")
    sys.exit(1)

reference_body = get_reference_body()
completed = load_progress()
if completed:
    print(f"レジューム: {len(completed)}件完了済みをスキップ")

targets = []

RANK_ORDER = {"A": 0, "B": 1, "C": 2, "": 3}

for md_path in sorted(TOPIC_DIR.rglob("*.md")):
    if md_path.name in ("README.md", "CLAUDE.md"):
        continue
    fm, body = read_note(md_path)
    if not isinstance(fm, dict):
        continue
    if not is_empty_template(body):
        continue
    # Category filter (for parallel runs)
    if CATEGORIES_FILTER:
        cat = fm.get("category", "")
        if cat not in CATEGORIES_FILTER:
            continue
    # Skip already completed (resume)
    topic_key = str(md_path.relative_to(TOPIC_DIR))
    if topic_key in completed:
        continue
    targets.append((md_path, fm, body, topic_key))

# Sort by importance: A first, then B, then C
targets.sort(key=lambda t: RANK_ORDER.get(t[1].get("importance", ""), 3))

print(f"空テンプレートノート: {len(targets)}件 (A: {sum(1 for t in targets if t[1].get('importance')=='A')}, B: {sum(1 for t in targets if t[1].get('importance')=='B')}, C: {sum(1 for t in targets if t[1].get('importance')=='C')})")

if DRY_RUN:
    for md_path, fm, _, _ in targets:
        topic = fm.get("topic", md_path.stem)
        rank = fm.get("importance", "?")
        print(f"  [{rank}] {topic}: {md_path}")
    print("")
    print("ドライランのため実行しません。")
    sys.exit(0)

if LIMIT > 0:
    targets = targets[:LIMIT]
    print(f"制限件数: {LIMIT}件に絞り込み")

enriched = 0
failed = 0

for i, (md_path, fm, body, topic_key) in enumerate(targets):
    topic = fm.get("topic", md_path.stem)
    rank = fm.get("importance", "?")
    print(f"[{i+1}/{len(targets)}] [{rank}] {topic}...")

    if enrich_note(md_path, fm, body, reference_body):
        enriched += 1
        completed.add(topic_key)
        save_progress(completed)
        print(f"  充実完了 (累計: {enriched}件)")
    else:
        failed += 1
        print(f"  失敗")

    if i < len(targets) - 1 and SLEEP_SEC > 0:
        time.sleep(SLEEP_SEC)

print("")
print(f"完了: 充実 {enriched}件 / 失敗 {failed}件 / 累計完了 {len(completed)}件")
PY

echo ""
echo "=== 論点ノート本文充実完了 ==="
