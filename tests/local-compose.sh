#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
GENERATED_ENV_FILES=(
  "$TMP_DIR/keycloak.env"
  "$TMP_DIR/gateway.env"
  "$TMP_DIR/mock.env"
)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

required_files=(
  local/compose.yaml
  local/.env.example
  local/keycloak/mcp-realm.json
  local/gateway/config.yaml
  scripts/local-build-push.sh
  scripts/source-identifier.py
  scripts/local-up.sh
  scripts/local-verify.sh
  scripts/local-pkce.py
  scripts/local-inspector.sh
  scripts/local-down.sh
)
for path in "${required_files[@]}"; do
  [ -f "$ROOT_DIR/$path" ] || fail "$path is missing"
done

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

cat >"$TMP_DIR/local.env" <<'EOF'
KEYCLOAK_ADMIN_PASSWORD=contract-admin-secret
LOCAL_USER_PASSWORD=contract-user-secret
MCP_API_TESTS_CLIENT_SECRET=contract-client-secret
MCP_INTERNAL_JWT_SECRET=contract-internal-secret-with-at-least-32-bytes
EOF
cat >"$TMP_DIR/images.env" <<'EOF'
GATEWAY_IMAGE=localhost:5000/mcp-auth-gateway@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MOCK_IMAGE=localhost:5000/mock-mcp-server@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
cat >"${GENERATED_ENV_FILES[0]}" <<'EOF'
KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=contract-admin-secret
LOCAL_USER_PASSWORD=contract-user-secret
MCP_API_TESTS_CLIENT_SECRET=contract-client-secret
EOF
cat >"${GENERATED_ENV_FILES[1]}" <<'EOF'
MCP_INTERNAL_JWT_SECRET=contract-internal-secret-with-at-least-32-bytes
EOF
cat >"${GENERATED_ENV_FILES[2]}" <<'EOF'
MCP_IDENTITY_JWT_SECRET=contract-internal-secret-with-at-least-32-bytes
EOF

KEYCLOAK_RUNTIME_ENV_FILE="${GENERATED_ENV_FILES[0]}" \
GATEWAY_RUNTIME_ENV_FILE="${GENERATED_ENV_FILES[1]}" \
MOCK_RUNTIME_ENV_FILE="${GENERATED_ENV_FILES[2]}" \
docker compose \
  --env-file "$TMP_DIR/local.env" \
  --env-file "$TMP_DIR/images.env" \
  -f "$ROOT_DIR/local/compose.yaml" \
  config --no-env-resolution --format json >"$TMP_DIR/compose.json"

for secret in contract-admin-secret contract-user-secret contract-client-secret contract-internal-secret; do
  if grep -Fq "$secret" "$TMP_DIR/compose.json"; then
    fail "rendered Compose leaked fixture secret: $secret"
  fi
done

python3 - "$ROOT_DIR" "$TMP_DIR/compose.json" "${GENERATED_ENV_FILES[@]}" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
compose = json.loads(pathlib.Path(sys.argv[2]).read_text())
expected_env_files = [str(pathlib.Path(value).resolve()) for value in sys.argv[3:]]
services = compose["services"]

required_services = {"registry", "keycloak", "gateway", "mock"}
assert required_services <= services.keys(), services.keys()
assert "inspector" not in services, "Inspector must remain opt-in and outside Compose"
assert services["registry"]["image"] == "registry:2"

keycloak = services["keycloak"]
assert keycloak["image"] == "quay.io/keycloak/keycloak:26.0"
command = " ".join(keycloak.get("command", []))
assert "start-dev" in command and "--import-realm" in command
assert any(str(port.get("published")) == "8081" for port in keycloak["ports"])
assert not any("keycloak-data" in str(volume) for volume in keycloak.get("volumes", []))

gateway = services["gateway"]
mock = services["mock"]
assert gateway["image"].endswith("@sha256:" + "a" * 64)
assert mock["image"].endswith("@sha256:" + "b" * 64)
assert gateway["pull_policy"] == "always"
assert mock["pull_policy"] == "always"
assert "build" not in gateway and "build" not in mock
assert any(str(port.get("published")) == "8080" for port in gateway["ports"])
assert not mock.get("ports"), "mock must not publish a host port"
assert mock.get("expose") == ["8080"]
assert set(services["registry"]["networks"]) == {"registry"}
assert compose["networks"]["registry"].get("internal") is not True, "published registry network must not be internal"
assert set(keycloak["networks"]) == {"frontend"}
assert set(mock["networks"]) == {"backend"}
assert set(gateway["networks"]) == {"frontend", "backend"}

