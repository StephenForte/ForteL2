# feat/l1-scan-checkpoint — resumed self-anchor windows must scan only the L1 delta

DISPATCH · Model: Sonnet · Order: solo; last plumbing before the US-P7-005 measurement rerun
Surface: Claude Code on the operator's Mac
Baseline: main @ 95ca07dd213c (git rev-parse origin/main yourself; trust the repo over this brief)
Working directory: /Users/steveforte/ForteL2 · Landing: PR to main; review takes the next free decision id (D-0100 as of writing)

## Branch
Cut `feat/l1-scan-checkpoint` off current main yourself. If it exists, stop and ask.
First commit: this brief, verbatim, as `tasks/worker-prompts/l1-scan-checkpoint.md`.

## Read first
- `tasks/decisions.md` D-0097 (scan-cost note), D-0099 (why this exists: the genesis→tip
  scan per window drove a hosted L1 endpoint to its monthly cap; scans now run on a free
  Alchemy key with `DERIVATION_RPC_MAX_RPS` pacing), D-0094 (Path A).
- `scripts/derivation-check.sh` — self-anchor flow; `FROM_L1` plumbing at lines ~118–140
  (legacy lookback) and ~305 (self-anchor genesis sets `FROM_L1` from rollup genesis.l1).
- `derivation/l1.go`, `derivation/verify.go` — the inbox scan and how `-from-l1` is used.
- OP Stack derivation spec (channel timeout): https://specs.optimism.io/protocol/derivation.html

## Evidence
Measured live (D-0097/D-0099): every window — including a resumed self-anchor window —
scans L1 from genesis (or a wide lookback) to tip: ~21k+ full blocks + receipts, ~50–58
min, per run. The self-anchor already made the L2 side incremental (resume from own
datadir); the L1 scan is the remaining per-run cost, and it is what blew the endpoint
budget. `channel_timeout` in `deployments/sepolia/.deployer/rollup.json` is **300** L1
blocks — read it from the rollup config at runtime, do not hard-code it.

## Outcome (properties, not implementation)

1. **A resumed self-anchor window scans only the L1 delta.** When the seal EL resumes
   from its own head at L2 block M, the L1 inbox scan starts near M's L1 origin rather
   than genesis — bounded below by the safety invariant in (2). Expected effect on this
   chain: a daily audit scans hours of L1, not weeks; state the before/after scan range
   in your report.
2. **The safety invariant (this is the whole task):** no batch that contributes to any
   L2 block > M may be missed. Frames of a channel still open at M's L1 origin can sit
   earlier on L1, but no earlier than `channel_timeout` L1 blocks before it (spec:
   expired channels are dropped). So the resumed scan start must be at or below
   **origin(M) − channel_timeout − margin** (margin yours to choose and justify; read
   `channel_timeout` from the rollup config). Over-scanning is only cost; under-scanning
   is a missed batch. Note the failure direction: a missed batch surfaces as the existing
   "missing derived block N in window" hard error — loud, not silent — but a run that
   dies an hour in is exactly the cost this task removes, so get the bound right.
3. **Where the resume point comes from is derived, not stored, unless you argue
   otherwise.** origin(M) is recoverable from the kept datadir plus the rollup config /
   L1 (the sealed head's L1-info). Prefer deriving it over a checkpoint file (nothing to
   corrupt, nothing to drift); if you conclude a persisted checkpoint is genuinely
   needed, argue it in the report and keep it beside the self-anchor datadir, never in
   the reference stack's paths.
4. **Genesis and legacy behavior unchanged:** a fresh self-anchor run (empty datadir,
   start=1) still scans from rollup genesis.l1; legacy modes (`--anchor-datadir`,
   `--make-anchor`, default windows, `--channel-tx`, `--scan-from-genesis`) byte-identical.
5. **Tests:** the bound computation (given origin(M), channel_timeout, margin → scan
   start; clamped at genesis.l1), the genesis-unchanged case, and whatever of the
   delta-scan plumbing is testable without a live chain — appended to
   `scripts/test-helpers.sh` and/or `go test` fixtures as fits where the logic lands.

## Scope
- **Freely changeable:** `scripts/derivation-check.sh`, `derivation/` Go touching the
  scan-range logic (`l1.go`, `verify.go`, `cmd/verify` flags as needed).
- **Additive only:** `scripts/test-helpers.sh` (append only), `derivation/README.md`
  (runbook/CLI rows only — Limitations stays T3's), `tasks/worker-prompts/l1-scan-checkpoint.md`.
- **Do not touch:** `batcher/**` (import-only), `scripts/lib.sh`, `.github/workflows/**`,
  `tasks/decisions.md` (planner-owned), `derivation/rpc.go` (just landed in #159 — if the
  scan work truly needs a client change, stop and report).
- Stop and report rather than widening scope.

## The trap
The tempting resume point is "the last L1 block the previous scan reached" — a stored
high-water mark. It is wrong twice: it misses frames of channels that were still open at
that point (the channel_timeout invariant above), and a stored mark can survive a wiped
or diverged datadir and silently point past batches the new derivation needs. Derive the
bound from the sealed head every run; the sealed head is the only state that cannot lie
about what has actually been derived.

## What must survive
- Everything in Outcome (4), plus: the kill switch (nothing runs unless invoked; the
  reference stack is never written to), D-0049 (never read/print `.env.sepolia` values;
  no secrets on argv beyond the existing URL-flag pattern), macOS bash 3.2 compatibility.
- Expected on main at `95ca07dd`: `./scripts/test-helpers.sh` 311 PASS 0 FAIL;
  `./scripts/phase7-gate-parity.sh` 60 PASS exit 0; `cd derivation && go test ./...`
  green. Unexplained movement is a finding — report it, don't absorb it.

## Live shakeout (required; the endpoint is a free Alchemy key — set pacing)
With `DERIVATION_RPC_MAX_RPS` set (pick a value under the free-tier rate and say what you
chose): one resumed self-anchor window on Sepolia (`FORTEL2_ENV=.env.sepolia`) proving
(a) the scan started at the derived bound, not genesis — paste the "L1 inbox scan from
block …" line; (b) the window PASSes; (c) wall-clock vs the ~50–58 min genesis scan.
If the seal-EL datadir is at genesis when you start, first run a short window 1 (e.g.
--end-l2 200) to create a resume point, then the resumed window is your proof.

## Out of scope, with reasons
- The full ≥1000-block measurement and the factory audit — operator-run after merge
  (D-0097/D-0098 follow-ups).
- T3 docs.
- Any rpc.go/client change — #159 just landed; keep surfaces separate.

If you believe the approach is wrong — the derived bound, the margin, a checkpoint file
after all — argue it with evidence in your report rather than implementing it
half-heartedly. The repo is the authority.

## Return format (verbatim, these labels, this order)

TASK:        l1-scan-checkpoint — <one line>
LINE OF WORK: feat/l1-scan-checkpoint
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
LIVE SHAKEOUT: scan start <L1 block> (bound: origin(M)=<n> − channel_timeout=<n> − margin=<n>),
               window <a>–<b> PASS, wall-clock <t> vs genesis-scan baseline, RPS cap used
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     none (review allocates the next decision id)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; hand-verified vs automated; risk plainly

Disclosure in the last three fields counts as diligence, not failure.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
