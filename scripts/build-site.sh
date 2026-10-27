#!/usr/bin/env bash
# Stages the website into dist/site: the tracked files of site/, plus the reference documents
# from docs/ under /ref/ and the synthetic example folder under /examples/. Only files git
# tracks are copied (git add a new page first), so nothing untracked is ever published.
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf dist/site
mkdir -p dist/site
git ls-files -z site | while IFS= read -r -d '' f; do
  rel="${f#site/}"
  mkdir -p "dist/site/$(dirname "$rel")"
  cp "$f" "dist/site/$rel"
done
rm -f dist/site/vercel.json
mkdir -p dist/site/ref
cp docs/mcp.md docs/schema.md docs/prompts.md docs/export-coverage.md dist/site/ref/
mkdir -p dist/site/examples
git ls-files -z examples | while IFS= read -r -d '' f; do
  rel="${f#examples/}"
  [ "$rel" = generate.py ] && continue
  mkdir -p "dist/site/examples/$(dirname "$rel")"
  cp "$f" "dist/site/examples/$rel"
done
echo "dist/site: $(find dist/site -type f | wc -l | tr -d ' ') files, $(du -sh dist/site | cut -f1)"
