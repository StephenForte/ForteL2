# T1 — spike/genesis-replay-measure: self-anchor mode + genesis-replay measurement (US-P7-005)

DISPATCH · Model: Sonnet · Order: wave 1, alone (T2 dispatches after this is in review)
Surface: Claude Code on the operator's Mac
Baseline: main @ 8faa389d8fb4078c89a1f632bae99a19997c3b0f
Host: the operator's Mac only — this task measures the live Sepolia stack; nothing else has it
Working directory: /Users/steveforte/ForteL2 · Landing: PR to main; review takes the next free decision id

## Read first (repo over brief — verify every claim here against the checkout)

- `tasks/frd-us-p7-005-independent-derivation.md` — the governing spec; you are T1.
- `tasks/decisions.md` D-0094 (path choice), D-0049 (env-file rules), D-R1-1 / D-R2-2 (separate sealing EL, anchor flow).
- `derivation/README.md` — current runbook and Limitations.
- `scripts/derivation-check.sh` — the file you own.

Everything below was true at `8faa389` on 2026-08-25. Trust the repository over this brief.

## Branch

Cut `spike/genesis-replay-measure` off main at `8faa389` yourself. If a branch with that
name already exists, stop and ask — do not reuse or rename. First commit on the branch:
this brief, verbatim, as `tasks/worker-prompts/genesis-replay-measure.md`.

## Why this task exists

`cmd/verify` today anchors mid-chain windows on a datadir copied from the operator's own
node (`--make-anchor`, stack stopped), and genesis replays rebuild the seal EL from
scratch every run. D-0094 commits to Path A: after one full genesis replay, the
derivation EL's own datadir becomes the anchor for every future audit. T1 builds the
resume mechanism and measures the replay cost. The measurement is a first-class
deliverable: T2/T3 planning and an operator decision on checkpointing hang on it.

## Outcome (properties, not implementation)

1. **Self-anchor mode** in `scripts/derivation-check.sh` (flag name yours; FRD suggests
   `--self-anchor`): the seal-EL datadir survives the run and a subsequent invocation
   resumes derivation from the last self-sealed block instead of re-initializing genesis
   or copying anything.
   - Must refuse to combine with `--anchor-datadir` / `--make-anchor` (mutually
     exclusive by meaning; name the conflict in the error).
   - Must never read, copy, or require stopping the reference stack's datadir. The
     reference node stays a read-only RPC oracle exactly as today.
   - A resumed window must be provably contiguous with the prior one: the first resumed
     block's parent is the last self-sealed block (derive 1..N, exit, derive N+1..M —
     hashes chain, PASS).
2. **Measurement on the live Sepolia chain** (`FORTEL2_ENV=.env.sepolia`), reported as
   numbers in your return block:
   - Seal/derivation rate (blocks/s) over a window of ≥1000 real chain-852 blocks.
   - Projected genesis→head wall-clock at that rate, with the head height and timestamp
     you measured against.
   - The stop/resume proof from (1), run on Sepolia, with the block numbers used.
3. **Tests** appended to `scripts/test-helpers.sh`: flag mutual-exclusion refusal, and
   whatever of the resume logic is testable without a live chain. Live behavior is
   proven by the measurement runs, not by CI.

## Scope

- **Freely changeable:** `scripts/derivation-check.sh`.
- **Additive only:** `scripts/test-helpers.sh` (append; do not reorder or edit existing
  cases — every task appends here), `tasks/worker-prompts/genesis-replay-measure.md`
  (this brief, first commit), `derivation/README.md` runbook section (you may add the
  self-anchor invocation to the runbook block only; the Limitations rewrite is T3's).
- **Do not touch:** `derivation/*.go` and `derivation/cmd/**` (T2 owns them and may run
  in parallel), `batcher/**` (import-only rule, module wiring note in derivation
  README), `scripts/lib.sh` (just consolidated, #151/#152), `.github/workflows/**`,
  `tasks/decisions.md` (planner-owned; the review allocates the next free id).
- If the task appears to require changing anything outside this surface, stop and
  report. Do not widen scope.

## The trap

The existing anchor flow (`--make-anchor`) copies the *reference* datadir and therefore
requires the stack stopped, with `refuse_live_anchor_copy` guarding a live copy. The
easy wrong implementation of self-anchor reuses that copy path — which silently
reintroduces the operator-datadir dependency this whole story exists to remove, and a
copy of a live LevelDB is corrupt in a way that surfaces as spurious hash mismatches
much later, not as an error now. Self-anchor must be a *keep-and-reuse* of the
derivation EL's own datadir, never a copy of anything. If you find yourself calling the
copy helper, you are on the wrong path.

Second, smaller: measure on Sepolia chain 852, not local 901 — local blocks are
synthetic and the rate does not transfer.

## What must survive

- Legacy modes unchanged: genesis replay without the new flag, `--anchor-datadir`,
  `--make-anchor`, `--channel-tx`, local and `--sepolia` invocations all behave exactly
  as documented in `derivation/README.md`.
- The kill switch stays true: not running `derivation-check.sh` leaves stock derivation
  untouched; the reference stack is never written to.
- All existing checks pass unweakened: no test deleted, skipped, or loosened. Expected
  on main at `8faa389`: `./scripts/test-helpers.sh` 299 PASS 0 FAIL;
  `./scripts/phase7-gate-parity.sh` 60 PASS exit 0. Unexplained movement in either
  count is a finding — report it, don't absorb it.
- macOS bash 3.2 + zsh operator environment: no bash-4-isms in scripts; empty
  `"${arr[@]}"` under `set -u` crashes; quote `?` in URLs.
- D-0049: never read or print `.env.sepolia` values; scripts load it via `FORTEL2_ENV`;
  no secrets on argv.

## Operator decision — do not resolve it yourself

If the projected genesis→head wall-clock exceeds ~12 hours, that triggers a decision on
checkpoint cadence (or acceptance) that belongs to the operator. Report the number under
DECISIONS NEEDED and build nothing for it — no checkpointing, no compression, no
parallelism. The spike measures; it does not optimize.

## Verification (run at hand-back, after merging current main into your branch)

```
bash -n scripts/derivation-check.sh scripts/test-helpers.sh
./scripts/test-helpers.sh                      # 299 + your additions PASS, 0 FAIL
./scripts/phase7-gate-parity.sh                # 60 PASS, exit 0
FORTEL2_ENV=.env.sepolia ./scripts/derivation-check.sh --sepolia <your flag> ...   # the measurement runs themselves
```

The live runs are the proof for outcome (2); paste rates, heights, and block ranges into
the return block. State plainly which properties were verified by hand vs by test.

## Out of scope, with reasons

- Proposal/output-root comparison — T2 (`feat/proposal-compare`), different files.
- README Limitations rewrite and counterparty runbook — T3, after T1+T2 merge.
- Checkpointing or replay optimization — operator decision pending your measurement.
- Replica pack — separately blocked on T3 (PRD § 3).

If you believe this approach is wrong — the flag design, the resume semantics, the
measurement method — argue it with evidence in your report rather than implementing it
half-heartedly. The brief's author has been wrong before and the repo is the authority.

## Return format (verbatim, these labels, this order)

TASK:        T1 genesis-replay-measure — <one line>
LINE OF WORK: spike/genesis-replay-measure
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
MEASUREMENT: seal rate <n> blocks/s over blocks <a>–<b>; head <h> at <timestamp>;
             projected genesis→head <duration>; stop/resume proven at <N>/<N+1>
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     none (review allocates the next decision id)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; hand-verified vs automated; risk plainly

Disclosure in the last three fields counts as diligence, not failure.
