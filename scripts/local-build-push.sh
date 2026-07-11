#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_DIR="$(cd "$ROOT_DIR/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/local"
ENV_FILE="$LOCAL_DIR/.env"
IMAGES_FILE="$LOCAL_DIR/.images.env"
REGISTRY="localhost:5000"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for command_name in docker git python3 curl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
[ -f "$ENV_FILE" ] || fail "copy local/.env.example to local/.env and set CA_CERT_FILE"

CA_CERT_FILE="$(python3 - "$ENV_FILE" <<'PY'
import pathlib
import shlex
import sys

value = ""
for raw in pathlib.Path(sys.argv[1]).read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, candidate = line.split("=", 1)
    if key.strip() == "CA_CERT_FILE":
        parts = shlex.split(candidate, comments=True, posix=True)
        value = parts[0] if parts else ""
        break
print(value)
PY
)"
[ -n "$CA_CERT_FILE" ] || fail "CA_CERT_FILE must be nonempty in local/.env"
[ -r "$CA_CERT_FILE" ] && [ -s "$CA_CERT_FILE" ] || fail "CA_CERT_FILE must name a readable, nonempty CA bundle"

GATEWAY_IMAGE="$REGISTRY/unused-gateway:compose-bootstrap" \
MOCK_IMAGE="$REGISTRY/unused-mock:compose-bootstrap" \
  docker compose -f "$LOCAL_DIR/compose.yaml" up -d registry

ready=false
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error "http://$REGISTRY/v2/" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[ "$ready" = true ] || fail "local OCI registry did not become ready"

GATEWAY_REPO="$REPOS_DIR/mcp-auth-gateway"
MOCK_REPO="$REPOS_DIR/mock-mcp-server"
for repo in "$GATEWAY_REPO" "$MOCK_REPO"; do
  [ -x "$repo/scripts/build-and-push.sh" ] || fail "missing executable build script: $repo/scripts/build-and-push.sh"
done

gateway_id="$(python3 "$ROOT_DIR/scripts/source-identifier.py" "$GATEWAY_REPO")"
mock_id="$(python3 "$ROOT_DIR/scripts/source-identifier.py" "$MOCK_REPO")"
[[ "$gateway_id" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "gateway source identifier is invalid"
[[ "$mock_id" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || fail "mock source identifier is invalid"

REGISTRY=localhost:5000 IMAGE_TAG="$gateway_id" CA_CERT_FILE="$CA_CERT_FILE" PUSH=1 \
  "$GATEWAY_REPO/scripts/build-and-push.sh"
REGISTRY=localhost:5000 IMAGE_TAG="$mock_id" CA_CERT_FILE="$CA_CERT_FILE" PUSH=1 \
  "$MOCK_REPO/scripts/build-and-push.sh"

repo_digest() {
  local tagged_ref="$1"
  local repository="$2"
  local repo_digests
  repo_digests="$(docker image inspect --format '{{json .RepoDigests}}' "$tagged_ref")"
  python3 - "$repository" "$repo_digests" <<'PY'
import json
import sys

repository = sys.argv[1]
digests = json.loads(sys.argv[2]) or []
matches = [value for value in digests if value.startswith(repository + "@sha256:")]
if len(matches) != 1:
    raise SystemExit(f"expected one RepoDigest for {repository}, found {matches}")
digest = matches[0]
if len(digest.rsplit("@sha256:", 1)[1]) != 64:
    raise SystemExit(f"invalid digest reference: {digest}")
print(digest)
PY
}

gateway_tag="$REGISTRY/mcp-platform/mcp-auth-gateway:$gateway_id"
mock_tag="$REGISTRY/mcp-platform/mock-mcp-server:$mock_id"
gateway_digest="$(repo_digest "$gateway_tag" "$REGISTRY/mcp-platform/mcp-auth-gateway")"
mock_digest="$(repo_digest "$mock_tag" "$REGISTRY/mcp-platform/mock-mcp-server")"

tmp_images="$IMAGES_FILE.tmp.$$"
trap 'rm -f "$tmp_images"' EXIT
umask 077
printf 'GATEWAY_IMAGE=%s\nMOCK_IMAGE=%s\n' "$gateway_digest" "$mock_digest" >"$tmp_images"
mv "$tmp_images" "$IMAGES_FILE"
trap - EXIT

for tagged_ref in "$gateway_tag" "$mock_tag"; do
  docker image rm "$tagged_ref" >/dev/null
  if docker image inspect "$tagged_ref" >/dev/null 2>&1; then
    fail "mutable tag still resolves after removal: $tagged_ref"
  fi
done
docker pull "$gateway_digest" >/dev/null
docker pull "$mock_digest" >/dev/null
docker image inspect "$gateway_digest" "$mock_digest" >/dev/null

echo "PASS: wrote digest-only app references to local/.images.env and proved digest pulls"
