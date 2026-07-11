# mcp-platform-gitops, Mock MCP Gateway

GitOps configuration for the mock MCP server catalog behind a Keycloak-backed
auth gateway in the `mcp-gateway` namespace.

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
  verifies** it. Both containers mount the same `mcp-internal-signing` Secret
  (key `jwt-secret`), but each maps it to its own env var name: the gateway
  reads `MCP_INTERNAL_JWT_SECRET`, mock-mcp-server reads
  `MCP_IDENTITY_JWT_SECRET` (see `apps/mcp-servers/mock/deployment.yaml` for
  its full identity env block, which mirrors mock-mcp-server's
  `Settings.from_env()`).
- **mock-mcp-server has NO public Ingress**. It is a `ClusterIP` Service reached
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
| Public client | `mcp-cli` (Authorization Code + PKCE S256) |

## Repository layout

```
apps/
  keycloak/            CNPG cluster + Keycloak Deployment/Service/Ingress
  keycloak-bootstrap/  kcadm.sh bootstrap Job + generated script ConfigMap
  mcp-auth-gateway/    Gateway Deployment/Service/Ingress/ConfigMap/PDB
  mcp-servers/
    mock/              Mock Deployment + ClusterIP Service + NetworkPolicy
argocd/                Root, 3 fixed Applications, and MCP server ApplicationSet
local/                 Opt-in local Compose configuration
scripts/               Local build, lifecycle, verification, and Inspector tools
tests/                 Shell contract and production-render tests
```

---

## Prerequisites (manual — not managed by ArgoCD)

Cluster-level components assumed to be already installed:

- **ArgoCD with the ApplicationSet CRD and controller**. The root Application
  reconciles three fixed platform Applications plus the MCP server ApplicationSet
  in `argocd/`.
- **CloudNativePG operator** — provides the `postgresql.cnpg.io` CRDs used by `cnpg-cluster.yaml`.
- **Contour** — the `contour` IngressClass used by both Ingresses.

The namespace and all Secrets are created out-of-band. **Real Secret values are
never committed to Git** — only `secrets.example.yaml` files documenting the
shape live in this repo.

> **DS SSO claim name:** the bootstrap maps the ADFS `loginid` claim to the
> Keycloak `loginid` user attribute. If DS SSO emits this claim under a
> different name (e.g. a URI), adjust the IdP mapper `config.claim` in
> `apps/keycloak-bootstrap/bootstrap.sh`.

### 1. Namespace

```bash
kubectl create ns mcp-gateway
```

### 2. Secrets

```bash
kubectl -n mcp-gateway create secret generic keycloak-admin \
  --from-literal=username=admin \
  --from-literal=password='<KEYCLOAK_ADMIN_PASSWORD>'

# CNPG requires this Secret to be of type kubernetes.io/basic-auth.
kubectl -n mcp-gateway create secret generic keycloak-db \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=keycloak \
  --from-literal=password='<KEYCLOAK_DB_PASSWORD>' \
  --from-literal=database=keycloak

kubectl -n mcp-gateway create secret generic ds-sso-oidc \
  --from-literal=discovery-url='https://stsds.secsso.net/adfs/.well-known/openid-configuration' \
  --from-literal=client-id='<DS_SSO_CLIENT_ID>' \
  --from-literal=client-secret='<DS_SSO_CLIENT_SECRET>'

# Use the real corporate trust bundle that validates the DS SSO endpoint.
# Do not copy the certificate into this repository.
CORPORATE_CA_BUNDLE=/absolute/path/to/corporate-ca-bundle.pem
test -s "$CORPORATE_CA_BUNDLE"
kubectl -n mcp-gateway create secret generic corporate-ca \
  --from-file=ca.crt="$CORPORATE_CA_BUNDLE"

kubectl -n mcp-gateway create secret generic mcp-internal-signing \
  --from-literal=jwt-secret='<LONG_RANDOM_INTERNAL_JWT_SECRET>'
```

The `corporate-ca` Secret verifies TLS both while the bootstrap Job fetches DS
SSO discovery metadata and when Keycloak makes outbound broker requests to the
discovered endpoints. The `mcp-internal-signing` Secret is injected into
**both** the gateway (signer) and the mock server (verifier).

### 3. TLS Secret

