#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/local"
ENV_FILE="$LOCAL_DIR/.env"
IMAGES_FILE="$LOCAL_DIR/.images.env"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for command_name in docker curl python3; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
[ -f "$ENV_FILE" ] || fail "copy local/.env.example to local/.env and set all values"
[ -f "$IMAGES_FILE" ] || fail "run scripts/local-build-push.sh to create local/.images.env"

umask 077
python3 - "$ENV_FILE" "$IMAGES_FILE" "$LOCAL_DIR" <<'PY'
import os
import pathlib
import re
import shlex
import sys

env_path = pathlib.Path(sys.argv[1])
images_path = pathlib.Path(sys.argv[2])
local_dir = pathlib.Path(sys.argv[3])

def read_env(path):
    values = {}
    raw_values = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        key = key.strip()
        parts = shlex.split(raw_value, comments=True, posix=True)
        values[key] = parts[0] if parts else ""
        raw_values[key] = raw_value
    return values, raw_values

values, raw_values = read_env(env_path)
images, _ = read_env(images_path)
required = (
    "KEYCLOAK_ADMIN_PASSWORD",
    "LOCAL_USER_PASSWORD",
    "MCP_API_TESTS_CLIENT_SECRET",
    "MCP_INTERNAL_JWT_SECRET",
)
missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit("nonempty values required in local/.env: " + ", ".join(missing))
if len(values["MCP_INTERNAL_JWT_SECRET"].encode()) < 32:
    raise SystemExit("MCP_INTERNAL_JWT_SECRET must be at least 32 bytes")

image_pattern = re.compile(r"^localhost:5000/mcp-platform/[a-z0-9-]+@sha256:[0-9a-f]{64}$")
for key in ("GATEWAY_IMAGE", "MOCK_IMAGE"):
    value = images.get(key, "")
    if not image_pattern.fullmatch(value):
        raise SystemExit(f"{key} must be a localhost:5000 digest reference in local/.images.env")

outputs = {
    ".keycloak.env": [
        "KC_BOOTSTRAP_ADMIN_USERNAME=admin",
        "KC_BOOTSTRAP_ADMIN_PASSWORD=" + raw_values["KEYCLOAK_ADMIN_PASSWORD"],
        "LOCAL_USER_PASSWORD=" + raw_values["LOCAL_USER_PASSWORD"],
        "MCP_API_TESTS_CLIENT_SECRET=" + raw_values["MCP_API_TESTS_CLIENT_SECRET"],
    ],
    ".gateway.env": ["MCP_INTERNAL_JWT_SECRET=" + raw_values["MCP_INTERNAL_JWT_SECRET"]],
    ".mock.env": ["MCP_IDENTITY_JWT_SECRET=" + raw_values["MCP_INTERNAL_JWT_SECRET"]],
}
for name, lines in outputs.items():
    destination = local_dir / name
    temporary = local_dir / (name + f".tmp.{os.getpid()}")
    temporary.write_text("\n".join(lines) + "\n")
    temporary.chmod(0o600)
    os.replace(temporary, destination)
PY

compose=(docker compose --env-file "$ENV_FILE" --env-file "$IMAGES_FILE" -f "$LOCAL_DIR/compose.yaml")
"${compose[@]}" config --quiet
"${compose[@]}" up -d registry
"${compose[@]}" up -d --force-recreate --wait --wait-timeout 180 keycloak

discovery_url="http://keycloak.localhost:8081/realms/mcp/.well-known/openid-configuration"
expected_issuer="http://keycloak.localhost:8081/realms/mcp"
ready=false
for _ in $(seq 1 90); do
  if discovery="$(curl --fail --silent --show-error "$discovery_url" 2>/dev/null)" && \
    python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin).get("issuer") == sys.argv[1] else 1)' \
      "$expected_issuer" <<<"$discovery"; then
    ready=true
    break
  fi
  sleep 2
done
[ "$ready" = true ] || fail "Keycloak discovery did not publish the exact local issuer"

"${compose[@]}" pull gateway mock
"${compose[@]}" up -d --wait --wait-timeout 120 mock
"${compose[@]}" up -d --force-recreate --no-deps gateway

gateway_ready=false
for _ in $(seq 1 60); do
  if curl --fail --silent --show-error "http://gateway.localhost:8080/readyz" >/dev/null 2>&1; then
    gateway_ready=true
    break
  fi
  sleep 1
done
[ "$gateway_ready" = true ] || fail "gateway did not become ready"

echo "PASS: local registry, Keycloak, digest-pinned gateway, and internal mock are ready"
