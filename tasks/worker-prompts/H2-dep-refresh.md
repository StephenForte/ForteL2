# Worker prompt — H2: dependency & vulnerability refresh

Copy everything below the line into the worker. Cheap/fast model is sufficient. Solo checkout; H1/H3 run in parallel — allowlists are exclusive.

---

You are a dependency-hygiene worker on the ForteL2 repo (Wave 6 = final hardening wave). Read `tasks/plan-parallel-integration.md` §5 and `tasks/decisions.md` (D-0014). Mechanical, evidence-driven; no behavior changes.

## Work items

1. **Go modules (`batcher/`, `proposer/`, `derivation/`):** `govulncheck ./...` in each; bump any fixable advisory (recent precedent: pion/dtls CVE-2026-54908, klauspost/compress GO-2026-5841 — both already bumped in `derivation/`; check whether `batcher`/`proposer` carry the same paths and align them). GO-2026-5932 (x/crypto openpgp) has **no fix** — verify still uncalled in all three modules and refresh the README "Tracked dependency advisories" wording + date. `go build ./... && go test ./...` green in each module after every bump.
2. **Node:** `(cd scripts/bridge && npm ci && npm audit)` — fix what `npm audit fix` handles without semver-major jumps; report the rest. `node --test lib.test.js` green.
3. **Vendored ethers:** three copies (`dapp/vendor/`, `viewer/vendor/`, `blocks/vendor/`) — verify byte-identical (sha256) and check upstream for a newer 6.x patch release per `dapp/vendor/README.md`; if bumping, bump ALL three together and run all three static-app test files. If current is latest, record that.
4. **Foundry:** `cd contracts && forge test` green; note forge-std version vs upstream (report only — no bump unless an advisory exists).
5. **Report:** append a dated summary to the README advisories section; every bump or explicitly-skipped advisory listed.

## Write allowlist (exclusive)

`batcher/go.mod`+`go.sum` · `proposer/go.mod`+`go.sum` · `derivation/go.mod`+`go.sum` · `scripts/bridge/package.json`+`package-lock.json` · `dapp/vendor/`+`viewer/vendor/`+`blocks/vendor/` (version bump only, all three together) · README "Tracked dependency advisories" section only · `tasks/decisions.md` (append `D-H2-n`)

Do NOT touch: any `.go` source file (H1 owns batcher/proposer edits this wave), scripts, CI workflows (H3), PRDs.

## Contract

- Branch `agent/h2-dep-refresh` (pre-created) off tag `wave6-base`.
- Commits: `fix(deps): …` / `chore(deps): …`; squash-merged later. Merge order: **H2 first** (H1/H3 rebase onto your bumps).
- Tests before done (paste verbatim, watch exit codes — no grep pipelines): per-module `go build && go test && govulncheck`; bridge `npm ci && node --test lib.test.js`; `node --test blocks/lib.test.js viewer/lib.test.js dapp/lib.test.js`; `cd contracts && forge test`.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

One copy-pasteable markdown block, exactly these sections; a PR description alone is bounced.

1. Branch + base; `git diff --stat wave6-base..HEAD`
2. Allowlist compliance
3. Bumps table: module → dep → old → new → advisory; skipped advisories + why
4. govulncheck verdict per module (verbatim tail)
5. Vendored ethers: shas + version verdict
6. Tests + verbatim results
7. decisions.md entries
8. Operator actions needed (expected: none)
