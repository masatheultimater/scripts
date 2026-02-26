"""Source name normalization for houjinzei topic notes.

Fixes duplicate publisher prefixes in the sources field, e.g.:
  '税務研究会出版局 税務研究会出版局 法人税基本通達逐条解説'
  → '税務研究会出版局 法人税基本通達逐条解説'
"""

# Mapping: raw (broken) source string → corrected source string
# Covers all 20 known duplicate-publisher variants found in the vault.
SOURCES_MAP: dict[str, str] = {
    # 税務研究会出版局
    "税務研究会出版局 税務研究会出版局 法人税基本通達逐条解説":
        "税務研究会出版局 法人税基本通達逐条解説",
    # 大蔵財務協会
    "大蔵財務協会 大蔵財務協会 図解 法人税 令和7年版":
        "大蔵財務協会 図解 法人税 令和7年版",
    # 中央経済社
    "中央経済社 中央経済社 詳解役員給与税務ハンドブック":
        "中央経済社 詳解役員給与税務ハンドブック",
    # 不明 出版社 — publisher="不明", short_source_name="出版社 重点解説 ..."
    "不明 出版社 重点解説 法人税申告の実務(R7)":
        "不明 重点解説 法人税申告の実務(R7)",
    # 不明 不明
    "不明 不明 交際費と隣接費用の区分判断(R6改正)":
        "不明 交際費と隣接費用の区分判断(R6改正)",
    # 資格の大原 / 大原 duplicates
    "資格の大原 資格の大原 法人税法 計算問題集 (一発合格) 1-2":
        "資格の大原 法人税法 計算問題集 (一発合格) 1-2",
    "資格の大原 資格の大原 法人税法 計算問題集 (一発合格) 1-1":
        "資格の大原 法人税法 計算問題集 (一発合格) 1-1",
    "資格の大原 資格の大原 法人税法 計算テキスト2":
        "資格の大原 法人税法 計算テキスト2",
    "資格の大原 資格の大原 法人税法 計算問題集 4-1":
        "資格の大原 法人税法 計算問題集 4-1",
    "資格の大原 資格の大原 法人税法 計算問題集 3-2":
        "資格の大原 法人税法 計算問題集 3-2",
    "資格の大原 大原 法人税法 計算問題集 3-1":
        "資格の大原 法人税法 計算問題集 3-1",
    "資格の大原 大原 法人税法 計算問題集(一発合格) 2-2":
        "資格の大原 法人税法 計算問題集(一発合格) 2-2",
    "資格の大原 大原 法人税法 計算テキスト3":
        "資格の大原 法人税法 計算テキスト3",
    "資格の大原 大原計テ①":
        "資格の大原 計テ①",
    "大原 大原 法人税法 計算問題集 2-1":
        "大原 法人税法 計算問題集 2-1",
    "大原 大原 法人税法 理論テキスト":
        "大原 法人税法 理論テキスト",
    "大原 大原 法人理論問題集":
        "大原 法人理論問題集",
    # 清文社
    "清文社 清文社 なるほど!純資産の部":
        "清文社 なるほど!純資産の部",
    # 税務大学校
    "税務大学校 税務大学校 法人税法(基礎編)":
        "税務大学校 法人税法(基礎編)",
    # TAC
    "TAC TAC 法人税法 計算テキスト4":
        "TAC 法人税法 計算テキスト4",
}


def normalize_source(source: str) -> str:
    """Normalize a single source string.

    Returns the corrected form if a known duplicate pattern is found,
    otherwise returns the original string unchanged.
    """
    return SOURCES_MAP.get(source, source)


def normalize_sources_list(sources: list[str]) -> tuple[list[str], int]:
    """Normalize a list of source strings.

    Returns (normalized_list, change_count).
    Deduplicates after normalization (two different broken forms
    could map to the same corrected form).
    """
    seen: set[str] = set()
    result: list[str] = []
    changes = 0
    for s in sources:
        normalized = normalize_source(s)
        if normalized != s:
            changes += 1
        if normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result, changes
