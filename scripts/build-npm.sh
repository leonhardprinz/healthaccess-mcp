#!/usr/bin/env bash
# Builds healthaccess-mcp and healthaccess for five platforms and stages the npm packages:
#   dist/npm/healthaccess-mcp            the launcher (optionalDependencies on the five below)
#   dist/npm/healthaccess-mcp-<os>-<cpu> one binary pair each
# then packs every package into dist/npm/*.tgz. Needs zig and cargo-zigbuild for Linux
# and Windows. The MCP is built without the `telemetry` feature: no network code.
# Usage: scripts/build-npm.sh            (all platforms)
#        ONLY=darwin-arm64 scripts/build-npm.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
# Keep build-machine paths (home folder, checkout) out of the published binaries.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=~ --remap-path-prefix=$(cd "$(dirname "$0")/.." && pwd)=."

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
NPM_VERSION=$(node -p 'require("./npm/healthaccess-mcp/package.json").version')
[ "$VERSION" = "$NPM_VERSION" ] || { echo "Cargo $VERSION != npm $NPM_VERSION; run scripts/bump-version.sh" >&2; exit 1; }

#        npm key       rust target                    builder  exe
TARGETS="darwin-arm64  aarch64-apple-darwin           cargo    -
darwin-x64             x86_64-apple-darwin            cargo    -
linux-x64              x86_64-unknown-linux-musl      zig      -
linux-arm64            aarch64-unknown-linux-musl     zig      -
win32-x64              x86_64-pc-windows-gnu          zig      .exe"

OUT=dist/npm
rm -rf "$OUT"; mkdir -p "$OUT"

while read -r key target builder exe; do
  [ -n "${ONLY:-}" ] && [ "$ONLY" != "$key" ] && continue
  [ "$exe" = "-" ] && exe=""
  os=${key%-*}; cpu=${key#*-}
  echo "== $key ($target)"
  if [ "$builder" = zig ]; then build=(cargo zigbuild); else build=(cargo build); fi
  "${build[@]}" --release --locked --target "$target" -p healthaccess-mcp --no-default-features --quiet
  "${build[@]}" --release --locked --target "$target" -p healthaccess-cli --quiet
  pkg="$OUT/healthaccess-mcp-$key"
  mkdir -p "$pkg/bin"
  cp "target/$target/release/healthaccess-mcp$exe" "target/$target/release/healthaccess$exe" "$pkg/bin/"
  chmod 755 "$pkg/bin/"*
  cp LICENSE "$pkg/"
  cat > "$pkg/package.json" <<JSON
{
  "name": "healthaccess-mcp-$key",
  "version": "$VERSION",
  "description": "The $key binaries of healthaccess-mcp (Health Access MCP). Install healthaccess-mcp instead.",
  "os": ["$os"],
  "cpu": ["$cpu"],
  "files": ["bin", "LICENSE"],
  "license": "MIT",
  "author": "Prinz Tech Consulting d.o.o. <support@healthaccessmcp.com>",
  "homepage": "https://healthaccessmcp.com",
  "preferUnplugged": true
}
JSON
  printf '# healthaccess-mcp-%s\n\nThe %s binaries of [healthaccess-mcp](https://www.npmjs.com/package/healthaccess-mcp). Install that package instead: `npx -y healthaccess-mcp`.\n' "$key" "$key" > "$pkg/README.md"
done <<< "$TARGETS"

cp -R npm/healthaccess-mcp "$OUT/healthaccess-mcp"
(cd "$OUT" && for d in */; do npm pack "./$d" --silent >/dev/null; done)
ls -l "$OUT"/*.tgz
