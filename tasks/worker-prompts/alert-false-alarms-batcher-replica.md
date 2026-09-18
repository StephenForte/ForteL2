DISPATCH · alert false-alarm suppression (batcher window + replica trend)
Model: mid tier · Order: single task, no parallel dependencies
Surface: Cursor or Claude Code
Repository: StephenForte/ForteL2
Baseline: origin/main @ 009c91f (verify yourself: git fetch && git rev-parse origin/main —
          trust the repo over this brief, including over its confident assertions)
Branch: fix/alert-false-alarms-batcher-replica  (cut it yourself, off origin/main)
Host: any — everything here runs offline against fixtures
Runtime: ~1–1.5 h. No metered RPC spend: do not call QuickNode or the live replica.
Working directory: a scratch clone — NOT the operator's ~/ForteL2 checkout
Teardown: delete the clone after the PR is pushed
Landing: PR to main. Closes two nightly false-alarm classes.

Silent-failure class: a change that suppresses the noise by also suppressing a real
outage is worse than the noise. Both fixes narrow when an alert fires; neither may
make a wedged replica or a genuinely dead batcher undetectable.

## 1. Clone first — do not touch ~/ForteL2

This is a numbered step, not a header note. A previous worker ignored a clone named
only in a header and ran `git stash` in the shared checkout over another task's
uncommitted work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-falsealarm.XXXXXX")
    trap 'rm -rf "$SCRATCH"' EXIT
    git clone https://github.com/StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git switch -c fix/alert-false-alarms-batcher-replica origin/main

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and confirm deletion before handing back.

Commit this brief verbatim as
tasks/worker-prompts/alert-false-alarms-batcher-replica.md.

## 2. Read before changing anything

