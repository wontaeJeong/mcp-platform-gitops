#!/usr/bin/env bash

set -euo pipefail

KCADM="${KCADM:-/opt/keycloak/bin/kcadm.sh}"
SERVER="${KC_SERVER_URL:-http://keycloak.mcp-gateway.svc.cluster.local:8080}"
DISCOVERY_FILE="${DISCOVERY_FILE:-/discovery/oidc-discovery.json}"
KEYCLOAK_LOGIN_MAX_ATTEMPTS="${KEYCLOAK_LOGIN_MAX_ATTEMPTS:-24}"
KEYCLOAK_LOGIN_RETRY_SECONDS="${KEYCLOAK_LOGIN_RETRY_SECONDS:-5}"

REALM="mcp"
IDP_ALIAS="ds-sso"
SCOPE_NAME="mcp:mock:use"
AUDIENCE="https://gateway.mcp.aidev.samsungds.net/mock/mcp"
CLI_CLIENT="mcp-cli"

if ! [[ "$KEYCLOAK_LOGIN_MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "KEYCLOAK_LOGIN_MAX_ATTEMPTS must be a positive integer" >&2
  exit 1
fi
if ! [[ "$KEYCLOAK_LOGIN_RETRY_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "KEYCLOAK_LOGIN_RETRY_SECONDS must be a non-negative integer" >&2
  exit 1
fi

echo ">> Waiting for Keycloak admin login at ${SERVER} ..."
logged_in=false
for ((attempt = 1; attempt <= KEYCLOAK_LOGIN_MAX_ATTEMPTS; attempt++)); do
  if "$KCADM" config credentials --server "$SERVER" --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1; then
    logged_in=true
    break
  fi
  if ((attempt < KEYCLOAK_LOGIN_MAX_ATTEMPTS)); then
    echo "   Keycloak not ready, retrying in ${KEYCLOAK_LOGIN_RETRY_SECONDS}s (${attempt}/${KEYCLOAK_LOGIN_MAX_ATTEMPTS})..."
    sleep "$KEYCLOAK_LOGIN_RETRY_SECONDS"
  fi
done
if [ "$logged_in" != true ]; then
  echo "!! Keycloak admin login failed after ${KEYCLOAK_LOGIN_MAX_ATTEMPTS} attempts" >&2
  exit 1
fi
echo ">> Logged in."

reconcile_realm() {
  local command_name="$1"
  shift
  "$KCADM" "$command_name" "$@" \
    -s realm="${REALM}" \
    -s enabled=true \
    -s registrationAllowed=false \
    -s sslRequired=external \
    -s bruteForceProtected=true \
    -s permanentLockout=false \
    -s maxFailureWaitSeconds=900 \
    -s waitIncrementSeconds=60 \
    -s quickLoginCheckMilliSeconds=1000 \
    -s minimumQuickLoginWaitSeconds=60 \
    -s maxDeltaTimeSeconds=43200 \
    -s failureFactor=5
}

if "$KCADM" get "realms/${REALM}" >/dev/null 2>&1; then
  echo ">> Reconciling realm '${REALM}'."
  reconcile_realm update "realms/${REALM}"
else
  echo ">> Creating realm '${REALM}'."
  reconcile_realm create realms
fi

echo ">> Reading DS SSO discovery document..."
DISC="$(<"$DISCOVERY_FILE")"
field() {
  local value=""
  if value="$(
    printf '%s\n' "$DISC" \
      | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | sed -nE '1s/.*:[[:space:]]*"([^"]*)".*/\1/p'
  )"; then
    printf '%s\n' "$value"
  fi
  return 0
}

ISSUER="$(field issuer)"
AUTH_URL="$(field authorization_endpoint)"
TOKEN_URL="$(field token_endpoint)"
JWKS_URL="$(field jwks_uri)"
USERINFO_URL="$(field userinfo_endpoint)"
LOGOUT_URL="$(field end_session_endpoint)"

if [ -z "$ISSUER" ] || [ -z "$AUTH_URL" ] || [ -z "$TOKEN_URL" ] || [ -z "$JWKS_URL" ]; then
  echo "!! Failed to parse required DS SSO discovery fields from ${DISCOVERY_FILE}" >&2
  exit 1
fi

reconcile_idp() {
  local command_name="$1"
  shift
  "$KCADM" "$command_name" "$@" -r "$REALM" \
    -s alias="${IDP_ALIAS}" \
    -s displayName="DS SSO" \
    -s providerId=oidc \
    -s enabled=true \
    -s trustEmail=true \
    -s storeToken=false \
    -s firstBrokerLoginFlowAlias="first broker login" \
    -s "config.clientId=${DS_SSO_CLIENT_ID}" \
    -s "config.clientSecret=${DS_SSO_CLIENT_SECRET}" \
    -s "config.clientAuthMethod=client_secret_post" \
    -s "config.issuer=${ISSUER}" \
    -s "config.authorizationUrl=${AUTH_URL}" \
    -s "config.tokenUrl=${TOKEN_URL}" \
    -s "config.jwksUrl=${JWKS_URL}" \
    -s "config.userInfoUrl=${USERINFO_URL}" \
    -s "config.logoutUrl=${LOGOUT_URL}" \
    -s "config.useJwksUrl=true" \
    -s "config.validateSignature=true" \
    -s "config.defaultScope=openid profile email" \
    -s "config.syncMode=FORCE"
}

if "$KCADM" get "identity-provider/instances/${IDP_ALIAS}" -r "$REALM" >/dev/null 2>&1; then
  echo ">> Reconciling identity provider '${IDP_ALIAS}'."
  reconcile_idp update "identity-provider/instances/${IDP_ALIAS}"
else
  echo ">> Creating identity provider '${IDP_ALIAS}'."
  reconcile_idp create identity-provider/instances
fi

IDP_MAPPER_ID="$(
  "$KCADM" get "identity-provider/instances/${IDP_ALIAS}/mappers" -r "$REALM" \
    --fields id,name --format csv --noquotes \
    | awk -F, '$2 == "loginid" { print $1; exit }'
)"
reconcile_idp_mapper() {
  local command_name="$1"
  local resource="$2"
  "$KCADM" "$command_name" "$resource" -r "$REALM" \
    -s name=loginid \
    -s identityProviderAlias="${IDP_ALIAS}" \
    -s identityProviderMapper=oidc-user-attribute-idp-mapper \
    -s 'config."claim"=loginid' \
    -s 'config."user.attribute"=loginid' \
    -s 'config."syncMode"=INHERIT'
}
if [ -n "$IDP_MAPPER_ID" ]; then
  echo ">> Reconciling IdP mapper 'loginid'."
  reconcile_idp_mapper update "identity-provider/instances/${IDP_ALIAS}/mappers/${IDP_MAPPER_ID}"
else
  echo ">> Creating IdP mapper 'loginid'."
  reconcile_idp_mapper create "identity-provider/instances/${IDP_ALIAS}/mappers"
fi

SCOPE_ID="$(
  "$KCADM" get client-scopes -r "$REALM" --fields id,name --format csv --noquotes \
    | awk -F, -v name="$SCOPE_NAME" '$2 == name { print $1; exit }'
)"
reconcile_scope() {
  local command_name="$1"
  local resource="$2"
  shift 2
  "$KCADM" "$command_name" "$resource" "$@" -r "$REALM" \
    -s name="${SCOPE_NAME}" \
    -s protocol=openid-connect \
    -s 'attributes."include.in.token.scope"=true' \
    -s 'attributes."display.on.consent.screen"=false'
}
if [ -n "$SCOPE_ID" ]; then
  echo ">> Reconciling client scope '${SCOPE_NAME}'."
  reconcile_scope update "client-scopes/${SCOPE_ID}"
else
  echo ">> Creating client scope '${SCOPE_NAME}'."
  SCOPE_ID="$(reconcile_scope create client-scopes -i)"
fi

MAPPERS="$(
  "$KCADM" get "client-scopes/${SCOPE_ID}/protocol-mappers/models" -r "$REALM" \
    --fields id,name --format csv --noquotes
)"
AUDIENCE_MAPPER_ID="$(printf '%s\n' "$MAPPERS" | awk -F, '$2 == "mock-audience" { print $1; exit }')"
LOGINID_MAPPER_ID="$(printf '%s\n' "$MAPPERS" | awk -F, '$2 == "loginid" { print $1; exit }')"

