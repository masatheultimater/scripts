#!/bin/bash
# ============================================================
# STAGE 2: Claude Code によるノート生成
# 使い方: bash stage2.sh <SAFE_NAME>
# ingest.sh から呼ばれる。単独実行も可（STAGE 1 のリカバリ用）
# ============================================================

set -euo pipefail

VAULT="$HOME/vault/houjinzei"

if [ $# -lt 1 ]; then
  echo "使い方: bash stage2.sh <SAFE_NAME>"
  echo "例:     bash stage2.sh 計算問題集①"
  exit 1
fi

SAFE_NAME="$1"
TOPICS_FILE="$VAULT/02_extracted/${SAFE_NAME}_topics.json"

if [ ! -f "$TOPICS_FILE" ]; then
  echo "❌ topics.json が見つかりません: $TOPICS_FILE"
  exit 1
fi

echo "📝 Claude Code でノート生成開始..."
echo "   入力: $TOPICS_FILE"
echo ""

# Claude Code に渡すプロンプト
claude -p "
あなたはObsidian Vaultの管理者です。以下のJSONファイルを読み込み、Vaultにノートを生成・更新してください。

## 入力ファイル
$TOPICS_FILE

## Vault構造
- 論点ノート: $VAULT/10_論点/{category}/{topic_id}.md
- ソースマップ: $VAULT/30_ソース別/

## タスク

### 1. 論点ノートの生成・更新
JSONの各topicについて:

**ノートが存在しない場合** → 新規作成:
\`\`\`markdown
---
topic: \"{topic_id}\"
category: \"{category}\"
subcategory: \"{subcategory}\"
type: {type配列}
importance: \"{importance}\"
conditions: {conditions配列}
sources:
  - \"{source_nameの短縮形}\"
keywords: {keywords配列}
related: {related配列}
kome_total: 0
calc_correct: 0
calc_wrong: 0
last_practiced:
stage: \"未着手\"
status: \"未着手\"
pdf_refs: []
mistakes: []
extracted_from: \"Gemini $(date +%Y-%m-%d)\"
---

# {論点の日本語名}

## 概要
{論点の簡潔な説明を1-2文で}

## 計算手順
{計算の流れをステップ形式で。問題集の内容から推測できる範囲で}

## 判断ポイント
{この論点で問われる主な判断ポイント}

## 間違えやすいポイント


## 関連条文
{conditionsの条文を列挙}
\`\`\`

**ノートが既に存在する場合** → frontmatterのsourcesに教材を追記するだけ（本文は変更しない）

### 2. ソースマップの生成
\`$VAULT/30_ソース別/\` 配下に、出版社別のソースマップを作成:

\`\`\`markdown
---
source_name: \"{JSONのsource_name}\"
source_type: \"{JSONのsource_type}\"
publisher: \"{JSONのpublisher}\"
total_problems: {JSONのtotal_problems}
covered: 0
---

# {source_name}

## 問題 → 論点 マッピング

| 問題番号 | 論点 | リンク |
|---|---|---|
| {各問題番号} | {論点名} | [[{topic_id}]] |
\`\`\`

### 3. categoryフォルダの確認
論点ノートのcategoryに対応するサブフォルダが $VAULT/10_論点/ になければ作成。
既存のカテゴリ: 所得計算, 損金算入, 益金不算入, 税額計算, グループ法人, 組織再編, 国際課税, その他

### 重要な注意
- 既存ノートの本文は絶対に上書きしない
- frontmatterのsources配列への追記のみ行う
- topic_idはJSONの値をそのまま使う
- ファイル名にスラッシュは使わない
- 作成したファイル数と更新したファイル数を最後に報告
"

echo ""
echo "✅ STAGE 2 完了"
