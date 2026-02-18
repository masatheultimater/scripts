#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# E2Eシミュレーションテスト
# 一時ディレクトリにVaultをコピーし、全フローを検証する。
# 実データは一切変更しない。
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_VAULT="${VAULT:-$HOME/vault/houjinzei}"

if [[ ! -d "$REAL_VAULT/10_論点" ]]; then
  echo "エラー: Vault が見つかりません: $REAL_VAULT" >&2
  exit 1
fi

# --- 一時環境の構築 ---
TMPROOT="$(mktemp -d /tmp/houjinzei-e2e.XXXXXX)"
TEST_VAULT="$TMPROOT/vault/houjinzei"

cleanup() {
  rm -rf "$TMPROOT"
  echo "[CLEANUP] $TMPROOT 削除完了"
}
trap cleanup EXIT

echo "[SETUP] テスト用 Vault を作成中..."
mkdir -p "$TEST_VAULT"
# 必要なディレクトリ構造のみコピー（PDFなど大きいファイルは除外）
rsync -a --exclude='01_sources/' --exclude='*.pdf' "$REAL_VAULT/" "$TEST_VAULT/"

export VAULT="$TEST_VAULT"

# --- テスト用論点ノートの作成 ---
mkdir -p "$VAULT/10_論点/テスト"
cat > "$VAULT/10_論点/テスト/test_topic.md" <<'EOF'
---
topic: テスト論点E2E
category: テスト
subcategory: テスト
type: [計算]
importance: A
conditions: []
sources:
  - 'テスト教材'
keywords: []
related: []
kome_total: 0
calc_correct: 0
calc_wrong: 0
interval_index: 0
last_practiced: 2025-11-26
stage: 学習中
status: 学習中
pdf_refs: []
mistakes: []
extracted_from: 'E2Eテスト'
---

# テスト論点E2E

## 概要
E2Eシミュレーション用のダミー論点です。

## 計算手順
1. ダミー手順

## 理論キーワード
- ダミー

## 間違えやすいポイント
- ダミー
EOF

# --- interval_index ベース卒業テスト用ノート ---
cat > "$VAULT/10_論点/テスト/test_interval.md" <<'EOF'
---
topic: テスト論点_interval
category: テスト
subcategory: テスト
type: [計算]
importance: A
conditions: []
sources:
  - 'テスト教材'
keywords: []
related: []
kome_total: 10
calc_correct: 5
calc_wrong: 1
interval_index: 3
last_practiced: '2025-12-25'
stage: 復習中
status: 復習中
pdf_refs: []
mistakes: []
extracted_from: 'E2Eテスト'
---

# テスト論点_interval

## 概要
interval_indexベースの卒業判定テスト用ノートです。

## 計算手順
1. ダミー手順

## 間違えやすいポイント
- ダミー
EOF

PASS=0
FAIL=0
TOTAL=0

