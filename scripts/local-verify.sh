#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/local"
ENV_FILE="$LOCAL_DIR/.env"
IMAGES_FILE="$LOCAL_DIR/.images.env"

[ -f "$ENV_FILE" ] || { echo "FAIL: local/.env is missing" >&2; exit 1; }
[ -f "$IMAGES_FILE" ] || { echo "FAIL: local/.images.env is missing" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "FAIL: docker is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 1; }

python3 - "$ENV_FILE" "$IMAGES_FILE" "$LOCAL_DIR/compose.yaml" <<'PY'
import base64
import json
import pathlib
import shlex
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

env_file, images_file, compose_file = sys.argv[1:]
issuer = "http://keycloak.localhost:8081/realms/mcp"
token_url = issuer + "/protocol/openid-connect/token"
gateway_url = "http://gateway.localhost:8080/mock/mcp"
audience = gateway_url

def read_env(path):
    values = {}
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        parts = shlex.split(raw_value, comments=True, posix=True)
        values[key.strip()] = parts[0] if parts else ""
    return values

secret = read_env(env_file).get("MCP_API_TESTS_CLIENT_SECRET", "")
if not secret:
    raise SystemExit("MCP_API_TESTS_CLIENT_SECRET must be nonempty")

def request(url, *, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read()

def access_token(scope=None):
    fields = {
        "grant_type": "client_credentials",
        "client_id": "mcp-api-tests",
        "client_secret": secret,
    }
    if scope:
        fields["scope"] = scope
    status, _, body = request(
        token_url,
        data=urllib.parse.urlencode(fields).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    if status != 200:
        raise AssertionError(f"client_credentials failed with HTTP {status}")
    token = json.loads(body)["access_token"]
    if not token:
        raise AssertionError("token endpoint returned an empty access token")
    return token

def jwt_claims(token):
    encoded = token.split(".")[1]
    encoded += "=" * (-len(encoded) % 4)
    return json.loads(base64.urlsafe_b64decode(encoded))

scoped_token = access_token("mcp:mock:use")
claims = jwt_claims(scoped_token)
token_audiences = claims.get("aud", [])
if isinstance(token_audiences, str):
    token_audiences = [token_audiences]
assert audience in token_audiences
assert "mcp:mock:use" in claims.get("scope", "").split()
assert claims.get("loginid") == "mcp-api-tests"
assert claims.get("sub")

status, headers, _ = request(gateway_url)
assert status == 401
challenge = headers.get("WWW-Authenticate", "")
assert challenge.startswith('Bearer realm="mcp"') and "error=" not in challenge

status, headers, _ = request(gateway_url, headers={"Authorization": "Bearer invalid-token"})
assert status == 401
assert 'error="invalid_token"' in headers.get("WWW-Authenticate", "")

unscoped_token = access_token()
unscoped_claims = jwt_claims(unscoped_token)
unscoped_audiences = unscoped_claims.get("aud", [])
if isinstance(unscoped_audiences, str):
    unscoped_audiences = [unscoped_audiences]
assert audience in unscoped_audiences
assert "mcp:mock:use" not in unscoped_claims.get("scope", "").split()
status, headers, _ = request(gateway_url, headers={"Authorization": "Bearer " + unscoped_token})
assert status == 403
assert 'error="insufficient_scope"' in headers.get("WWW-Authenticate", "")

mcp_headers = {
    "Authorization": "Bearer " + scoped_token,
    "Accept": "application/json, text/event-stream",
    "Content-Type": "application/json",
}
initialize = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "local-verify", "version": "1.0.0"},
    },
}
status, _, body = request(gateway_url, data=json.dumps(initialize).encode(), headers=mcp_headers)
assert status == 200, body.decode(errors="replace")
assert "result" in json.loads(body)

tools_call = {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {"name": "whoami", "arguments": {}},
}
status, _, body = request(gateway_url, data=json.dumps(tools_call).encode(), headers=mcp_headers)
assert status == 200, body.decode(errors="replace")
response = json.loads(body)
result = response["result"]
identity = result.get("structuredContent")
if identity is None:
    identity = json.loads(result["content"][0]["text"])
assert identity["loginid"] == "mcp-api-tests"
assert identity["subject"] == claims["sub"]
assert "mcp:mock:use" in identity["scopes"]

compose = [
    "docker", "compose",
    "--env-file", env_file,
    "--env-file", images_file,
    "-f", compose_file,
]
container_id = subprocess.check_output(compose + ["ps", "-q", "mock"], text=True).strip()
assert container_id, "mock container is not running"
inspection = json.loads(subprocess.check_output(["docker", "inspect", container_id], text=True))[0]
assert inspection["HostConfig"]["PortBindings"].get("8080/tcp") is None

print("PASS: auth challenges, token claims, gateway identity, whoami, and mock isolation verified")
PY
