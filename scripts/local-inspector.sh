#!/usr/bin/env bash

set -euo pipefail

for command_name in node npx curl; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "FAIL: $command_name is required" >&2
    exit 1
  }
done

node -e '
const [major, minor, patch] = process.versions.node.split(".").map(Number);
if (major < 22 || (major === 22 && (minor < 7 || (minor === 7 && patch < 5)))) {
  console.error("FAIL: MCP Inspector 0.22.0 requires Node.js 22.7.5 or newer");
  process.exit(1);
}
'

if ! curl --fail --silent --show-error "http://gateway.localhost:8080/readyz" >/dev/null; then
  echo "FAIL: local gateway is not ready; run scripts/local-up.sh first" >&2
  exit 1
fi

echo "Starting MCP Inspector 0.22.0 on http://localhost:6274"
echo "The Inspector creates an ephemeral proxy token and prints it to this terminal."
echo "Press Ctrl-C to stop both the Inspector UI and proxy."

exec env \
  HOST=localhost \
  CLIENT_PORT=6274 \
  SERVER_PORT=6277 \
  MCP_AUTO_OPEN_ENABLED=false \
  npx --yes @modelcontextprotocol/inspector@0.22.0 \
    --transport streamable-http \
    --server-url http://gateway.localhost:8080/mock/mcp
