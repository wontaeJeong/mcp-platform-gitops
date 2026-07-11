#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT_DIR/apps/keycloak-bootstrap/bootstrap.sh"
FAKE_KCADM="$ROOT_DIR/tests/fixtures/fake-kcadm.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

run_bootstrap() {
  local state_dir="$1"
  shift
  mkdir -p "$state_dir/discovery"
  if [ "${DISCOVERY_INCLUDE_OPTIONAL_FIELDS:-1}" = "1" ]; then
    cat >"$state_dir/discovery/oidc-discovery.json" <<'JSON'
{"issuer":"https://sso.example.test","authorization_endpoint":"https://sso.example.test/auth","token_endpoint":"https://sso.example.test/token","jwks_uri":"https://sso.example.test/jwks","userinfo_endpoint":"https://sso.example.test/userinfo","end_session_endpoint":"https://sso.example.test/logout"}
JSON
  else
    cat >"$state_dir/discovery/oidc-discovery.json" <<'JSON'
{"issuer":"https://sso.example.test","authorization_endpoint":"https://sso.example.test/auth","token_endpoint":"https://sso.example.test/token","jwks_uri":"https://sso.example.test/jwks"}
JSON
  fi
  env \
    KCADM="$FAKE_KCADM" \
    FAKE_KCADM_STATE_DIR="$state_dir" \
    DISCOVERY_FILE="$state_dir/discovery/oidc-discovery.json" \
    KEYCLOAK_ADMIN=admin \
    KEYCLOAK_ADMIN_PASSWORD=test-password \
    DS_SSO_CLIENT_ID=test-client \
    DS_SSO_CLIENT_SECRET=test-secret \
    KEYCLOAK_LOGIN_RETRY_SECONDS=0 \
    "$@" \
    bash "$BOOTSTRAP"
}

assert_reconciled() {
  local state_dir="$1"
  assert_file_contains "$state_dir/realm" "enabled=true"
  assert_file_contains "$state_dir/realm" "registrationAllowed=false"
  assert_file_contains "$state_dir/realm" "sslRequired=external"
  assert_file_contains "$state_dir/realm" "bruteForceProtected=true"
  assert_file_contains "$state_dir/realm" "permanentLockout=false"
  assert_file_contains "$state_dir/realm" "maxFailureWaitSeconds=900"
  assert_file_contains "$state_dir/realm" "waitIncrementSeconds=60"
  assert_file_contains "$state_dir/realm" "quickLoginCheckMilliSeconds=1000"
  assert_file_contains "$state_dir/realm" "minimumQuickLoginWaitSeconds=60"
  assert_file_contains "$state_dir/realm" "maxDeltaTimeSeconds=43200"
  assert_file_contains "$state_dir/realm" "failureFactor=5"
  assert_file_contains "$state_dir/idp" "config.clientId=test-client"
  assert_file_contains "$state_dir/idp" "config.authorizationUrl=https://sso.example.test/auth"
  assert_file_contains "$state_dir/idp-mapper" 'config."claim"=loginid'
  assert_file_contains "$state_dir/scope" "name=mcp:mock:use"
  assert_file_contains "$state_dir/audience-mapper" 'config."included.custom.audience"=https://gateway.mcp.aidev.samsungds.net/mock/mcp'
  assert_file_contains "$state_dir/loginid-mapper" 'config."claim.name"=loginid'
  assert_file_contains "$state_dir/client" "protocol=openid-connect"
  assert_file_contains "$state_dir/client" "implicitFlowEnabled=false"
  assert_file_contains "$state_dir/client" "directAccessGrantsEnabled=false"
  assert_file_contains "$state_dir/client" "serviceAccountsEnabled=false"
  assert_file_contains "$state_dir/client" "fullScopeAllowed=false"
  assert_file_contains "$state_dir/client" 'attributes."pkce.code.challenge.method"=S256'
  [ -f "$state_dir/optional-scope" ] || fail "optional scope was not attached"
}

[ -f "$BOOTSTRAP" ] || fail "standalone bootstrap.sh is missing"
if grep -Fq '|| true' "$BOOTSTRAP"; then
  fail "bootstrap ignores a command failure with || true"
fi

fresh="$TMP_DIR/fresh"
run_bootstrap "$fresh" FAKE_KCADM_LOGIN_FAILURES=2 KEYCLOAK_LOGIN_MAX_ATTEMPTS=5
assert_reconciled "$fresh"
[ "$(grep -c '^create ' "$fresh/calls.log")" -eq 7 ] || fail "fresh run did not create each absent object exactly once"
[ "$(<"$fresh/login-attempts")" -eq 3 ] || fail "fresh run did not retry login as expected"
assert_file_contains "$fresh/calls.log" "create client-scopes -i"
assert_file_contains "$fresh/calls.log" "create clients -i"

drifted="$TMP_DIR/drifted"
mkdir -p "$drifted"
for object in realm idp idp-mapper scope audience-mapper loginid-mapper client; do
  printf '%s\n' "stale=true" >"$drifted/$object"
done
run_bootstrap "$drifted"
assert_reconciled "$drifted"
[ "$(grep -c '^update ' "$drifted/calls.log")" -eq 8 ] || fail "drifted run did not update all objects and attach the scope"
assert_file_contains "$drifted/calls.log" "update identity-provider/instances/ds-sso/mappers/idp-mapper-loginid"
assert_file_contains "$drifted/calls.log" "update client-scopes/scope-mock/protocol-mappers/models/scope-audience"
assert_file_contains "$drifted/calls.log" "update clients/client-cli"

: >"$drifted/calls.log"
run_bootstrap "$drifted"
assert_reconciled "$drifted"
if grep -q '^create ' "$drifted/calls.log"; then
  fail "stable second run recreated an existing object"
fi
if grep -q 'optional-client-scopes/scope-mock' "$drifted/calls.log"; then
  fail "stable second run reattached an existing optional scope"
fi

bounded="$TMP_DIR/bounded"
if run_bootstrap "$bounded" FAKE_KCADM_LOGIN_FAILURES=99 KEYCLOAK_LOGIN_MAX_ATTEMPTS=3 >/dev/null 2>&1; then
  fail "bootstrap succeeded after exhausting bounded login attempts"
fi
[ "$(<"$bounded/login-attempts")" -eq 3 ] || fail "bounded login did not stop after three attempts"

attach_failure="$TMP_DIR/attach-failure"
if run_bootstrap "$attach_failure" FAKE_KCADM_FAIL_ATTACH=1 >/dev/null 2>&1; then
  fail "bootstrap ignored optional scope attachment failure"
fi

optional_discovery="$TMP_DIR/optional-discovery"
DISCOVERY_INCLUDE_OPTIONAL_FIELDS=0 run_bootstrap "$optional_discovery"
assert_reconciled "$optional_discovery"
assert_file_contains "$optional_discovery/idp" "config.userInfoUrl="
assert_file_contains "$optional_discovery/idp" "config.logoutUrl="

echo "PASS: bootstrap reconciles fresh, drifted, and stable Keycloak state"
