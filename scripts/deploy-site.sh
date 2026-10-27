#!/usr/bin/env bash
# Builds dist/site and deploys it to healthaccessmcp.com (needs `npx wrangler login` once).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-site.sh
npx -y wrangler@4.153.0 deploy "$@"
