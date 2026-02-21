#!/usr/bin/env bash
# ============================================================
# 法人税法 カテゴリ別弱点分析ダッシュボード
# トピックノートのfrontmatterとセッションログからカテゴリ別進捗を分析
# 使い方: bash dashboard.sh
# 出力: $VAULT/40_分析/ダッシュボード.md
# ============================================================
set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

python3 - "$VAULT" <<'PYEOF'
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import date, datetime, timedelta
from pathlib import Path

import yaml

from lib.houjinzei_common import (
    VaultPaths,
    read_frontmatter,
    to_int,
)

vault_path = sys.argv[1]
vp = VaultPaths(vault_path)

# ────────────────────────────────────
# 1. Topic Notes Analysis
# ────────────────────────────────────
categories = defaultdict(lambda: {
    "total": 0, "enriched": 0,
    "a_total": 0, "b_total": 0, "c_total": 0,
    "stage_未着手": 0, "stage_学習中": 0, "stage_復習中": 0, "stage_卒業": 0,
    "calc_correct": 0, "calc_wrong": 0,
    "kome_total": 0,
    "topics": [],
})

all_topics = []
for md in sorted(vp.topics.rglob("*.md")):
    if md.name in ("README.md", "CLAUDE.md"):
        continue
    try:
        fm, body = read_frontmatter(md)
    except Exception:
        continue
    if not isinstance(fm, dict):
        continue

    cat = str(fm.get("category", "不明")).strip()
    topic = str(fm.get("topic", md.stem)).strip()
    importance = str(fm.get("importance", "")).strip()
    stage = str(fm.get("stage", "未着手")).strip()
    cc = to_int(fm.get("calc_correct", 0))
    cw = to_int(fm.get("calc_wrong", 0))
    kome = to_int(fm.get("kome_total", 0))
    idx = to_int(fm.get("interval_index", 0))
    body_len = len(body.strip()) if body else 0

    c = categories[cat]
    c["total"] += 1
    if body_len > 200:
        c["enriched"] += 1
    if importance == "A":
        c["a_total"] += 1
    elif importance == "B":
        c["b_total"] += 1
    elif importance == "C":
        c["c_total"] += 1

    stage_key = f"stage_{stage}" if f"stage_{stage}" in c else "stage_未着手"
    c[stage_key] += 1
    c["calc_correct"] += cc
    c["calc_wrong"] += cw
    c["kome_total"] += kome

    entry = {
        "topic": topic, "category": cat, "importance": importance,
        "stage": stage, "cc": cc, "cw": cw, "kome": kome, "idx": idx,
    }
    c["topics"].append(entry)
    all_topics.append(entry)

# ────────────────────────────────────
# 2. Session Logs Analysis
# ────────────────────────────────────
session_dir = Path(vault_path) / "20_演習ログ" / "komekome"
sessions = []
topic_results = defaultdict(lambda: {"correct": 0, "wrong": 0})

if session_dir.exists():
    for md in sorted(session_dir.glob("*.md")):
        try:
            fm, body = read_frontmatter(md)
        except Exception:
            continue
        if not isinstance(fm, dict):
            continue
        sessions.append({
            "date": str(fm.get("date", "")),
            "total": to_int(fm.get("total_questions", 0)),
            "correct": to_int(fm.get("correct_count", 0)),
        })
        # Parse detail table
        for line in body.splitlines():
            m = re.match(r"\|\s*(\S+/\S+)\s*\|.*\|\s*(○|×)\s*\|", line)
            if m:
                tid, result = m.group(1), m.group(2)
                cat_from_tid = tid.split("/")[0] if "/" in tid else "不明"
                if result == "○":
                    topic_results[tid]["correct"] += 1
                    topic_results[cat_from_tid + "/_cat"]["correct"] = \
                        topic_results.get(cat_from_tid + "/_cat", {"correct": 0, "wrong": 0})["correct"] + 1
                else:
                    topic_results[tid]["wrong"] += 1
                    topic_results[cat_from_tid + "/_cat"]["wrong"] = \
                        topic_results.get(cat_from_tid + "/_cat", {"correct": 0, "wrong": 0})["wrong"] + 1

# Category-level session results
cat_session_results = {}
for key, vals in topic_results.items():
    if key.endswith("/_cat"):
        cat_name = key.replace("/_cat", "")
        cat_session_results[cat_name] = vals

