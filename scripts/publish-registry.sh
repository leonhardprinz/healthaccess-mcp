#!/usr/bin/env bash
# Publishes npm/server.json to the official MCP registry (registry.modelcontextprotocol.io)
# as com.healthaccessmcp/healthaccess-mcp. Run after scripts/publish-npm.sh: the registry
# checks that the npm version exists and carries the same mcpName.
# Auth is DNS: the TXT record "v=MCPv1; k=ed25519; p=..." at the apex of healthaccessmcp.com
# matches the Ed25519 key below (kept outside the repo; back it up in 1Password).
# Needs: brew install mcp-publisher openssl@3
set -euo pipefail
cd "$(dirname "$0")/../npm"
KEY=${MCP_REGISTRY_KEY:-$HOME/.config/healthaccessmcp/mcp-registry-ed25519.pem}
OPENSSL=$(brew --prefix openssl@3)/bin/openssl
name=$(node -p 'require("./server.json").name')
version=$(node -p 'require("./server.json").version')
mcp-publisher validate
mcp-publisher login dns --domain healthaccessmcp.com \
  --private-key "$("$OPENSSL" pkey -in "$KEY" -noout -text | grep -A3 'priv:' | tail -n +2 | tr -d ' :\n')"
mcp-publisher publish
curl -fsS "https://registry.modelcontextprotocol.io/v0.1/servers?search=$name" \
  | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const v=process.argv[1];
      const s=JSON.parse(d).servers.find(s=>s.server.version===v);
      if(!s){console.error("not listed yet: "+v);process.exit(1)}
      console.log("listed: "+s.server.name+" "+v)})' "$version"