- tasks/decisions.md — D-0135 (the 12.7 h replica stall; nothing alerted), D-0136
  (why the replica predicate is a head-age TREND, not an absolute age: "a
  healthy-but-too-slow node and a wedged node are indistinguishable from the EL"),
  D-0026 (the nightly 23:45–03:00 PT sleep window), D-0139 (most recent entry).
- scripts/alert-watch.sh — the whole file. In particular: the header comment block
  documenting every condition (it is the contract and must be updated with the
  behaviour), `in_dev_sleep_window()` at ~line 521 and how stack-down uses it at
  ~line 690, `replica_ok()` at ~line 1144, the ALERT_WATCH_* test-only override
  naming convention (these names must NEVER appear in env files — lib.sh sources
  with `set -a`), and the `--help` awk that prints header comments to the first
  non-comment line.
- scripts/pipeline-snapshot.py — `L1_SCAN_BLOCKS` (line 32), `snapshot_batcher()`,
  `snapshot_sequencer()`.
- scripts/test-helpers.sh — the `aw_run` fixture (~line 4820) and the existing
  replica cases. This is where alert-watch regressions live.
- scripts/test_pipeline_snapshot.py — where snapshot regressions live.
- .env.sepolia.example lines ~295–301 — the commented replica threshold block and
  the D-0065 rule it states (thresholds stay COMMENTED so an empty `KEY=` cannot
  override the script default).

## 3. Evidence — measured 2026-09-18, reproduce it if you doubt it

### 3a. The batcher is healthy; the snapshot window is too narrow.

Batcher publish timestamps from the live log
(/Users/steveforte/src/fortel2/data-sepolia/logs/op-batcher.log, operator's machine —
you do not need it, this is the evidence):

    t=2026-09-18T07:28:15-0700
    t=2026-09-18T07:33:15-0700
    t=2026-09-18T07:38:15-0700
    t=2026-09-18T07:43:15-0700
    t=2026-09-18T07:49:15-0700

Over 278 publishes in the current log: gaps min 59 s, MEDIAN 360 s, max 12112 s
(the max is the nightly sleep window, not a fault).

pipeline-snapshot.py sets `L1_SCAN_BLOCKS = 8`. Eight Sepolia L1 blocks is ~96 s.
96 / 360 = 0.27, so the window straddles a batch post only about 27% of the time.
Roughly three snapshots in four report `post_count: 0` on a perfectly healthy
batcher. Today's 05:00 PT snapshot did exactly that:

    "batcher": { "scan_from": 11730538, "scan_to": 11730545, "post_count": 0,
                 "last_hash": null, "last_age_sec": null, "cadence_sec": null }

and the previous day's 05:00 snapshot missed a post that landed at 05:00:23 PT.
The snapshot runs ONCE PER DAY (launchd/com.steve.fortel2-health.plist, 05:00 PT),
so widening the window costs ~52 extra `eth_getBlockByNumber` calls per day —
negligible against the QuickNode budget.

`lag_unsafe_safe: 54` in that same file is the same artifact: safe advances one
batch at a time, so the lag sawtooths from 0 to ~180 blocks (360 s ÷ 2 s block
time). 54 is mid-cycle normal, not degradation.

### 3b. The replica trend predicate fires on two things that are not outages.

Two alerts reached the operator, both false:

  2026-09-17T08:30:02Z (01:30 PT) — "head age grew by 3599 s on 2 consecutive
  successful probes (noise floor 120 s). current age 6407 s (head 1097053);
  previous age 2808 s."

  2026-09-17T14:30:04Z (07:30 PT) — "head age grew by 121 s on 2 consecutive
  successful probes (noise floor 120 s). current age 340 s (head 1110887);
  previous age 219 s."

**Class 1 — the nightly sleep-window freeze.** 01:30 PT is inside the 23:45–03:00 PT
window. The Mac stack is down, no batches are produced, so the Render replica has
nothing to follow and its head age grows 1 s/s by arithmetic. The delta is 3599 s:
exactly one probe hour of zero progress. alert-watch runs hourly at :30
(launchd/com.steve.fortel2-alerts.plist), so the 00:30 and 01:30 probes both grow
and the streak reaches 2 every single night. The header comment at line ~105 says
the replica conditions take no sleep grace because "Render does not sleep." That is
true of the replica and false of its SOURCE, which is the whole defect.

**Class 2 — batch-cadence sawtooth jitter.** The replica tracks the derived chain,
so its head age sawtooths with the batcher cadence. Measured live, one sample every
40 s:

    07:49:49 head 1154653 age 395
    07:50:29 head 1154833 age  75
    07:51:09 head 1154833 age 115
    07:51:50 head 1154833 age 156
    07:52:30 head 1154833 age 196
    07:53:10 head 1154833 age 236
    07:53:50 head 1154833 age 276
    07:54:30 head 1154833 age 316
    07:55:11 head 1154833 age 357
    07:55:51 head 1155013 age  37
    07:56:31 head 1155013 age  77
    07:57:11 head 1155013 age 117

Head advances in exact 180-block steps 360 s apart — the batcher cadence. A 320 s
drop in 40 s when a batch landed, then a linear climb. Steady-state head-age swing
is ~360 s peak-to-trough, measured over two full cycles (not "~0–400 s"). Hourly
probes land at uniformly random phase, so deltas above 120 s are ordinary. A 120 s
floor is under a third of the natural swing. The 121 s alert above is literally 1 s
over the floor.

Current replica state is healthy: ~360 s behind, self-recovered from the 09-17 freeze
with no intervention.

## 4. What must hold when you are done

State these as properties; the implementation is yours.

**P1.** A batcher posting at the measured ~360 s median cadence must not produce a
`post_count: 0` snapshot. Set `L1_SCAN_BLOCKS = 60` (~12 min of Sepolia, ≥2 batch
cycles). This value is assigned, not derived — do not pick a different one without
arguing it back (see §9).

**P2.** `snapshot_batcher()` emits a new `verdict` field so downstream consumers stop
inventing thresholds from raw numbers. It must be a small closed set of strings, must
be documented in the README section that describes pipeline-health.json, and must be
derivable from what the scan already collects. A healthy batcher at 360 s cadence over
a 60-block window yields the healthy value; zero posts over that window yields a
non-healthy value. `post_count`, `last_hash`, `last_age_sec` and `cadence_sec` all keep
their current names, types and null semantics — this is ADDITIVE ONLY. An external
agent reads this file byte-for-byte; a renamed or retyped existing field breaks it
silently.

**P3.** `replica-losing-ground` does not fire on the nightly sleep window. A probe
whose growth interval lies wholly or partly inside 23:45–03:00 PT must not advance
`replica_losing_streak`. `in_dev_sleep_window()` already exists — reuse it rather than
writing a second window definition. Add one cycle of recovery grace after 03:00 so the
first post-wake probe, which sees a large but legitimate catch-up delta, also does not
advance the streak.

**P4.** `REPLICA_TREND_NOISE_SECS` default moves 120 → 900, above the measured ~400 s
sawtooth with slack. Update the commented line in .env.sepolia.example and every
header comment that quotes 120. Keep it COMMENTED per D-0065.

**P5.** A genuinely wedged replica is still caught. After P3 and P4, a replica frozen
outside the sleep window still reaches streak 2 and alerts, and `replica-head-stale`
(10800 s) still fires as the backstop. Add a regression that proves a wedged replica
outside the window still alerts — this is the property that stops the fix becoming a
blindfold.

**P6.** The alert body text stays self-explanatory. Wherever the new floor or the sleep
suppression changes what a reader should conclude, the emitted body says so. The
`--help` output and the header condition list are part of the contract; update both.

## 5. Pre-assigned identifier

The decision record for this work is **D-0140**. This OVERRIDES any "find the highest
and add one" convention — D-0139 is the current last entry and its Consequence line
already says the next free id is D-0140. Do not allocate a different one. If D-0140 is
already taken when you open the file, STOP and report rather than picking D-0141.

Write the D-0140 entry yourself in tasks/decisions.md, in the existing format, and
append the "Next free decision id is **D-0141**" line the file's convention requires.
It must record: both false-alarm classes with the measured numbers above, that the
batcher and replica were both healthy throughout, the new values and why each was
chosen, and that the Morning Briefing's DEGRADED verdict logic lives OUTSIDE this repo
and is not fixed by this change.

Per the operator's standing rule on verdict entries: grep the repo for the OLD claims
and for obligation language before you finish. Search for "120" near the replica
thresholds, for `L1_SCAN_BLOCKS`, for "Render does not sleep", and for any README,
AGENTS.md, launchd/README.md or decisions.md text asserting the old behaviour or
saying this "must" still be done. Read whole sections, not matched lines. Fix every
cross-reference in the same PR and list them in your report.

## 6. Scope

Freely changeable:
  scripts/pipeline-snapshot.py
  scripts/alert-watch.sh
  scripts/test_pipeline_snapshot.py
  scripts/test-helpers.sh          (append cases; do not restructure existing ones)
  .env.sepolia.example             (the commented threshold block only)
  tasks/worker-prompts/alert-false-alarms-batcher-replica.md   (new — this brief)

Additive only (other work appends here; never rewrite or reorder):
  tasks/decisions.md               (one new D-0140 section at the end + the next-free line)
  README.md, launchd/README.md     (only the sentences that state the changed behaviour)

Do not touch:
  launchd/*.plist — the schedules are correct and both plists are on the operator's
    fdautil allowlist; an edit means a supervised re-install, which is out of scope here.
  .env.sepolia — untracked, holds live secrets, operator-owned.
  refresh_health.sh — its swallow-and-continue structure is load-bearing (D-0138/D-0139).
  Anything under batcher/, derivation/, contracts/, viewer/, dapp/, replica/ — no
    part of this change reaches them.

If the task appears to require changing something outside this surface, STOP and report
rather than widening scope.

## 7. The trap

The obvious implementation of P3 is "if we are in the sleep window right now, skip the
replica trend check." That is wrong, and wrong in a way that still passes a naive test.

The delta is computed between the PREVIOUS successful probe and the current one, so
what matters is the INTERVAL, not the instant. The 03:30 PT probe is outside the
window, but its previous sample is the 02:30 probe, which is inside it — the interval
spans the freeze, the delta is ~3600 s, and a now-only check lets it alert anyway. The
consequence: the noise moves from 01:30 to 03:30 and looks fixed in testing while the
operator's inbox is unchanged.

Judge the interval `[prev_obs, now]` against the window, and give the first post-wake
probe grace on top of that for the catch-up. The related failure — writing a second,
subtly different copy of the window boundaries instead of calling
`in_dev_sleep_window()` — produces two definitions that drift the next time the sleep
schedule moves.

## 8. What must survive

- pipeline-health.json is consumed byte-for-byte by an external agent. Existing keys,
  types and null semantics are frozen; only additions are permitted.
- alert-watch's channel independence: the macOS banner and the Resend email each fire
  even when the other is broken, and any channel failure still exits nonzero.
- Per-condition cooldown and ALERT_REALERT_HOURS behaviour is unchanged.
- The other replica conditions (`replica-head-stale`, `replica-unreachable`) and their
  streak-reset semantics are unchanged by this task.
- ALERT_WATCH_* names must not leak into any env file.
- Existing checks may not be weakened, skipped or deleted to make this pass. If a test
  legitimately changes because it encoded the very behaviour being corrected, declare it
  in the return block with before, after, and why it is a strengthening.

## 9. Coverage, as properties

Add regressions asserting the PROPERTY, not the line:

  - A 60-block window containing one post at the measured cadence yields the healthy
    verdict and a non-null `last_hash`.
  - A 60-block window containing zero posts yields the non-healthy verdict.
  - Existing pipeline-health.json keys are present with unchanged types after the
    change (guard against an accidental rename).
  - A probe interval spanning the sleep window does NOT advance
    `replica_losing_streak`, INCLUDING the case where the current probe is outside the
    window and the previous one is inside it (the trap in §7 — assert this case
    explicitly and by itself).
  - The first probe after 03:00 does not advance the streak.
  - A delta of 400 s outside the window does NOT alert at the new floor.
  - A delta of 1200 s outside the window on two consecutive probes DOES alert.
  - A replica wedged outside the window still reaches streak 2 and alerts (P5).

## 10. Verification

Everything runs offline. Do not call QuickNode or the live replica gateway.

    bash -n scripts/alert-watch.sh
    bash -n scripts/pipeline-snapshot.py 2>/dev/null || true
    python3 -m py_compile scripts/pipeline-snapshot.py
    python3 -m unittest scripts/test_pipeline_snapshot.py
    ./scripts/test-helpers.sh
    ./scripts/alert-watch.sh --help

`./scripts/test-helpers.sh` is the big one — report its pass count before and after
your change. Unexplained movement in that count is itself a finding, not a rounding
error.

Then, at the MOMENT of hand-back, rebase onto current origin/main and re-run all of
the above. Green against a stale base says nothing about what it is merging into.

    git fetch origin && git rebase origin/main
    ./scripts/test-helpers.sh && python3 -m unittest scripts/test_pipeline_snapshot.py

There is no harness that exercises alert-watch against a live replica and you must not
build one. State in your report exactly what you exercised by hand, if anything.

Migration: none.

Temp files: everything outside the repo goes under the $SCRATCH directory from step 1.
Delete it before hand-back and report the path on the TEMP: line. A temp folder is fine;
leaving it behind is not.

## 11. Out of scope, with reasons

- The Morning Briefing agent's DEGRADED verdict logic. It lives outside this repo —
  `lag_unsafe_safe` appears exactly once in the whole tree, as a raw field in
  pipeline-snapshot.py, and the "healthy threshold" the briefing cites exists nowhere
  here. P2 gives that agent something authoritative to read; making it read it is the
  operator's change, not yours. Do not go looking for it.
- `REPLICA_HEAD_STALE_SECS` (10800). Left alone deliberately: it is the backstop that
  makes P5 safe. Note, do not fix: at the 02:30 PT probe the head age during a normal
  sleep window is ~9900 s, within 900 s of that threshold, so a late wake could trip it.
  Report it as an observation; a change needs its own decision.
- launchd schedules and any plist edit — see §6.
- Log-volume or rotation work (D-0139 territory).

## 12. Operator decision to return, not to resolve

The briefing prompt change in §11 is the operator's. Do not decide it, do not work
around it, and do not add a compatibility shim that guesses what the briefing wants.
Emit the verdict field per P2, document its values in the README, and put the question
on the DECISIONS NEEDED: line of your report so it reaches the operator.

## 13. Argue if this is wrong

If you think the approach is wrong — the 60-block window, the 900 s floor, the
interval-based sleep suppression, the shape of the verdict field — argue it with
evidence rather than implementing it half-heartedly. The measurements in §3 are real
and reproducible; the values chosen from them are judgement and you may have a better
one. Bring the counter-measurement.

## 14. Return format

Emit this whole block inside ONE fenced code block so the operator can copy it in a
single click. Disclosure in the last three fields counts as diligence, not failure: a
declared assertion change is reviewable and a silent one is how a guarantee dies.

TASK:        D-0140 — suppress batcher-window and replica-trend false alarms
LINE OF WORK: fix/alert-false-alarms-batcher-replica
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: bash -n — pass/fail
              py_compile — pass/fail
              test_pipeline_snapshot.py — pass/fail, N tests
              test-helpers.sh — pass/fail, N assertions (was N before)
              alert-watch.sh --help — pass/fail
              (all re-run against origin/main as of hand-back, sha <sha>)
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
CROSS-REFERENCES SWEPT: <every file/section grepped for the old 120 s / 8-block /
                        "Render does not sleep" claims, and what you fixed>
IDENTIFIERS USED:     D-0140; next free id line set to D-0141
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this is a strengthening
                          rather than weakens                      (or: none)
CLONE:               deleted <path>
TEMP:                <every temp path created outside the repo> — deleted: yes/no
DECISIONS NEEDED:    the Morning Briefing prompt (§12), plus anything else you hit
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly

The standing goal below authorises fixing CI failures and review-bot findings on this
change set. It does NOT authorise widening the §6 file scope, weakening or skipping
checks to get green, or resolving the §12 operator decision. Blocked by any of those:
stop and report.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
