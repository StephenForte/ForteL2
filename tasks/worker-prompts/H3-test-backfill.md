# Worker prompt — H3: test backfill & CI tightening

Copy everything below the line into the worker. Mid-tier model. Solo checkout; H1/H2 run in parallel — allowlists are exclusive.

---

You are a test-hardening worker on the ForteL2 repo (Wave 6 = final hardening wave). Read `tasks/plan-parallel-integration.md` §5+§7 and `tasks/decisions.md` — especially D-0010..D-0014: this program found seven real bugs via operator runs, and your job is turning each bug **class** into a permanent guard. Test existing main-state behavior only — do not write tests for H1/H2's in-flight changes (they carry their own).

## Work items

1. **Regression guards for the debugging-arc bug classes** (in `derivation/` test files):
   - `parentBeaconBlockRoot`: unit test that `BuildPayloadAttributes` propagates a non-zero L1 origin beacon root into attrs (the zero-root bug was invisible on Anvil — pin it with a synthetic non-zero vector).
   - `L2Ref` JSON: marshal→unmarshal roundtrip preserves hash+number; absent-number tolerance stays.
   - Timestamp numbering: drift, pre-genesis, block-0, duplicate handling — verify existing coverage, fill gaps.
   - Sequence-number continuation (seq>0 within an epoch — the Sepolia-only path): unit-level coverage if absent.
2. **Script dry-walk tests** in `scripts/test-helpers.sh` (you own it this wave): static assertions for the CLI-mode bug class — `--make-anchor` never reaches the live-RPC window-setup block (grep-level check on script structure), `--json-out` adds `-json`, mid-chain start without anchor errors out, usage text mentions `--sepolia --make-anchor`. Follow the file's existing grep-assert style.
3. **CI tightening** (`.github/workflows/ci.yml`): add a shell-syntax job (`bash -n scripts/*.sh` — and shellcheck if trivially available); verify the derivation test step exercises the golden-fixture replay (it should — confirm and note); confirm actions remain SHA-pinned. Append-only where possible.
4. **Review-habit codification:** append to `tasks/plan-parallel-integration.md` §7 the lessons now proven: "dry-walk every new CLI flag combination end-to-end", "never pipe test output through grep in a gating chain", "fields excluded from a diff are fields you have not checked". Short, imperative lines in the existing checklist style.

## Write allowlist (exclusive)

`*_test.go` in `derivation/` (+ `batcher/`/`proposer/` only if covering existing behavior) · `scripts/test-helpers.sh` · `.github/workflows/ci.yml` · `tasks/plan-parallel-integration.md` (§7 append only) · `tasks/decisions.md` (append `D-H3-n`)

Do NOT touch: production `.go` files, non-test scripts (H1), `go.mod`/vendors (H2), READMEs, PRDs.

## Contract

- Branch `agent/h3-test-backfill` (pre-created) off tag `wave6-base`.
- Commits: `test(…): …` / `ci: …`; squash-merged later. Merge order H2 → H1 → **H3** (you land last; expect a rebase over their merges — your files are disjoint from theirs by design).
- Tests before done (paste verbatim, watch exit codes — no grep pipelines): `(cd derivation && go test ./...)` + any module you added tests to; `./scripts/test-helpers.sh`; `/bin/bash -n scripts/test-helpers.sh`.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

One copy-pasteable markdown block, exactly these sections; a PR description alone is bounced.

1. Branch + base; `git diff --stat wave6-base..HEAD`
2. Allowlist compliance
3. Regression-guard table: bug class → new/verified test → file:line
4. Script dry-walk assertions added
5. CI changes
6. Tests + verbatim results
7. decisions.md entries
8. Operator actions needed (expected: none)
