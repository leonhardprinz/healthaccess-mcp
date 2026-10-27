#!/usr/bin/env bash
# Publishes what scripts/build-npm.sh staged: the five platform packages first, then the
# launcher. Safe to run again: versions already on the registry are skipped.
# npm requires two-factor authentication to publish. With an authenticator app, pass one
# code for the whole run (it is reused for every package while it is valid):
#   scripts/publish-npm.sh --otp=123456
# With a passkey or security key, run it bare and approve in the browser when asked.
# Pass --dry-run to see what would go out.
set -euo pipefail
cd "$(dirname "$0")/../dist/npm"
args=(--access public "$@")
publish() {
  local tgz=$1 name version
  name=$(tar -xzOf "$tgz" package/package.json | node -p 'JSON.parse(require("fs").readFileSync(0)).name')
  version=$(tar -xzOf "$tgz" package/package.json | node -p 'JSON.parse(require("fs").readFileSync(0)).version')
  if npm view "$name@$version" version >/dev/null 2>&1; then
    echo "skip $name@$version (already published)"
    return
  fi
  npm publish "$tgz" "${args[@]}"
}
for tgz in healthaccess-mcp-darwin-*.tgz healthaccess-mcp-linux-*.tgz healthaccess-mcp-win32-*.tgz; do
  publish "$tgz"
done
publish "$(ls healthaccess-mcp-[0-9]*.tgz)"
echo "done: npx -y healthaccess-mcp --version"
echo "next: scripts/publish-registry.sh (MCP registry)"
