#!/bin/bash
# ============================================================
# コメコメ結果のObsidian書き戻し
# 使い方: bash komekome_writeback.sh <results_json_path>
# 例:     bash komekome_writeback.sh ~/vault/houjinzei/50_エクスポート/komekome_results.json
# ============================================================

set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

if [ $# -ne 1 ]; then
  echo "使い方: bash komekome_writeback.sh <results_json_path>"
  exit 1
fi

RESULTS_JSON="$1"

if [ ! -f "$RESULTS_JSON" ]; then
  echo "エラー: JSONファイルが見つかりません: $RESULTS_JSON"
  exit 1
fi

# ファイルロック（並行実行対策）
LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; exit 1; }

python3 - "$RESULTS_JSON" "$VAULT" <<'PYEOF'
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

import yaml

from lib.houjinzei_common import (
    VaultPaths,
    GRADUATION_GAP_DAYS,
    GRADUATION_INTERVAL_INDEX,
    GRADUATION_MIN_KOME,
    INTERVAL_DAYS,
    KOME_THRESHOLD_REVIEW,
    read_frontmatter,
    to_int,
    write_frontmatter,
)


def error_exit(message: str) -> None:
    print(f"エラー: {message}")
    sys.exit(1)


def load_json(path: Path):
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        error_exit(f"JSON形式が不正です: {e}")
    except OSError as e:
        error_exit(f"JSONファイルの読み込みに失敗しました: {e}")


def validate_input(data):
    if not isinstance(data, dict):
        error_exit("JSONルートはオブジェクトである必要があります")

    for key in ["session_date", "session_id", "results"]:
        if key not in data:
            error_exit(f"必須キーがありません: {key}")

    session_date = data["session_date"]
    session_id = data["session_id"]
    results = data["results"]

    if not isinstance(session_date, str):
        error_exit("session_date は文字列である必要があります")
    try:
        datetime.strptime(session_date, "%Y-%m-%d")
    except ValueError:
        error_exit("session_date は YYYY-MM-DD 形式で指定してください")

    if not isinstance(session_id, str) or not session_id.strip():
        error_exit("session_id は空でない文字列である必要があります")

    if not isinstance(results, list):
        error_exit("results は配列である必要があります")

    validated = []
    for i, item in enumerate(results):
        if not isinstance(item, dict):
            error_exit(f"results[{i}] はオブジェクトである必要があります")

        for key in ["topic_id", "kome_count", "correct", "time_seconds"]:
            if key not in item:
                error_exit(f"results[{i}] に必須キーがありません: {key}")

        topic_id = item["topic_id"]
        kome_count = item["kome_count"]
        correct = item["correct"]
        time_seconds = item["time_seconds"]
        mistakes = item.get("mistakes", [])

        if not isinstance(topic_id, str) or not topic_id.strip():
            error_exit(f"results[{i}].topic_id は空でない文字列である必要があります")

        if not isinstance(kome_count, int) or kome_count < 0:
            error_exit(f"results[{i}].kome_count は0以上の整数である必要があります")

        if not isinstance(correct, bool):
            error_exit(f"results[{i}].correct は true/false である必要があります")

        if not isinstance(time_seconds, (int, float)) or time_seconds < 0:
            error_exit(f"results[{i}].time_seconds は0以上の数値である必要があります")

        if mistakes is None:
            mistakes = []
        if not isinstance(mistakes, list):
            error_exit(f"results[{i}].mistakes は配列である必要があります")

        cleaned_mistakes = []
        for j, m in enumerate(mistakes):
            if not isinstance(m, str):
                error_exit(f"results[{i}].mistakes[{j}] は文字列である必要があります")
            if m.strip():
                cleaned_mistakes.append(m.strip())

        # intervalIndex は任意フィールド（コメコメアプリ側が送信）
        interval_index = item.get("intervalIndex")
        if interval_index is not None:
            try:
                interval_index = int(interval_index)
            except (ValueError, TypeError):
                interval_index = None

        validated.append(
            {
                "topic_id": topic_id.strip(),
                "kome_count": kome_count,
                "correct": correct,
                "time_seconds": int(time_seconds),
                "mistakes": cleaned_mistakes,
                "interval_index": interval_index,
            }
        )

    return session_date, session_id.strip(), validated


