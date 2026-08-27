DISPATCH · Model: Sonnet · Order: solo; after #163 merges (both append to test-helpers.sh)
Surface: Claude Code on the operator's Mac
Baseline: main after #163 merges (git rev-parse origin/main yourself; trust the repo over this brief)
Working directory: /Users/steveforte/ForteL2 · Landing: PR to main; review takes the next free decision id (D-0104)

# fix/stack-start-stop-symmetry — services that stop at dev-sleep must come back, their absence must alert, and CI must cache Go modules

## Branch
Cut `fix/stack-start-stop-symmetry` off current main yourself. If it exists, stop and ask.
First commit: this brief, verbatim, as `tasks/worker-prompts/stack-start-stop-symmetry.md`.

## Read first
`tasks/decisions.md` D-0102 (the 2026-08-27 outage and its endpoint policy), D-0103 (the
funding gate now has a third outcome — relevant to property 3 below), D-0081 (the
l1-batch-proxy and why the challenger dials it), D-0049 (never read/print `.env.sepolia`
values). `README.md` § the challenger/proxy start order. `scripts/start-all-sepolia.sh`,
`scripts/stop-all-sepolia.sh`, `scripts/dev-sleep.sh`, `scripts/alert-watch.sh`.

## Evidence (reviewer-verified, 2026-08-27)
`op-challenger` last logged **2026-08-24 23:45:05**, stopping cleanly at that night's
dev-sleep, and had not run since — **three days with the fault-proof defense off.** The
cause is a plain asymmetry between two scripts:

```
stop-all-sepolia.sh stops : l2-rpc-filter op-challenger l1-batch-proxy op-proposer op-batcher op-node op-geth
start-all-sepolia.sh starts: 04-start-sequencer (op-geth+op-node), 07-start-rpc-filter, 05-start-batcher, 06-start-proposer
                    MISSING: op-challenger, l1-batch-proxy
```

Nothing in the repo invokes `09-start-challenger-sepolia.sh` except itself, and the
dev-sleep **wake** path does not start it either. So every nightly sleep removes the
challenger permanently until a human notices by hand. Nothing alerted in three days.

Severity context, measured: the respected game type is **8**, and `proposer()` reverts on a
live game instance — these are **permissionless** games, so anyone may create one. Games
are actively created (120 at time of writing, the latest that afternoon, IN_PROGRESS).
The reviewer checked all **45 games created in the down window** against the node's output
root at each game's `l2BlockNumber`: **45 match, 0 mismatch** — no false claim was posted,
so no loss occurred. The exposure was real; it simply did not materialise.

**Second defect, folded in (reviewer-verified same day).** PR #163 — a docs-and-shell
change touching no Go code — failed CI twice in a row, both times `[setup failed]` while
downloading a module: first `bits-and-blooms/bitset@v1.20.0`, then
`grafana/pyroscope-go@v1.2.7`, each `stream error: … INTERNAL_ERROR` from
`proxy.golang.org`. Both modules download fine from the operator's machine (HTTP 200 in
under 0.5 s), so the proxy is healthy; the runner's network path is not, and **CI has no
module cache to fall back on**. Every run re-downloads everything, so any transient
network fault fails an unrelated PR. That is why this is folded in rather than queued: it
blocks merging the very work in this queue.

## Outcome (properties, not implementation)

1. **Symmetry, enforced by a test, not by care.** Every service `stop-all-sepolia.sh`
   stops must be started by `start-all-sepolia.sh`. Add a check to
   `scripts/test-helpers.sh` that derives both service lists **from the scripts themselves**
   and fails when they diverge. This regression guard is the most valuable part of the task:
   it is what stops this class of bug returning the next time a service is added.
2. **The challenger comes back on start**, with the proxy ordering honored: when
   `CHALLENGER_L1_RPC_URL` is non-empty, `l1-batch-proxy` starts first (D-0081, README);
   when empty, the challenger dials `L1_RPC_URL` directly and no proxy is needed. Both
   paths must work.
3. **A failing optional service must NOT tear down the stack.** This is the hard
   constraint. The 2026-08-27 outage was a fail-closed teardown; adding services to the
   startup path must not widen that blast radius. If the challenger (or proxy) fails to
   start — including via D-0103's new "balance could not be established" outcome on the
   challenger's funding gate — the sequencer, batcher and proposer must stay up, the
   failure must be loud on stderr, and the run must surface it rather than aborting the
   whole stack. Sequencer-class failures keep today's fail-closed behavior; challenger-class
   failures degrade instead.
4. **Absence alerts.** `alert-watch.sh` (hourly at :30, macOS banner + Resend email) must
   raise when a service that should be running is not — the challenger specifically, and
   the stack generally. Three days of silence is the defect being fixed here, and it is
   also why the 03:00 wake failure went unnoticed for six hours. Reuse the existing
   alerting shape (OK/WARN never alert; FAIL alerts) and its `--test` flag.
5. **The wake path inherits the fix.** `dev-sleep.sh wake` must bring back everything
   `dev-sleep.sh sleep` stopped. If it delegates to `start-all-sepolia.sh`, property 2 is
   enough — confirm that it does rather than assuming.
6. **Tests** appended to `scripts/test-helpers.sh`: the symmetry check from (1); the
   proxy-ordering branch both ways; a challenger-start failure leaving the core stack up
   (drive with a stub/forced failure — no live chain); the new alert condition firing on a
   missing service and staying silent when present.
