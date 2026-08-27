DISPATCH · Model: Sonnet · Order: solo; the only active task (US-P7-005 is parked, D-0102)
Surface: Claude Code on the operator's Mac
Baseline: main @ 9d9073a38958 (git rev-parse origin/main yourself; trust the repo over this brief)
Working directory: /Users/steveforte/ForteL2 · Landing: PR to main; review takes the next free decision id (D-0103)

# fix/balance-gate-staleness — the funding gate tears the stack down on one unpinned balance read

## Branch
Cut `fix/balance-gate-staleness` off current main yourself. If it exists, stop and ask.
First commit: this brief, verbatim, as `tasks/worker-prompts/balance-gate-staleness.md`.

## Read first
`tasks/decisions.md` D-0102 (the incident, including the **corrected** diagnosis - an
earlier, wrong diagnosis is recorded there and superseded; read both so you do not
re-derive the wrong one), D-0049 (never read/print `.env.sepolia` values; no secrets on
argv). `scripts/lib.sh` `require_min_balance_eth` (~line 597).

## Evidence (live incident, 2026-08-27 - reviewer-verified)
At 03:00 the scheduled wake ran the funding preflight and reported:

```
ERROR: BATCHER  0x3D54...a31d has 0.145017850904298120 ETH; need >= 0.15 ETH on Sepolia
ERROR: PROPOSER 0x350A...6803 has 0.008696034557436770 ETH; need >= 0.15 ETH on Sepolia
ERROR: Sepolia start failed after sequencer - stopping partial stack
```

**Both readings were false, and the reads succeeded.** Archive reads at block 11577135 -
the exact block the wake logged - show PROPOSER `4.034788608877127862` and BATCHER
`1.739993085535783340`; a control read at 11570000 returns a different historical value,
so the archive endpoint is answering truthfully rather than echoing latest.

**What this is NOT:** it is not a swallowed error. Callers run `set -euo pipefail` and
`bal_wei="$(cast balance ...)"` is a plain assignment, so a failing `cast` propagates and
aborts the script - verified, the following statement never runs. Because the messages
carry specific numbers, `cast balance` exited 0 with wrong data.

**Most probable cause:** a lagging backend behind the provider's load balancer served
stale state. The proposer held ~0 before its funding and ~4.05 after, so 0.0087 fits a
stale view from that window. Not proven - the public endpoint lacks retention to test it -
and **you are not asked to prove it.** The fix must hold regardless of why a node lies.

The consequence is the part that matters: one bad read from one endpoint fail-closed the
**entire stack** for ~6 hours while the wallets were fully funded.

## Outcome (properties, not implementation)

1. **Pin the block.** Read the balance at an explicit, recent L1 block rather than the
   implicit default. A node that has not caught up to that block must error instead of
   silently answering from an older view - this is the core of the fix, converting silent
   staleness into a loud failure. Source the block from the L1 head the startup path
   already establishes; if that is awkward to thread, fetch it once in the helper.
2. **Corroborate before tearing anything down.** Refusing to start is high-consequence, so
   a below-floor result must be confirmed - a second read (at the pinned block, after a
   short delay) that agrees before the gate refuses. Two agreeing reads refuse; a
   disagreement is a read problem, not a funding problem, and must be reported as such.
3. **Three outcomes, not two.** (a) confirmed >= floor -> proceed; (b) confirmed < floor ->
   refuse with today's underfunded message and funding guidance, unchanged; (c) **balance
   could not be established** (node behind the pinned block, reads disagree, non-numeric,
   retries exhausted) -> refuse with a *clearly different* message that names the read
   problem and the redacted endpoint and **quotes no balance figure**. At 03:00 a human
   must be able to tell (b) from (c) instantly.
4. **Still fail-closed.** (c) refuses. This task changes *diagnosis and confidence*, never
   permissiveness: do not proceed on an unknown balance and do not weaken the floors.
5. **Bounded retries** with short backoff before declaring (c), so a transient throttle
   does not take the stack down. Bash 3.2 safe, no new dependencies.
6. **All five call sites benefit** with no changes of their own: batcher, proposer, admin,
   challenger, `start-all-sepolia.sh`.
