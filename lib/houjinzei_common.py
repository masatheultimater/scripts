"""法人税学習システム共通モジュール

全スクリプトで共有する定数・frontmatter I/O・ユーティリティ関数。
"""

import json
import os
import sys
import tempfile
from datetime import date, datetime
from pathlib import Path

import yaml

# ─── 定数 ───────────────────────────────────────────────

# stage: 学習進捗（frontmatter "stage" フィールド）
STAGE_VALUES = ("未着手", "学習中", "復習中", "卒業済")

# status: ライフサイクル（frontmatter "status" フィールド）
STATUS_VALUES = ("未着手", "学習中", "復習中", "卒業")

# 出題・集計から除外すべき status
EXCLUDED_STATUSES = frozenset({"卒業"})

# 卒業判定パラメータ
GRADUATION_GAP_DAYS = 25
GRADUATION_MIN_KOME = 4
KOME_THRESHOLD_REVIEW = 16  # kome_total >= 16 で stage=復習中

# 間隔反復スケジュール（interval_index → 復習間隔日数）
# index 0=初回, 1=3日後完了, 2=7日後完了, 3=14日後完了, 4=28日後完了(卒業)
INTERVAL_DAYS = (3, 7, 14, 28)
GRADUATION_INTERVAL_INDEX = len(INTERVAL_DAYS)  # == 4

VAULT_DEFAULT = Path(os.environ.get("VAULT", "")).expanduser() or Path.home() / "vault" / "houjinzei"
TOPIC_DIR_NAME = "10_論点"
LOCKFILE = "/tmp/houjinzei_vault.lock"

# Gemini / Claude 外部コマンドタイムアウト
PDF_TEXT_SIZE_THRESHOLD = 500_000  # bytes: 小/大PDFの境界
GEMINI_TIMEOUT_SMALL = 600  # 秒: 小PDF
GEMINI_TIMEOUT_LARGE = 1200  # 秒: 大PDF
ENRICH_TIMEOUT = 120  # 秒: claude -p

# クイズ・ログ
DEFAULT_QUIZ_LIMIT = 20
LOG_RETENTION_DAYS = 30


class VaultPaths:
    """Vaultのディレクトリ構造を一元管理するクラス。"""

    def __init__(self, root=None):
        self.root = Path(root) if root else VAULT_DEFAULT
        self.topics = self.root / "10_論点"
        self.sources = self.root / "01_sources"
        self.extracted = self.root / "02_extracted"
        self.exercise_log = self.root / "20_演習ログ"
        self.source_map = self.root / "30_ソース別"
        self.analysis = self.root / "40_分析"
        self.export = self.root / "50_エクスポート"
        self.index_json = self.sources / "_index.json"

    def ensure_dirs(self):
        """全必須ディレクトリを作成する。"""
        for d in (self.root, self.topics, self.sources, self.extracted,
                  self.exercise_log, self.source_map, self.analysis, self.export):
            d.mkdir(parents=True, exist_ok=True)


# ─── ユーティリティ ─────────────────────────────────────

def eprint(msg: str) -> None:
    """標準エラー出力にメッセージを出力する。"""
    print(msg, file=sys.stderr)


def parse_date(s: str) -> date:
    """YYYY-MM-DD 文字列を date に変換する。"""
    s = str(s).strip()
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise ValueError(f"日付形式エラー: {s} (YYYY-MM-DD で指定してください)")


def to_int(v) -> int:
    """安全に int 変換。失敗時は 0 を返す。"""
    try:
        return int(str(v).strip())
    except (ValueError, TypeError):
        return 0


# ─── Atomic JSON I/O ─────────────────────────────────────

