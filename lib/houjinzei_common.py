"""法人税学習システム共通モジュール

全スクリプトで共有する定数・frontmatter I/O・ユーティリティ関数。
"""

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

    parsed = yaml.safe_load(fm_text)
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