`star-mcp-aidev-tls` must already exist in `mcp-gateway` (used by both external
Ingresses). Verify:

```bash
kubectl -n mcp-gateway get secret star-mcp-aidev-tls
```

---

## Deploy

Apply the single app-of-apps root:

```bash
kubectl apply -f argocd/root-application.yaml
```

The root manages three fixed platform Applications and one MCP server
ApplicationSet:

- `argocd/keycloak-application.yaml`
- `argocd/keycloak-bootstrap-application.yaml`
- `argocd/gateway-application.yaml`
- `argocd/mcp-servers-applicationset.yaml`

The ApplicationSet scans `apps/mcp-servers/*`. A directory named
`apps/mcp-servers/<name>/` generates an Argo CD Application named
`<name>-mcp-server`, so the current mock catalog entry becomes
`mock-mcp-server`. Removing a server directory removes the generated Application
and prunes the workload resources it managed through the Argo CD resources
finalizer.

The mock runtime contract is unchanged: the workload name remains
`mock-mcp-server`, the Service stays private as `ClusterIP`, NetworkPolicy only
admits gateway pods, the gateway route remains `/mock/mcp`, the required scope
is `mcp:mock:use`, the audience remains
`https://gateway.mcp.aidev.samsungds.net/mock/mcp`, and CI still replaces the
`REPLACE_WITH_GIT_SHA` image placeholder from the sibling source repository.

### ArgoCD sync order (sync-waves)

| Wave | Component | Notes |
|------|-----------|-------|
| —  | namespace + Secrets | **manual prerequisite** (above) |
| 10 | `keycloak-db` (CNPG) | |
| 20 | `keycloak` | Deployment/Service/Ingress |
| 30 | `keycloak-bootstrap` | realm/IdP/scope/client |
| 40 | `mcp-auth-gateway` | |
| 50 | `mcp-servers` ApplicationSet | creates generated MCP server Applications |

Root sync-wave `50` orders creation of the ApplicationSet resource only. It does
not wait for the generated `<name>-mcp-server` Applications to become Healthy or
ready before the root sync completes.

### Image tags

Deployments start with placeholder image tags; the Git commit SHA is stamped
into `kustomization.yaml` (`images[].newTag`) by CI:

```
cr.aidev.samsungds.net/mcp-platform/mcp-auth-gateway:<commit-sha>
cr.aidev.samsungds.net/mcp-platform/mock-mcp-server:<commit-sha>
```

`REPLACE_WITH_GIT_SHA` is deliberately left in the gateway and mock
kustomizations until CI supplies the real source revision. The mock image still
comes from the sibling `mock-mcp-server` source repository. Registry digest
promotion and CNPG backup settings also require external registry/storage
values; this repository does not invent image digests, backup endpoints,
credentials, or retention policy.

---

## Re-running the Keycloak bootstrap

The bootstrap script is **idempotent** — it checks for existing objects before
creating them. The Job is defined as an ArgoCD `Sync` hook
(`hook-delete-policy: BeforeHookCreation`), so it is deleted and re-created
**every time ArgoCD performs a Sync operation on the `keycloak-bootstrap`
Application** — not on a timer, and not merely because the Job's own pod
finished. In practice that means: the initial deploy, any `argocd app sync`,
and any auto-sync triggered by drift in that Application's resources (the
script ConfigMap or the Job manifest itself). Because it's idempotent, repeat
runs are safe (they just re-verify the realm/IdP/scope/client and exit).

To force a manual re-run:

```bash
argocd app sync keycloak-bootstrap
# or, without ArgoCD:
kubectl -n mcp-gateway delete job keycloak-bootstrap --ignore-not-found
kubectl apply -k apps/keycloak-bootstrap
```

---

## Verification