7. **CI must cache Go modules** (folded in deliberately — see evidence below). Configure
   `actions/setup-go` so the three module checksums are cached across runs. Today the step
   sits at the repo root with only `go-version:`; there is no `go.sum` at the root (they
   live in `batcher/`, `derivation/`, `proposer/`), so the action's default cache lookup
   finds nothing and silently caches nothing. Every run re-downloads every dependency from
   `proxy.golang.org`. Set `cache-dependency-path` to cover all three `go.sum` files. Do
   not change the pinned action SHA or the Go version; do not restructure the workflow.

## Scope
- **Freely changeable:** `scripts/start-all-sepolia.sh`, `scripts/dev-sleep.sh`,
  `scripts/alert-watch.sh`.
- **Additive only:** `scripts/test-helpers.sh` (append; do not reorder existing cases),
  `README.md` (the start-order/ops paragraphs only), `tasks/worker-prompts/stack-start-stop-symmetry.md`.
- **Careful, not free:** `scripts/stop-all-sepolia.sh` — you may read it and may adjust it
  only if symmetry genuinely requires it; say so explicitly in the report.
- **Narrowly changeable:** `.github/workflows/ci.yml` — **only** the `Setup Go` step's
  `with:` block, to add `cache-dependency-path` (property 7). Nothing else in that file:
  not the pinned action SHAs, not the Go version, not job structure, not triggers.
- **Do not touch:** `scripts/lib.sh` (D-0103 just landed there — if symmetry truly needs a
  lib.sh helper, stop and report), `scripts/09-start-challenger-sepolia.sh` and the other
  numbered start scripts (they work; the defect is that nobody calls them),
  `derivation/**` (parked, D-0102), `tasks/decisions.md` (planner-owned).
- Stop and report rather than widening scope.

## The trap
Two ways to make this worse than the bug:

**Widening the fail-closed blast radius.** The challenger has its own funding gate. Since
D-0103, an unreadable balance refuses. If you wire the challenger into the startup path
naively, a challenger funding-read problem now takes down the sequencer too — converting a
one-service outage into a total one. Property 3 exists for this; treat it as the acceptance
criterion, not a nicety.

**Alert storms.** An hourly alert that fires every hour for a known-down service trains the
operator to ignore alerts, which is how three days of silence happened in a different form.
Match the existing OK/WARN/FAIL discipline and avoid re-alerting on an unchanged condition
more often than the existing checks do.

Also: `scripts/lib.sh` is sourced by every script including the hourly agents; macOS ships
**bash 3.2** (no `${var,,}`, no associative arrays, empty `"${arr[@]}"` under `set -u`
crashes); and a plain `x="$(cmd)"` assignment **aborts under `set -e`** — capture status
explicitly when you want to handle failure.

## What must survive
- Existing start/stop behavior for the core services, their ordering, and their exit codes.
- The challenger's own preflight (funding floor, proxy wiring) unchanged in substance.
- Every existing check passes unweakened; nothing deleted, skipped, or loosened. Counts on
  main **after #163 merges**: `./scripts/test-helpers.sh` **323 PASS 0 FAIL**;
  `./scripts/phase7-gate-parity.sh` **60 PASS exit 0**. Unexplained movement is a finding.
- D-0049: never read or print `.env.sepolia` values; endpoints only via `redact_rpc_url`.

## Live shakeout (required)
1. `FORTEL2_ENV=.env.sepolia ./scripts/stop-all-sepolia.sh` then
   `FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh` — **op-challenger and
   l1-batch-proxy must both be running afterwards**, with the challenger logging fresh
   `Game info` lines dated today. Paste the evidence.
2. `FORTEL2_ENV=.env.sepolia ./scripts/status.sh` — clean.
3. `./scripts/alert-watch.sh --test` — delivers, as the existing pattern does.
4. **CI cache proof:** after your PR runs CI twice, the second run's `Setup Go` step must
   report a cache hit (or visibly restore a cache) rather than re-downloading every module.
   Quote the log line. A green run alone does not prove the cache works — a warm cache is
   the claim, so evidence it.
Note: the operator may already have started the challenger by hand before you begin; a
restart via (1) is still the proof.

## Out of scope, with reasons
- Auto-restart / retry after a failed wake — alerting first; an unattended restart loop on
  a genuinely broken stack is its own hazard, and deserves its own task once absence is
  visible.
- `derivation/**` and anything US-P7-005 — parked (D-0102).
- The op-node call-rate levers (`--l1.rpckind`, poll intervals) — separate, queued task.
- Any CI change beyond the `Setup Go` cache path — no new jobs, no retry wrappers, no
  action upgrades. If module downloads still fail with a warm cache, report it; do not
  paper over it with retries.
- Why `resolve-games` skips every game as `not_type_1` while the respected type is 8 —
  noticed during this investigation, genuinely separate, do not chase it here.

If you believe the approach is wrong — the symmetry test, degrade-don't-abort, the alert
shape — argue it with evidence in your report rather than implementing it half-heartedly.

## Return format (verbatim, these labels, this order)

TASK:        stack-start-stop-symmetry — <one line>
LINE OF WORK: fix/stack-start-stop-symmetry
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
SYMMETRY: <the two derived service lists, and how the test derives them>
DEGRADE PROOF: <how you proved a challenger-start failure leaves the core stack up>
CI CACHE:    <the cache-dependency-path you set, and the Setup Go log line proving a hit>
LIVE SHAKEOUT: <stop/start cycle result; challenger + proxy running; alert --test>
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     none (review allocates the next decision id)
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; hand-verified vs automated; risk plainly

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