assert_ok() {
  local label="$1"
  TOTAL=$((TOTAL + 1))
  if [[ $? -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label" >&2
  fi
}

# ============================================================
echo ""
echo "=========================================="
echo "STEP 1: generate_quiz.sh"
echo "=========================================="

bash "$SCRIPT_DIR/generate_quiz.sh" --date 2025-11-29 --limit 200

python3 - <<'PY'
import json, os, sys
from pathlib import Path

vault = Path(os.environ["VAULT"])
path = vault / "50_エクスポート" / "komekome_import.json"
if not path.exists():
    print(f"FAIL: {path} が存在しません", file=sys.stderr)
    sys.exit(1)

data = json.loads(path.read_text(encoding="utf-8"))
questions = data.get("questions", [])

found = None
for q in questions:
    if q.get("topic_id") == "テスト/test_topic":
        found = q
        break

if not found:
    print("FAIL: テスト論点が出題リストに含まれていません", file=sys.stderr)
    for q in questions[:5]:
        print(f"  - {q.get('topic_id', '?')}", file=sys.stderr)
    sys.exit(1)

if "intervalIndex" not in found:
    print("FAIL: intervalIndex フィールドが出力に含まれていません", file=sys.stderr)
    sys.exit(1)

print(f"  PASS: generate_quiz.sh ({len(questions)}問生成、テスト論点含む、intervalIndex={found['intervalIndex']})")
PY
TOTAL=$((TOTAL + 1))
if [[ $? -eq 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# ============================================================
echo ""
echo "=========================================="
echo "STEP 2: komekome_writeback.sh (1回目: 学習中→復習中)"
echo "=========================================="

RESULT1="$VAULT/50_エクスポート/komekome_results_mock_1.json"
python3 - "$RESULT1" <<'PY'
import json, sys
out = sys.argv[1]
payload = {
    "session_date": "2025-12-01",
    "session_id": "e2e-mock-1",
    "results": [
        {
            "topic_id": "テスト/test_topic",
            "kome_count": 16,
            "correct": True,
            "time_seconds": 120,
            "mistakes": [],
            "intervalIndex": 0
        }
    ]
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
PY

bash "$SCRIPT_DIR/komekome_writeback.sh" "$RESULT1"

python3 - <<'PY'
import os, sys, yaml
from pathlib import Path

path = Path(os.environ["VAULT"]) / "10_論点/テスト/test_topic.md"
text = path.read_text(encoding="utf-8")
if not text.startswith("---\n"):
    print("FAIL: frontmatter なし", file=sys.stderr)
    sys.exit(1)
end = text.find("\n---\n", 4)
fm = yaml.safe_load(text[4:end]) or {}

errors = []
if fm.get("status") != "復習中":
    errors.append(f"status 期待=復習中, 実際={fm.get('status')}")
if fm.get("stage") != "復習中":
    errors.append(f"stage 期待=復習中, 実際={fm.get('stage')}")
if int(fm.get("kome_total", 0)) < 16:
    errors.append(f"kome_total 期待>=16, 実際={fm.get('kome_total')}")
ii = fm.get("interval_index")
if ii is None or int(ii) != 1:
    errors.append(f"interval_index 期待=1, 実際={ii}")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

print(f"  PASS: 1回目書き戻し (status=復習中, interval_index={ii}, kome_total={fm.get('kome_total')})")
PY
TOTAL=$((TOTAL + 1))
if [[ $? -eq 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# ============================================================
echo ""
echo "=========================================="
echo "STEP 3: komekome_writeback.sh (2回目: 卒業判定)"
echo "=========================================="

RESULT2="$VAULT/50_エクスポート/komekome_results_mock_2.json"
python3 - "$RESULT2" <<'PY'
import json, sys
out = sys.argv[1]
# 29日後のセッション（gap >= 25日 && kome_total >= 4 && correct=true → 卒業）
payload = {
    "session_date": "2025-12-30",
    "session_id": "e2e-mock-2",
    "results": [
        {
            "topic_id": "テスト/test_topic",
            "kome_count": 1,
            "correct": True,
            "time_seconds": 90,
            "mistakes": []
        }
    ]
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
PY

bash "$SCRIPT_DIR/komekome_writeback.sh" "$RESULT2"

python3 - <<'PY'
import os, sys, yaml
from pathlib import Path

path = Path(os.environ["VAULT"]) / "10_論点/テスト/test_topic.md"
text = path.read_text(encoding="utf-8")
end = text.find("\n---\n", 4)
fm = yaml.safe_load(text[4:end]) or {}

errors = []
if fm.get("status") != "卒業":
    errors.append(f"status 期待=卒業, 実際={fm.get('status')}")
if fm.get("stage") != "卒業済":
    errors.append(f"stage 期待=卒業済, 実際={fm.get('stage')}")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

print(f"  PASS: 2回目書き戻しで卒業判定発火 (status=卒業, stage=卒業済)")
PY
TOTAL=$((TOTAL + 1))
if [[ $? -eq 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# ============================================================
echo ""
echo "=========================================="
echo "STEP 3b: komekome_writeback.sh (interval_indexベース卒業)"
echo "=========================================="

RESULT_IV="$VAULT/50_エクスポート/komekome_results_mock_iv.json"
python3 - "$RESULT_IV" <<'PY'
import json, sys
out = sys.argv[1]
# interval_index=3 + correct → interval_index=4 → 卒業
payload = {
    "session_date": "2025-12-28",
    "session_id": "e2e-mock-iv",
    "results": [
        {
            "topic_id": "テスト/test_interval",
            "kome_count": 2,
            "correct": True,
            "time_seconds": 80,
            "mistakes": [],
            "intervalIndex": 3
        }
    ]
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
PY

bash "$SCRIPT_DIR/komekome_writeback.sh" "$RESULT_IV"

python3 - <<'PY'
import os, sys, yaml
from pathlib import Path

path = Path(os.environ["VAULT"]) / "10_論点/テスト/test_interval.md"
text = path.read_text(encoding="utf-8")
end = text.find("\n---\n", 4)
fm = yaml.safe_load(text[4:end]) or {}

errors = []
if fm.get("status") != "卒業":
    errors.append(f"status 期待=卒業, 実際={fm.get('status')}")
if fm.get("stage") != "卒業済":
    errors.append(f"stage 期待=卒業済, 実際={fm.get('stage')}")
ii = fm.get("interval_index")
if ii is None or int(ii) != 4:
    errors.append(f"interval_index 期待=4, 実際={ii}")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

print(f"  PASS: interval_indexベース卒業 (status=卒業, interval_index={ii})")
PY
TOTAL=$((TOTAL + 1))
if [[ $? -eq 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# ============================================================
echo ""
echo "=========================================="
echo "STEP 4: generate_quiz.sh (卒業後は出題されない)"
echo "=========================================="

bash "$SCRIPT_DIR/generate_quiz.sh" --date 2025-12-31 --limit 200

python3 - <<'PY'
import json, os, sys
from pathlib import Path

vault = Path(os.environ["VAULT"])
path = vault / "50_エクスポート" / "komekome_import.json"
data = json.loads(path.read_text(encoding="utf-8"))
questions = data.get("questions", [])

found = any(q.get("topic_id") == "テスト/test_topic" for q in questions)
if found:
    print("FAIL: 卒業済み論点が出題リストに含まれています", file=sys.stderr)
    sys.exit(1)

print(f"  PASS: 卒業済み論点は出題リストから除外されている ({len(questions)}問生成)")
PY
TOTAL=$((TOTAL + 1))
if [[ $? -eq 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi

# ============================================================
echo ""
echo "=========================================="
echo "STEP 5: anki_export.sh --dry-run"
echo "=========================================="

DRYRUN_OUT="$(bash "$SCRIPT_DIR/anki_export.sh" --dry-run 2>&1)" || true
echo "$DRYRUN_OUT"

if echo "$DRYRUN_OUT" | grep -q "テスト論点E2E"; then
  echo "  PASS: 卒業論点が Anki 候補に含まれている"
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
else
  echo "  FAIL: 卒業論点が Anki 候補に含まれていない" >&2
  TOTAL=$((TOTAL + 1))
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=========================================="
echo "STEP 6: coverage_analysis.sh"
echo "=========================================="

bash "$SCRIPT_DIR/coverage_analysis.sh" --date 2025-12-31 || true
TOTAL=$((TOTAL + 1))
if [[ -f "$VAULT/40_分析/カバレッジ/2025-12-31.md" ]]; then
  echo "  PASS: カバレッジレポート生成"
  PASS=$((PASS + 1))
else
  echo "  FAIL: カバレッジレポートが見つかりません" >&2
  FAIL=$((FAIL + 1))
fi

# ============================================================
echo ""
echo "=========================================="
echo "結果サマリ"
echo "=========================================="
echo "TOTAL: $TOTAL"
echo "PASS:  $PASS"
echo "FAIL:  $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo "RESULT: FAILED"
  exit 1
else
  echo "RESULT: ALL PASSED"
  exit 0
fi
