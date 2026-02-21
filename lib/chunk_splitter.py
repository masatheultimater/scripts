#!/usr/bin/env python3
"""Split extracted PDF text into Gemini-safe chunks.

Input format expects repeated sections like:
--- ページ 1 ---
<page text>
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

PAGE_HEADER_RE = re.compile(r"^--- ページ\s+(\d+)\s+---\s*$", re.MULTILINE)
CHAPTER_RE = re.compile(
    r"^(?:\s*(?:第[0-9０-９一二三四五六七八九十百千万]+(?:章|編)\b.*|(?:CHAPTER|Chapter)\s+\d+\b.*))$"
)


@dataclass
class Page:
    page_no: int
    text: str


def parse_pages(raw_text: str) -> list[Page]:
    matches = list(PAGE_HEADER_RE.finditer(raw_text))
    pages: list[Page] = []
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(raw_text)
        body = raw_text[start:end].strip("\n")
        pages.append(Page(page_no=int(m.group(1)), text=body))
    return pages


def _normalized_lines(text: str, limit: int = 30) -> Iterable[str]:
    cnt = 0
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        yield s
        cnt += 1
        if cnt >= limit:
            break


def detect_chapter_starts(pages: list[Page]) -> list[int]:
    if not pages:
        return []
    starts = [0]
    for idx, page in enumerate(pages[1:], start=1):
        header_lines = list(_normalized_lines(page.text, limit=30))
        if any(CHAPTER_RE.match(line) for line in header_lines):
            starts.append(idx)
    # remove duplicates while preserving order
    deduped: list[int] = []
    seen = set()
    for s in starts:
        if s not in seen:
            deduped.append(s)
            seen.add(s)
    return deduped


def _fallback_boundaries(total_pages: int, pages_per_chunk: int) -> list[int]:
    if total_pages <= 0:
        return []
    boundaries = list(range(0, total_pages, pages_per_chunk))
    if boundaries[0] != 0:
        boundaries.insert(0, 0)
    return boundaries


def _expand_boundaries(boundaries: list[int], total_pages: int, max_pages: int) -> list[int]:
    """Split oversized chapter ranges so each chunk stays bounded."""
    if not boundaries:
        return []
    expanded: list[int] = [boundaries[0]]
    for i, start in enumerate(boundaries):
        end = boundaries[i + 1] if i + 1 < len(boundaries) else total_pages
        length = end - start
        if i == 0 and expanded[0] != start:
            expanded.append(start)
        if length > max_pages:
            next_start = start + max_pages
            while next_start < end:
                expanded.append(next_start)
                next_start += max_pages
        if i + 1 < len(boundaries):
            expanded.append(boundaries[i + 1])

    # normalize ordered unique boundaries within range
    ordered = sorted({b for b in expanded if 0 <= b < total_pages})
    if 0 not in ordered and total_pages > 0:
        ordered.insert(0, 0)
    return ordered


def build_chunks(pages: list[Page], pages_per_chunk: int) -> tuple[list[tuple[int, int]], str]:
    total = len(pages)
    if total == 0:
        return [], "empty"

    chapter_starts = detect_chapter_starts(pages)
    max_reasonable_chunks = max(total // pages_per_chunk * 3, 30)
    if len(chapter_starts) <= 1 or len(chapter_starts) > max_reasonable_chunks:
        boundaries = _fallback_boundaries(total, pages_per_chunk)
        mode = "fallback_pages"
    else:
        boundaries = chapter_starts
        mode = "chapters"

    boundaries = _expand_boundaries(boundaries, total, pages_per_chunk)

    chunks: list[tuple[int, int]] = []
    for i, start in enumerate(boundaries):
        end = boundaries[i + 1] if i + 1 < len(boundaries) else total
        if start < end:
            chunks.append((start, end))
    return chunks, mode


def chunk_to_text(pages: list[Page], start: int, end: int) -> str:
    blocks = []
    for page in pages[start:end]:
        blocks.append(f"--- ページ {page.page_no} ---\n{page.text}\n")
    return "\n".join(blocks).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Split extracted text into chapter/page chunks")
    parser.add_argument("--input", required=True, help="Input extracted text file")
    parser.add_argument("--output-dir", required=True, help="Chunk output directory")
    parser.add_argument("--safe-name", required=True, help="Base safe file name")
    parser.add_argument("--manifest-out", required=True, help="Output manifest json path")
    parser.add_argument("--pages-per-chunk", type=int, default=50, help="Fallback/maximum pages per chunk")
    args = parser.parse_args()

    in_path = Path(args.input)
    out_dir = Path(args.output_dir)
    manifest_path = Path(args.manifest_out)

    raw = in_path.read_text(encoding="utf-8")
    pages = parse_pages(raw)
    chunks, mode = build_chunks(pages, max(1, args.pages_per_chunk))

    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "source": str(in_path),
        "mode": mode,
        "total_pages": len(pages),
        "chunk_count": len(chunks),
        "chunks": [],
    }

    for idx, (start, end) in enumerate(chunks, start=1):
        file_name = f"{args.safe_name}_chunk_{idx}_text.txt"
        chunk_path = out_dir / file_name
        chunk_path.write_text(chunk_to_text(pages, start, end), encoding="utf-8")
        manifest["chunks"].append(
            {
                "chunk_index": idx,
                "path": str(chunk_path),
                "start_page": pages[start].page_no,
                "end_page": pages[end - 1].page_no,
                "page_count": end - start,
            }
        )

    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
