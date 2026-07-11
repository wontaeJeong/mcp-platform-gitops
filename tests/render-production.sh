#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

validate_mcp_servers_applicationset() {
  local applicationset="$1"
  local parser_dir
  local expected
  local unexpected

  parser_dir="$(mktemp -d "$TMP_DIR/applicationset.XXXXXX")"
  cp "$applicationset" "$parser_dir/mcp-servers-applicationset.yaml"
  printf '%s\n' \
    'resources:' \
    '  - mcp-servers-applicationset.yaml' >"$parser_dir/kustomization.yaml"
  kubectl kustomize "$parser_dir" >/dev/null || return 1

  local required=(
    "apiVersion: argoproj.io/v1alpha1"
    "kind: ApplicationSet"
    "namespace: argocd"
    'argocd.argoproj.io/sync-wave: "50"'
    "goTemplate: true"
    'goTemplateOptions: ["missingkey=error"]'
    "repoURL: https://github.com/wontaeJeong/mcp-platform-gitops.git"
    "revision: main"
    "path: apps/mcp-servers/*"
    "name: '{{.path.basename}}-mcp-server'"
    "targetRevision: main"
    "path: '{{.path.path}}'"
    "project: default"
    "server: https://kubernetes.default.svc"
    "namespace: mcp-gateway"
    "resources-finalizer.argocd.argoproj.io"
    "prune: true"
    "selfHeal: true"
    "CreateNamespace=false"
    "preserveResourcesOnDeletion: false"
  )
  local forbidden=(
    "preserveResourcesOnDeletion: true"
    "applicationsSync:"
    "applicationsSync: create-only"
    "applicationsSync: create-update"
  )

  for expected in "${required[@]}"; do
    grep -Fq -- "$expected" "$applicationset" || return 1
  done
  for unexpected in "${forbidden[@]}"; do
    if grep -Fq -- "$unexpected" "$applicationset"; then
      return 1
    fi
  done
}

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"

app_paths=(keycloak keycloak-bootstrap mcp-auth-gateway mcp-servers/mock)
app_names=(keycloak keycloak-bootstrap mcp-auth-gateway mock-mcp-server)
for index in "${!app_paths[@]}"; do
  app_path="${app_paths[$index]}"
  app_name="${app_names[$index]}"
  kubectl kustomize "$ROOT_DIR/apps/$app_path" >"$TMP_DIR/$app_name.yaml"
  [ -s "$TMP_DIR/$app_name.yaml" ] || fail "apps/$app_path rendered no resources"
done

gateway="$TMP_DIR/mcp-auth-gateway.yaml"
assert_contains "$gateway" "allowed_origins:"
assert_contains "$gateway" '- "https://gateway.mcp.aidev.samsungds.net"'
assert_contains "$gateway" 'issuer: "https://auth.mcp.aidev.samsungds.net/realms/mcp"'
assert_contains "$gateway" 'discovery_url: "https://auth.mcp.aidev.samsungds.net/realms/mcp/.well-known/openid-configuration"'
assert_contains "$gateway" 'public_resource: "https://gateway.mcp.aidev.samsungds.net/mock/mcp"'
assert_contains "$gateway" 'audience: "https://gateway.mcp.aidev.samsungds.net/mock/mcp"'
assert_not_contains "$gateway" "http://auth.mcp.aidev.samsungds.net"
assert_not_contains "$gateway" "http://gateway.mcp.aidev.samsungds.net"
assert_contains "$gateway" "kind: PodDisruptionBudget"
assert_contains "$gateway" "minAvailable: 1"
assert_contains "$gateway" "automountServiceAccountToken: false"
assert_contains "$gateway" "runAsNonRoot: true"
assert_contains "$gateway" "allowPrivilegeEscalation: false"
assert_contains "$gateway" "readOnlyRootFilesystem: true"
assert_contains "$gateway" "type: RuntimeDefault"
assert_contains "$gateway" $'startupProbe:\n        httpGet:\n          path: /healthz'

mock="$TMP_DIR/mock-mcp-server.yaml"
assert_contains "$mock" $'readinessProbe:\n        httpGet:\n          path: /readyz'
assert_contains "$mock" $'livenessProbe:\n        httpGet:\n          path: /healthz'
assert_contains "$mock" $'startupProbe:\n        httpGet:\n          path: /healthz'
assert_contains "$mock" "runAsNonRoot: true"
assert_contains "$mock" "allowPrivilegeEscalation: false"
assert_contains "$mock" "readOnlyRootFilesystem: true"
assert_contains "$mock" "type: RuntimeDefault"
assert_contains "$mock" "kind: NetworkPolicy"
assert_contains "$mock" $'policyTypes:\n  - Ingress'
assert_contains "$mock" $'podSelector:\n            matchLabels:\n              app: mcp-auth-gateway'
assert_contains "$mock" "port: 8080"
assert_not_contains "$mock" "kind: Ingress"
assert_not_contains "$mock" "kind: PodDisruptionBudget"
assert_contains "$mock" "automountServiceAccountToken: false"

bootstrap="$TMP_DIR/keycloak-bootstrap.yaml"
assert_contains "$bootstrap" "bootstrap.sh: |"
assert_contains "$bootstrap" 'argocd.argoproj.io/sync-wave: "30"'
assert_contains "$bootstrap" "secretName: corporate-ca"
assert_contains "$bootstrap" "- key: ca.crt"
assert_contains "$bootstrap" "mountPath: /etc/corporate-ca"
assert_contains "$bootstrap" "readOnly: true"
assert_contains "$bootstrap" 'curl --fail --silent --show-error --cacert /etc/corporate-ca/ca.crt'
assert_not_contains "$bootstrap" "--insecure"
if grep -Eq '(^|[[:space:]])-k([[:space:]]|$)' "$bootstrap"; then
  fail "bootstrap uses insecure curl"
