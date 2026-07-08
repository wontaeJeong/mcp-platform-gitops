# mcp-platform-gitops — Mock MCP Gateway

GitOps configuration for the **mock** MCP server behind a Keycloak-backed auth
gateway on the `mcp-gateway` namespace.

## Architecture

```
              (browser / mcp-cli)                DS SSO (ADFS)
                     │                        stsds.secsso.net/adfs
                     │ OIDC login                     ▲
                     ▼                                │ broker (ds-sso)
   auth.mcp.aidev.samsungds.net ──► Keycloak (realm: mcp) ──► CNPG (keycloak-db)
                     │ access_token (aud, scope mcp:mock:use, loginid)
                     ▼
 gateway.mcp.aidev.samsungds.net ──► mcp-auth-gateway
                     │  1. verifies Keycloak access token (JWKS)
                     │  2. checks audience + scope mcp:mock:use
                     │  3. SIGNS internal X-MCP-Identity JWT (HS256, shared secret)
                     ▼  strips /mock, forwards /mcp
              mock-mcp-server (ClusterIP, no Ingress)
                        verifies X-MCP-Identity JWT (same shared secret)
```

- The **gateway signs** an internal `X-MCP-Identity` JWT; the **mock server
  verifies** it. Both share the `mcp-internal-signing` Secret
  (`MCP_INTERNAL_JWT_SECRET`).
- **mock-mcp-server has NO public Ingress** — it is a `ClusterIP` Service reached
  only in-cluster by the gateway.

## Endpoints

| Component | URL |
|-----------|-----|
| Keycloak  | `https://auth.mcp.aidev.samsungds.net` |
| Gateway   | `https://gateway.mcp.aidev.samsungds.net` |
| Mock MCP  | `https://gateway.mcp.aidev.samsungds.net/mock/mcp` |

### DS SSO (identity broker)

- **Discovery URL:** `https://stsds.secsso.net/adfs/.well-known/openid-configuration`
- **Broker alias:** `ds-sso`
- **Redirect URI** (register this in DS SSO):
  `https://auth.mcp.aidev.samsungds.net/realms/mcp/broker/ds-sso/endpoint`

## Keycloak realm objects (created by bootstrap)

| Object | Value |
|--------|-------|
| Realm | `mcp` |
| Identity provider | `ds-sso` (OIDC) |
| Client scope | `mcp:mock:use` |
| Audience | `https://gateway.mcp.aidev.samsungds.net/mock/mcp` |
| Required claim | `loginid` |
| Public client | `mcp-cli` (PKCE) |

## Repository layout

```
apps/
  keycloak/            CNPG cluster + Keycloak Deployment/Service/Ingress
  keycloak-bootstrap/  kcadm.sh bootstrap Job + script ConfigMap
  mcp-auth-gateway/    Gateway Deployment/Service/Ingress/ConfigMap
  mock-mcp-server/     Mock Deployment + ClusterIP Service (no Ingress)
argocd/                One ArgoCD Application per app dir
```

---

## Prerequisites (manual — not managed by ArgoCD)

The namespace and all Secrets are created out-of-band. **Real Secret values are
never committed to Git** — only `secrets.example.yaml` files documenting the
shape live in this repo.

### 1. Namespace

```bash
kubectl create ns mcp-gateway
```

### 2. Secrets

```bash
kubectl -n mcp-gateway create secret generic keycloak-admin \
  --from-literal=username=admin \
  --from-literal=password='<KEYCLOAK_ADMIN_PASSWORD>'

kubectl -n mcp-gateway create secret generic keycloak-db \
  --from-literal=username=keycloak \
  --from-literal=password='<KEYCLOAK_DB_PASSWORD>' \
  --from-literal=database=keycloak

kubectl -n mcp-gateway create secret generic ds-sso-oidc \
  --from-literal=discovery-url='https://stsds.secsso.net/adfs/.well-known/openid-configuration' \
  --from-literal=client-id='<DS_SSO_CLIENT_ID>' \
  --from-literal=client-secret='<DS_SSO_CLIENT_SECRET>'

kubectl -n mcp-gateway create secret generic mcp-internal-signing \
  --from-literal=jwt-secret='<LONG_RANDOM_INTERNAL_JWT_SECRET>'
```

The `mcp-internal-signing` Secret is injected into **both** the gateway (signer)
and the mock server (verifier).

### 3. TLS Secret

`star-mcp-aidev-tls` must already exist in `mcp-gateway` (used by both external
Ingresses). Verify:

```bash
kubectl -n mcp-gateway get secret star-mcp-aidev-tls
```

---

## Deploy

Apply the ArgoCD Applications (or point your app-of-apps at `argocd/`):

```bash
kubectl apply -f argocd/keycloak-application.yaml
kubectl apply -f argocd/keycloak-bootstrap-application.yaml
kubectl apply -f argocd/gateway-application.yaml
kubectl apply -f argocd/mock-application.yaml
```

### ArgoCD sync order (sync-waves)

| Wave | Component | Notes |
|------|-----------|-------|
| —  | namespace + Secrets | **manual prerequisite** (above) |
| 10 | `keycloak-db` (CNPG) | |
| 20 | `keycloak` | Deployment/Service/Ingress |
| 30 | `keycloak-bootstrap` | realm/IdP/scope/client |
| 40 | `mcp-auth-gateway` | |
| 50 | `mock-mcp-server` | last |

### Image tags

Deployments reference untagged images; the Git commit SHA is stamped into
`kustomization.yaml` (`images[].newTag`) by CI:

```
cr.aidev.samsungds.net/mcp-platform/mcp-auth-gateway:<commit-sha>
cr.aidev.samsungds.net/mcp-platform/mock-mcp-server:<commit-sha>
```

---

## Re-running the Keycloak bootstrap

The bootstrap script is **idempotent** — it checks for existing objects before
creating them. It is defined as an ArgoCD `Sync` hook, so it re-runs on every
sync of the `keycloak-bootstrap` Application. To force a manual re-run:

```bash
# Delete the finished Job and re-apply, or re-sync the ArgoCD app:
kubectl -n mcp-gateway delete job keycloak-bootstrap --ignore-not-found
argocd app sync keycloak-bootstrap        # or: kubectl apply -k apps/keycloak-bootstrap
```

It does **not** re-run on its own between syncs, so it will not thrash the realm.

---

## Verification

```bash
kubectl -n mcp-gateway get pods
kubectl -n mcp-gateway get ingress
kubectl -n mcp-gateway logs job/keycloak-bootstrap

# Keycloak realm is up:
curl -k https://auth.mcp.aidev.samsungds.net/realms/mcp/.well-known/openid-configuration

# Gateway advertises the protected resource metadata:
curl -ki https://gateway.mcp.aidev.samsungds.net/.well-known/oauth-protected-resource/mock/mcp

# Unauthenticated MCP request -> 401 + WWW-Authenticate:
curl -ki https://gateway.mcp.aidev.samsungds.net/mock/mcp
```

A tokenless `/mock/mcp` request must return **`401`** with a **`WWW-Authenticate`**
header pointing at the Keycloak realm.

You should see two Ingresses (`keycloak`, `mcp-auth-gateway`) and **no** Ingress
for `mock-mcp-server`.