gateway_env_files = gateway.get("env_file", [])
mock_env = mock.get("environment", {})
rendered_env_files = [
    str(pathlib.Path(keycloak["env_file"][0]["path"]).resolve()),
    str(pathlib.Path(gateway_env_files[0]["path"]).resolve()),
    str(pathlib.Path(mock["env_file"][0]["path"]).resolve()),
]
assert rendered_env_files == expected_env_files, (rendered_env_files, expected_env_files)
assert mock_env["MCP_IDENTITY_ISSUER"] == "mcp-auth-gateway"
assert mock_env["MCP_IDENTITY_AUDIENCE"] == "mock-mcp-server"
assert mock_env["MCP_IDENTITY_ALGORITHM"] == "HS256"

realm = json.loads((root / "local/keycloak/mcp-realm.json").read_text())
assert realm["realm"] == "mcp" and realm["enabled"] is True
clients = {client["clientId"]: client for client in realm["clients"]}
for client in clients.values():
    assert client.get("protocol") == "openid-connect"
    assert "clientProtocol" not in client
browser = clients["mcp-local"]
assert browser["publicClient"] is True
assert browser["standardFlowEnabled"] is True
assert browser["implicitFlowEnabled"] is False
assert browser["directAccessGrantsEnabled"] is False
assert browser["serviceAccountsEnabled"] is False
assert browser["fullScopeAllowed"] is False
assert browser["attributes"]["pkce.code.challenge.method"] == "S256"
assert browser["defaultClientScopes"] == ["basic", "mcp-mock-audience"]
assert browser["redirectUris"] == ["http://127.0.0.1:8765/callback"]
assert browser["webOrigins"] == []

inspector = clients["mcp-inspector"]
assert inspector["publicClient"] is True
assert inspector["standardFlowEnabled"] is True
assert inspector["implicitFlowEnabled"] is False
assert inspector["directAccessGrantsEnabled"] is False
assert inspector["serviceAccountsEnabled"] is False
assert inspector["fullScopeAllowed"] is False
assert inspector["attributes"]["pkce.code.challenge.method"] == "S256"
assert inspector["redirectUris"] == [
    "http://localhost:6274/oauth/callback",
    "http://localhost:6274/oauth/callback/debug",
]
assert inspector["webOrigins"] == ["http://localhost:6274"]
assert inspector["defaultClientScopes"] == ["basic", "mcp-mock-audience"]
assert inspector["optionalClientScopes"] == ["mcp:mock:use"]
assert "basic" in browser["defaultClientScopes"]

tests = clients["mcp-api-tests"]
assert tests["publicClient"] is False
assert tests["standardFlowEnabled"] is False
assert tests["implicitFlowEnabled"] is False
assert tests["directAccessGrantsEnabled"] is False
assert tests["serviceAccountsEnabled"] is True
assert tests["fullScopeAllowed"] is False
assert tests["secret"] == "${MCP_API_TESTS_CLIENT_SECRET}"
assert tests["defaultClientScopes"] == ["basic", "mcp-mock-audience"]
assert "basic" in tests["defaultClientScopes"]

scope = next(scope for scope in realm["clientScopes"] if scope["name"] == "mcp:mock:use")
assert scope["attributes"]["include.in.token.scope"] == "true"
audience = next(mapper for mapper in scope["protocolMappers"] if mapper["protocolMapper"] == "oidc-audience-mapper")
assert audience["config"]["included.custom.audience"] == "http://gateway.localhost:8080/mock/mcp"
basic_scope = next(scope for scope in realm["clientScopes"] if scope["name"] == "basic")
subject_mapper = next(mapper for mapper in basic_scope["protocolMappers"] if mapper["protocolMapper"] == "oidc-sub-mapper")
assert subject_mapper["config"]["access.token.claim"] == "true"

def has_loginid_mapper(client):
    return any(mapper.get("config", {}).get("claim.name") == "loginid" for mapper in client.get("protocolMappers", []))

assert has_loginid_mapper(browser)
assert has_loginid_mapper(inspector)
assert has_loginid_mapper(tests)
user = next(user for user in realm["users"] if user["username"] == "local-user")
assert user["attributes"]["loginid"]
assert user["credentials"][0]["value"] == "${LOCAL_USER_PASSWORD}"

config = (root / "local/gateway/config.yaml").read_text()
assert 'issuer: "http://keycloak.localhost:8081/realms/mcp"' in config
assert 'public_resource: "http://gateway.localhost:8080/mock/mcp"' in config
assert 'audience: "http://gateway.localhost:8080/mock/mcp"' in config
assert 'backend_url: "http://mock:8080"' in config
assert '- "mcp:mock:use"' in config
assert '- "http://gateway.localhost:8080"' in config
assert '- "http://localhost:6274"' in config
assert "INSPECTOR_ORIGIN_INSERTION_POINT" not in config

build = (root / "scripts/local-build-push.sh").read_text()
for contract in ("REGISTRY=localhost:5000", "CA_CERT_FILE", "PUSH=1", "RepoDigests", ".images.env", "@sha256:", "image rm", "pull"):
    assert contract in build, contract
