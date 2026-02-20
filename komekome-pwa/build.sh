#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

npx esbuild src/komekome.jsx \
  --bundle \
  --outfile=public/app.js \
  --format=iife \
  --jsx=automatic \
  --target=safari15,chrome90,firefox90 \
  --minify

echo "Build complete: public/app.js"