```bash
kubectl -n mcp-gateway get pods
kubectl -n mcp-gateway get ingress
kubectl -n mcp-gateway logs job/keycloak-bootstrap

# Point this at the real trust bundle; never bypass TLS verification with -k.
CORPORATE_CA_BUNDLE=/absolute/path/to/corporate-ca-bundle.pem

# Keycloak realm is up and TLS verifies:
curl --fail --show-error --cacert "$CORPORATE_CA_BUNDLE" \
  https://auth.mcp.aidev.samsungds.net/realms/mcp/.well-known/openid-configuration

# Gateway advertises the protected resource metadata:
curl --fail --show-error --cacert "$CORPORATE_CA_BUNDLE" \
  https://gateway.mcp.aidev.samsungds.net/.well-known/oauth-protected-resource/mock/mcp

# Unauthenticated MCP request -> 401 + WWW-Authenticate:
curl --include --silent --show-error --cacert "$CORPORATE_CA_BUNDLE" \
  https://gateway.mcp.aidev.samsungds.net/mock/mcp
```

A tokenless `/mock/mcp` request must return **`401`** with a **`WWW-Authenticate`**
challenge containing:

```text
Bearer realm="mcp", resource_metadata="https://gateway.mcp.aidev.samsungds.net/.well-known/oauth-protected-resource/mock/mcp", scope="mcp:mock:use"
```

The `resource_metadata` URL resolves to the gateway's protected-resource
document; that document identifies the Keycloak realm in its
`authorization_servers` field.

You should see two Ingresses (`keycloak`, `mcp-auth-gateway`) and **no** Ingress
for `mock-mcp-server`.

---

## Local Compose workflow

The local stack is opt-in and binds its published ports to loopback. The mock
server has no host port. Application images are built from the sibling
`mcp-auth-gateway` and `mock-mcp-server` repositories, pushed to the local
registry, resolved to immutable digests, and then pulled by digest.
Clean sibling worktrees use their full Git commit SHA as the temporary build
tag. Dirty worktrees use a deterministic SHA-256 source identifier covering
tracked and untracked, non-ignored files, so a development image never claims
to be the clean `HEAD`; both temporary tags are removed after digest resolution.

Prerequisites are Docker with Compose, Python 3, `curl`, Git, and the real CA
bundle required by the sibling image builds. Node.js 22.7.5 or newer is needed
only for the optional MCP Inspector workflow.

```bash
cp local/.env.example local/.env
# Fill every value in local/.env. CA_CERT_FILE must be an absolute path to the
# existing trusted CA bundle; do not place the bundle in this repository.

scripts/local-build-push.sh
scripts/local-up.sh
scripts/local-verify.sh
```

`local-up.sh` recreates Keycloak so realm-import changes take effect and
recreates the gateway so changes to the bind-mounted
`local/gateway/config.yaml` take effect. It waits for Keycloak and mock Compose
healthchecks, verifies the exact local issuer, and then verifies gateway
readiness. Run the browser Authorization Code + PKCE S256 check separately:

```bash
scripts/local-pkce.py
```

Sign in as `local-user` with `LOCAL_USER_PASSWORD` from `local/.env`. The script
checks callback state, token issuer, audience, scope, `loginid`, MCP
initialization, and `whoami` without printing the access token.

### MCP Inspector 0.22.0 (optional)

Start the stack first, then launch the Inspector as a foreground host process:

```bash
scripts/local-inspector.sh
```

The script runs exactly `@modelcontextprotocol/inspector@0.22.0`, binds the UI
and proxy to loopback (`http://localhost:6274` and port 6277), keeps proxy
authentication enabled, and preselects Streamable HTTP at
`http://gateway.localhost:8080/mock/mcp`. Open the full URL printed by the
Inspector so its generated proxy token is populated. In the Inspector's OAuth
settings, use client ID `mcp-inspector`, leave the client secret empty, and set
the scope to `openid mcp:mock:use`; then connect and sign in as `local-user`.
The registered callbacks are `/oauth/callback` and `/oauth/callback/debug` on
`http://localhost:6274`.

The Inspector is intentionally not a Compose service and receives neither the
Docker socket nor application secrets. Press Ctrl-C in its terminal to stop
both the UI and proxy. Its random proxy token and OAuth state are browser-local;
clear site data for `http://localhost:6274` after use if the workstation is
shared.

To remove the local stack and generated runtime files:

```bash
scripts/local-down.sh
```

This removes Compose containers, networks, volumes, `local/.images.env`, and
generated per-service env files. It deliberately preserves the user-managed
`local/.env`; delete that file manually only when its local secrets are no
longer needed.

### Repository tests

```bash
tests/bootstrap-reconciliation.sh
tests/render-production.sh
tests/local-compose.sh
```
