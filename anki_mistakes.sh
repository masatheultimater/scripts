#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: bash anki_mistakes.sh [options]
  --dry-run            Anki APIを呼ばずにカード生成プレビュー
  --since DATE         指定日以降の間違いのみ対象 (YYYY-MM-DD)
  --deck-name NAME     デッキ名 (デフォルト: 法人税法::間違い)
  --anki-host HOST     AnkiConnectホスト（デフォルト: auto）
  --anki-port PORT     AnkiConnectポート（デフォルト: 8765）
  -h, --help           このヘルプを表示
USAGE
}

DRY_RUN=0
SINCE_DATE=""
DECK_NAME="法人税法::間違い"
ANKI_HOST="auto"
ANKI_PORT="8765"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --since)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --since の値が不足しています" >&2
        usage
        exit 1
      fi
      SINCE_DATE="$2"
      shift 2
      ;;
    --deck-name)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --deck-name の値が不足しています" >&2
        usage
        exit 1
      fi
      DECK_NAME="$2"
      shift 2
      ;;
    --anki-host)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --anki-host の値が不足しています" >&2
        usage
        exit 1
      fi
      ANKI_HOST="$2"
      shift 2
      ;;
    --anki-port)
      if [[ $# -lt 2 ]]; then
        echo "エラー: --anki-port の値が不足しています" >&2
        usage
        exit 1
      fi
      ANKI_PORT="$2"
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

export PYTHONPATH="${PYTHONPATH:-/home/masa/scripts}"
VAULT="${VAULT:-$HOME/vault/houjinzei}"
export VAULT DRY_RUN SINCE_DATE DECK_NAME ANKI_HOST ANKI_PORT

if [[ "${HOUJINZEI_LOCK_HELD:-}" != "1" ]]; then
  LOCKFILE="/tmp/houjinzei_vault.lock"
  exec 200>"$LOCKFILE"
  flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; exit 1; }
fi

python3 - <<'PY'
import datetime
import json
import os
import re
from pathlib import Path

from lib.anki_common import anki_request, detect_anki_host, sanitize_anki_tag, to_html_block
from lib.houjinzei_common import atomic_json_write, eprint, extract_body_sections, read_frontmatter
from lib.topic_normalize import get_parent_category, normalize_topic


def to_str(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def parse_yyyy_mm_dd(value: str) -> datetime.date:
    return datetime.datetime.strptime(value, "%Y-%m-%d").date()


def load_json(path: Path, label: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        eprint(f"エラー: {label} が見つかりません: {path}")
        raise SystemExit(1)
    except json.JSONDecodeError:
        eprint(f"エラー: {label} のJSON解析に失敗しました: {path}")
        raise SystemExit(1)


def load_exported(path: Path):
    if not path.exists():
        return {"exported": {}}
    data = load_json(path, "エクスポート追跡ファイル")
    if not isinstance(data, dict):
        return {"exported": {}}
    exported = data.get("exported")
    if not isinstance(exported, dict):
        data["exported"] = {}
    return data


def find_problem_by_topic(problem_map: dict, topic_id: str, note_fm: dict):
    title_candidate = topic_id.split("/")[-1].split("_")[-1]
    normalized_topic_candidates = []

    topics = note_fm.get("keywords")
    if isinstance(topics, list):
        normalized_topic_candidates.extend(normalize_topic(to_str(x)) for x in topics if to_str(x))

    subcategory = to_str(note_fm.get("subcategory"))
    if subcategory:
        normalized_topic_candidates.append(normalize_topic(subcategory))

    topic_field = to_str(note_fm.get("topic"))
    if topic_field:
        normalized_topic_candidates.append(normalize_topic(topic_field.split("_")[-1]))

    normalized_topic_candidates = [x for x in dict.fromkeys(normalized_topic_candidates) if x]

    for problem in problem_map.values():
        if title_candidate and title_candidate == to_str(problem.get("title")):
            return problem

    for problem in problem_map.values():
        p_topics = problem.get("normalized_topics") or []
        if not isinstance(p_topics, list):
            continue
        if set(normalized_topic_candidates) & set(to_str(t) for t in p_topics):
            return problem

    return None


def book_short(book: str) -> str:
    if not book:
        return "unknown"
    short = re.sub(r"[\s　]+", "", book)
    short = short.replace("問題集", "").replace("テキスト", "")
    short = re.sub(r"[^0-9A-Za-zぁ-んァ-ヶー一-龠]+", "_", short)
    return short.strip("_") or "unknown"


def make_front(problem: dict | None, topic_id: str) -> str:
    if not problem:
        title = topic_id.split("/")[-1]
        book = "(不明)"
        number = ""
        rank = ""
    else:
        title = to_str(problem.get("title")) or topic_id.split("/")[-1]
        book = to_str(problem.get("book")) or "(不明)"
        number = to_str(problem.get("number"))
        rank = to_str(problem.get("rank"))

    lines = [
        f"<b>問題</b>: {to_html_block(title)}",
        f"<b>問題集</b>: {to_html_block(book)}",
        f"<b>問題番号</b>: {to_html_block(number) if number else '(未設定)'}",
        f"<b>ランク</b>: {to_html_block(rank) if rank else '(未設定)'}",
    ]
    return "<br>".join(lines)


def make_back(mistake_labels: list[str], normalized_topics: list[str], strategy: str) -> str:
    mistake_text = " / ".join(mistake_labels) if mistake_labels else "(未設定)"
    topics_text = " / ".join(normalized_topics) if normalized_topics else "(未設定)"
    lines = [
        f"<b>間違い分類</b><br>{to_html_block(mistake_text)}",
        f"<b>関連論点</b><br>{to_html_block(topics_text)}",
        f"<b>対策</b><br>{to_html_block(strategy) if strategy else '(未記載)'}",
    ]
    return "<br><br>".join(lines)


def is_theory_problem(problem: dict | None, note_fm: dict) -> bool:
    if problem:
        p_type = to_str(problem.get("type"))
        book = to_str(problem.get("book"))
        if "理論" in p_type or "理論" in book:
            return True

    note_type = note_fm.get("type")
    if isinstance(note_type, list):
        return any("理論" in to_str(x) for x in note_type)
    return "理論" in to_str(note_type)


def main():
    vault = Path(os.environ["VAULT"])
    dry_run = os.environ.get("DRY_RUN", "0") == "1"
    since_raw = os.environ.get("SINCE_DATE", "")
    deck_root = os.environ.get("DECK_NAME", "法人税法::間違い")
    anki_host = os.environ.get("ANKI_HOST", "auto")
    anki_port = int(os.environ.get("ANKI_PORT", "8765"))

    since_date = None
    if since_raw:
        try:
            since_date = parse_yyyy_mm_dd(since_raw)
        except ValueError:
            eprint(f"エラー: --since は YYYY-MM-DD 形式で指定してください: {since_raw}")
            raise SystemExit(1)

    export_dir = vault / "50_エクスポート"
    results_path = export_dir / "komekome_results.json"
    problems_path = export_dir / "problems_master.json"
    tracking_path = export_dir / "anki_mistakes_exported.json"

    results = load_json(results_path, "komekome_results.json")
    session_date_raw = to_str(results.get("session_date"))
    try:
        session_date = parse_yyyy_mm_dd(session_date_raw)
    except ValueError:
        eprint(f"エラー: session_date が不正です: {session_date_raw}")
        raise SystemExit(1)

    if since_date and session_date < since_date:
        print(f"対象セッションなし: session_date={session_date_raw}, since={since_raw}")
        return

    results_list = results.get("results")
    if not isinstance(results_list, list):
        eprint("エラー: komekome_results.json の results が配列ではありません")
        raise SystemExit(1)

    problems_data = load_json(problems_path, "problems_master.json")
    problem_map = problems_data.get("problems") if isinstance(problems_data, dict) else None
    if not isinstance(problem_map, dict):
        eprint("エラー: problems_master.json の problems がオブジェクトではありません")
        raise SystemExit(1)

    exported_data = load_exported(tracking_path)
    exported_map = exported_data.setdefault("exported", {})

    candidates = []
    skipped_exported = 0
    for idx, result in enumerate(results_list):
        if not isinstance(result, dict):
            continue
        if result.get("correct") is not False:
            continue

        topic_id = to_str(result.get("topic_id"))
        if not topic_id:
            continue

        export_key = f"{session_date_raw}:{idx}:{topic_id}"
        if export_key in exported_map:
            skipped_exported += 1
            continue

        note_path = vault / "10_論点" / f"{topic_id}.md"
        if not note_path.exists():
            eprint(f"警告: 対応ノートが見つかりません: {note_path}")
            continue

        fm, body = read_frontmatter(note_path)
        sections = extract_body_sections(body)
        strategy = to_str(sections.get("mistakes"))

        mistake_labels = []
        fm_mistakes = fm.get("mistakes") if isinstance(fm, dict) else None
        if isinstance(fm_mistakes, list):
            mistake_labels.extend(to_str(x) for x in fm_mistakes if to_str(x))
        elif fm_mistakes:
            mistake_labels.append(to_str(fm_mistakes))

        result_mistakes = result.get("mistakes")
        if isinstance(result_mistakes, list):
            mistake_labels.extend(to_str(x) for x in result_mistakes if to_str(x))
        elif result_mistakes:
            mistake_labels.append(to_str(result_mistakes))

        mistake_labels = list(dict.fromkeys(x for x in mistake_labels if x))

        problem = find_problem_by_topic(problem_map, topic_id, fm if isinstance(fm, dict) else {})
        if problem and isinstance(problem.get("normalized_topics"), list):
            normalized_topics = [to_str(x) for x in problem.get("normalized_topics") if to_str(x)]
        else:
            topic_tail = topic_id.split("/")[-1].split("_")[-1]
            normalized_topics = [normalize_topic(topic_tail)]

        if problem:
            parent_category = to_str(problem.get("parent_category")) or get_parent_category(normalized_topics[0])
            rank = to_str(problem.get("rank")) or "unknown"
            book = to_str(problem.get("book"))
        else:
            parent_category = get_parent_category(normalized_topics[0])
            rank = "unknown"
            book = ""

        front = make_front(problem, topic_id)
        back = make_back(mistake_labels, normalized_topics, strategy)

        session_tag = f"mistake_{session_date.strftime('%Y%m%d')}"
        tags = [
            sanitize_anki_tag(session_tag),
            sanitize_anki_tag(f"book_{book_short(book)}"),
            sanitize_anki_tag(f"rank_{rank}"),
        ]

        deck_name = f"{deck_root}::{parent_category}"
        note = {
            "deckName": deck_name,
            "modelName": "Basic",
            "fields": {
                "Front": front,
                "Back": back,
            },
            "tags": tags,
        }
        candidates.append(
            {
                "export_key": export_key,
                "topic_id": topic_id,
                "deck_name": deck_name,
                "note": note,
                "is_theory_memory": is_theory_problem(problem, fm if isinstance(fm, dict) else {})
                and any("暗記不足" in label for label in mistake_labels),
                "front_preview": re.sub(r"<[^>]+>", "", front),
            }
        )

    print(f"誤答候補: {len(candidates)}件")
    if skipped_exported:
        print(f"既エクスポート済みスキップ: {skipped_exported}件")

    if not candidates:
        print("処理対象がないため終了します。")
        return

    notes_to_send = []
    note_owner_keys = []
    for c in candidates:
        notes_to_send.append(c["note"])
        note_owner_keys.append((c["export_key"], c["deck_name"], c["topic_id"], False))
        if c["is_theory_memory"]:
            theory_note = dict(c["note"])
            theory_note["deckName"] = "法人税法::理論"
            notes_to_send.append(theory_note)
            note_owner_keys.append((c["export_key"], "法人税法::理論", c["topic_id"], True))

    if dry_run:
        print("DRY RUN: AnkiConnect呼び出しをスキップします。")
        for c in candidates:
            print(f"- {c['topic_id']} -> {c['deck_name']}")
            if c["is_theory_memory"]:
                print(f"  + 理論デッキ追加: 法人税法::理論")
        return

    resolved_host = detect_anki_host() if anki_host == "auto" else anki_host
    try:
        version = anki_request("version", host=resolved_host, port=anki_port)
    except Exception as exc:
        eprint(f"エラー: AnkiConnect接続に失敗しました: {exc}")
        raise SystemExit(1)

    print(f"AnkiConnect接続OK: host={resolved_host}, port={anki_port}, version={version}")

    decks = sorted({n["deckName"] for n in notes_to_send})
    for deck in decks:
        anki_request("createDeck", {"deck": deck}, host=resolved_host, port=anki_port)

    note_ids = anki_request("addNotes", {"notes": notes_to_send}, host=resolved_host, port=anki_port)
    if not isinstance(note_ids, list) or len(note_ids) != len(notes_to_send):
        eprint("エラー: addNotes の結果形式が不正です")
        raise SystemExit(1)

    now_iso = datetime.datetime.now().replace(microsecond=0).isoformat()
    success = 0
    duplicate_or_fail = 0

    for (export_key, deck_name, topic_id, is_theory_copy), note_id in zip(note_owner_keys, note_ids):
        if note_id is None:
            duplicate_or_fail += 1
            continue

        record = exported_map.setdefault(
            export_key,
            {
                "topic_id": topic_id,
                "session_date": session_date_raw,
                "exported_at": now_iso,
                "note_ids": [],
            },
        )
        note_ids_list = record.get("note_ids")
        if not isinstance(note_ids_list, list):
            note_ids_list = []
            record["note_ids"] = note_ids_list

        note_ids_list.append(
            {
                "deck": deck_name,
                "note_id": note_id,
                "is_theory_copy": is_theory_copy,
            }
        )
        success += 1

    atomic_json_write(tracking_path, exported_data)

    print("Anki誤答エクスポート完了")
    print(f"- 送信ノート数: {len(notes_to_send)}")
    print(f"- 追加成功: {success}")
    print(f"- 重複/失敗: {duplicate_or_fail}")
    print(f"- 管理ファイル: {tracking_path}")


try:
    main()
except SystemExit:
    raise
except Exception as exc:
    eprint(f"エラー: {exc}")
    raise SystemExit(1)
PY
