#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: bash notebooklm_export.sh [--type 理論|計算|all]
  --type: 論点タイプで絞り込みます。省略時は all（両方出力）。
USAGE
}

TYPE_FILTER="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --type の値が不足しています" >&2
        usage
        exit 1
      fi
      TYPE_FILTER="$2"
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

if [[ "$TYPE_FILTER" != "理論" && "$TYPE_FILTER" != "計算" && "$TYPE_FILTER" != "all" ]]; then
  echo "エラー: --type は 理論 / 計算 / all のいずれかを指定してください" >&2
  exit 1
fi

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VAULT TYPE_FILTER PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; exit 1; }

python3 - <<'PY'
import json
import os
import re
import hashlib
import shutil
import subprocess
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from lib.houjinzei_common import (
    VaultPaths,
    eprint,
    read_frontmatter,
)

TYPE_FILTER = os.environ["TYPE_FILTER"]
vp = VaultPaths(os.environ["VAULT"])
TOPIC_DIR = vp.topics
OUTPUT_DIR = vp.export
TARGET_TYPES = ["理論", "計算"] if TYPE_FILTER == "all" else [TYPE_FILTER]
HASH_FILE = OUTPUT_DIR / ".notebooklm_hash"
CHAR_LIMIT = 500_000
PLACEHOLDER_PATTERNS = [
    r"[-*]\s*（.*?記入.*?）",
    r"[-*]\s*（.*?未記入.*?）",
    r"[-*]\s*TODO\b",
    r"[-*]\s*TBD\b",
]


def read_note(md_path: Path):
    fm, body = read_frontmatter(md_path)
    if not fm:
        return None, body
    return fm, body


def parse_type_array(raw_value: str):
    if not raw_value:
        return []
    try:
        parsed = json.loads(raw_value)
    except json.JSONDecodeError:
        return []

    if not isinstance(parsed, list):
        return []

    result = []
    for item in parsed:
        if isinstance(item, str):
            s = item.strip()
            if s:
                result.append(s)
    return result


def has_substantive_content(body: str) -> bool:
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
        if in_overview:
            continue
        substantive_count += 1
        if substantive_count >= 2:
            return True
    return False


def remove_placeholders(body: str) -> str:
    lines = body.splitlines()
    return "\n".join(
        l
        for l in lines
        if not any(re.fullmatch(p, l.strip()) for p in PLACEHOLDER_PATTERNS)
    )


def normalize_headings(body: str) -> str:
    lines = body.splitlines()
    result = []
    for line in lines:
        m = re.match(r"^(#{1,3})\s+(.+)$", line)
        if m:
            level = len(m.group(1))
            result.append(f"{'#' * (level + 3)} {m.group(2)}")
        else:
            result.append(line)
    return "\n".join(result)


def sha256_text(text: str) -> str:
    canonical = re.sub(r"^生成日時: .*$", "生成日時: <stable>", text, flags=re.MULTILINE)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def load_hashes(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(k): str(v) for k, v in data.items()}


def render_chunk(t: str, now_str: str, categories: list) -> str:
    lines = []
    lines.append(f"# 法人税法 {t} まとめ")
    lines.append("")
    lines.append(f"生成日時: {now_str}")
    lines.append("")
    lines.append("## 目次")
    lines.append("")

    total = 0
    if categories:
        for category, items in categories:
            lines.append(f"- {category}")
            for item in items:
                lines.append(f"  - {item['topic']}")
                total += 1
    else:
        lines.append("- 対象トピックはありません")

    lines.append("")
    lines.append("## 本文")
    lines.append("")

    if categories:
        for category, items in categories:
            lines.append(f"## {category}")
            lines.append("")
            for item in items:
                lines.append(f"### {item['topic']}")
                lines.append("")
                lines.append(item["body"].rstrip())
                lines.append("")
                lines.append("---")
                lines.append("")
    else:
        lines.append("対象トピックはありません。")
        lines.append("")

    lines.append(f"総トピック数: {total}")
    lines.append("")
    return "\n".join(lines)


