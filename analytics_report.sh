#!/usr/bin/env bash
# ============================================================
# 法人税法 演習分析レポート生成
# Cloudflare KV から attempts を取得し、Obsidian 用 Markdown を生成
# 使い方: bash analytics_report.sh [--pull]
#   --pull  API から最新データを取得してから生成
# ============================================================
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT="${VAULT:-$HOME/vault/houjinzei}"
EXPORT_DIR="$VAULT/50_エクスポート"
REPORT_DIR="$VAULT/40_分析"
MASTER_FILE="$EXPORT_DIR/problems_master.json"
ATTEMPTS_FILE="$EXPORT_DIR/attempts.json"

mkdir -p "$REPORT_DIR"

# Pull from API if --pull flag
if [[ "${1:-}" == "--pull" ]]; then
  CONF="$SCRIPTS_DIR/komekome_cf.conf"
  source "$CONF"
  TOKEN_FILE="${TOKEN_FILE:-$HOME/.config/komekome/cf_token}"
  if [[ -f "$TOKEN_FILE" ]]; then API_TOKEN="$(cat "$TOKEN_FILE")"; fi

  echo "API からデータ取得中..."
  curl -s "${API_URL}/api/komekome/attempts" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -H "User-Agent: komekome-sync/1.0" \
    -o "$ATTEMPTS_FILE"
  echo "取得完了: $ATTEMPTS_FILE"
fi

if [[ ! -f "$MASTER_FILE" ]]; then
  echo "エラー: $MASTER_FILE が見つかりません" >&2
  exit 1
fi

if [[ ! -f "$ATTEMPTS_FILE" ]]; then
  echo "エラー: $ATTEMPTS_FILE が見つかりません（--pull で取得してください）" >&2
  exit 1
fi

export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

python3 - "$MASTER_FILE" "$ATTEMPTS_FILE" "$REPORT_DIR" <<'PYEOF'
import json
import sys
from datetime import datetime, timedelta
from collections import defaultdict
from pathlib import Path

master_path, attempts_path, report_dir = sys.argv[1:4]

with open(master_path) as f:
    master = json.load(f)
problems = master.get("problems", {})

with open(attempts_path) as f:
    adata = json.load(f)
attempts = adata.get("attempts", [])

today = datetime.now().strftime("%Y-%m-%d")
now_str = datetime.now().strftime("%Y-%m-%d %H:%M")

# ── Period helpers ──
def week_start(d):
    dt = datetime.strptime(d, "%Y-%m-%d")
    ws = dt - timedelta(days=dt.weekday())
    return ws.strftime("%Y-%m-%d")

def month_start(d):
    return d[:7] + "-01"

def year_start(d):
    return d[:4] + "-01-01"

def filter_period(atts, start):
    return [a for a in atts if a.get("date", "") >= start]

def date_range(start, end):
    s = datetime.strptime(start, "%Y-%m-%d")
    e = datetime.strptime(end, "%Y-%m-%d")
    days = []
    while s <= e:
        days.append(s.strftime("%Y-%m-%d"))
        s += timedelta(days=1)
    return days

