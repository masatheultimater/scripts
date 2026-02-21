#!/usr/bin/env bash
# R2 へ WebP 画像をアップロード
# 使い方: bash upload_page_images.sh [--dry-run]
set -euo pipefail

VAULT="${VAULT:-$HOME/vault/houjinzei}"
IMAGE_DIR="$VAULT/02_extracted/page_images"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ ! -d "$IMAGE_DIR" ]]; then
  echo "エラー: 画像ディレクトリが見つかりません: $IMAGE_DIR" >&2
  exit 1
fi

# wrangler バイナリを1回だけ解決
WRANGLER_JS="${WRANGLER_JS:-$(find "$HOME/.npm/_npx" -name wrangler.js -path '*/bin/*' 2>/dev/null | head -1)}"
if [[ -z "$WRANGLER_JS" ]] && ! $DRY_RUN; then
  echo "エラー: wrangler.js が見つかりません。npx wrangler --version を実行してキャッシュしてください" >&2
  exit 1
fi

uploaded=0
skipped=0
total=$(find "$IMAGE_DIR" -name "*.webp" | wc -l)

for book_dir in "$IMAGE_DIR"/*/; do
  book=$(basename "$book_dir")
  for webp in "$book_dir"*.webp; do
    [[ -f "$webp" ]] || continue
    page=$(basename "$webp")
    key="$book/$page"

    if $DRY_RUN; then
      echo "[dry-run] r2 put komekome-pages/$key"
      uploaded=$((uploaded + 1))
    else
      if node "$WRANGLER_JS" r2 object put "komekome-pages/$key" \
        --file "$webp" \
        --content-type "image/webp" \
        --remote 2>/dev/null; then
        uploaded=$((uploaded + 1))
        printf "\r%d/%d uploaded" "$uploaded" "$total"
      else
        echo -e "\nエラー: アップロード失敗: $key" >&2
        skipped=$((skipped + 1))
      fi
    fi
  done
done

echo ""
echo "完了: ${uploaded}ファイルアップロード, ${skipped}ファイルスキップ"