# ────────────────────────────────────
# 3. Problems Master Analysis
# ────────────────────────────────────
pm_path = vp.export / "problems_master.json"
problem_cats = Counter()
if pm_path.exists():
    with open(pm_path) as f:
        pm = json.load(f)
    for pid, p in pm.get("problems", {}).items():
        if isinstance(p, dict):
            problem_cats[p.get("parent_category", "不明")] += 1

# ────────────────────────────────────
# 4. Generate Dashboard
# ────────────────────────────────────
today = date.today().strftime("%Y-%m-%d")
now_str = datetime.now().strftime("%Y-%m-%d %H:%M")

L = []

L.append("# 法人税法 学習ダッシュボード")
L.append("")
L.append(f"> 生成日時: {now_str}")
L.append("")

# ── Overall Summary ──
total_topics = sum(c["total"] for c in categories.values())
total_enriched = sum(c["enriched"] for c in categories.values())
total_progress = sum(1 for t in all_topics if t["stage"] != "未着手")
total_graduated = sum(1 for t in all_topics if t["stage"] == "卒業")
total_cc = sum(t["cc"] for t in all_topics)
total_cw = sum(t["cw"] for t in all_topics)
overall_rate = round(total_cc / (total_cc + total_cw) * 100) if (total_cc + total_cw) > 0 else 0

L.append("## 全体サマリー")
L.append("")
L.append(f"| 指標 | 値 |")
L.append(f"|------|-----|")
L.append(f"| トピック総数 | {total_topics} |")
L.append(f"| 充実済み | {total_enriched} ({round(total_enriched/total_topics*100)}%) |")
L.append(f"| 学習進捗あり | {total_progress} ({round(total_progress/total_topics*100)}%) |")
L.append(f"| 卒業 | {total_graduated} |")
L.append(f"| 累計正解率 | {overall_rate}% ({total_cc}/{total_cc+total_cw}) |")
L.append(f"| 問題マスター | {sum(problem_cats.values())}問 |")
L.append(f"| セッション数 | {len(sessions)} |")
L.append("")

# ── Category Progress Table ──
L.append("## カテゴリ別進捗")
L.append("")
L.append("| カテゴリ | トピック | 充実 | 進捗 | 卒業 | 正答率 | 問題数 | 評価 |")
L.append("|----------|----------|------|------|------|--------|--------|------|")

# Sort categories by total topics descending
cat_order = sorted(categories.keys(), key=lambda k: -categories[k]["total"])
for cat_name in cat_order:
    c = categories[cat_name]
    enriched_pct = round(c["enriched"] / c["total"] * 100) if c["total"] > 0 else 0
    progress = c["total"] - c["stage_未着手"]
    progress_pct = round(progress / c["total"] * 100) if c["total"] > 0 else 0
    cc_cat = c["calc_correct"]
    cw_cat = c["calc_wrong"]
    rate = round(cc_cat / (cc_cat + cw_cat) * 100) if (cc_cat + cw_cat) > 0 else 0
    prob_count = problem_cats.get(cat_name, 0)

    # Rating based on progress and accuracy
    if c["stage_卒業"] >= c["total"] * 0.5:
        rating = "A"
    elif progress_pct >= 30 and rate >= 80:
        rating = "B"
    elif progress_pct >= 10:
        rating = "C"
    elif progress_pct > 0:
        rating = "D"
    else:
        rating = "E"

    bar_filled = round(progress_pct / 10)
    bar = "█" * bar_filled + "░" * (10 - bar_filled)

    rate_str = f"{rate}%" if (cc_cat + cw_cat) > 0 else "-"
    L.append(f"| {cat_name} | {c['total']} | {enriched_pct}% | {bar} {progress_pct}% | {c['stage_卒業']} | {rate_str} | {prob_count} | {rating} |")

L.append("")

# ── Category Detail: Stage Distribution ──
L.append("## ステージ分布")
L.append("")
L.append("| カテゴリ | 未着手 | 学習中 | 復習中 | 卒業 | A | B | C |")
L.append("|----------|--------|--------|--------|------|---|---|---|")
for cat_name in cat_order:
    c = categories[cat_name]
    L.append(f"| {cat_name} | {c['stage_未着手']} | {c['stage_学習中']} | {c['stage_復習中']} | {c['stage_卒業']} | {c['a_total']} | {c['b_total']} | {c['c_total']} |")
L.append("")

# ── Weakness Detection ──
L.append("## 弱点カテゴリ")
L.append("")

