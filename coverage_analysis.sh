#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: bash coverage_analysis.sh [--date YYYY-MM-DD]
  --date  レポート日。省略時は本日。
USAGE
}

DATE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --date の値が不足しています" >&2
        usage
        exit 1
      fi
      DATE_ARG="$2"
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

VAULT="${HOME}/vault/houjinzei"
export VAULT DATE_ARG

# ファイルロック（並行実行対策）
LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -w 30 200 || { echo "エラー: ロック取得タイムアウト" >&2; exit 1; }

python3 - <<'PY'
import os
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

import yaml

VAULT = Path(os.environ["VAULT"])
DATE_ARG = os.environ.get("DATE_ARG", "").strip()
TOPIC_ROOT = VAULT / "10_論点"
SOURCE_ROOT = VAULT / "30_ソース別"
OUTPUT_ROOT = VAULT / "40_分析" / "カバレッジ"

VALID_STAGES = ("未着手", "学習中", "復習中", "卒業済")
VALID_IMPORTANCE = ["A", "B", "C"]


def normalize_stage(raw_stage: str, status: str) -> str:
    """stage を正規化。欠損時は status から推定する。"""
    if raw_stage in VALID_STAGES:
        return raw_stage
    if status == "卒業":
        return "卒業済"
    if status in ("未着手", "学習中", "復習中"):
        return status
    return "未着手"


def eprint(msg: str) -> None:
    print(msg, file=os.sys.stderr)


def parse_date(s: str) -> date:
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise ValueError(f"日付形式エラー: {s} (YYYY-MM-DD で指定してください)")


def parse_frontmatter(md_path: Path) -> dict:
    try:
        text = md_path.read_text(encoding="utf-8")
    except OSError:
        return {}

    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}
    try:
        parsed = yaml.safe_load(text[4:end])
    except yaml.YAMLError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def as_int(v) -> int:
    try:
        return int(str(v).strip())
    except (ValueError, TypeError):
        return 0


def pct(n: int, d: int) -> str:
    if d <= 0:
        return "0.0%"
    return f"{(n / d) * 100:.1f}%"


def md_escape(v: str) -> str:
    return str(v).replace("|", "\\|").replace("\n", " ").strip()


if not TOPIC_ROOT.exists():
    eprint(f"エラー: 論点ディレクトリが見つかりません: {TOPIC_ROOT}")
    raise SystemExit(1)
if not SOURCE_ROOT.exists():
    eprint(f"エラー: ソースディレクトリが見つかりません: {SOURCE_ROOT}")
    raise SystemExit(1)

report_date = date.today() if not DATE_ARG else parse_date(DATE_ARG)
report_date_s = report_date.strftime("%Y-%m-%d")

cat_stats = defaultdict(
    lambda: {
        "total": 0,
        "stages": {k: 0 for k in VALID_STAGES},
        "importance": {k: 0 for k in VALID_IMPORTANCE},
        "kome_sum": 0,
    }
)
importance_stats = defaultdict(lambda: {"total": 0, "未着手": 0})

all_topics = 0
all_not_started = 0
all_started = 0
orphan_topics = []
unstarted_a_topics = []

for md in sorted(TOPIC_ROOT.rglob("*.md")):
    if md.name in ("README.md", "CLAUDE.md"):
        continue
    fm = parse_frontmatter(md)
    if not fm:
        continue

    all_topics += 1

    rel = md.relative_to(TOPIC_ROOT).as_posix()
    category_default = rel.split("/")[0] if "/" in rel else "未分類"

    topic_name = str(fm.get("topic", "") or "").strip() or md.stem
    category = str(fm.get("category", "") or "").strip() or category_default
    raw_stage = str(fm.get("stage", "") or "").strip()
    status = str(fm.get("status", "") or "").strip()
    stage = normalize_stage(raw_stage, status)
    importance = str(fm.get("importance", "") or "").strip()
    kome_total = as_int(fm.get("kome_total", 0))
    sources_val = fm.get("sources")

    stat = cat_stats[category]
    stat["total"] += 1
    stat["kome_sum"] += kome_total

    if stage in stat["stages"]:
        stat["stages"][stage] += 1
    else:
        stat["stages"].setdefault(stage, 0)
        stat["stages"][stage] += 1

    if importance in stat["importance"]:
        stat["importance"][importance] += 1
    elif importance:
        stat["importance"].setdefault(importance, 0)
        stat["importance"][importance] += 1

    if stage == "未着手":
        all_not_started += 1
    else:
        all_started += 1

    if importance in VALID_IMPORTANCE:
        importance_stats[importance]["total"] += 1
        if stage == "未着手":
            importance_stats[importance]["未着手"] += 1

    if importance == "A" and stage == "未着手":
        unstarted_a_topics.append({"category": category, "topic": topic_name, "path": rel})

    has_source = isinstance(sources_val, list) and len(sources_val) > 0 or (isinstance(sources_val, str) and sources_val.strip())
    if not has_source:
        orphan_topics.append({"category": category, "topic": topic_name, "path": rel})

