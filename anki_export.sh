#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
使い方: bash anki_export.sh [options]
  --dry-run           Anki APIを呼ばずに候補リストのみ表示
  --deck-name NAME    デッキ名（デフォルト: 法人税法）
  --anki-host HOST    AnkiConnectホスト（デフォルト: auto）
  --anki-port PORT    AnkiConnectポート（デフォルト: 8765）
  --force             既エクスポート済みも再エクスポート
  -h, --help          このヘルプを表示
USAGE
}

DRY_RUN=0
DECK_NAME="法人税法"
ANKI_HOST="auto"
ANKI_PORT="8765"
FORCE_FLAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
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
    --force)
      FORCE_FLAG=1
      shift
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

VAULT="${VAULT:-$HOME/vault/houjinzei}"
export VAULT DRY_RUN DECK_NAME ANKI_HOST ANKI_PORT FORCE_FLAG
export PYTHONPATH="/home/masa/scripts"

LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; exit 1; }

python3 - <<'PY'
import datetime
import json
import os
import re
from pathlib import Path

from lib.anki_common import anki_request, detect_anki_host, sanitize_anki_tag, to_html_block
from lib.houjinzei_common import eprint, extract_body_sections, read_frontmatter


def to_str(value) -> str:
    if value is None:
        return ""
    return str(value).strip()


