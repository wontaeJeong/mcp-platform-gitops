# EXECUTABLE CONTRACTS

## OVERVIEW

Shell-based specifications for rendered production resources, local Compose behavior, Keycloak reconciliation, and source identity semantics.

## WHERE TO LOOK

| File | Contract |
|------|----------|
| `bootstrap-reconciliation.sh` | Fresh, drifted, stable, retry, discovery, and failure paths against fake `kcadm` |
| `render-production.sh` | All production Kustomize roots plus security, TLS, sync-wave, and README invariants |
| `local-compose.sh` | Compose topology, realm/config coupling, helper scripts, syntax/compile checks, nested contracts |
| `source-identifier.sh` | Clean/dirty/ignored/deleted/renamed/symlink/mode source IDs |
| `fixtures/fake-kcadm.sh` | Stateful test double recording only bootstrap-used Keycloak operations |

## CONVENTIONS

- Scripts use `set -euo pipefail`, repo-relative `ROOT_DIR`, temporary directories, and cleanup traps.
- Shell assertions use exact fixed-string checks for required and forbidden rendered content.
- Structured Compose and realm checks use embedded Python over rendered JSON and committed config.
- Fixture secrets are synthetic and must remain absent from rendered Compose output.
- `local-compose.sh` is the broadest gate: after local assertions it checks shell syntax, compiles Python, and invokes source-ID and production-render tests.
- External systems are modeled with local fixtures and temporary state; bootstrap tests do not call a real Keycloak.
- Update a contract only when the corresponding repository invariant intentionally changes.

## ANTI-PATTERNS

- Do not weaken exact security, OAuth, TLS, topology, or sync-wave assertions into mere resource-existence checks.
- Do not permit `|| true` in bootstrap behavior or ignore optional-scope attachment failures.
- Do not allow mock host-port or Ingress exposure, mutable local images, or leaked fixture secrets.
- Do not permit `curl -k`, `curl -ki`, or `--insecure` in production paths or documentation.
- Do not remove nested checks from `local-compose.sh` without preserving an equivalent top-level coverage chain.
- Do not expand `fake-kcadm.sh` beyond operations the production bootstrap actually consumes.