source_rows = []
zero_coverage_sources = []

for md in sorted(SOURCE_ROOT.rglob("*.md")):
    fm = parse_frontmatter(md)
    if not fm:
        continue

    source_name = str(fm.get("source_name", "") or "").strip() or md.stem
    source_type = str(fm.get("source_type", "") or "").strip() or "-"
    publisher = str(fm.get("publisher", "") or "").strip() or "-"
    total_problems = as_int(fm.get("total_problems", 0))
    covered = as_int(fm.get("covered", 0))

    if covered < 0:
        covered = 0
    if total_problems < 0:
        total_problems = 0
    if total_problems > 0 and covered > total_problems:
        covered = total_problems

    rate_num = (covered / total_problems * 100.0) if total_problems > 0 else 0.0
    rate_text = f"{rate_num:.1f}%"

    row = {
        "name": source_name,
        "type": source_type,
        "publisher": publisher,
        "total": total_problems,
        "covered": covered,
        "rate": rate_text,
    }
    source_rows.append(row)

    if covered == 0:
        zero_coverage_sources.append(row)

category_count = len(cat_stats)
overall_start_rate = pct(all_started, all_topics)

lines = []
lines.append("---")
lines.append(f"date: {report_date_s}")
lines.append("type: カバレッジ分析")
lines.append("---")
lines.append(f"# カバレッジ分析 {report_date_s}")
lines.append("")
lines.append("## 全体サマリ")
lines.append(f"- 総論点数: {all_topics}")
lines.append(f"- 着手率: {overall_start_rate}")
lines.append(f"- カテゴリ数: {category_count}")
lines.append("")
lines.append("## カテゴリ別進捗")
lines.append("| カテゴリ | 総数 | 未着手 | 学習中 | 復習中 | 卒業済 | 着手率 | 平均コメ |")
lines.append("|----------|------|--------|--------|--------|------|--------|----------|")

for category in sorted(cat_stats.keys()):
    s = cat_stats[category]
    total = s["total"]
    not_started = s["stages"].get("未着手", 0)
    learning = s["stages"].get("学習中", 0)
    reviewing = s["stages"].get("復習中", 0)
    graduated = s["stages"].get("卒業済", 0)
    started = total - not_started
    start_rate = pct(started, total)
    avg_kome = f"{(s['kome_sum'] / total):.1f}" if total > 0 else "0.0"

    lines.append(
        "| {cat} | {total} | {ns} | {l} | {r} | {g} | {rate} | {avg} |".format(
            cat=md_escape(category),
            total=total,
            ns=not_started,
            l=learning,
            r=reviewing,
            g=graduated,
            rate=start_rate,
            avg=avg_kome,
        )
    )

lines.append("")
lines.append("## 重要度別進捗")
lines.append("| 重要度 | 総数 | 未着手 | 着手率 |")
lines.append("|--------|------|--------|--------|")

for imp in VALID_IMPORTANCE:
    total = importance_stats[imp]["total"]
    not_started = importance_stats[imp]["未着手"]
    started = total - not_started
    lines.append(f"| {imp} | {total} | {not_started} | {pct(started, total)} |")

lines.append("")
lines.append("## 教材別カバレッジ")
lines.append("| 教材 | 出版社 | 種別 | 総問題 | カバー | 率 |")
lines.append("|------|--------|------|--------|--------|-----|")

for row in source_rows:
    lines.append(
        "| {name} | {pub} | {typ} | {total} | {covered} | {rate} |".format(
            name=md_escape(row["name"]),
            pub=md_escape(row["publisher"]),
            typ=md_escape(row["type"]),
            total=row["total"],
            covered=row["covered"],
            rate=row["rate"],
        )
    )

if not source_rows:
    lines.append("| - | - | - | 0 | 0 | 0.0% |")

lines.append("")
lines.append("## 未着手の重要論点")
if unstarted_a_topics:
    for t in unstarted_a_topics:
        lines.append(f"- [{md_escape(t['category'])}] {md_escape(t['topic'])} (`{t['path']}`)")
else:
    lines.append("- 該当なし")

lines.append("")
lines.append("## 孤立論点（ソースなし）")
if orphan_topics:
    for t in orphan_topics:
        lines.append(f"- [{md_escape(t['category'])}] {md_escape(t['topic'])} (`{t['path']}`)")
else:
    lines.append("- 該当なし")

OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
out_path = OUTPUT_ROOT / f"{report_date_s}.md"
out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

print(f"カバレッジ分析を出力しました: {out_path}")
print(f"総論点数: {all_topics}")
print(f"着手率: {overall_start_rate}")
print(f"カテゴリ数: {category_count}")
print(f"教材数: {len(source_rows)}")
print(f"未着手A論点: {len(unstarted_a_topics)}")
print(f"孤立論点: {len(orphan_topics)}")
print(f"0%教材: {len(zero_coverage_sources)}")
PY
