# Worker prompt — R2: Sepolia window anchoring (re-close US-061 Sepolia metric)

Copy everything below the line into the worker. Run on the **strongest model**. Cloud/isolated checkout (runs its own 901 stack for the rehearsal).

---

You are a protocol-engineering worker on the ForteL2 repo. Your task is **R2**, defined by decision **D-0010** in `tasks/decisions.md`: the operator's Sepolia run of `derivation-check.sh --sepolia` failed with `missing derived block 595045 in window (have 1998 batches)` because the T4 verifier (a) numbers batches sequentially from 1 by scan position and (b) seals from genesis state — correct for whole-chain local-901 replay, impossible for a mid-chain Sepolia window. You make mid-chain windows work. Binding context, read all first:

- `tasks/decisions.md` — D-0010 (your charter), D-T2-3 (match rule), D-T4-1..4, D-T6-1..3
- `tasks/prd-phase-6-derivation.md` — the re-opened Sepolia success metric is what you are closing (implementation side)
- `derivation/` — you own it: `pipeline.go` (the `blockNum := 1` numbering), `verify.go` (genesis anchor), `engine.go` (sealing EL lifecycle + T6's head helpers), `l1info.go`, `scripts/derivation-check.sh`
- `tasks/plan-parallel-integration.md` §5 + AGENTS.md (always)

## The two halves

### R2a — Timestamp-based block numbering
Replace scan-position numbering: an OP Stack L2 has dense timestamps (`block N time = genesis.l2_time + N * block_time`; this chain never skips). Number every decoded batch by `(batch.Timestamp − genesis.l2_time) / block_time`, drop batches outside the requested window, and de-duplicate (rebroadcast channels may repeat blocks — last write wins is fine, log duplicates). This must leave the local-901 genesis-replay path (blocks 1–20) working unchanged — it becomes a special case, not a separate code path. Validate timestamp alignment (`(ts − l2_time) % block_time == 0`) and fail loudly on drift.

### R2b — State-anchored sealing (the design work)
Sealing block N needs state at N−1. For mid-chain windows, initialize the sealing EL from a **copy of the reference datadir taken while the reference stack is stopped**, then roll the copy back to window-start−1 with `debug_setHead`, and seal forward per the existing Engine API path.

- **Anchor acquisition (script):** `derivation-check.sh` gains `--anchor-datadir <path>` (a pre-made copy) and/or `--make-anchor` (perform the copy itself). The copy step MUST refuse to run while the reference EL is up (probe the RPC port / check the geth lockfile) — a live-copy is corrupt by construction. Document the operator flow: the dev-sleep window (stack stopped nightly 21:00–05:00) is the natural copy time.
- **Derivation-state anchor:** `BuildPayloadAttributes` needs parent hash + epoch (L1 origin number/hash) + sequence number at window start. All of it is recoverable read-only from the reference: parent hash/timestamp via `eth_getBlockByNumber(start−1)`, and epoch + sequence number by decoding the **L1-info deposit tx in block start−1** (first tx of every L2 block; `l1info.go` already parses these bytes). No new trust, no guesswork.
- **Scan bound:** with an anchored window, derive `-from-l1` from the anchor's L1 origin minus the existing `DERIVATION_L1_LOOKBACK` — the current safe-head-based default stays as fallback.
- **Isolation invariants unchanged:** the copy lives under `$DATA_DIR` (own path, gitignored), own ports/JWT, foreground-child lifecycle, `engine_*` confined to `engine.go`, reference stack strictly read-only at runtime. `debug_setHead` runs ONLY against the copy.

### Hardening riders (from D-0010)
- Scan progress output (e.g. a line every 100 L1 blocks) so a slow scan is distinguishable from a hung one.
- Refuse `-from-l1 0` (genesis scan) when the L1 tip is above ~1M blocks unless an explicit `--scan-from-genesis` flag is passed.

## Verification you must run yourself (cloud VM, own 901 stack)

The full mid-chain rehearsal on 901 — this is the acceptance proof:
1. Start the local stack; let it build well past 100 blocks with batches posted.
2. Stop the stack; copy the reference datadir (your `--make-anchor` path); restart the stack.
3. Run the verifier over a window that does **not** start at 1 (e.g. 60–80) using the anchor.
4. PASS = every derived hash matches the reference; paste the run output.
Also: genesis-replay regression (901 blocks 1–20 still PASS) and `go test ./...` with new unit tests for timestamp numbering (incl. duplicates + drift) and L1-info anchor decoding.

## What you must NOT do

- Close the Sepolia success metric yourself — annotate it "implementation landed (R2); operator verification pending" only. The operator runs Sepolia.
- Touch `batcher/`, `proposer/`, `blocks/`, `viewer/`, `dapp/`, `scripts/lib.sh`, `deployments/`. No Sepolia spend/keys/redeploy. No `engine_*` or `debug_*` to the reference stack.
- Copy a datadir while its owner process runs.

## Write allowlist (exclusive)

`derivation/` · `scripts/derivation-check.sh` · `README.md` (Phase 6 derivation subsection: anchor flow + operator copy procedure) · `tasks/prd-phase-6-derivation.md` (annotate re-opened metric + implementation notes) · `tasks/decisions.md` (append `D-R2-n`) · `.gitignore` (anchor-datadir pattern, if needed)

## Contract

- Branch `agent/r2-window-anchoring` (pre-created) off tag `wave4-base` — verify with `git merge-base --is-ancestor wave4-base HEAD`.
- Commits: `feat(derivation): …` / `fix(derivation): …` / `test(derivation): …` / `docs(prd6): …`; squash-merged later.
- Tests before done (paste verbatim): `cd derivation && go build ./... && go test ./... && govulncheck ./...`; `./scripts/test-helpers.sh`; `/bin/bash -n scripts/derivation-check.sh` (macOS bash 3.2 — and no `$VAR`-adjacent en-dashes; see commit `ede2ddf` for the bug class); the 901 mid-chain rehearsal + genesis-replay outputs.
- No merging, no pushing to main.

## Handoff report — REQUIRED as your final chat message

Your last message must BE the report: one copy-pasteable markdown block with exactly these numbered sections. Putting it only in a PR description or a repo file does not count — work without a final-message report is bounced unreviewed.

1. Branch + base (`wave4-base`); `git diff --stat wave4-base..HEAD`
2. Allowlist compliance
3. R2a numbering: approach + edge cases handled (duplicates, drift, window filtering)
4. R2b anchor: copy-guard behavior, `debug_setHead` flow, derivation-state anchor decode — with the 901 mid-chain rehearsal output (window, hashes, PASS)
5. Genesis-replay regression output (901 blocks 1–20)
6. Tests run + verbatim results (incl. govulncheck + bash -n)
7. `decisions.md` entries (D-R2-n) + escalations
8. Operator actions needed (Sepolia anchored run + fixture capture command sequence, spelled out)