reconcile_audience_mapper() {
  local command_name="$1"
  local resource="$2"
  "$KCADM" "$command_name" "$resource" -r "$REALM" \
    -s name=mock-audience \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s "config.\"included.custom.audience\"=${AUDIENCE}" \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=false'
}
if [ -n "$AUDIENCE_MAPPER_ID" ]; then
  echo ">> Reconciling audience mapper -> ${AUDIENCE}"
  reconcile_audience_mapper update "client-scopes/${SCOPE_ID}/protocol-mappers/models/${AUDIENCE_MAPPER_ID}"
else
  echo ">> Creating audience mapper -> ${AUDIENCE}"
  reconcile_audience_mapper create "client-scopes/${SCOPE_ID}/protocol-mappers/models"
fi

reconcile_loginid_mapper() {
  local command_name="$1"
  local resource="$2"
  "$KCADM" "$command_name" "$resource" -r "$REALM" \
    -s name=loginid \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-usermodel-attribute-mapper \
    -s 'config."user.attribute"=loginid' \
    -s 'config."claim.name"=loginid' \
    -s 'config."jsonType.label"=String' \
    -s 'config."access.token.claim"=true' \
    -s 'config."id.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true'
}
if [ -n "$LOGINID_MAPPER_ID" ]; then
  echo ">> Reconciling loginid claim mapper."
  reconcile_loginid_mapper update "client-scopes/${SCOPE_ID}/protocol-mappers/models/${LOGINID_MAPPER_ID}"
