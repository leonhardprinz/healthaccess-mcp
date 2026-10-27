#!/usr/bin/env bash
# Sets one version everywhere: Cargo workspace, the npm launcher and its optional
# dependencies, npm/server.json, the Claude plugin (its version and the pinned npx package),
# the Homebrew formula and the app's MARKETING_VERSION (the app's build number goes up by one).
# Usage: scripts/bump-version.sh 0.5.1
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?usage: scripts/bump-version.sh <version>}
sed -i '' -E "s/^version = \"[^\"]+\"/version = \"$V\"/" Cargo.toml
sed -i '' -E "s/(healthaccess-core = \{ path = \"core\", version = \")[^\"]+/\1$V/" Cargo.toml
node -e '
  const fs = require("fs"), v = process.argv[1];
  const p = "npm/healthaccess-mcp/package.json", j = JSON.parse(fs.readFileSync(p));
  j.version = v; for (const k of Object.keys(j.optionalDependencies)) j.optionalDependencies[k] = v;
  fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
  const s = "npm/server.json", m = JSON.parse(fs.readFileSync(s));
  m.version = v; for (const pkg of m.packages) pkg.version = v;
  fs.writeFileSync(s, JSON.stringify(m, null, 2) + "\n");
' "$V"
sed -i '' -E "s/\"version\": \"[^\"]+\"/\"version\": \"$V\"/" claude-plugin/.claude-plugin/plugin.json
sed -i '' -E "s/healthaccess-mcp@[0-9][0-9.]*/healthaccess-mcp@$V/g" claude-plugin/.mcp.json claude-plugin/README.md
sed -i '' -E "s/version \"[^\"]+\"/version \"$V\"/; s#v[0-9.]+/healthaccess-mcp-[0-9.]+#v$V/healthaccess-mcp-$V#" packaging/homebrew/healthaccess-mcp.rb
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]+\"/MARKETING_VERSION: \"$V\"/" app/project.yml
build=$(sed -n -E 's/.*CURRENT_PROJECT_VERSION: "([0-9]+)".*/\1/p' app/project.yml)
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[0-9]+\"/CURRENT_PROJECT_VERSION: \"$((build + 1))\"/" app/project.yml
export PATH="$HOME/.cargo/bin:$PATH"; cargo metadata --format-version 1 >/dev/null  # refreshes Cargo.lock
echo "version $V, app build $((build + 1))"