# ── Core stats function ──
def compute_stats(atts):
    total = len(atts)
    correct = sum(1 for a in atts if a.get("result") == "○")
    wrong = total - correct
    rate = round(correct / total * 100) if total > 0 else 0
    time_min = sum(a.get("time_min", 0) for a in atts)
    unique = len(set(a.get("problem_id", "") for a in atts))

    mistakes = defaultdict(int)
    for a in atts:
        if a.get("result") == "×" and a.get("mistakes"):
            for m in a["mistakes"]:
                mistakes[m] += 1

    by_book = defaultdict(lambda: {"correct": 0, "wrong": 0, "total": 0, "time": 0, "ids": set()})
    for a in atts:
        p = problems.get(a.get("problem_id", ""), {})
        book = p.get("book", "不明")
        by_book[book]["total"] += 1
        by_book[book]["time"] += a.get("time_min", 0)
        by_book[book]["ids"].add(a.get("problem_id", ""))
        if a.get("result") == "○":
            by_book[book]["correct"] += 1
        else:
            by_book[book]["wrong"] += 1

    weak = defaultdict(lambda: {"correct": 0, "wrong": 0})
    for a in atts:
        pid = a.get("problem_id", "")
        if a.get("result") == "○":
            weak[pid]["correct"] += 1
        else:
            weak[pid]["wrong"] += 1

    weak_sorted = sorted(
        [(pid, v) for pid, v in weak.items() if v["wrong"] > 0],
        key=lambda x: -x[1]["wrong"]
    )[:20]

    return {
        "total": total, "correct": correct, "wrong": wrong, "rate": rate,
        "time_min": time_min, "unique": unique, "mistakes": dict(mistakes),
        "by_book": {k: {**v, "ids": len(v["ids"])} for k, v in by_book.items()},
        "weak": weak_sorted,
    }

# ── Generate report ──
BOOK_SHORT = {
    "法人計算問題集1-1": "計算1-1", "法人計算問題集1-2": "計算1-2",
    "法人計算問題集2-1": "計算2-1", "法人計算問題集2-2": "計算2-2",
    "法人計算問題集3-1": "計算3-1", "法人計算問題集3-2": "計算3-2",
    "法人理論問題集": "理論",
}

BOOK_ORDER = [
    "法人計算問題集1-1", "法人計算問題集1-2",
    "法人計算問題集2-1", "法人計算問題集2-2",
    "法人計算問題集3-1", "法人計算問題集3-2",
    "法人理論問題集",
]

periods = {
    "今日": filter_period(attempts, today),
    "今週": filter_period(attempts, week_start(today)),
    "今月": filter_period(attempts, month_start(today)),
    "今年": filter_period(attempts, year_start(today)),
    "累計": attempts,
}

lines = []
L = lines.append

L(f"# 演習分析レポート")
L(f"")
L(f"> 生成日時: {now_str}")
L(f"> 問題数: {len(problems)} / 記録数: {len(attempts)}")
L(f"")

# ── Summary table ──
L(f"## サマリー")
L(f"")
L(f"| 期間 | 解答数 | 正答率 | 学習時間 | 問題種類 |")
L(f"|------|--------|--------|----------|----------|")
for name, atts in periods.items():
    s = compute_stats(atts)
    L(f"| {name} | {s['total']} | {s['rate']}% | {s['time_min']}分 | {s['unique']} |")
L(f"")

# ── Streak ──
streak = 0
d = today
while True:
    if any(a.get("date") == d for a in attempts):
        streak += 1
        dt = datetime.strptime(d, "%Y-%m-%d") - timedelta(days=1)
        d = dt.strftime("%Y-%m-%d")
    else:
        break
L(f"**連続学習日数: {streak}日**")
L(f"")

# ── Coverage ──
attempted_all = len(set(a.get("problem_id", "") for a in attempts))
cov = round(attempted_all / len(problems) * 100) if problems else 0
L(f"**カバー率: {cov}%** ({attempted_all}/{len(problems)}問)")
L(f"")

# ── Book-by-book ──
L(f"## 問題集別")
L(f"")
L(f"| 問題集 | 着手 | 解答数 | ○ | × | 正答率 | 時間 |")
L(f"|--------|------|--------|---|---|--------|------|")
all_stats = compute_stats(attempts)
for book in BOOK_ORDER:
    bs = all_stats["by_book"].get(book)
    if not bs:
        total = sum(1 for p in problems.values() if p.get("book") == book)
        L(f"| {BOOK_SHORT.get(book, book)} | 0/{total} | 0 | 0 | 0 | - | 0分 |")
        continue
    total = sum(1 for p in problems.values() if p.get("book") == book)
    rate = round(bs["correct"] / bs["total"] * 100) if bs["total"] > 0 else 0
    L(f"| {BOOK_SHORT.get(book, book)} | {bs['ids']}/{total} | {bs['total']} | {bs['correct']} | {bs['wrong']} | {rate}% | {bs['time']}分 |")