def chunk_categories(t: str, now_str: str, categories: list) -> list:
    if not categories:
        return [render_chunk(t, now_str, [])]

    chunks = []
    current = []
    for cat in categories:
        if not current:
            current = [cat]
            continue
        candidate = render_chunk(t, now_str, current + [cat])
        if len(candidate) <= CHAR_LIMIT:
            current.append(cat)
        else:
            chunks.append(current)
            current = [cat]

    if current:
        chunks.append(current)

    rendered = []
    for c in chunks:
        txt = render_chunk(t, now_str, c)
        if len(txt) > CHAR_LIMIT:
            eprint(f"警告: 1チャンクが文字数上限を超えています: type={t}, {len(txt)}文字")
        rendered.append(txt)
    return rendered


def output_paths_for_type(t: str, chunk_count: int) -> list:
    if chunk_count <= 1:
        return [OUTPUT_DIR / f"notebooklm_{t}.md"]
    return [OUTPUT_DIR / f"notebooklm_{t}_{i}.md" for i in range(1, chunk_count + 1)]


if not TOPIC_DIR.exists():
    eprint(f"エラー: 論点ディレクトリが見つかりません: {TOPIC_DIR}")
    raise SystemExit(1)

all_topics = []
for md_path in sorted(TOPIC_DIR.rglob("*.md")):
    if md_path.name in ("README.md", "CLAUDE.md"):
        continue
    fm, body = read_note(md_path)

    importance = fm.get("importance", "") if isinstance(fm, dict) else ""
    if isinstance(importance, str):
        importance = importance.strip().upper()
    if importance not in ("A", "B"):
        continue

    raw_type = fm.get("type", []) if isinstance(fm, dict) else []
    if isinstance(raw_type, list):
        type_values = [str(x).strip() for x in raw_type if str(x).strip()]
    elif isinstance(raw_type, str):
        type_values = parse_type_array(raw_type)
    else:
        type_values = []
    if not type_values:
        continue

    cleaned_body = normalize_headings(remove_placeholders(body)).strip()
    if not has_substantive_content(cleaned_body):
        continue

    category = str(fm.get("category", "") or "").strip() if isinstance(fm, dict) else ""
    category = category or "未分類"
    topic_name = str(fm.get("topic", "") or "").strip() if isinstance(fm, dict) else ""
    topic_name = topic_name or md_path.stem

    all_topics.append(
        {
            "path": md_path,
            "types": type_values,
            "category": category,
            "topic": topic_name,
            "body": cleaned_body,
        }
    )

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
summary = {}
changed_types = []
prev_hashes = load_hashes(HASH_FILE)
new_hashes = dict(prev_hashes)

for t in TARGET_TYPES:
    matched = [x for x in all_topics if t in x["types"]]
    matched.sort(key=lambda x: (x["category"], x["topic"]))
    grouped = defaultdict(list)
    for item in matched:
        grouped[item["category"]].append(item)

    categories = [(cat, grouped[cat]) for cat in sorted(grouped.keys())]
    chunk_texts = chunk_categories(t, now_str, categories)
    target_paths = output_paths_for_type(t, len(chunk_texts))

    type_changed = False
    for out_path, content in zip(target_paths, chunk_texts):
        key = str(out_path)
        digest = sha256_text(content)
        if prev_hashes.get(key) == digest and out_path.exists():
            new_hashes[key] = digest
            continue
        out_path.write_text(content, encoding="utf-8")
        new_hashes[key] = digest
        type_changed = True

    old_files = sorted(OUTPUT_DIR.glob(f"notebooklm_{t}*.md"))
    target_set = {str(p) for p in target_paths}
    for old_file in old_files:
        if str(old_file) in target_set:
            continue
        old_file.unlink(missing_ok=True)
        new_hashes.pop(str(old_file), None)
        type_changed = True

    if type_changed:
        changed_types.append(t)

    summary[t] = {
        "count": len(matched),
        "paths": [str(p) for p in target_paths],
    }

HASH_FILE.write_text(
    json.dumps(new_hashes, ensure_ascii=False, indent=2, sort_keys=True),
    encoding="utf-8",
)

print("NotebookLMエクスポートが完了しました。")
for t in ["理論", "計算"]:
    if t in summary:
        print(f"- {t}: {summary[t]['count']}件 -> {', '.join(summary[t]['paths'])}")

if changed_types and shutil.which("wslview"):
    subprocess.run(["wslview", "https://notebooklm.google.com/"], check=False)
PY
