#!/usr/bin/env bash
# End-to-end test of the npm packages without publishing anything: starts a throwaway
# Verdaccio registry on localhost, publishes dist/npm/*.tgz to it, then runs the server
# and the CLI through `npx` exactly as a user would, and speaks MCP to the server.
# Run scripts/build-npm.sh first.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
WORK=$(mktemp -d)
PORT=48731
REG="http://127.0.0.1:$PORT"
trap 'kill $VPID 2>/dev/null || true; rm -rf "$WORK"' EXIT

cat > "$WORK/config.yaml" <<YAML
storage: $WORK/storage
auth: { htpasswd: { file: $WORK/htpasswd, max_users: -1 } }
uplinks: {}
packages:
  'healthaccess-mcp*': { access: \$anonymous, publish: \$anonymous }
  '**': { access: \$anonymous }
log: { type: stdout, format: pretty, level: error }
YAML
npx -y verdaccio@6.11.1 --config "$WORK/config.yaml" --listen "127.0.0.1:$PORT" >"$WORK/verdaccio.log" 2>&1 &
VPID=$!
for _ in $(seq 1 60); do curl -sf "$REG/-/ping" >/dev/null && break; sleep 1; done
curl -sf "$REG/-/ping" >/dev/null || { cat "$WORK/verdaccio.log"; exit 1; }

export npm_config_registry="$REG" npm_config_cache="$WORK/cache" npm_config_userconfig="$WORK/npmrc"
echo "//127.0.0.1:$PORT/:_authToken=anonymous" > "$WORK/npmrc"
for tgz in "$ROOT"/dist/npm/healthaccess-mcp-*-*.tgz "$ROOT"/dist/npm/healthaccess-mcp-[0-9]*.tgz; do
  npm publish "$tgz" --registry "$REG" --access public >/dev/null 2>&1 || { echo "publish failed: $tgz"; exit 1; }
done
echo "published $(ls "$ROOT"/dist/npm/*.tgz | wc -l | tr -d ' ') packages to $REG"

cd "$WORK"
V=$(npx -y healthaccess-mcp --version)
echo "npx -y healthaccess-mcp --version -> $V"
C=$(npx -y -p healthaccess-mcp healthaccess --version)
echo "npx -y -p healthaccess-mcp healthaccess --version -> $C"

# A folder the search would not find; --dir it, then talk MCP (2026-07-28 style).
mkdir -p "$WORK/folder/workouts"
cp "$ROOT/examples/index.json" "$WORK/folder/"
cp "$ROOT"/examples/workouts/*.json "$WORK/folder/workouts/"
python3 - "$WORK/folder" <<'PY'
import json, subprocess, sys, time, os
d = sys.argv[1]
p = subprocess.Popen(["npx", "-y", "healthaccess-mcp", "--dir", d], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "local-registry-test", "version": "1"},
        "io.modelcontextprotocol/clientCapabilities": {}}
def call(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
call(1, "server/discover", {"_meta": meta})
tools = call(2, "tools/list", {"_meta": meta})["result"]["tools"]
res = call(3, "tools/call", {"name": "list_workouts", "arguments": {}, "_meta": meta})["result"]
p.stdin.close(); p.wait(timeout=10)
rows = json.loads(res["content"][0]["text"])
clients = os.listdir(os.path.join(d, "mcp", "clients"))
print(f"MCP over npx: {len(tools)} tools, list_workouts returned {len(rows.get('workouts', rows)) if isinstance(rows, dict) else len(rows)} rows, handshake files: {len(clients)}")
assert len(tools) == 13 and clients
PY
echo "OK"