def load_exported(path: Path):
    if not path.exists():
        return {"exported": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        eprint(f"エラー: JSONの解析に失敗しました: {path}")
        raise SystemExit(1)
    if not isinstance(data, dict):
        return {"exported": {}}
    exported = data.get("exported")
    if not isinstance(exported, dict):
        data["exported"] = {}
    return data


def candidate_key(topic: str, category: str) -> str:
    return f"{topic}_{category}"


def print_candidates(candidates):
    if not candidates:
        print("候補はありません。")
        return
    for item in candidates:
        print(f"- {item['topic']} / {item['category']} ({item['path']})")


def _extract_named_section(body: str, heading: str) -> str:
    marker = f"\n## {heading}\n"
    start = body.find(marker)
    if start == -1:
        if body.startswith(f"## {heading}\n"):
            start = 0
        else:
            return ""
    content_start = start + len(marker)
    next_h = re.search(r"\n##\s+", body[content_start:])
    if not next_h:
        return body[content_start:].strip()
    return body[content_start:content_start + next_h.start()].strip()


def main():
    vault = Path(os.environ["VAULT"])
    dry_run = os.environ.get("DRY_RUN", "0") == "1"
    deck_name = os.environ.get("DECK_NAME", "法人税法")
    anki_host = os.environ.get("ANKI_HOST", "auto")
    anki_port = int(os.environ.get("ANKI_PORT", "8765"))
    force_flag = os.environ.get("FORCE_FLAG", "0") == "1"

    topic_dir = vault / "10_論点"
    export_dir = vault / "50_エクスポート"
    exported_json_path = export_dir / "anki_exported.json"

    if not topic_dir.exists():
        eprint(f"エラー: 論点ディレクトリが見つかりません: {topic_dir}")
        raise SystemExit(1)

    export_dir.mkdir(parents=True, exist_ok=True)
    exported_data = load_exported(exported_json_path)
    exported_map = exported_data.setdefault("exported", {})

    graduated = []
    for md_path in sorted(topic_dir.rglob("*.md")):
        if md_path.name in ("README.md", "CLAUDE.md"):
            continue
        fm, body = read_frontmatter(md_path)
        if not isinstance(fm, dict):
            continue

        status = to_str(fm.get("status"))
        if status != "卒業":
            continue

        topic = to_str(fm.get("topic")) or md_path.stem
        category = to_str(fm.get("category")) or "未分類"
        key = candidate_key(topic, category)
        graduated.append(
            {
                "key": key,
                "path": str(md_path),
                "path_obj": md_path,
                "topic": topic,
                "category": category,
                "body": body,
                "fm": fm,
            }
        )

    if force_flag:
        candidates = graduated
    else:
        candidates = [item for item in graduated if item["key"] not in exported_map]

    print(f"卒業論点: {len(graduated)}件")
    print(f"エクスポート候補: {len(candidates)}件")

    if not candidates:
        print("処理対象がないため終了します。")
        return

    resolved_host = detect_anki_host() if anki_host == "auto" else anki_host
    connected = False
    version = None
    connection_error = None
    if not dry_run:
        try:
            version = anki_request("version", host=resolved_host, port=anki_port)
            connected = True
        except Exception as exc:
            connection_error = str(exc)

    if dry_run or not connected:
        if dry_run:
            print("DRY RUN: AnkiConnect呼び出しをスキップします。")
        else:
            eprint(f"AnkiConnect接続に失敗したため候補のみ表示します: {connection_error}")
        print_candidates(candidates)
        return

    print(f"AnkiConnect接続OK: host={resolved_host}, port={anki_port}, version={version}")
    anki_request("createDeck", {"deck": deck_name}, host=resolved_host, port=anki_port)

    today_tag = "auto_import_" + datetime.datetime.now().strftime("%Y%m%d")
    notes = []
    for item in candidates:
        fm = item["fm"]
        body = item["body"]

        sections = extract_body_sections(body)
        summary = sections.get("summary", "")
        steps = sections.get("steps", "")
        pitfalls = sections.get("mistakes", "")
        theory_keywords = _extract_named_section(body, "理論キーワード")

        importance = to_str(fm.get("importance"))
        conditions = to_str(fm.get("conditions"))
        kome_total = fm.get("kome_total")
        calc_correct = fm.get("calc_correct")
        calc_wrong = fm.get("calc_wrong")

        front_parts = [
            f"<b>論点</b>: {to_html_block(item['topic'])}",
            f"<b>カテゴリ</b>: {to_html_block(item['category'])}",
            f"<b>概要</b><br>{to_html_block(summary) if summary else '(未記載)'}",
            f"<b>importance</b>: {to_html_block(importance) if importance else '(未記載)'}",
            f"<b>conditions</b>: {to_html_block(conditions) if conditions else '(未記載)'}",
        ]
        back_parts = [
            f"<b>計算手順</b><br>{to_html_block(steps) if steps else '(未記載)'}",
            f"<b>理論キーワード</b><br>{to_html_block(theory_keywords) if theory_keywords else '(未記載)'}",
            f"<b>間違えやすいポイント</b><br>{to_html_block(pitfalls) if pitfalls else '(未記載)'}",
            "<b>学習履歴</b>",
            f"kome_total: {to_html_block(to_str(kome_total) or '0')}",
            f"calc_correct: {to_html_block(to_str(calc_correct) or '0')}",
            f"calc_wrong: {to_html_block(to_str(calc_wrong) or '0')}",
        ]

        notes.append(
            {
                "deckName": deck_name,
                "modelName": "Basic",
                "fields": {
                    "Front": "<br><br>".join(front_parts),
                    "Back": "<br>".join(back_parts),
                },
                "tags": [today_tag, sanitize_anki_tag(item["category"])],
            }
        )

    note_ids = anki_request("addNotes", {"notes": notes}, host=resolved_host, port=anki_port)
    if not isinstance(note_ids, list):
        eprint("エラー: addNotes の結果形式が不正です。")
        raise SystemExit(1)

    now_iso = datetime.datetime.now().replace(microsecond=0).isoformat()
    success_count = 0
    duplicate_or_fail_count = 0
    for item, note_id in zip(candidates, note_ids):
        if note_id is None:
            duplicate_or_fail_count += 1
            continue
        fm = item["fm"]
        exported_map[item["key"]] = {
            "anki_note_id": note_id,
            "exported_at": now_iso,
            "kome_total_at_export": fm.get("kome_total", 0),
        }
        success_count += 1

    exported_json_path.write_text(
        json.dumps(exported_data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print("Ankiエクスポート完了")
    print(f"- 対象件数: {len(candidates)}")
    print(f"- 追加成功: {success_count}")
    print(f"- 重複/失敗: {duplicate_or_fail_count}")
    print(f"- 管理ファイル: {exported_json_path}")


try:
    main()
except SystemExit:
    raise
except Exception as exc:
    eprint(f"エラー: {exc}")
    raise SystemExit(1)
PY
