#!/usr/bin/env bash
# PDF→WebP ページ画像抽出
# 使い方: bash extract_page_images.sh [--book BOOK_NAME] [--dpi N]
set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DPI=200
BOOK_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dpi) DPI="$2"; shift 2 ;;
    --book) BOOK_FILTER="$2"; shift 2 ;;
    -h|--help) echo "使い方: bash extract_page_images.sh [--book BOOK_NAME] [--dpi N]"; exit 0 ;;
    *) echo "エラー: 不明な引数: $1" >&2; exit 1 ;;
  esac
done

export PYTHONPATH="${SCRIPTS_DIR}:${PYTHONPATH:-}"

python3 - "$VAULT" "$DPI" "$BOOK_FILTER" <<'PY'
import json
import sys
from pathlib import Path

vault = Path(sys.argv[1])
dpi = int(sys.argv[2])
book_filter = sys.argv[3]

master_path = vault / "50_エクスポート" / "problems_master.json"
with open(master_path, encoding="utf-8") as f:
    master = json.load(f)

output_dir = vault / "02_extracted" / "page_images"
output_dir.mkdir(parents=True, exist_ok=True)

# Map book names to PDF files in 01_sources/
sources_dir = vault / "01_sources"

# Collect unique (book, page) pairs from problems
pages_needed: dict[str, set[int]] = {}
for pid, prob in master.get("problems", {}).items():
    book = prob.get("book", "")
    page = prob.get("page", 0)
    if not book or page <= 0:
        continue
    if book_filter and book != book_filter:
        continue
    pages_needed.setdefault(book, set()).add(page)

print(f"対象: {sum(len(v) for v in pages_needed.values())}ページ ({len(pages_needed)}冊)")

try:
    import pypdfium2 as pdfium
except ImportError:
    print("エラー: pypdfium2 をインストールしてください: pip install pypdfium2", file=sys.stderr)
    sys.exit(1)

# Find PDF files - try matching book name patterns
# Book names like "法人計算問題集1-1" → look for PDF containing this name
pdf_cache: dict[str, Path] = {}
for pdf_file in sorted(sources_dir.glob("**/*.pdf")):
    pdf_cache[pdf_file.stem] = pdf_file
    # Also index by partial name match
    pdf_cache[pdf_file.name] = pdf_file

def find_pdf(book_name: str) -> Path | None:
    """PDF file for a book name."""
    # Direct stem match
    for stem, path in pdf_cache.items():
        if book_name in stem or stem in book_name:
            return path
    return None

extracted = 0
skipped = 0

for book, pages in sorted(pages_needed.items()):
    book_dir = output_dir / book
    book_dir.mkdir(parents=True, exist_ok=True)

    pdf_path = find_pdf(book)
    if not pdf_path:
        print(f"警告: PDF not found for '{book}', skipping {len(pages)} pages")
        skipped += len(pages)
        continue

    print(f"処理中: {book} ({len(pages)}ページ) from {pdf_path.name}")

    try:
        pdf = pdfium.PdfDocument(str(pdf_path))
    except Exception as e:
        print(f"エラー: {pdf_path}: {e}", file=sys.stderr)
        skipped += len(pages)
        continue

    for page_num in sorted(pages):
        out_file = book_dir / f"{page_num:03d}.webp"
        if out_file.exists():
            extracted += 1
            continue

        # pypdfium2 uses 0-based indexing
        page_idx = page_num - 1
        if page_idx < 0 or page_idx >= len(pdf):
            print(f"  警告: ページ {page_num} は範囲外 (max={len(pdf)})")
            skipped += 1
            continue

        try:
            page = pdf[page_idx]
            bitmap = page.render(scale=dpi / 72)
            image = bitmap.to_pil()
            image.save(str(out_file), "WEBP", quality=85)
            extracted += 1
        except Exception as e:
            print(f"  エラー: page {page_num}: {e}", file=sys.stderr)
            skipped += 1

    pdf.close()

print(f"\n完了: {extracted}ページ抽出, {skipped}ページスキップ")
PY