def build_topic_index(notes_root: Path):
    """topic_id（パスベース）と topic フィールド値の両方でインデックスを構築する。"""
    path_index = {}   # key: relative path without .md → Path
    topic_index = {}  # key: topic field value → [Path, ...]
    parse_errors = []

    for path in sorted(notes_root.rglob("*.md")):
        if path.name in ("README.md", "CLAUDE.md"):
            continue

        try:
            fm, _ = read_frontmatter(path)
        except OSError as e:
            parse_errors.append(f"{path}: 読み込み失敗 ({e})")
            continue
        except yaml.YAMLError as e:
            parse_errors.append(f"{path}: frontmatter解析失敗 ({e})")
            continue

        if not fm:
            continue

        # パスベースの topic_id（generate_quiz.sh と同じ形式）
        rel = path.relative_to(notes_root).as_posix()
        path_key = rel[:-3] if rel.endswith(".md") else rel
        path_index[path_key] = path

        # topic フィールド値（互換フォールバック用）
        topic = fm.get("topic")
        if isinstance(topic, str) and topic.strip():
            topic_index.setdefault(topic.strip(), []).append(path)

    return path_index, topic_index, parse_errors


def write_session_log(log_path: Path, session_date: str, session_id: str, results):
    total_questions = len(results)
    correct_count = sum(1 for r in results if r["correct"])
    total_seconds = sum(r["time_seconds"] for r in results)
    accuracy = (correct_count / total_questions * 100.0) if total_questions else 0.0
    total_minutes = total_seconds / 60.0

    lines = [
        "---",
        f"date: {session_date}",
        f"session_id: {session_id}",
        "type: コメコメ",
        f"total_questions: {total_questions}",
        f"correct_count: {correct_count}",
        "---",
        f"# コメコメセッション {session_date}",
        "",
        "## 結果サマリ",
        f"- 正解率: {accuracy:.1f}%",
        f"- 所要時間: {total_minutes:.1f}分",
        "",
        "## 詳細",
        "| 論点 | コメ数 | 結果 | 時間 |",
        "|------|--------|------|------|",
    ]

    for r in results:
        result_mark = "○" if r["correct"] else "×"
        lines.append(f"| {r['topic_id']} | {r['kome_count']} | {result_mark} | {r['time_seconds']}s |")

    content = "\n".join(lines) + "\n"
    log_path.write_text(content, encoding="utf-8")

    return {
        "total_questions": total_questions,
        "correct_count": correct_count,
        "total_seconds": total_seconds,
        "accuracy": accuracy,
    }


def update_topic_note(path: Path, topic_result, session_date: str):
    data, body = read_frontmatter(path)
    if not isinstance(data, dict) or not data:
        raise ValueError("frontmatterがありません")

    current_kome = to_int(data.get("kome_total", 0))
    new_kome = current_kome + topic_result["kome_count"]
    data["kome_total"] = new_kome

    # last_practiced の旧値を保存（卒業判定の gap 計算用）
    old_last_practiced = data.get("last_practiced", "")
    data["last_practiced"] = session_date

    # --- interval_index の読み取り ---
    current_interval = to_int(data.get("interval_index", 0))

    # コメコメ側から送信された intervalIndex があれば採用
    incoming_interval = topic_result.get("interval_index")
    if incoming_interval is not None:
        current_interval = incoming_interval

    # --- stage / status 更新 ---
    current_status = data.get("status", "未着手")
    calc_correct = to_int(data.get("calc_correct", 0))
    calc_wrong = to_int(data.get("calc_wrong", 0))

    # 卒業済みノートは stage/status を巻き戻さない
    if current_status == "卒業":
        data["stage"] = data.get("stage", "卒業済")
    elif topic_result["correct"]:
        data["stage"] = "復習中" if new_kome >= KOME_THRESHOLD_REVIEW else "学習中"

        # status 遷移
        if current_status == "未着手":
            data["status"] = "学習中"
        elif current_status == "学習中" and new_kome >= KOME_THRESHOLD_REVIEW:
            data["status"] = "復習中"

        # interval_index をインクリメント（正解時）
        if current_status in ("復習中", "学習中"):
            current_interval = min(current_interval + 1, GRADUATION_INTERVAL_INDEX)

        # 卒業判定: interval_index ベース（優先）
        graduated = False
        if current_interval >= GRADUATION_INTERVAL_INDEX and new_kome >= GRADUATION_MIN_KOME:
            graduated = True

        # レガシーフォールバック: gap ベース（interval_index 未設定ノート向け）
        if not graduated and old_last_practiced and current_status == "復習中":
            try:
                from datetime import date as _date
                if isinstance(old_last_practiced, (_date, datetime)):
                    old_d = old_last_practiced if isinstance(old_last_practiced, _date) else old_last_practiced.date()
                else:
                    old_d = datetime.strptime(str(old_last_practiced), "%Y-%m-%d").date()
                new_d = datetime.strptime(session_date, "%Y-%m-%d").date()
                gap = (new_d - old_d).days
                if gap >= GRADUATION_GAP_DAYS and new_kome >= GRADUATION_MIN_KOME:
                    graduated = True
            except ValueError:
                pass

        if graduated:
            data["status"] = "卒業"
            data["stage"] = "卒業済"
    else:
        # 不正解時: ステータス補正、interval_index リセット
        if current_status == "未着手":
            data["status"] = "学習中"
            data["stage"] = "学習中"
        current_interval = 0

    data["interval_index"] = current_interval

    if not topic_result["correct"] and topic_result["mistakes"]:
        current_mistakes = data.get("mistakes", [])
        if current_mistakes in (None, ""):
            current_mistakes = []
        elif not isinstance(current_mistakes, list):
            current_mistakes = [str(current_mistakes)]

        current_mistakes.extend(topic_result["mistakes"])
        data["mistakes"] = current_mistakes

    write_frontmatter(path, data, body)