else
  echo ">> Creating loginid claim mapper."
  reconcile_loginid_mapper create "client-scopes/${SCOPE_ID}/protocol-mappers/models"
fi

CLIENT_ID="$(
  "$KCADM" get clients -r "$REALM" --query "clientId=${CLI_CLIENT}" \
    --fields id --format csv --noquotes \
    | awk -F, 'NR == 1 { print $1; exit }'
)"
reconcile_client() {
  local command_name="$1"
  local resource="$2"
  shift 2
  "$KCADM" "$command_name" "$resource" "$@" -r "$REALM" \
    -s clientId="${CLI_CLIENT}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s fullScopeAllowed=false \
    -s 'redirectUris=["http://localhost:*","http://127.0.0.1:*"]' \
    -s 'attributes."pkce.code.challenge.method"=S256'
}
if [ -n "$CLIENT_ID" ]; then
  echo ">> Reconciling public client '${CLI_CLIENT}'."
  reconcile_client update "clients/${CLIENT_ID}"
else
  echo ">> Creating public client '${CLI_CLIENT}'."
  CLIENT_ID="$(reconcile_client create clients -i)"
fi

OPTIONAL_SCOPE_ID="$(
  "$KCADM" get "clients/${CLIENT_ID}/optional-client-scopes" -r "$REALM" \
    --fields id,name --format csv --noquotes \
    | awk -F, -v id="$SCOPE_ID" '$1 == id { print $1; exit }'
)"
if [ -z "$OPTIONAL_SCOPE_ID" ]; then
  echo ">> Attaching '${SCOPE_NAME}' as an optional client scope on '${CLI_CLIENT}'."
  "$KCADM" update "clients/${CLIENT_ID}/optional-client-scopes/${SCOPE_ID}" -r "$REALM"
else
  echo ">> Optional client scope '${SCOPE_NAME}' is already attached."
fi

echo ">> Bootstrap complete."
