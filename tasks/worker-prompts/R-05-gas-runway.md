# Worker prompt — R-05: batcher gas runway readout

Copy everything below the line into the worker. **Mid model tier.** Wave 1; R-01/R-03/R-06 run in parallel — allowlists are exclusive. R-03 also edits `README.md` (the launchd schedule paragraph); touch only your Phase 3 paragraph and do not reflow surrounding text. You own the `test-helpers.sh` append this wave (R-04 appends its own case in a later wave).

---

You are a worker on the ForteL2 repo. Your task card is **`tasks/review-2026-08-05.md` §R-05** — read it in full; it is the spec. This prompt adds the coordination contract and one design constraint the card leaves implicit.

## Task in one line

`sepolia-fund-check.sh` answers "is BATCHER above the floor?"; nothing answers "for how many days?". Build `scripts/gas-runway.sh`: append a balance sample per run to gitignored `data/gas-samples.jsonl`, and once ≥2 samples span ≥1 h, report burn/day and days-to-floor per role (batcher + proposer), with top-up intervals skipped, exit 2 below `GAS_RUNWAY_MIN_DAYS` (default 3), exit 0 with `INSUFFICIENT SAMPLES` before an hour of history.

## Design constraint: sampling and analysis must be separable

You have **no live RPC, no `.env.sepolia`, no QuickNode URL** — and `test-helpers.sh` runs in CI, which has none either. So structure the script in two paths:

- **Sample path** (default): `require_sepolia_env`, `require_bin cast`, `cast balance <addr> --rpc-url "$L1_RPC_URL"` per role, append one JSONL line `{"ts": <unix>, "batcher_wei": "<...>", "proposer_wei": "<...>", "l2_block": <n>}`. Only the operator ever runs this.
- **Analyze path**: pure computation over the samples file — must run with no network, no `cast`, no Sepolia env. Support `GAS_RUNWAY_SAMPLES_FILE=<path>` to override the samples location and an `--analyze-only` flag that skips sampling entirely. This is what your `test-helpers.sh` case exercises with hand-written fixtures.
- Math in `python3` (invoked from the script), not shell arithmetic — wei values exceed bash integers. Use the same floors `sepolia-fund-check.sh` uses (read that script; mirror its floor values or source them the same way it does).
- Burn computation per the card: oldest sample ≥1 h old vs newest; skip any adjacent pair where balance increased (top-up) rather than reporting negative burn.
- Redaction discipline: pass any URL through `redact_rpc_url` before echoing; never print balances' source URL raw; never store or print keys. `set -euo pipefail`; source `scripts/lib.sh` (read-only — never edit it). macOS bash 3.2 compatible (no `declare -A`, no `${var,,}`).

## Test-helpers case (append at end, following existing style)

Fixtures in a temp dir (mktemp, cleaned up — **nothing committed under `data/`**, it is gitignored and must stay untracked):
1. Two samples 1 h apart, 0.01 ETH consumed → asserts ~0.24 ETH/day and a plausible days-remaining.
2. Top-up fixture (balance rises) → no negative burn in output.
3. Single sample → `INSUFFICIENT SAMPLES`, exit 0.
4. Below-min-days fixture → exit 2.

## README paragraph

One paragraph under the Phase 3 "Batcher funding" text: the sampling model, that the first run only records a sample, and the exit-code meanings (0 / 2 / `INSUFFICIENT SAMPLES`).

## Write allowlist (exclusive)

`scripts/gas-runway.sh` (new, executable) · `scripts/test-helpers.sh` (**append your case at the end only**) · `README.md` **Phase 3 batcher-funding paragraph only**

Do NOT touch: `scripts/lib.sh`, `scripts/sepolia-fund-check.sh` (read-only), `.github/`, `tasks/`, anything under `data/`. Needs elsewhere → `E-R05-n` escalation in `decisions.md`.

## Contract

- Branch `agent/r05-gas-runway` off tag `wave8-base`. Commits: `feat(scripts): …` / `test(scripts): …`. Squash-merged last in Wave 1.
- **Never run the sample path against any RPC.** All your verification is fixtures through the analyze path.
- Checks before done (paste verbatim): `bash -n scripts/gas-runway.sh` · `./scripts/test-helpers.sh` ending `All script helper tests passed.` · your captured fixture-run output, then `grep -icE 'private|quiknode'` over that captured output (expect 0) · `git status --porcelain` showing nothing under `data/`.
- Live two-run sampling ≥1 h apart is **operator verification** — list it; do not claim it.
- No merging, no pushing to main, no tags.

## Handoff report — REQUIRED as your final chat message

1. Branch + base tag; `git diff --stat wave8-base..HEAD`
2. Allowlist compliance
3. Card success criteria — each: met-by-fixture / operator-verification-needed, with evidence
4. Tests run + verbatim result lines
5. `decisions.md` entries (expect: none, or E-R05-n)
6. Anticipated conflicts with siblings (expect: README adjacency with R-03; note for integrator that R-04 appends to `test-helpers.sh` next wave)
7. Operator actions needed (expect: two live runs ≥1 h apart; record batcher runway in `tasks/hardening-findings.md` or the next plan per review §4)
