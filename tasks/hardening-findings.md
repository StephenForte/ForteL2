# Hardening findings — Wave 6 (H1 security audit)

Audit date: 2026-08-04. Worker: H1 (`agent/h1-security-audit` off `wave6-base`).

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

## H4 operator drill results (2026-08-04 evening → 2026-08-05 morning)

| Drill | Result | Evidence / notes |
|---|---|---|
| Local 901 redeploy (`start-all.sh` + `deploy-guestbook.sh`) | **PASS** | Fresh contract set; regenerated `deployments.json`/`guestbook.txt`/`intent.toml` committed (`31cb1d3`); guestbook at `0x0116…86Ef` |
| H3a stub double-run (fresh + `--no-wipe`) | **PASS** | Run 2 continued head 10 → block 11 **seq=10** (parentSeq+1) through 20 seq=19; follow-validate PASS both runs; reference tip untouched |
| `derivation-check.sh` 901 window 1–20 | **PASS** | All derived hashes match reference EL on the fresh chain |
| `demo-checklist.sh --sepolia` | **PASS** (exit 0) | After fixing H4-001; all live checks green incl. funds, batch nonce, syncStatus |
| `sepolia-fund-check.sh` | **PASS** (exit 0) | All roles ≥ floors; found + fixed H4-002 |
| Replica sync check | **PASS** | Web Shell method per D-0016: replica chain 852, head=safe=629995 == local safe 629995; lag vs local unsafe 630036 = 41 ≤ 50 (08:16 PT) |
| Dev-sleep/wake cycle | **PASS** (observed) | 21:00 sleep + 04:00 wake both fired via launchd; sequencer backfilled the sleep gap; wake-hour doc drift fixed (`859803a`) |
| Cold-start-under-30-min runbook | **Operator-only** | Not run by integrator per plan §3 |

Drill-found fixes (post-wave, committed to main):

| ID | Finding | Fix |
|---|---|---|
| H4-001 | `test-helpers.sh` gen-viewer-config fixture failed under inherited `FORTEL2_ENV` (only visible via `demo-checklist --sepolia`) | `env -u FORTEL2_ENV` for the fixture run (`902c3aa`) |
| H4-002 | `sepolia-fund-check.sh` example `cast send` hints expanded the raw tokenized L1 URL (missed by H1's sweep — same class as H1-001) | Print literal `$L1_RPC_URL` (`d9713eb`) |
| H4-003 | Repo said wake=05:00; installed LaunchAgent fires 04:00 | Docs + checked-in plist trued up (`859803a`) |
