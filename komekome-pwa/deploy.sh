#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Update SW cache version to bust old caches
STAMP=$(date +%Y%m%d%H%M%S)
sed -i "s/^const CACHE_VERSION = .*/const CACHE_VERSION = \"${STAMP}\";/" public/sw.js

# Build
bash build.sh

# Cache-bust app.js in index.html
sed -i "s|/app\.js[^\"]*\"|/app.js?v=${STAMP}\"|g" public/index.html

# Deploy to Cloudflare Pages
npx wrangler pages deploy public --project-name komekome --branch main --commit-dirty=true --commit-message="deploy $(date +%Y%m%d-%H%M%S)"

echo "Deploy complete"
