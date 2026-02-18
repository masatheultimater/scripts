# 統合設計書: 3スクリプト実装仕様（合議結果）

> 3エージェント（データフロー分析・リスク分析・パターン分析）の合議結果を統合

---

## 0. 全体最適の設計方針

### stage vs status の明確化（最重要）

現状の問題: `stage` と `status` が混乱している。log.sh と komekome_writeback.sh で異なるロジックで `stage` を更新。`status` はどのスクリプトも更新していない。

**決定: 暫定アプローチ（interval_index なし）**

コメコメアプリ側の改修（interval_index の追加）は別セッションで行う。
今回は `last_practiced` と `session_date` の日数差 + kome_total で卒業を推定する。

```
卒業条件（暫定）:
  correct == true
  AND gap_days >= 25（last_practiced からの日数）
  AND kome_total >= 4（最低限のコメ蓄積）
  AND stage が "復習中"
```

### frontmatter フィールドの責務分担

| フィールド | 更新者 | 意味 |
|-----------|--------|------|
| stage | komekome_writeback.sh, log.sh | 学習進捗（未着手/学習中/復習中） |
| status | komekome_writeback.sh のみ（新規追加） | ライフサイクル（未着手/学習中/復習中/卒業） |
| kome_total | komekome_writeback.sh | 累積コメ数 |
| calc_correct/wrong | log.sh | 計算演習の正誤 |
| last_practiced | komekome_writeback.sh, log.sh | 最終演習日 |

### ファイルロック（並行実行対策）

全スクリプト共通で `flock` を使用:
```bash
LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "エラー: 別のスクリプトが実行中です" >&2; exit 1; }
```

---

## 1. komekome_writeback.sh — 卒業判定ロジック追加

### 変更箇所

Python部分の `update_topic_note()` 関数内、stage 更新ロジックの直後に status 更新を追加。

### 卒業判定ロジック（暫定）

```python
# --- status 更新（卒業判定） ---
from datetime import datetime

current_status = data.get("status", "未着手")

if topic_result["correct"]:
    # stage 更新（既存ロジック維持）
    data["stage"] = "復習中" if new_kome >= 16 else "学習中"

    # status 更新
    if current_status == "未着手":
        data["status"] = "学習中"
    elif current_status == "学習中" and new_kome >= 16:
        data["status"] = "復習中"

    # 卒業判定（暫定: interval_index なし）
    old_last = data.get("last_practiced_prev", data.get("last_practiced", ""))
    if old_last and current_status == "復習中":
        try:
            old_dt = datetime.strptime(str(old_last), "%Y-%m-%d")
            new_dt = datetime.strptime(session_date, "%Y-%m-%d")
            gap = (new_dt - old_dt).days
            if gap >= 25 and new_kome >= 4:
                data["status"] = "卒業"
                data["stage"] = "卒業済"
        except ValueError:
            pass
else:
    # 不正解時: 卒業を取り消し
    if current_status == "卒業":
        data["status"] = "復習中"
        data["stage"] = "復習中"
    elif current_status == "未着手":
        data["status"] = "学習中"
        data["stage"] = "学習中"
```

### 重要な注意

- `last_practiced` は更新前の値を保存してから gap 計算する必要がある
- yaml.safe_dump の `width=10000` オプションは維持必須
- validate_input() のバリデーションは変更しない
- セッションログの Markdown 表形式（ヘッダー名）は変更しない

---

## 2. anki_export.sh — 新規作成

### パターン: Pattern B（while+case + export + <<'PY'）

```
#!/usr/bin/env bash
set -euo pipefail

usage() { cat <<'USAGE' ... USAGE }

引数: --dry-run, --deck-name, --anki-host, --anki-port, --force
デフォルト: DECK="法人税法", ANKI_HOST=auto, ANKI_PORT=8765

VAULT="${HOME}/vault/houjinzei"
export VAULT DRY_RUN DECK_NAME ANKI_HOST ANKI_PORT FORCE_FLAG

# ファイルロック
LOCKFILE="/tmp/houjinzei_vault.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "エラー: 別のスクリプトが実行中" >&2; exit 1; }

python3 - <<'PY'
... (メインロジック)
PY
```

### Python メインロジック

1. **環境変数受け取り** + 定数定義
2. **論点ノート走査**: `10_論点/` を rglob して status:"卒業" を抽出
3. **エクスポート済み管理**: `50_エクスポート/anki_exported.json` をロード
4. **差分計算**: 未エクスポートの卒業論点を抽出
5. **AnkiConnect 疎通確認**: curl 相当の HTTP リクエスト（`urllib.request`）
   - ホストIP自動検出: `ip route show default` の結果をパース
   - 接続失敗時: エクスポート候補リストのみ表示して終了（API呼ばない）
6. **デッキ作成**: `createDeck` アクション
7. **カード追加**: `addNotes` バッチアクション
   - 表面: topic, category, 概要セクション, importance, 条文番号
   - 裏面: 計算手順, 理論キーワード, 間違えやすいポイント, 学習履歴
   - タグ: `auto_import_YYYYMMDD`, カテゴリ名
   - HTML エスケープ必須（`html.escape()`）
8. **管理ファイル更新**: anki_exported.json に追記
9. **サマリ出力**

### anki_exported.json の形式

```json
{
  "exported": {
    "減価償却_普通": {
      "anki_note_id": 1234567890,
      "exported_at": "2026-02-18T16:00:00",
      "kome_total_at_export": 12
    }
  }
}
```

### AnkiConnect API 呼び出し

