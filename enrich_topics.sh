#!/usr/bin/env bash
# ============================================================
# 論点ノート本文充実スクリプト
# 空テンプレートノートの本文を claude -p で自動生成する。
# 使い方: bash enrich_topics.sh [--dry-run] [--limit N] [--sleep-sec S]
# ============================================================

set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$VAULT/logs"
RUN_TS="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/enrich_topics_${RUN_TS}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

DRY_RUN=false
LIMIT=0
SLEEP_SEC=5

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
    -h|--help)
      echo "使い方: bash enrich_topics.sh [--dry-run] [--limit N] [--sleep-sec S]"
      echo ""
      echo "オプション:"
      echo "  --dry-run    対象ノートの一覧を表示するのみ（実行しない）"
      echo "  --limit N    処理する最大件数（0 = 無制限）"
      echo "  --sleep-sec S  各ノート処理後のスリープ秒数（デフォルト: 5）"
      exit 0
      ;;
    *)
      echo "エラー: 不明な引数です: $1" >&2
      exit 1
      ;;
  esac
done

export VAULT DRY_RUN LIMIT SLEEP_SEC

# リファレンスノート（充実済み）のbody部分を取得
REFERENCE_NOTE="$VAULT/10_論点/損金算入/減価償却_普通.md"
if [[ ! -f "$REFERENCE_NOTE" ]]; then
  echo "警告: リファレンスノートが見つかりません: $REFERENCE_NOTE" >&2
fi

echo "=== 論点ノート本文充実 ==="
echo "日時: $(date '+%Y-%m-%d %H:%M:%S')"
echo "ドライラン: $DRY_RUN"
echo "制限件数: $LIMIT"
echo "スリープ: ${SLEEP_SEC}秒"
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

import yaml

VAULT = Path(os.environ["VAULT"])
DRY_RUN = os.environ["DRY_RUN"] == "true"
LIMIT = int(os.environ["LIMIT"])
SLEEP_SEC = int(os.environ["SLEEP_SEC"])

TOPIC_DIR = VAULT / "10_論点"
REFERENCE_NOTE = VAULT / "10_論点" / "損金算入" / "減価償却_普通.md"

PLACEHOLDER_PATTERNS = [
    re.compile(r"[-*]\s*（.*?記入.*?）"),
    re.compile(r"[-*]\s*（.*?未記入.*?）"),
    re.compile(r"[-*]\s*TODO\b"),
    re.compile(r"[-*]\s*TBD\b"),
]


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def read_note(md_path: Path):
    text = md_path.read_text(encoding="utf-8")
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return None, text
    try:
        fm = yaml.safe_load(text[4:end]) or {}
    except yaml.YAMLError:
        return None, text
    body = text[end + 5:]
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
        ref_section = f"""
## リファレンス（充実済みノートの例）
以下は「減価償却_普通」の論点ノートの本文例です。このレベルの充実度と書式を目指してください。

```markdown
{reference_body}
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


def enrich_note(md_path: Path, fm: dict, body: str, reference_body: str) -> bool:
    prompt = build_prompt(fm, body, reference_body)

    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--output-format", "text"],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except FileNotFoundError:
        eprint("エラー: claude コマンドが見つかりません")
        return False
    except subprocess.TimeoutExpired:
        eprint(f"タイムアウト: {md_path}")
        return False

    if result.returncode != 0:
        eprint(f"claude -p 失敗 (code {result.returncode}): {md_path}")
        if result.stderr:
            eprint(result.stderr[:500])
        return False

    new_body = result.stdout.strip()
    if not new_body or len(new_body) < 50:
        eprint(f"生成結果が短すぎます: {md_path}")
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
targets = []

for md_path in sorted(TOPIC_DIR.rglob("*.md")):
    if md_path.name in ("README.md", "CLAUDE.md"):
        continue
    fm, body = read_note(md_path)
    if not isinstance(fm, dict):
        continue
    if not is_empty_template(body):
        continue
    targets.append((md_path, fm, body))

print(f"空テンプレートノート: {len(targets)}件")

if DRY_RUN:
    for md_path, fm, _ in targets:
        topic = fm.get("topic", md_path.stem)
        print(f"  - {topic}: {md_path}")
    print("")
    print("ドライランのため実行しません。")
    sys.exit(0)

if LIMIT > 0:
    targets = targets[:LIMIT]
    print(f"制限件数: {LIMIT}件に絞り込み")

enriched = 0
failed = 0

for i, (md_path, fm, body) in enumerate(targets):
    topic = fm.get("topic", md_path.stem)
    print(f"[{i+1}/{len(targets)}] {topic}...")

    if enrich_note(md_path, fm, body, reference_body):
        enriched += 1
        print(f"  充実完了")
    else:
        failed += 1
        print(f"  失敗")

    if i < len(targets) - 1 and SLEEP_SEC > 0:
        time.sleep(SLEEP_SEC)

print("")
print(f"完了: 充実 {enriched}件 / 失敗 {failed}件")
PY

echo ""
echo "=== 論点ノート本文充実完了 ==="
