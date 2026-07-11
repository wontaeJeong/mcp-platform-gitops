# OPERATIONAL SCRIPTS

## OVERVIEW

Local image preparation, Compose lifecycle, authentication smoke flows, MCP Inspector launch, and source identity tooling.

## WHERE TO LOOK

| Task | Location | Contract |
|------|----------|----------|
| Build local images | `local-build-push.sh` | Builds sibling repos, pushes, resolves digests, writes `local/.images.env` |
| Identify source state | `source-identifier.py` | Clean HEAD SHA or deterministic dirty SHA-256 |
| Start local stack | `local-up.sh` | Generates runtime env files and enforces issuer/readiness |
| Noninteractive verification | `local-verify.sh` | Auth challenges, claims, MCP initialize/`whoami`, mock isolation |
| Browser login verification | `local-pkce.py` | Authorization Code + PKCE S256 on `127.0.0.1:8765` |
| Optional Inspector | `local-inspector.sh` | Inspector 0.22.0 on loopback ports 6274/6277 |
| Teardown | `local-down.sh` | Removes stack/generated artifacts, preserves `local/.env` |

## CONVENTIONS

- Workflow order: build/push, up, verify, optional PKCE/Inspector, down.
- Runtime outputs stay under `local/`: `.images.env`, generated service env files, `.verify-*`, `.pkce-*`, and temporary files.
- `local/.env` is user-managed input; cleanup must not delete it.
- Builds assume sibling `../mcp-auth-gateway` and `../mock-mcp-server` repos with executable `scripts/build-and-push.sh`.
- Compose image inputs are immutable `localhost:5000/...@sha256:<64 hex>` references.
- Source IDs are 40 hex for clean Git HEAD and 64 hex for deterministic dirty state, including untracked/deleted/symlink/mode changes.
- PKCE uses S256 plus random verifier, state, nonce, and `resource` in authorization and token exchange.
- Inspector stays a foreground host process with proxy authentication enabled; it is not part of Compose.

## ANTI-PATTERNS

- Do not start the stack before `.images.env` exists with valid digest references.
- Do not emit mutable tags, placeholder digests, zero hashes, secrets, or access tokens.
- Do not copy the corporate CA into the repository; `CA_CERT_FILE` points to an absolute existing bundle.
- Do not replace browser PKCE with password grant or omit issuer/audience/scope/`loginid` checks.
- Do not add Docker socket access, application secrets, or Compose wiring to Inspector.
- Do not publish the mock service on a host port.
- Do not delete `local/.env` during teardown.