L(f"")

# ── Mistake analysis ──
L(f"## 間違い分類")
L(f"")
if all_stats["mistakes"]:
    L(f"| 分類 | 回数 | 割合 |")
    L(f"|------|------|------|")
    total_m = sum(all_stats["mistakes"].values())
    for mtype, cnt in sorted(all_stats["mistakes"].items(), key=lambda x: -x[1]):
        pct = round(cnt / total_m * 100) if total_m > 0 else 0
        bar = "█" * (pct // 5) + "░" * (20 - pct // 5)
        L(f"| {mtype} | {cnt} | {bar} {pct}% |")
    L(f"")
else:
    L(f"まだ間違いデータがありません。")
    L(f"")

# ── Daily heatmap (last 28 days) ──
L(f"## 日別推移（直近28日）")
L(f"")
L(f"| 日付 | 解答 | 正答率 | 時間 | ○× |")
L(f"|------|------|--------|------|-----|")
for i in range(27, -1, -1):
    dt = datetime.strptime(today, "%Y-%m-%d") - timedelta(days=i)
    d = dt.strftime("%Y-%m-%d")
    day_atts = [a for a in attempts if a.get("date") == d]
    if not day_atts:
        continue
    cnt = len(day_atts)
    cor = sum(1 for a in day_atts if a.get("result") == "○")
    wrg = cnt - cor
    rate = round(cor / cnt * 100) if cnt > 0 else 0
    tm = sum(a.get("time_min", 0) for a in day_atts)
    ox = "○" * min(cor, 10) + "×" * min(wrg, 10)
    L(f"| {d[5:]} | {cnt} | {rate}% | {tm}分 | {ox} |")
L(f"")

# ── Weak problems ──
L(f"## 弱点問題 TOP20")
L(f"")
if all_stats["weak"]:
    L(f"| # | 問題 | 問題集 | × | ○ | 正答率 |")
    L(f"|---|------|--------|---|---|--------|")
    for i, (pid, v) in enumerate(all_stats["weak"], 1):
        p = problems.get(pid, {})
        title = p.get("title", pid)
        book = BOOK_SHORT.get(p.get("book", ""), p.get("book", ""))
        total_p = v["correct"] + v["wrong"]
        rate_p = round(v["correct"] / total_p * 100) if total_p > 0 else 0
        L(f"| {i} | {title} | {book} | {v['wrong']} | {v['correct']} | {rate_p}% |")
    L(f"")
else:
    L(f"まだデータがありません。")
    L(f"")

# ── Speed analysis ──
L(f"## 時間分析")
L(f"")
speed_data = defaultdict(list)
for a in attempts:
    if a.get("time_min", 0) > 0:
        speed_data[a["problem_id"]].append(a["time_min"])

slow_problems = []
for pid, times in speed_data.items():
    p = problems.get(pid, {})
    target = p.get("time_min", 0)
    if not target:
        continue
    avg = round(sum(times) / len(times))
    ratio = round(avg / target * 100)
    if ratio > 120:
        slow_problems.append((pid, avg, target, ratio))

slow_problems.sort(key=lambda x: -x[3])
if slow_problems:
    L(f"### 目安時間超過（120%超）")
    L(f"")
    L(f"| 問題 | 実績(平均) | 目安 | 比率 |")
    L(f"|------|------------|------|------|")
    for pid, avg, target, ratio in slow_problems[:15]:
        p = problems.get(pid, {})
        L(f"| {p.get('title', pid)} | {avg}分 | {target}分 | {ratio}% |")
    L(f"")

# ── Write report ──
report_path = Path(report_dir) / "演習分析レポート.md"
report_path.write_text("\n".join(lines), encoding="utf-8")
print(f"レポート生成: {report_path}")
print(f"  記録数: {len(attempts)}, 問題数: {len(problems)}")
PYEOF
