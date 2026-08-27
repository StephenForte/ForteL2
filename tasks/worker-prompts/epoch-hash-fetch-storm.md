DISPATCH · Model: Sonnet · Order: solo; blocks the US-P7-005 measurement (and refunds its cost)
Surface: Claude Code on the operator's Mac
Baseline: main @ b90f0364c8cb (git rev-parse origin/main yourself; trust the repo over this brief)
Working directory: /Users/steveforte/ForteL2 · Landing: PR to main; review takes the next free decision id (D-0101 as of writing)

# fix/epoch-hash-fetch-storm — batch decode fetches one L1 header per L2 block of the whole chain

## Branch
Cut `fix/epoch-hash-fetch-storm` off current main yourself. If it exists, stop and ask.
First commit: this brief, verbatim, as `tasks/worker-prompts/epoch-hash-fetch-storm.md`.

## Evidence (reviewer-diagnosed live, 2026-08-26 — this is the root cause of the endpoint-cost incident)
`deriveBlockInputs` (`derivation/pipeline.go`, the decode loop around line 54) calls
`l1.BlockHeader(ctx, e.EpochNumber)` for every decoded batch element whose `EpochHash` is
empty. Span batches carry epoch numbers, not hashes, and this chain batches spans — so a
genesis-scale run resolves **one header per L2 block of the entire decoded history**
(~185k blocks since the 2026-08-22 wipe), before the window filter, with no memoization.
Observed live: 3 h of continuous `eth_getBlockByNumber` at a throttled 1–2 calls/s after
the inbox scan completed (stack samples hot in JSON string decode; ~70 KB/s inbound;
seal EL parked at 0), projecting 25–50 h to complete a 2,200-block window. The same storm,
unpaced, is what exhausted the QuickNode monthly quota across three earlier runs. This is
a cost/scale defect, not a correctness one: derivations that complete are correct.

## Outcome (properties, not implementation)

1. **Epoch-hash resolution is window-scoped:** decode does not fetch headers for elements
   whose L2 block number falls outside the requested `[start, end]` window. Elements
   outside the window need no resolved hash (they are dropped before derivation).
2. **Within the window, resolution is memoized:** repeated epochs (≈6 consecutive L2
   blocks share one L1 origin) cost one header fetch, cached by block number — mirror the
   existing `blobFeeCache` pattern in `derivation/l1.go`.
3. **Net effect, stated and tested as a budget:** a W-block window touching K distinct L1
   origins performs O(K) header fetches during decode — for a 2,200-block window, ~370,
   not ~185,000. A test must assert the fetch count (instrument the client in the fixture;
   count calls), not just the end result — so a refactor cannot silently reintroduce the
   storm.
4. **Correctness unchanged:** derived hashes for any window are byte-identical to before
   (same fixtures pass unmodified); a genuinely-needed epoch hash is still resolved; a
   missing/unfetchable epoch header inside the window is still a hard error.
5. If the decode path *requires* a resolved hash for elements outside the window for some
   reason you discover (validation, parent linkage), do not silently keep the storm —
   stop and report with the specific requirement.

## Scope
- **Freely changeable:** `derivation/pipeline.go`, `derivation/l1.go` (header cache),
  their test files; `derivation/span*.go` ONLY if the element structure genuinely forces
  it (say so in the report).
- **Additive only:** `scripts/test-helpers.sh` (append only, if any shell-level gate is
  useful), `tasks/worker-prompts/epoch-hash-fetch-storm.md` (this brief, first commit).
- **Do not touch:** `derivation/rpc.go` (#159's surface), `scripts/derivation-check.sh`
  (#160's surface), `batcher/**`, `scripts/lib.sh`, `.github/workflows/**`,
  `tasks/decisions.md` (planner-owned).
- Stop and report rather than widening scope.

## The trap
The window filter today happens *after* decode; the tempting fix is to move filtering
earlier and drop out-of-window elements entirely. Careful: span-batch decoding may need
to walk all elements of a channel to maintain epoch/parent continuity even when only some
land in the window — dropping elements mid-span can corrupt the decode of in-window ones.
Skipping the *header fetch* is safe (the hash is unused for dropped elements); skipping
the *element* may not be. Prove in-window derivations are byte-identical (property 4)
rather than assuming.

## What must survive
- All existing `go test ./...` green with zero modified assertions; fixture-derived
  hashes unchanged. `./scripts/test-helpers.sh` count as found on main; movement is a
  finding. `./scripts/phase7-gate-parity.sh` 60 PASS exit 0.
- The D-0100 resume bound, #159 retry/pacing behavior, and legacy modes untouched.
- D-0049: never read or print `.env.sepolia` values.

## Live shakeout (required, and it doubles as the W1 the operator has been waiting for)
From the merged branch state (after merging current main into it), with
`DERIVATION_RPC_MAX_RPS=10` and `FORTEL2_ENV=.env.sepolia`:
`./scripts/derivation-check.sh --sepolia --self-anchor --start-l2 1 --end-l2 2200`
Expected with the fix: the inbox scan (~2¼ h at 10 RPS — unavoidable, unchanged) and then
a post-scan phase of **minutes, not hours** (≈370 memoized header fetches), sealing, and
`derivation-check: PASS` with the seal-rate line. Report scan wall-clock, post-scan
wall-clock, and the seal rate — these are the D-0097 measurement numbers. If the run
cannot finish before the 23:45 chain dev-sleep window, run it the next morning and say so
rather than handing back an interrupted run.

## Out of scope, with reasons
- W2 (resumed ≥1000-block window) and the factory audit — operator-run after merge.
- Pacer burst-smoothing (post-backoff credit burst observed, minor) — noted for a future
  task, not this one.
- T3 docs.

If you believe the approach is wrong — the window-scoping, the cache, the budget test —
argue it with evidence in your report rather than implementing it half-heartedly.

## Return format (verbatim, these labels, this order)

TASK:        epoch-hash-fetch-storm — <one line>
LINE OF WORK: fix/epoch-hash-fetch-storm
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
CALL BUDGET: <fetches for the fixture window, asserted in test: n for K origins>
LIVE SHAKEOUT: scan <t1>, post-scan <t2>, seal rate <r> blocks/s, window 1–2200 PASS/FAIL,
               RPS cap used; or why it could not run
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     none (review allocates the next decision id)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; hand-verified vs automated; risk plainly

Disclosure in the last three fields counts as diligence, not failure.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
