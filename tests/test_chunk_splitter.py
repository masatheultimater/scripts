"""chunk_splitter のテスト。"""

import json

from lib.chunk_splitter import build_chunks, detect_chapter_starts, parse_pages


def test_detect_chapter_starts_japanese_and_english():
    text = (
        "--- ページ 1 ---\n"
        "第1章 総論\n本文\n\n"
        "--- ページ 2 ---\n"
        "本文のみ\n\n"
        "--- ページ 3 ---\n"
        "Chapter 2 Special\n本文\n\n"
        "--- ページ 4 ---\n"
        "本文のみ\n"
    )
    pages = parse_pages(text)
    starts = detect_chapter_starts(pages)
    assert starts == [0, 2]


def test_build_chunks_fallback_by_pages_when_no_chapter():
    text = "".join([f"--- ページ {i} ---\n本文{i}\n\n" for i in range(1, 6)])
    pages = parse_pages(text)
    chunks, mode = build_chunks(pages, pages_per_chunk=2)
    assert mode == "fallback_pages"
    assert chunks == [(0, 2), (2, 4), (4, 5)]


def test_cli_creates_manifest_and_chunk_files(tmp_path):
    in_file = tmp_path / "book_text.txt"
    out_dir = tmp_path / "out"
    manifest = tmp_path / "manifest.json"
    in_file.write_text(
        "--- ページ 1 ---\n第1章 総則\nA\n\n"
        "--- ページ 2 ---\nB\n\n"
        "--- ページ 3 ---\n第2章 各論\nC\n\n"
        "--- ページ 4 ---\nD\n",
        encoding="utf-8",
    )

    import subprocess

    subprocess.run(
        [
            "python3",
            "lib/chunk_splitter.py",
            "--input",
            str(in_file),
            "--output-dir",
            str(out_dir),
            "--safe-name",
            "sample",
            "--manifest-out",
            str(manifest),
            "--pages-per-chunk",
            "50",
        ],
        check=True,
    )

    data = json.loads(manifest.read_text(encoding="utf-8"))
    assert data["mode"] == "chapters"
    assert data["chunk_count"] == 2
    assert (out_dir / "sample_chunk_1_text.txt").exists()
    assert (out_dir / "sample_chunk_2_text.txt").exists()
