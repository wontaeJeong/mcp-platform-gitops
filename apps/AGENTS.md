# PRODUCTION APPLICATIONS

## OVERVIEW

Four independent Kustomize boundaries for production resources in namespace `mcp-gateway`; cross-app ordering belongs in sibling `argocd/` Applications.

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Keycloak and database | `keycloak/` | CNPG, Deployment, Service, public Ingress |
| Realm bootstrap | `keycloak-bootstrap/` | Sync-hook Job and generated script ConfigMap |
| Authentication gateway | `mcp-auth-gateway/` | Deployment, Service, Ingress, PDB, generated config |
| Mock MCP backend | `mock-mcp-server/` | Deployment, ClusterIP Service, NetworkPolicy; no Ingress |
| Gateway route/auth data | `mcp-auth-gateway/configmap.yaml` | Raw application YAML, not a ConfigMap manifest |
| Secret shapes | `*/secrets.example.yaml` | Documentation only; live Secrets are manual |

## CONVENTIONS

- Every app owns its `kustomization.yaml`; do not add a parent `apps/kustomization.yaml`.
- `keycloak-bootstrap/kustomization.yaml` generates the script ConfigMap from `bootstrap.sh`.
- Bootstrap is an ArgoCD `Sync` hook with `BeforeHookCreation`; repeat syncs must safely reconcile existing objects.
- Gateway config is a generator input named `config.yaml`; hash changes drive Deployment rollout through Kustomize references.
- Gateway signs internal identity with `mcp-internal-signing.jwt-secret` via `MCP_INTERNAL_JWT_SECRET`.
- Mock verifies the same key via `MCP_IDENTITY_JWT_SECRET`, issuer `mcp-auth-gateway`, audience `mock-mcp-server`.
- Mock remains private: ClusterIP only, no Ingress, ingress NetworkPolicy limited to gateway pods.
- CNPG consumes the manual `keycloak-db` basic-auth Secret; database credentials are not generated here.
- Gateway and mock image tags remain `REPLACE_WITH_GIT_SHA` until external CI stamps them.

## ANTI-PATTERNS

- Do not add public ingress or a load-balancer path to `mock-mcp-server`.
- Do not include example Secret manifests in Kustomize resources or fill them with real values.
- Do not replace generated ConfigMaps with checked-in rendered ConfigMap manifests.
- Do not split gateway signing and mock verification keys without changing both application contracts together.
- Do not move realm reconciliation into the Keycloak Deployment; the rerunnable hook owns it.
- Do not relax pod hardening, TLS, PDB, or NetworkPolicy invariants without updating `tests/render-production.sh` intentionally.
