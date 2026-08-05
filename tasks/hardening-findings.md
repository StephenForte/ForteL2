# Hardening findings — Wave 6 (H1 security audit)

Audit date: 2026-08-05. Worker: H1 (`agent/h1-security-audit` off `wave6-base`).

| ID | Finding | Severity | Status | Notes |
|---|---|---|---|---|
| H1-001 | Shell scripts echo/banner `L1_RPC_URL` / `L2_*` without `redact_rpc_url` | **High** | **Fixed** | 17 echo sites wrapped; see handoff §3 |
| H1-002 | `batcher/` Go RPC helpers leak raw URL in transport errors | **High** | **Fixed** | `batcher/redact.go` + `cmd/*/rpc.go` + submit-loop dial |
| H1-003 | `proposer/` Go RPC helpers leak raw URL in transport errors | **High** | **Fixed** | `proposer/rpc.go` + propose-loop / inspect-game dial |
| H1-004 | Google Fonts CDN breaks static self-containment + CSP | **Medium** | **Fixed** | Sora/Syne vendored under `{viewer,blocks,dapp}/fonts/`; CSP `font-src 'self'` |
| H1-005 | `innerHTML` for on-chain strings in static apps | **Medium** | **Accepted (clean)** | Re-sweep: zero `innerHTML` in `viewer/`, `blocks/`, `dapp/` JS; all user/chain text via `textContent` |
| H1-006 | Serve paths must bind loopback only | **Medium** | **Accepted (clean)** | `serve-dapp.sh`, `serve-viewer.sh`, `serve-blocks.sh` all call `serve_static_loopback` |
| H1-007 | `.env` / key material in repo | **High** | **Accepted (clean)** | `.env`, `.env.sepolia`, `data/`, JWT paths gitignored; `.env.example` keys are public Foundry defaults only |
| H1-008 | `proposer/.gomodcache/` not in `.gitignore` | **Low** | **Escalated** | See E-H1-1 in `tasks/decisions.md` |
| H1-009 | `03-init-l2.sh` logs JWT **path** on first create | **Low** | **Accepted** | Path only, not secret bytes; operator-local |
| H1-010 | go-ethereum deep contract-call errors may embed dial URL | **Low** | **Accepted** | Dial sites redacted; deeper geth strings out of redaction-only scope |
| H1-011 | Sepolia L1 RPC token rotation after debugging | **Info** | **Operator** | Rotate QuickNode path token if logs were shared during development |

## Summary counts

| Status | Count |
|---|---|
| Fixed here | 4 |
| Escalated | 1 |
| Accepted (clean or with rationale) | 6 |