def atomic_json_write(path, data, indent=2) -> None:
    """JSONデータをアトミックに書き出す（tempfile + os.replace）。

    ensure_ascii=False で日本語をそのまま保存する。
    書き込み中にエラーが発生しても元ファイルは破損しない。
    """
    path = Path(path)
    parent = path.parent
    fd, tmp_path = tempfile.mkstemp(dir=parent, suffix=".tmp", prefix=".aj_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=indent)
            f.write("\n")
        os.replace(tmp_path, str(path))
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ─── Stage / Status ロジック ─────────────────────────────

def compute_stage(status: str, kome_total: int, calc_correct: int, calc_wrong: int) -> str:
    """status と累計値から stage を算出する（全スクリプト共通基準）。

    - status=="卒業" → "卒業済"
    - kome_total >= 16 or status=="復習中" → "復習中"
    - 学習実績あり（kome_total>0 or attempts>0） → "学習中"
    - それ以外 → "未着手"
    """
    if status == "卒業":
        return "卒業済"
    attempts = calc_correct + calc_wrong
    if kome_total >= KOME_THRESHOLD_REVIEW or status == "復習中":
        return "復習中"
    if kome_total > 0 or attempts > 0:
        return "学習中"
    return "未着手"


def normalize_stage(raw_stage: str, status: str) -> str:
    """frontmatter の stage 値を正規化する（集計用）。

    stage が欠損・不正な場合、status から推定する。
    """
    if raw_stage in STAGE_VALUES:
        return raw_stage
    # stage 欠損時: status からマッピング
    if status == "卒業":
        return "卒業済"
    if status in ("未着手", "学習中", "復習中"):
        return status
    return "未着手"


# ─── Interval Index ──────────────────────────────────────

def next_review_days(interval_index: int) -> int:
    """interval_index に対応する次回復習までの日数を返す。

    interval_index が INTERVAL_DAYS の範囲外なら最大間隔を返す。
    """
    if interval_index < 0:
        interval_index = 0
    if interval_index >= len(INTERVAL_DAYS):
        return INTERVAL_DAYS[-1]
    return INTERVAL_DAYS[interval_index]


def is_graduation_ready(interval_index: int, kome_total: int) -> bool:
    """卒業条件を満たしているか判定する。

    interval_index == GRADUATION_INTERVAL_INDEX (4) かつ
    kome_total >= GRADUATION_MIN_KOME
    """
    return interval_index >= GRADUATION_INTERVAL_INDEX and kome_total >= GRADUATION_MIN_KOME


# ─── Answer Processing ────────────────────────────────

def process_answer(
    fm: dict,
    correct: bool,
    answer_date: str,
    kome_delta: int = 0,
    mistake_text: str = "",
) -> dict:
    """回答結果を frontmatter dict に適用し、更新後の dict を返す。

    - interval_index: 正解+1, 不正解→0
    - kome_total: kome_delta で加算
    - status/stage: 遷移ルールに従い更新
    - 卒業判定: interval_index ベース（優先）+ レガシー gap ベース
    - 卒業済みノートは変更しない
    """
    data = dict(fm)  # shallow copy

    current_status = str(data.get("status", "未着手"))

    # 卒業済みノートは変更しない
    if current_status == "卒業":
        data["last_practiced"] = answer_date
        data["stage"] = data.get("stage", "卒業済")
        return data

    kome_total = to_int(data.get("kome_total", 0)) + kome_delta
    data["kome_total"] = kome_total

    calc_correct = to_int(data.get("calc_correct", 0))
    calc_wrong = to_int(data.get("calc_wrong", 0))
    interval_index = to_int(data.get("interval_index", 0))
    old_last_practiced = data.get("last_practiced")

    data["last_practiced"] = answer_date

    if correct:
        # interval_index インクリメント
        interval_index = min(interval_index + 1, GRADUATION_INTERVAL_INDEX)

        # status 遷移
        if current_status == "未着手":
            data["status"] = "学習中"
        if kome_total >= KOME_THRESHOLD_REVIEW and current_status in ("未着手", "学習中"):
            data["status"] = "復習中"

        # 卒業判定: interval_index ベース
        graduated = False
        if interval_index >= GRADUATION_INTERVAL_INDEX and kome_total >= GRADUATION_MIN_KOME:
            graduated = True

        # レガシーフォールバック: gap ベース
        if not graduated and old_last_practiced and data.get("status") == "復習中":
            try:
                if isinstance(old_last_practiced, date):
                    old_d = old_last_practiced
                elif isinstance(old_last_practiced, datetime):
                    old_d = old_last_practiced.date()
                else:
                    old_d = datetime.strptime(str(old_last_practiced), "%Y-%m-%d").date()
                new_d = datetime.strptime(answer_date, "%Y-%m-%d").date()
                gap = (new_d - old_d).days
                if gap >= GRADUATION_GAP_DAYS and kome_total >= GRADUATION_MIN_KOME:
                    graduated = True
            except (ValueError, TypeError):
                pass

        if graduated:
            data["status"] = "卒業"
            data["stage"] = "卒業済"
        else:
            data["stage"] = compute_stage(data["status"], kome_total, calc_correct, calc_wrong)
    else:
        # 不正解: 2段階戻し（完全リセットではなく緩やかに）
        interval_index = max(0, interval_index - 2)

        if current_status == "未着手":
            data["status"] = "学習中"

        # 復習中は降格しない
        data["stage"] = compute_stage(data["status"], kome_total, calc_correct, calc_wrong)

        # mistakes 追記
        if mistake_text and mistake_text.strip():
            mistakes = data.get("mistakes", [])
            if mistakes is None:
                mistakes = []
            elif not isinstance(mistakes, list):
                mistakes = [str(mistakes)]
            mistakes.append(mistake_text.strip())
            data["mistakes"] = mistakes

    data["interval_index"] = interval_index
    return data


# ─── Frontmatter I/O ───────────────────────────────────

def split_frontmatter(content: str):
    """Markdown から frontmatter テキストと body を分離する。

    Returns:
        (frontmatter_text, body) — frontmatter がなければ (None, content)
    """
    if not content.startswith("---\n"):
        return None, content

    marker = "\n---\n"
    end = content.find(marker, 4)
    if end == -1:
        return None, content

    return content[4:end], content[end + len(marker):]


def read_frontmatter(md_path: Path):
    """Markdown ファイルの frontmatter を yaml.safe_load でパースする。

    Returns:
        (dict, body_str) — frontmatter がなければ ({}, body_str)
    """
    text = md_path.read_text(encoding="utf-8")
    fm_text, body = split_frontmatter(text)
    if fm_text is None:
        return {}, body

    try:
        parsed = yaml.safe_load(fm_text)
    except yaml.YAMLError:
        return {}, body
    if not isinstance(parsed, dict):
        return {}, body
    return parsed, body


def write_frontmatter(md_path: Path, data: dict, body: str) -> None:
    """frontmatter + body を atomic に書き出す（tempfile + rename）。"""
    dumped = yaml.safe_dump(
        data,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
        width=10000,
    )

    new_body = body if body.startswith("\n") else "\n" + body
    new_content = f"---\n{dumped}---{new_body}"

    # atomic write: 同ディレクトリに tempfile → rename
    parent = md_path.parent
    fd, tmp_path = tempfile.mkstemp(dir=parent, suffix=".tmp", prefix=".fm_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new_content)
        os.replace(tmp_path, str(md_path))
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ─── Body Section Extraction ─────────────────────────────

def extract_body_sections(body: str) -> dict:
    """論点ノートの本文から各セクションを抽出する。

    Returns:
        dict with keys: display_name, summary, steps, judgment, mistakes, mistake_items
    """
    import re

    result = {
        "display_name": "",
        "summary": "",
        "steps": "",
        "judgment": "",
        "mistakes": "",
        "mistake_items": [],
    }

    # H1 見出し
    for line in body.split("\n"):
        stripped = line.strip()
        if stripped.startswith("# ") and not stripped.startswith("## "):
            result["display_name"] = stripped[2:].strip()
            break

    # セクション抽出ヘルパー
    def _extract_section(heading: str) -> str:
        marker = f"\n## {heading}\n"
        start = body.find(marker)
        if start == -1:
            return ""
        content_start = start + len(marker)
        next_h = body.find("\n## ", content_start)
        section = body[content_start:] if next_h == -1 else body[content_start:next_h]
        content = section.strip()
        if not content or content.startswith("## "):
            return ""
        return content

    result["summary"] = _extract_section("概要")
    result["steps"] = _extract_section("計算手順")
    result["judgment"] = _extract_section("判断ポイント")
    result["mistakes"] = _extract_section("間違えやすいポイント")

    # 間違えやすいポイントを個別項目に分解（チェックボックス用）
    if result["mistakes"]:
        items = []
        for line in result["mistakes"].split("\n"):
            line = line.strip()
            if not line.startswith("- "):
                continue
            bold = re.findall(r"\*\*(.+?)\*\*", line)
            if bold:
                items.append(bold[0])
            else:
                items.append(line[2:].strip()[:40])
        result["mistake_items"] = items

    return result
