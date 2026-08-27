DISPATCH · Model: Sonnet · Order: solo; the only active task (US-P7-005 is parked, D-0102)
Surface: Claude Code on the operator's Mac
Baseline: main @ 9d9073a38958 (git rev-parse origin/main yourself; trust the repo over this brief)
Working directory: /Users/steveforte/ForteL2 · Landing: PR to main; review takes the next free decision id (D-0103)

# fix/balance-read-fail-loud — a funding gate must never confuse "I cannot read the balance" with "there is no money"

## Branch
Cut `fix/balance-read-fail-loud` off current main yourself. If it exists, stop and ask.
First commit: this brief, verbatim, as `tasks/worker-prompts/balance-read-fail-loud.md`.

## Read first
`tasks/decisions.md` D-0102 (the incident this fixes), D-0049 (never read/print
`.env.sepolia` values; no secrets on argv). `scripts/lib.sh` `require_min_balance_eth`
(~line 597).

## Evidence (live incident, 2026-08-27 — reviewer-verified)
At 03:00 the scheduled wake ran the funding preflight. It reported:

```
ERROR: BATCHER  0x3D54…a31d has 0.145017850904298120 ETH; need >= 0.15 ETH on Sepolia
ERROR: PROPOSER 0x350A…6803 has 0.008696034557436770 ETH; need >= 0.15 ETH on Sepolia
ERROR: op-proposer exited immediately
ERROR: Sepolia start failed after sequencer — stopping partial stack
```

**Both readings were false.** Archive reads at block 11577135 — the exact block the wake
logged — show PROPOSER `4.034788608877127862` ETH and BATCHER `1.739993085535783340` ETH,
identical to their values hours later (control test confirmed the endpoint serves true
recent history and errors rather than echoing latest). The wallets were fully funded. The
gate's bad *reading* took the chain down for ~6 hours.

The defect, `scripts/lib.sh` in `require_min_balance_eth`:

```bash
bal_wei="$(cast balance "$addr" --rpc-url "$L1_RPC_URL")"
min_wei="$(cast to-wei "$min_eth" ether)"
if ! python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$bal_wei" "$min_wei"; then
```

`cast balance`'s exit status is discarded. On any RPC failure (429, timeout, transport
error) `bal_wei` is empty or non-numeric; `int('')` raises; python exits nonzero; the gate
concludes **underfunded** and `start-all-sepolia.sh` fail-closes the whole stack.
Demonstrated by reviewer against a dead endpoint: empty `bal_wei`, gate reports low.

The exact provenance of the two non-empty wrong numbers was not established (the endpoint
lacks retention to test the stale-state theory). **Do not chase it** — the fix is the same
either way: a reading that is not a verified integer must never be treated as a balance.

## Outcome (properties, not implementation)

1. **Three outcomes, not two.** The gate must distinguish: (a) balance read successfully
   and >= floor → proceed; (b) read successfully and < floor → refuse with today's
   "underfunded" message and funding guidance, unchanged; (c) **balance could not be
   determined** → refuse with a *clearly different* message naming the read failure and
   the redacted endpoint, never a number. A caller (and a human at 03:00 reading a log)
   must be able to tell (b) from (c) instantly.
2. **Validated, not assumed.** Treat the read as failed unless `cast balance` exited 0
   **and** its output is a non-empty decimal integer. Never pass an unvalidated value into
   the comparison.
3. **Retried before it fails.** A transient throttle must not take the stack down: retry
   a small bounded number of times with a short backoff before declaring (c). Keep it
   simple and bash-3.2-safe; no new dependencies.
4. **Refusal semantics preserved.** (c) still refuses — this is a money path and
   fail-closed is correct. This task changes *diagnosis*, not permissiveness: never
   proceed on an unknown balance, and never weaken the floors.
5. **All five call sites benefit** without their own changes: batcher, proposer, admin,
   challenger, and `start-all-sepolia.sh`.
6. **Tests** appended to `scripts/test-helpers.sh`: (i) unreadable/failed balance ⇒ exit
   nonzero AND the message names the read failure and does **not** claim a balance figure;
   (ii) a genuinely-low balance still produces today's underfunded message and refusal;
   (iii) a healthy balance passes. Drive these with a stub/unreachable endpoint — no live
   chain, no `.env.sepolia`, no secrets, no network dependence in CI.

## Scope
- **Freely changeable:** `scripts/lib.sh` (`require_min_balance_eth` and any small helper
  it needs).
- **Additive only:** `scripts/test-helpers.sh` (append; do not reorder or edit existing
  cases), `tasks/worker-prompts/balance-read-fail-loud.md` (this brief, first commit).
- **Do not touch:** the five call sites (they should need no edits — if one does, stop and
  report), `derivation/**` (parked, D-0102), `.github/workflows/**`, `tasks/decisions.md`
  (planner-owned), and **never** `.env.sepolia`.
- Stop and report rather than widening scope.

## The trap
`scripts/lib.sh` is sourced by **every** script in the repo, including the hourly
`resolve-games` agent and the alert watcher. A change here that is subtly wrong under
`set -euo pipefail` — an unset variable, an empty array expansion, a command substitution
whose failure now propagates where it previously didn't — breaks the whole fleet at once,
at 03:00, unattended. Two specifics: macOS ships **bash 3.2** (no `${var,,}`, no
associative arrays, empty `"${arr[@]}"` under `set -u` crashes), and adding `set -e`
sensitivity around the new retry loop can abort a caller that previously survived. Prefer
explicit status capture (`if ! out="$(cmd 2>/dev/null)"; then ...`) over anything clever.

## What must survive
- The existing floors and their env overrides (`SEPOLIA_BATCHER_MIN_ETH` etc.), the
  funding-guidance line, and the exit codes callers depend on.
- Every existing check passes unweakened, no test deleted, skipped, or loosened. Counts on
  main at `9d9073a`: `./scripts/test-helpers.sh` **318 PASS 0 FAIL**;
  `./scripts/phase7-gate-parity.sh` **60 PASS exit 0**. Unexplained movement is a finding —
  report it, don't absorb it.
- D-0090's duplicate-env-assignment loader guard and everything else in `lib.sh` untouched.
- D-0049: never read or print `.env.sepolia` values; endpoints appear only via
  `redact_rpc_url`.

## Live shakeout (small, and it is the point)
After merging current main into the branch, with the stack running normally:
`FORTEL2_ENV=.env.sepolia ./scripts/status.sh` — proves `lib.sh` still loads and the real
env still passes the gate (the D-0090 shakeout pattern). You do **not** need to reproduce
the outage. Report exactly what you ran.

## Out of scope, with reasons
- Anything in `derivation/` — US-P7-005 is parked (D-0102).
- The eip1559Params/extraData defect — recorded in D-0102, deliberately unfixed.
- Auto-restart after a failed wake, and alerting on "stack down but no alert fired" —
  real gaps from this incident, but separate operator-facing tasks.

If you believe the approach is wrong — the three-outcome split, the retry, the refusal
semantics — argue it with evidence in your report rather than implementing it
half-heartedly.

## Return format (verbatim, these labels, this order)

TASK:        balance-read-fail-loud — <one line>
LINE OF WORK: fix/balance-read-fail-loud
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
LIVE SHAKEOUT: <what you ran, result>
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     none (review allocates the next decision id)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; hand-verified vs automated; risk plainly

Disclosure in the last three fields counts as diligence, not failure.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