fi
assert_contains "$bootstrap" "activeDeadlineSeconds: 600"
assert_contains "$bootstrap" "automountServiceAccountToken: false"
assert_contains "$bootstrap" "runAsNonRoot: true"
assert_contains "$bootstrap" "allowPrivilegeEscalation: false"
assert_contains "$bootstrap" "type: RuntimeDefault"
assert_contains "$bootstrap" "registrationAllowed=false"
assert_contains "$bootstrap" "sslRequired=external"
assert_contains "$bootstrap" "bruteForceProtected=true"
assert_contains "$bootstrap" "implicitFlowEnabled=false"
assert_contains "$bootstrap" "serviceAccountsEnabled=false"
assert_contains "$bootstrap" "fullScopeAllowed=false"
assert_contains "$bootstrap" "protocol=openid-connect"
assert_contains "$bootstrap" "https://gateway.mcp.aidev.samsungds.net/mock/mcp"

[ -f "$ROOT_DIR/apps/keycloak-bootstrap/bootstrap.sh" ] || fail "standalone bootstrap.sh is missing"
[ ! -e "$ROOT_DIR/apps/keycloak-bootstrap/configmap-bootstrap-script.yaml" ] || fail "obsolete embedded ConfigMap still exists"
assert_not_contains "$ROOT_DIR/apps/keycloak-bootstrap/kustomization.yaml" "configmap-bootstrap-script.yaml"
assert_contains "$ROOT_DIR/apps/keycloak-bootstrap/kustomization.yaml" "configMapGenerator:"

assert_contains "$TMP_DIR/keycloak.yaml" 'argocd.argoproj.io/sync-wave: "20"'
assert_contains "$TMP_DIR/keycloak.yaml" "automountServiceAccountToken: false"
assert_contains "$TMP_DIR/keycloak.yaml" "name: KC_TRUSTSTORE_PATHS"
assert_contains "$TMP_DIR/keycloak.yaml" "value: /etc/corporate-ca/ca.crt"
assert_contains "$TMP_DIR/keycloak.yaml" "secretName: corporate-ca"
assert_contains "$TMP_DIR/keycloak.yaml" "mountPath: /etc/corporate-ca"
assert_contains "$bootstrap" 'argocd.argoproj.io/sync-wave: "30"'
assert_contains "$gateway" 'argocd.argoproj.io/sync-wave: "40"'
assert_contains "$mock" 'argocd.argoproj.io/sync-wave: "50"'

applicationset="$ROOT_DIR/argocd/mcp-servers-applicationset.yaml"
validate_mcp_servers_applicationset "$applicationset" || fail "MCP servers ApplicationSet contract is invalid"
[ ! -e "$ROOT_DIR/argocd/mock-application.yaml" ] || fail "obsolete explicit mock Application still exists"
[ ! -e "$ROOT_DIR/apps/mock-mcp-server" ] || fail "obsolete flat mock Kustomize root still exists"

invalid_applicationset="$TMP_DIR/invalid-mcp-servers-applicationset.yaml"
cp "$applicationset" "$invalid_applicationset"
printf '%s\n' '    preserveResourcesOnDeletion: true' >>"$invalid_applicationset"
if validate_mcp_servers_applicationset "$invalid_applicationset"; then
  fail "forbidden ApplicationSet preservation bypassed the contract"
fi

malformed_applicationset="$TMP_DIR/malformed-mcp-servers-applicationset.yaml"
cp "$applicationset" "$malformed_applicationset"
printf '\tmalformed: true\n' >>"$malformed_applicationset"
if validate_mcp_servers_applicationset "$malformed_applicationset" >/dev/null 2>&1; then
  fail "malformed ApplicationSet YAML bypassed the parser"
fi

assert_contains "$ROOT_DIR/apps/mcp-auth-gateway/kustomization.yaml" "newTag: REPLACE_WITH_GIT_SHA"
assert_contains "$ROOT_DIR/apps/mcp-servers/mock/kustomization.yaml" "newTag: REPLACE_WITH_GIT_SHA"

assert_contains "$TMP_DIR/keycloak.yaml" "tls:"
assert_contains "$TMP_DIR/keycloak.yaml" "host: auth.mcp.aidev.samsungds.net"
assert_contains "$TMP_DIR/keycloak.yaml" "secretName: star-mcp-aidev-tls"
assert_contains "$gateway" "tls:"
assert_contains "$gateway" "host: gateway.mcp.aidev.samsungds.net"
assert_contains "$gateway" "secretName: star-mcp-aidev-tls"

readme="$ROOT_DIR/README.md"
assert_contains "$readme" "apps/keycloak-bootstrap/bootstrap.sh"
assert_not_contains "$readme" "apps/keycloak-bootstrap/configmap-bootstrap-script.yaml"
assert_contains "$readme" "secret generic corporate-ca"
assert_contains "$readme" "--from-file=ca.crt="
assert_contains "$readme" "resource_metadata=\"https://gateway.mcp.aidev.samsungds.net/.well-known/oauth-protected-resource/mock/mcp\""
assert_contains "$readme" "--cacert"
assert_not_contains "$readme" "curl -k"
assert_not_contains "$readme" "curl -ki"

echo "PASS: all production app kustomizations render with required invariants"