weak_cats = []
for cat_name in cat_order:
    c = categories[cat_name]
    cc_cat = c["calc_correct"]
    cw_cat = c["calc_wrong"]
    if (cc_cat + cw_cat) >= 3:  # minimum attempts threshold
        rate = cc_cat / (cc_cat + cw_cat) * 100
        if rate < 85:
            weak_cats.append((cat_name, rate, cc_cat, cw_cat))

if weak_cats:
    weak_cats.sort(key=lambda x: x[1])
    L.append("以下のカテゴリは正答率が85%未満で、重点学習が推奨されます：")
    L.append("")
    for cat_name, rate, cc, cw in weak_cats:
        L.append(f"- **{cat_name}**: {round(rate)}% ({cc}/{cc+cw})")
    L.append("")
else:
    L.append("正答率85%未満のカテゴリはありません。")
    L.append("")

# ── Repeated Wrong Topics ──
L.append("## 繰返し不正解トピック")
L.append("")
repeated_wrong = [
    t for t in all_topics
    if t["cw"] >= 2 and t["cw"] > t["cc"]
]
repeated_wrong.sort(key=lambda t: -(t["cw"] - t["cc"]))

if repeated_wrong:
    L.append("| トピック | カテゴリ | ○ | × | 差 | ランク |")
    L.append("|----------|----------|---|---|----|--------|")
    for t in repeated_wrong[:15]:
        diff = t["cw"] - t["cc"]
        L.append(f"| {t['topic']} | {t['category']} | {t['cc']} | {t['cw']} | -{diff} | {t['importance']} |")
    L.append("")
else:
    L.append("繰返し不正解のトピックはまだありません。")
    L.append("")

# ── Coverage Gap ──
L.append("## カバレッジギャップ")
L.append("")
L.append("問題マスターに問題があるがトピック未学習のカテゴリ：")
L.append("")

gap_cats = []
for cat_name in cat_order:
    c = categories[cat_name]
    prob_count = problem_cats.get(cat_name, 0)
    progress = c["total"] - c["stage_未着手"]
    if prob_count > 0 and progress == 0:
        gap_cats.append((cat_name, c["total"], prob_count))

if gap_cats:
    for cat_name, t_count, p_count in gap_cats:
        L.append(f"- **{cat_name}**: {t_count}トピック / {p_count}問 → 未着手")
else:
    L.append("全カテゴリで学習が開始されています。")
L.append("")

# ── Session History ──
L.append("## 直近セッション")
L.append("")
if sessions:
    L.append("| 日付 | 問数 | 正解 | 正答率 |")
    L.append("|------|------|------|--------|")
    for s in sorted(sessions, key=lambda x: x["date"], reverse=True)[:10]:
        rate = round(s["correct"] / s["total"] * 100) if s["total"] > 0 else 0
        L.append(f"| {s['date']} | {s['total']} | {s['correct']} | {rate}% |")
    L.append("")
else:
    L.append("セッションデータがまだありません。")
    L.append("")

# ── Recommendations ──
L.append("## 推奨アクション")
L.append("")

recs = []

# Enrichment recommendation
if total_enriched < total_topics * 0.8:
    unenriched = total_topics - total_enriched
    recs.append(f"1. **ノート充実化**: {unenriched}件の空テンプレートを充実化（`enrich_topics.sh`）")

# Weak category recommendation
if weak_cats:
    worst_cat = weak_cats[0][0]
    recs.append(f"2. **弱点集中**: {worst_cat} カテゴリの重点学習")

# Coverage gap recommendation
if gap_cats:
    gap_names = ", ".join(g[0] for g in gap_cats[:3])
    recs.append(f"3. **カバレッジ拡大**: {gap_names} の学習開始")

# Low progress recommendation
low_progress = [cat_name for cat_name in cat_order
                if categories[cat_name]["total"] > 5
                and categories[cat_name]["stage_未着手"] == categories[cat_name]["total"]]
if low_progress:
    names = ", ".join(low_progress[:3])
    recs.append(f"4. **未着手カテゴリ**: {names}")

if recs:
    for r in recs:
        L.append(r)
else:
    L.append("素晴らしい進捗です！引き続き頑張りましょう。")
L.append("")

# ── Write ──
output_path = Path(vault_path) / "40_分析" / "ダッシュボード.md"
output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text("\n".join(L), encoding="utf-8")
print(f"ダッシュボード生成: {output_path}")
print(f"  {len(categories)}カテゴリ / {total_topics}トピック / {total_progress}進捗あり")
PYEOF
