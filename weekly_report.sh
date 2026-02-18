#!/bin/bash
# ============================================================
# 週次学習レポート生成
# 使い方: bash weekly_report.sh [--date YYYY-MM-DD]
# 例:     bash weekly_report.sh --date 2026-02-18
# ============================================================

set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"

usage() {
  echo "使い方: bash weekly_report.sh [--date YYYY-MM-DD]"
  echo "  --date: 週の終了日（デフォルト: 今日）。この日を含む直近7日を集計します。"
}

END_DATE="$(date +%F)"

if [ "$#" -eq 0 ]; then
  :
elif [ "$#" -eq 2 ] && [ "$1" = "--date" ]; then
  END_DATE="$2"
else
  usage
  exit 1
fi

# ファイルロック（並行実行対策）
LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -w 30 200 || { echo "エラー: ロック取得タイムアウト" >&2; exit 1; }

python3 - "$VAULT" "$END_DATE" <<'PYEOF'
import re
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import yaml

VAULT = Path(sys.argv[1]).expanduser()
end_date_raw = sys.argv[2]

try:
    PERIOD_END = datetime.strptime(end_date_raw, "%Y-%m-%d").date()
except ValueError:
    print(f"エラー: --date は YYYY-MM-DD 形式で指定してください: {end_date_raw}")
    sys.exit(1)

PERIOD_START = PERIOD_END - timedelta(days=6)

TOPIC_ROOT = VAULT / "10_論点"
LOG_ROOT = VAULT / "20_演習ログ"
REPORT_DIR = VAULT / "40_分析" / "週次レポート"
REPORT_PATH = REPORT_DIR / f"{PERIOD_END.isoformat()}.md"


STAGE_VALUES = ("未着手", "学習中", "復習中", "卒業済")


def split_frontmatter(content: str):
    if not content.startswith("---\n"):
        return "", content
    marker = "\n---\n"
    end = content.find(marker, 4)
    if end == -1:
        return "", content
    return content[4:end], content[end + len(marker) :]


def parse_frontmatter(text: str):
    if not text.strip():
        return {}
    try:
        parsed = yaml.safe_load(text)
        if isinstance(parsed, dict):
            return parsed
    except yaml.YAMLError:
        pass
    return {}


def normalize_stage(raw_stage: str, status: str) -> str:
    """stage を正規化。欠損時は status から推定する。"""
    if raw_stage in STAGE_VALUES:
        return raw_stage
    if status == "卒業":
        return "卒業済"
    if status in ("未着手", "学習中", "復習中"):
        return status
    return "未着手"


def to_int(value) -> int:
    try:
        return int(value)
    except Exception:
        return 0