json_path = Path(sys.argv[1]).expanduser().resolve()
vp = VaultPaths(sys.argv[2])
notes_root = vp.topics
log_dir = vp.exercise_log / "komekome"

if not json_path.exists():
    error_exit(f"JSONファイルが存在しません: {json_path}")
if not notes_root.exists():
    error_exit(f"論点ディレクトリが存在しません: {notes_root}")

raw_data = load_json(json_path)
session_date, session_id, results = validate_input(raw_data)

safe_session_id = re.sub(r"[^0-9A-Za-z._-]+", "_", session_id).strip("_") or "session"
log_dir.mkdir(parents=True, exist_ok=True)
log_path = log_dir / f"{session_date}_{safe_session_id}.md"

session_stats = write_session_log(log_path, session_date, session_id, results)

path_index, topic_index, parse_errors = build_topic_index(notes_root)

updated_count = 0
not_found = []
update_errors = []
multiple_matches = []

for result in results:
    tid = result["topic_id"]

    # 1) パスベースで完全一致（generate_quiz.sh 出力形式）
    target = path_index.get(tid)
    if target:
        pass  # found
    else:
        # 2) topic フィールド値で互換フォールバック
        candidates = topic_index.get(tid, [])
        if not candidates:
            not_found.append(tid)
            continue
        target = sorted(candidates)[0]
        if len(candidates) > 1:
            multiple_matches.append((tid, [str(p) for p in sorted(candidates)]))

    try:
        update_topic_note(target, result, session_date)
        updated_count += 1
    except Exception as e:
        update_errors.append(f"{target}: {e}")

print("書き戻し完了")
print(f"セッションログ: {log_path}")
print(f"問題数: {session_stats['total_questions']}")
print(f"正解数: {session_stats['correct_count']}")
print(f"正解率: {session_stats['accuracy']:.1f}%")
print(f"総時間: {session_stats['total_seconds']}秒")
print(f"論点ノート更新: {updated_count}件")

if parse_errors:
    print("\n注意: 解析できないノートがあります")
    for msg in parse_errors:
        print(f"- {msg}")

if multiple_matches:
    print("\n注意: topic一致が複数あるため先頭の1件のみ更新しました")
    for topic_id, paths in multiple_matches:
        joined = " / ".join(paths)
        print(f"- {topic_id}: {joined}")

if not_found:
    print("\n注意: 該当topicのノートが見つかりませんでした")
    for topic_id in not_found:
        print(f"- {topic_id}")

if update_errors:
    print("\n注意: 更新エラーが発生しました")
    for msg in update_errors:
        print(f"- {msg}")
PYEOF
