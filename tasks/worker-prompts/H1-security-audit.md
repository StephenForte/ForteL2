# Worker prompt — H1: security & serve-surface hardening audit

Copy everything below the line into the worker. Mid-tier model. Solo checkout; H2/H3 run in parallel — your allowlist is exclusive, respect theirs.

---

You are a security-hardening worker on the ForteL2 repo (Wave 6 = final hardening wave). Read `tasks/plan-parallel-integration.md` §5, `tasks/decisions.md` (D-0013/D-0014 carry your charter), AGENTS.md. Fix in place where allowlisted; everything else goes in a findings doc.

## Work items

1. **Secret-URL redaction sweep (primary, known-live):** `$L1_RPC_URL` carries the QuickNode auth token in its path. The Go derivation client redacts (`derivation/rpc.go` — copy this pattern); shell `redact_rpc_url` exists in `lib.sh` but many echo sites bypass it. Known offenders include `scripts/01-start-l1.sh`, `02-deploy-contracts*.sh`, `05-start-batcher*.sh`, `04-start-sequencer-sepolia.sh` (banner), `start-all-sepolia.sh` (header), `demo-live.sh` — sweep ALL of `scripts/` for echoes/banners/"Inspect:" hints printing URL vars and wrap with `redact_rpc_url`. Then audit `batcher/` and `proposer/` Go code (e.g. `proposer/rpc.go`, submit/propose loops) for transport errors embedding the raw URL — apply the `derivation/rpc.go` redactedError pattern (D-0014 authorizes these redaction-only edits to the otherwise-frozen Phase 4/5 modules; `go test ./...` must stay green and you add tests for what you change).
2. **Serve-surface audit:** every `serve_*` path asserts loopback; CSP headers on viewer/blocks/dapp reviewed. The Google Fonts dependency (viewer + blocks + dapp `index.html` + CSP allowances) breaks self-containment: vendor the woff2 files + `@font-face` CSS if the change is mechanical, else document as an accepted exception in the findings doc with rationale. `textContent`-not-`innerHTML` re-sweep across all three static apps.
3. **Secrets hygiene:** grep the repo for key-shaped strings, `.env` leak paths, log sites printing sensitive values; verify `.gitignore` covers every datadir/scratch pattern in use (anchor, stub, sealing, gomodcache).
4. **Findings doc:** `tasks/hardening-findings.md` (new) — table of finding → severity → fixed-here / escalated / accepted-with-rationale. Anything requiring `lib.sh` `start_bg`/`stop_bg` or out-of-allowlist changes → Escalations (`E-H1-n`), do not implement.

## Write allowlist (exclusive)

`scripts/` **except** `lib.sh` (read-only; escalate needs) and **except** `test-helpers.sh` (H3 owns) · `batcher/`+`proposer/` Go files (redaction-only edits + their tests; never behavior changes) · `viewer/`+`blocks/`+`dapp/` (CSP/fonts/textContent only) · `tasks/hardening-findings.md` (new) · `tasks/decisions.md` (append `D-H1-n`/`E-H1-n`) · README security-related lines only

Do NOT touch: `derivation/` (done), `.github/workflows/` (H3), `go.mod`/`go.sum` anywhere (H2), `deployments/`, PRDs.

## Contract

- Branch `agent/h1-security-audit` (pre-created) off tag `wave6-base`.
- Commits: `fix(security): …` / `docs(hardening): …`; squash-merged later. Merge order is H2 → **H1** → H3; expect a trivial rebase.
- Tests before done (paste verbatim, watch exit codes — do not pipe through grep): `(cd batcher && go test ./...)`; `(cd proposer && go test ./...)`; `node --test blocks/lib.test.js viewer/lib.test.js dapp/lib.test.js`; `/bin/bash -n` every touched script (macOS bash 3.2 — no `$VAR`-adjacent en-dashes, see `ede2ddf`); dry-walk every script flag combination you touched end-to-end on paper (the `--sepolia --make-anchor` ordering bug class).
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

One copy-pasteable markdown block, exactly these sections; a PR description alone is bounced.

1. Branch + base; `git diff --stat wave6-base..HEAD`
2. Allowlist compliance
3. Redaction sweep: every site fixed (file:line), incl. batcher/proposer error paths + their new tests
4. Serve-surface: fonts decision (vendored or exception + why); CSP/textContent results
5. Findings table summary: fixed / escalated / accepted counts
6. Tests + verbatim results
7. decisions.md entries + escalations
8. Operator actions needed