def parse_date(value):
    if value is None:
        return None
    if isinstance(value, date):
        return value
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, str):
        s = value.strip()
        if not s:
            return None
        for fmt in ("%Y-%m-%d", "%Y/%m/%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
            try:
                return datetime.strptime(s[:19], fmt).date()
            except ValueError:
                continue
    return None


def is_in_period(d: date | None) -> bool:
    return d is not None and PERIOD_START <= d <= PERIOD_END


def format_percent(numerator: int, denominator: int) -> str:
    if denominator == 0:
        return "0.0%"
    return f"{(numerator / denominator * 100):.1f}%"


def list_markdown_files(root: Path):
    if not root.exists():
        return []
    files = []
    for p in root.rglob("*.md"):
        if p.name in {"README.md", "CLAUDE.md"}:
            continue
        files.append(p)
    return files


def parse_tables(body: str):
    tables = []
    current = []
    for line in body.splitlines():
        if line.strip().startswith("|"):
            current.append(line.rstrip())
        else:
            if current:
                tables.append(current)
                current = []
    if current:
        tables.append(current)

    parsed = []
    for lines in tables:
        rows = []
        for line in lines:
            parts = [c.strip() for c in line.strip().split("|")]
            if len(parts) >= 3:
                parts = parts[1:-1]
            if not parts:
                continue
            if all(re.fullmatch(r"[-:]+", c) for c in parts):
                continue
            rows.append(parts)
        if len(rows) >= 2:
            parsed.append({"header": rows[0], "rows": rows[1:]})
    return parsed


def parse_result_cell(value: str):
    s = value.strip()
    if s in {"○", "◯", "o", "O", "正解", "true", "True", "1"}:
        return True
    if s in {"×", "x", "X", "不正解", "false", "False", "0"}:
        return False
    return None


# 1) 10_論点 集計
topic_files = list_markdown_files(TOPIC_ROOT)
stage_counts = {"未着手": 0, "学習中": 0, "復習中": 0, "卒業済": 0}
importance_counts = {"A": 0, "B": 0, "C": 0}
practiced_this_week = []
newly_started = []
weak_candidates = []

for path in topic_files:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        continue

    fm_text, _ = split_frontmatter(content)
    fm = parse_frontmatter(fm_text)

    topic = str(fm.get("topic") or path.stem)
    raw_stage = str(fm.get("stage") or "").strip()
    status = str(fm.get("status") or "").strip()
    stage = normalize_stage(raw_stage, status)
    stage_counts[stage] += 1

    importance = str(fm.get("importance") or "").strip().upper()
    if importance in importance_counts:
        importance_counts[importance] += 1

    kome_total = to_int(fm.get("kome_total", 0))
    correct = to_int(fm.get("calc_correct", 0))
    wrong = to_int(fm.get("calc_wrong", 0))

    last_practiced = parse_date(fm.get("last_practiced"))
    if is_in_period(last_practiced):
        practiced_this_week.append(topic)

    started_date = None
    for key in ("started_at", "start_date", "started_on", "first_practiced"):
        started_date = parse_date(fm.get(key))
        if started_date is not None:
            break

    attempts = correct + wrong
    is_new = False
    if is_in_period(started_date):
        is_new = True
    elif stage != "未着手" and is_in_period(last_practiced) and attempts > 0 and attempts <= 3:
        # 明示的な開始日がないデータ向けの近似判定
        is_new = True

    if is_new:
        newly_started.append(topic)

    if stage != "卒業済":
        weak_candidates.append(
            {
                "topic": topic,
                "kome_total": kome_total,
                "correct": correct,
                "wrong": wrong,
                "stage": stage,
            }
        )

weak_top10 = sorted(
    weak_candidates,
    key=lambda x: (x["kome_total"], x["wrong"], -(x["correct"])),
    reverse=True,
)[:10]

# 2) 20_演習ログ 集計
daily = {}
current = PERIOD_START
while current <= PERIOD_END:
    daily[current.isoformat()] = {"problems": 0, "correct": 0, "wrong": 0}
    current += timedelta(days=1)

log_files = list_markdown_files(LOG_ROOT)
total_sessions = 0
total_problems = 0
total_correct = 0
total_wrong = 0
total_kome_increase = 0

for path in log_files:
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        continue

    fm_text, body = split_frontmatter(content)
    fm = parse_frontmatter(fm_text)

    session_date = parse_date(fm.get("date"))
    if session_date is None:
        session_date = parse_date(path.stem)
    if not is_in_period(session_date):
        continue

    session_key = session_date.isoformat()
    total_sessions += 1

    session_problems = 0
    session_correct = 0
    session_wrong = 0
    session_kome = 0

    tables = parse_tables(body)
    table_has_results = False

    for table in tables:
        header = table["header"]
        rows = table["rows"]
        try:
            result_idx = header.index("結果")
        except ValueError:
            result_idx = -1
        try:
            kome_idx = header.index("コメ数")
        except ValueError:
            kome_idx = -1

        if result_idx >= 0:
            table_has_results = True
            for row in rows:
                if result_idx >= len(row):
                    continue
                parsed = parse_result_cell(row[result_idx])
                if parsed is None:
                    continue
                session_problems += 1
                if parsed:
                    session_correct += 1
                else:
                    session_wrong += 1

                if kome_idx >= 0 and kome_idx < len(row):
                    m = re.search(r"-?\d+", row[kome_idx])
                    if m:
                        session_kome += int(m.group(0))

    if not table_has_results:
        fm_total = to_int(fm.get("total_questions", 0))
        fm_correct = to_int(fm.get("correct_count", 0))
        if fm_total > 0:
            session_problems = fm_total
            session_correct = min(fm_correct, fm_total)
            session_wrong = max(0, fm_total - session_correct)

    total_problems += session_problems
    total_correct += session_correct
    total_wrong += session_wrong
    total_kome_increase += session_kome

    daily[session_key]["problems"] += session_problems
    daily[session_key]["correct"] += session_correct
    daily[session_key]["wrong"] += session_wrong

accuracy_text = format_percent(total_correct, total_problems)
started_topics_sorted = sorted(dict.fromkeys(newly_started))

# 3) レポート生成
REPORT_DIR.mkdir(parents=True, exist_ok=True)

lines = [
    "---",
    f"date: {PERIOD_END.isoformat()}",
    "type: 週次レポート",
    f"period_start: {PERIOD_START.isoformat()}",
    f"period_end: {PERIOD_END.isoformat()}",
    "---",
    f"# 週次レポート {PERIOD_START.isoformat()} 〜 {PERIOD_END.isoformat()}",
    "",
    "## 全体サマリ",
    f"- 総論点数: {len(topic_files)}",
]

started_count = len(topic_files) - stage_counts["未着手"]
started_ratio = format_percent(started_count, len(topic_files)) if topic_files else "0.0%"

lines.extend(
    [
        f"- 着手済み: {started_count} ({started_ratio})",
        f"- 学習中: {stage_counts['学習中']}",
        f"- 復習中: {stage_counts['復習中']}",
        f"- 卒業済: {stage_counts['卒業済']}",
        f"- 重要度分布: A={importance_counts['A']} / B={importance_counts['B']} / C={importance_counts['C']}",
        f"- 今週演習した論点数: {len(set(practiced_this_week))}",
        "",
        "## 今週の演習",
        f"- 演習回数: {total_sessions}",
        f"- 総問題数: {total_problems}",
        f"- 正答率: {accuracy_text}",
        f"- 累計コメ増加: {total_kome_increase}",
        "",
        "## 日別推移",
        "| 日付 | 問題数 | 正解 | 不正解 | 正答率 |",
        "|------|--------|------|--------|--------|",
    ]
)

for day in sorted(daily.keys()):
    p = daily[day]["problems"]
    c = daily[day]["correct"]
    w = daily[day]["wrong"]
    acc = format_percent(c, p)
    lines.append(f"| {day} | {p} | {c} | {w} | {acc} |")

lines.extend(["", "## 今週の新規着手論点"])
if started_topics_sorted:
    for topic in started_topics_sorted:
        lines.append(f"- {topic}")
else:
    lines.append("- なし")

lines.extend(
    [
        "",
        "## 弱点トップ10",
        "| 論点 | コメ数 | 正解 | 不正解 | ステージ |",
        "|------|--------|------|--------|----------|",
    ]
)

if weak_top10:
    for item in weak_top10:
        lines.append(
            f"| {item['topic']} | {item['kome_total']} | {item['correct']} | {item['wrong']} | {item['stage']} |"
        )
else:
    lines.append("| なし | 0 | 0 | 0 | - |")

# 4) 来週の推奨（自動生成）
suggestions = []

if total_problems == 0:
    suggestions.append("週内の演習ログが0件でした。まずは1日1セッション（10問以上）を目標に再開してください。")
else:
    acc_value = (total_correct / total_problems * 100.0) if total_problems else 0.0
    if acc_value < 60:
        suggestions.append("正答率が60%未満です。弱点トップ3を優先し、翌週前半で再演習してください。")
    elif acc_value < 80:
        suggestions.append("正答率は改善余地があります。誤答が多い論点を中心に復習セットを組んでください。")
    else:
        suggestions.append("正答率は良好です。A重要度論点の未着手・学習中を優先して進めてください。")

if weak_top10:
    top_names = ", ".join(item["topic"] for item in weak_top10[:3])
    suggestions.append(f"弱点上位: {top_names}。コメ数が高いため、週前半に重点的に再演習してください。")

if stage_counts["未着手"] > 0 and importance_counts["A"] > 0:
    suggestions.append("未着手論点が残っています。重要度Aから最低3論点を新規着手してください。")

if started_topics_sorted:
    suggestions.append("今週の新規着手論点は翌週も連続で演習し、学習中→復習中への移行を狙ってください。")

lines.extend(["", "## 来週の推奨"])
if suggestions:
    for s in suggestions:
        lines.append(f"- {s}")
else:
    lines.append("- 特になし")

REPORT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")

# 5) 標準出力サマリ
print("==========================================")
print("週次レポートを生成しました")
print("==========================================")
print(f"期間: {PERIOD_START.isoformat()} 〜 {PERIOD_END.isoformat()}")
print(f"出力: {REPORT_PATH}")
print("")
print("サマリ:")
print(f"- 総論点数: {len(topic_files)}")
print(f"- 今週の演習回数: {total_sessions}")
print(f"- 今週の総問題数: {total_problems}")
print(f"- 今週の正答率: {accuracy_text}")
print(f"- 今週の新規着手論点: {len(started_topics_sorted)}")
PYEOF