```python
import json
import urllib.request

def anki_request(action, params=None, host="172.29.64.1", port=8765):
    payload = {"action": action, "version": 6}
    if params:
        payload["params"] = params
    req = urllib.request.Request(
        f"http://{host}:{port}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            if result.get("error"):
                raise RuntimeError(f"AnkiConnect error: {result['error']}")
            return result.get("result")
    except Exception as e:
        return None  # 接続失敗
```

### ホストIP自動検出

```python
import subprocess
def detect_wsl_host():
    try:
        out = subprocess.check_output(["ip", "route", "show", "default"], text=True)
        return out.split()[2]  # "default via 172.29.64.1 dev eth0" → "172.29.64.1"
    except Exception:
        return "172.29.64.1"  # フォールバック
```

---

## 3. notebooklm_export.sh — 6点改善

### 改善1: プレースホルダー除去

```python
PLACEHOLDER_PATTERNS = [
    r"[-*]\s*（.*?記入.*?）",      # - （学習後に記入）
    r"[-*]\s*（.*?未記入.*?）",    # - （未記入）
    r"[-*]\s*TODO\b",              # - TODO
    r"[-*]\s*TBD\b",              # - TBD
]

def remove_placeholders(body: str) -> str:
    lines = body.splitlines()
    cleaned = []
    for line in lines:
        skip = False
        for pat in PLACEHOLDER_PATTERNS:
            if re.fullmatch(pat, line.strip()):
                skip = True
                break
        if not skip:
            cleaned.append(line)
    return "\n".join(cleaned)
```

### 改善2: 見出しレベル正規化

ノート body 内の H1 (`# xxx`) を H4 (`#### xxx`) に、H2 → H5 にシフト。
エクスポート側の `## カテゴリ名` / `### 論点名` と衝突しないようにする。

```python
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
```

### 改善3: importance A/B フィルタリング

```python
# parse_frontmatter を yaml.safe_load に統一（リスク C-7 対応）
import yaml

def read_note(md_path):
    text = md_path.read_text(encoding="utf-8", errors="ignore")
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return None, text
    fm = yaml.safe_load(text[4:end]) or {}
    body = text[end + 5:]
    return fm, body

# フィルタ: importance が A または B のみ
importance = fm.get("importance", "")
if isinstance(importance, str):
    importance = importance.strip().upper()
if importance not in ("A", "B"):
    continue
```

### 改善4: 差分検出

```python
import hashlib

HASH_FILE = OUTPUT_DIR / ".notebooklm_hash"

def load_hashes():
    if HASH_FILE.exists():
        return json.loads(HASH_FILE.read_text(encoding="utf-8"))
    return {}

def save_hashes(hashes):
    HASH_FILE.write_text(json.dumps(hashes, ensure_ascii=False, indent=2), encoding="utf-8")

# 生成後にハッシュ比較
content_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
if prev_hashes.get(t) == content_hash:
    print(f"- {t}: 差分なし（スキップ）")
    unchanged_count += 1
    continue
```

### 改善5: wslview ワンクリック化

```python
import subprocess
import shutil

if changed_types and shutil.which("wslview"):
    for t in changed_types:
        path = str(OUTPUT_DIR / f"notebooklm_{t}.md")
        # Windows側のパスに変換
        win_path = path.replace("/home/masa/vault", "\\\\wsl$\\Ubuntu\\home\\masa\\vault")
        subprocess.run(["wslview", f"https://notebooklm.google.com/"], check=False)
        print(f"NotebookLM をブラウザで開きました。{path} をアップロードしてください。")
```

### 改善6: 500,000文字制限分割

```python
CHAR_LIMIT = 500_000

def write_chunked(lines_by_category, type_name, output_dir, now_str):
    chunks = []
    current_chunk = []
    current_size = 0

    for category, cat_lines in sorted(lines_by_category.items()):
        cat_text = "\n".join(cat_lines)
        cat_size = len(cat_text)

        if current_size + cat_size > CHAR_LIMIT and current_chunk:
            chunks.append(current_chunk)
            current_chunk = []
            current_size = 0

        current_chunk.append((category, cat_lines))
        current_size += cat_size

    if current_chunk:
        chunks.append(current_chunk)

    for i, chunk in enumerate(chunks):
        suffix = f"_{i+1}" if len(chunks) > 1 else ""
        out_path = output_dir / f"notebooklm_{type_name}{suffix}.md"
        # ヘッダー + 目次 + 本文を生成
        ...
```

---

## 4. 実装順序

1. **komekome_writeback.sh** — 卒業判定追加（他2つの前提条件）
2. **notebooklm_export.sh** — 6点改善（独立して実装可能）
3. **anki_export.sh** — 新規作成（卒業論点がないとテスト不可だが、dry-run で検証）

## 5. 共通パターン規約

- shebang: `#!/usr/bin/env bash`（while+case系）/ `#!/bin/bash`（位置引数系）
- heredoc: `<<'PY'` ... `PY`（多数派に統一）
- 整数変換: `to_int()`（名前統一）
- yaml.safe_dump: `allow_unicode=True, sort_keys=False, default_flow_style=False, width=10000`
- エラー出力: `eprint()` + `raise SystemExit(1)`
- ファイルロック: `/tmp/houjinzei_vault.lock` で flock

## 6. 環境確認済み事項

- PyYAML 5.4.1 インストール済み
- wslview v10 インストール済み
- Windows ホスト IP: 172.29.64.1（`ip route show default`）
- hashlib 利用可能