assert "source-identifier.py" in build
assert re.search(r"mktemp|\.tmp", build), "image env must be written atomically"
assert "PLACEHOLDER_DIGEST" not in build
assert "sha256:" + "0" * 64 not in build

up = (root / "scripts/local-up.sh").read_text()
for contract in ("KEYCLOAK_ADMIN_PASSWORD", "LOCAL_USER_PASSWORD", "MCP_API_TESTS_CLIENT_SECRET", "MCP_INTERNAL_JWT_SECRET", "GATEWAY_IMAGE", "MOCK_IMAGE", "issuer"):
    assert contract in up, contract
assert "umask 077" in up
assert "--force-recreate" in up
assert re.search(r"--force-recreate(?:\s+--no-deps)?\s+gateway", up), "gateway config changes must force recreation"

assert "healthcheck" in keycloak
assert "healthcheck" in mock
assert gateway["depends_on"]["keycloak"]["condition"] == "service_healthy"
assert gateway["depends_on"]["mock"]["condition"] == "service_healthy"

inspector_script = (root / "scripts/local-inspector.sh").read_text()
for contract in (
    "@modelcontextprotocol/inspector@0.22.0",
    "HOST=localhost",
    "CLIENT_PORT=6274",
    "SERVER_PORT=6277",
    "MCP_AUTO_OPEN_ENABLED=false",
    "--transport streamable-http",
    "--server-url http://gateway.localhost:8080/mock/mcp",
):
    assert contract in inspector_script, contract
assert "docker.sock" not in inspector_script
assert "MCP_PROXY_AUTH_TOKEN=" not in inspector_script

verify = (root / "scripts/local-verify.sh").read_text()
for contract in ("client_credentials", "mcp:mock:use", "loginid", "WWW-Authenticate", "initialize", "tools/call", "whoami"):
    assert contract in verify, contract
assert "LOCAL_USER_PASSWORD" not in verify
assert not re.search(r"echo.*token|printf.*token", verify, re.IGNORECASE)
assert "dict(response.headers.items())" not in verify
assert "dict(error.headers.items())" not in verify
assert '["port", "mock", "8080"]' not in verify
assert '"protocolVersion": "2025-11-25"' in verify
assert "2025-03-26" not in verify

pkce = (root / "scripts/local-pkce.py").read_text()
for contract in ("secrets.token_urlsafe", "sha256", "code_challenge_method", "S256", "authorization_code", "resource", "state", "HTTPServer", "initialize", "tools/call", "whoami"):
    assert contract in pkce, contract
assert "grant_type=password" not in pkce
assert "LOCAL_USER_PASSWORD" not in pkce
assert pkce.count('"resource"') >= 2
assert '"scope": "openid mcp:mock:use"' in pkce
assert "openid profile" not in pkce
assert "127.0.0.1" in pkce and "8765" in pkce
assert "while" in pkce and "handle_request" in pkce
assert '"protocolVersion": "2025-11-25"' in pkce
assert "2025-03-26" not in pkce
assert re.search(r"nonce\s*=\s*secrets\.token_urlsafe", pkce)
assert re.search(r'"nonce"\s*:\s*nonce', pkce)
for claim_contract in ("jwt_claims", "loginid", "mcp:mock:use", "aud"):
    assert claim_contract in pkce

down = (root / "scripts/local-down.sh").read_text()
assert "down" in down and "--volumes" in down and "--remove-orphans" in down
assert '"$IMAGES_FILE"' in down
assert 'rm -f "$ENV_FILE"' not in down
assert "PLACEHOLDER_DIGEST" not in down
assert "sha256:" + "0" * 64 not in down

readme = (root / "README.md").read_text()
for contract in (
    "scripts/local-build-push.sh",
    "scripts/local-up.sh",
    "scripts/local-verify.sh",
    "scripts/local-pkce.py",
    "scripts/local-inspector.sh",
    "@modelcontextprotocol/inspector@0.22.0",
    "mcp-inspector",
    "http://localhost:6274",
    "http://gateway.localhost:8080/mock/mcp",
    "scripts/local-down.sh",
):
    assert contract in readme, contract
assert "DANGEROUSLY_OMIT_AUTH" not in readme
assert "docker.sock" not in readme

gitignore = (root / ".gitignore").read_text()
assert "local/.*.tmp.*" in gitignore
PY

for script in "$ROOT_DIR"/scripts/local-*.sh "$ROOT_DIR/tests/local-compose.sh"; do
  bash -n "$script"
done
PYTHONPYCACHEPREFIX="$TMP_DIR/pycache" python3 -m py_compile \
  "$ROOT_DIR/scripts/local-pkce.py" \
  "$ROOT_DIR/scripts/source-identifier.py"
bash "$ROOT_DIR/tests/source-identifier.sh"

"$ROOT_DIR/tests/render-production.sh"

echo "PASS: local Compose and security contracts hold"