7. **Tests** appended to `scripts/test-helpers.sh`, driven by a stub endpoint - no live
   chain, no `.env.sepolia`, no network dependence in CI: (i) a node that lacks the pinned
   block -> outcome (c), message names the read problem and quotes no figure; (ii) two
   disagreeing reads -> (c), never (b); (iii) a genuinely low balance, agreeing -> today's
   underfunded refusal, unchanged; (iv) a healthy balance -> proceeds.

## Scope
- **Freely changeable:** `scripts/lib.sh` (`require_min_balance_eth` and any small helper).
- **Additive only:** `scripts/test-helpers.sh` (append; do not reorder or edit existing
  cases), `tasks/worker-prompts/balance-gate-staleness.md` (this brief, first commit).
- **Do not touch:** the five call sites (they should need no edits - if one does, stop and
  report), `derivation/**` (parked, D-0102), `.github/workflows/**`, `tasks/decisions.md`
  (planner-owned), and **never** `.env.sepolia`.
- Stop and report rather than widening scope.

## The trap
`scripts/lib.sh` is sourced by **every** script in the repo, including the hourly
`resolve-games` agent and the alert watcher. A subtle break here takes the whole fleet
down at once, unattended, at 03:00. Specifics: macOS ships **bash 3.2** (no `${var,,}`, no
associative arrays, empty `"${arr[@]}"` under `set -u` crashes); and under `set -e` a
plain `x="$(cmd)"` assignment **aborts on failure** - that is exactly the behavior the
first diagnosis of this incident got wrong, so if you want a failure to be handled rather
than fatal you must capture status explicitly (`if ! out="$(cmd 2>/dev/null)"; then ...`).
Second trap: pinning too *recent* a block makes every honest node fail (it may not have
the head yet). Pin to something recent-but-settled and say what you chose and why.

## What must survive
- The floors and their env overrides (`SEPOLIA_BATCHER_MIN_ETH` etc.), the funding-guidance
  line, and the exit codes callers depend on.
- Every existing check passes unweakened; nothing deleted, skipped, or loosened. Counts on
  main at `9d9073a`: `./scripts/test-helpers.sh` **318 PASS 0 FAIL**;
  `./scripts/phase7-gate-parity.sh` **60 PASS exit 0**. Unexplained movement is a finding.
- D-0090's duplicate-env-assignment loader guard and the rest of `lib.sh` untouched.
- D-0049: endpoints appear only via `redact_rpc_url`; never print env values.

## Live shakeout (small, and it is the point)
After merging current main into the branch, with the stack running normally:
`FORTEL2_ENV=.env.sepolia ./scripts/status.sh` - proves `lib.sh` still loads and the real
env still passes the gate (the D-0090 shakeout pattern). You do **not** need to reproduce
the outage. Report exactly what you ran.

## Out of scope, with reasons
- Anything in `derivation/` - US-P7-005 is parked (D-0102).
- Proving why the endpoint returned stale data - unprovable from here, and the fix must
  hold regardless.
- Auto-restart after a failed wake, and alerting on "stack down but nothing fired" - real
  gaps from this incident, separate operator-facing tasks.

If you believe the approach is wrong - block pinning, corroboration, the three outcomes -
argue it with evidence in your report rather than implementing it half-heartedly. The
first diagnosis of this incident was wrong and a bot caught it; that is the standard here.

## Return format (verbatim, these labels, this order)

TASK:        balance-gate-staleness - <one line>
LINE OF WORK: fix/balance-gate-staleness
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> - pass/fail, with counts
              (run against main merged in as of hand-back)
PINNED BLOCK: <what you pin to and why that lag is safe>
LIVE SHAKEOUT: <what you ran, result>
MIGRATION:   none

SHARED FILES TOUCHED: <path> - what changed, why it is additive   (or: none)
IDENTIFIERS USED:     none (review allocates the next decision id)
EXISTING CHECKS MODIFIED: <path> - <before> -> <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; hand-verified vs automated; risk plainly

Disclosure in the last three fields counts as diligence, not failure.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
