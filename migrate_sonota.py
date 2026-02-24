#!/usr/bin/env python3
"""その他カテゴリの論点ノートを適切なカテゴリに再分類する。

ファイルの移動は行わず、frontmatter の category フィールドのみ更新する。
subcategory フィールドに基づき、MIGRATION_MAP の順序で最初にマッチしたカテゴリに変更。
"""

import argparse
import os
import re
import sys
import tempfile
from pathlib import Path

import yaml

# ─── マッピング定義 ─────────────────────────────────────
# (subcategory の部分一致, 新しい category)
# リスト順で最初にマッチした行が採用される。
# 「申告」は広い一致なので、「青色申告」「修正申告」「確定申告」より後に置く。

MIGRATION_MAP = [
    ("圧縮記帳", "圧縮記帳等"),
    ("青色申告", "申告納付等"),
    ("組織再編", "組織再編"),
    ("グループ通算", "通算制度"),
    ("グループ法人税制", "グループ法人"),
    ("完全支配関係", "グループ法人"),
    ("公益法人", "総則・定義"),
    ("非営利型法人", "総則・定義"),
    ("人格のない社団", "総則・定義"),
    ("協同組合", "総則・定義"),
    ("信託", "総則・定義"),
    ("法人課税信託", "総則・定義"),
    ("同族会社", "総則・定義"),
    ("用語の意義", "総則・定義"),
    ("基礎事項", "総則・定義"),
    ("総論", "総則・定義"),
    ("消費税", "所得計算"),
    ("税効果会計", "所得計算"),
    ("有価証券", "所得計算"),
    ("外貨建取引", "所得計算"),
    ("為替換算", "所得計算"),
    ("総合問題", "所得計算"),
    ("別表五", "所得計算"),
    ("確定決算", "所得計算"),
    ("会計処理", "所得計算"),
    ("退職年金", "損金算入"),
    ("保険料", "損金算入"),
    ("繰延資産", "損金算入"),
    ("寄附金", "損金算入"),
    ("リース取引", "損金算入"),
    ("ストックオプション", "損金算入"),
    ("新株予約権", "損金算入"),
    ("申告手続", "申告納付等"),
    ("申告", "申告納付等"),
    ("修正申告", "申告納付等"),
    ("確定申告", "申告納付等"),
    ("電子帳簿保存", "申告納付等"),
    ("自己株式", "資本等取引"),
    ("純資産", "資本等取引"),
    ("使途秘匿金", "税額計算"),
    ("留保金", "税額計算"),
    ("租税特別措置", "税額計算"),
    ("企業支配株式", "益金不算入"),
]

# ─── frontmatter 解析 ─────────────────────────────────────

_FM_DELIM = re.compile(r"^---\s*$", re.MULTILINE)


def parse_frontmatter(text: str):
    """frontmatter を解析して (yaml_dict, raw_fm_block, body) を返す。

    raw_fm_block は先頭の '---' から末尾の '---' までの文字列（改行含む）。
    frontmatter がなければ (None, None, text) を返す。
    """
    if not text.startswith("---"):
        return None, None, text

    # 2つ目の --- を探す
    second = text.find("\n---", 3)
    if second < 0:
        return None, None, text

    # raw block: 先頭の --- から2つ目の --- の行末まで
    end_of_delim = text.index("\n", second + 1) if second + 4 < len(text) else second + 4
    raw_fm = text[: end_of_delim + 1]
    body = text[end_of_delim + 1 :]

    # YAML 部分のみ抽出してパース
    yaml_str = text[4:second].strip()
    try:
        data = yaml.safe_load(yaml_str)
    except yaml.YAMLError:
        return None, None, text

    if not isinstance(data, dict):
        return None, None, text

    return data, raw_fm, body


def resolve_category(subcategory: str) -> str | None:
    """subcategory 文字列から新カテゴリを決定する。マッチしなければ None。"""
    if not subcategory:
        return None
    for pattern, new_cat in MIGRATION_MAP:
        if pattern in subcategory:
            return new_cat
    return None


def update_category_line(raw_fm: str, new_category: str) -> str:
    """frontmatter ブロック内の 'category: その他' 行を新カテゴリに置換する。

    yaml.safe_dump を使わず文字列レベルで置換することで、
    キーの順序やフォーマットを維持する。
    """
    return re.sub(
        r"^(category:\s*)その他\s*$",
        rf"\g<1>{new_category}",
        raw_fm,
        count=1,
        flags=re.MULTILINE,
    )


def atomic_write_text(path: Path, content: str) -> None:
    """テキストをアトミックに書き出す（tempfile + os.replace）。"""
    parent = path.parent
    fd, tmp_path = tempfile.mkstemp(dir=parent, suffix=".tmp", prefix=".mig_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# ─── メイン処理 ─────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="その他カテゴリの論点ノートを適切なカテゴリに再分類する"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="変更内容を表示するだけで実際には書き込まない（デフォルト: off）",
    )
    parser.add_argument(
        "--vault-dir",
        type=str,
        default="/mnt/c/Users/masa/vault/houjinzei",
        help="Vault ルートディレクトリ",
    )
    args = parser.parse_args()

    sonota_dir = Path(args.vault_dir) / "10_論点" / "その他"
    if not sonota_dir.is_dir():
        print(f"Error: directory not found: {sonota_dir}", file=sys.stderr)
        sys.exit(1)

    # 集計用カウンタ
    migration_counts: dict[str, int] = {}  # new_category → count
    remaining = 0
    total = 0
    errors = 0

    md_files = sorted(sonota_dir.glob("*.md"))

    for md_path in md_files:
        # CLAUDE.md をスキップ
        if md_path.name == "CLAUDE.md":
            continue

        total += 1

        text = md_path.read_text(encoding="utf-8")
        fm_data, raw_fm, body = parse_frontmatter(text)

        if fm_data is None:
            remaining += 1
            continue

        # category: その他 でなければスキップ
        if fm_data.get("category") != "その他":
            remaining += 1
            continue

        subcategory = str(fm_data.get("subcategory", ""))
        new_category = resolve_category(subcategory)

        if new_category is None:
            remaining += 1
            continue

        # カテゴリ変更を実行
        if args.dry_run:
            print(
                f"[DRY RUN] {md_path.name}: その他 → {new_category}"
                f" (subcategory: {subcategory})"
            )
        else:
            new_fm = update_category_line(raw_fm, new_category)
            new_text = new_fm + body
            try:
                atomic_write_text(md_path, new_text)
                print(
                    f"[UPDATED] {md_path.name}: その他 → {new_category}"
                    f" (subcategory: {subcategory})"
                )
            except Exception as e:
                print(f"[ERROR] {md_path.name}: {e}", file=sys.stderr)
                errors += 1
                remaining += 1
                continue

        migration_counts[new_category] = migration_counts.get(new_category, 0) + 1

    # サマリー出力
    print()
    print("=== Summary ===")
    for cat in sorted(migration_counts, key=lambda c: -migration_counts[c]):
        print(f"{cat}: {migration_counts[cat]}")
    if remaining > 0:
        print(f"Remaining in その他: {remaining}")
    if errors > 0:
        print(f"Errors: {errors}")
    print(f"Total files processed: {total}")


if __name__ == "__main__":
    main()
