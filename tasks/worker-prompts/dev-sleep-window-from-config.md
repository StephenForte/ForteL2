DISPATCH · D-0144 — the dev-sleep window is config, not a constant
Model: mid tier · Order: single task, no dependencies
Surface: Cursor or Claude Code
Repository: StephenForte/ForteL2
Baseline: origin/main @ a93637e (verify: git fetch && git rev-parse origin/main —
          trust the repo over this brief, including over its confident assertions)
Branch: fix/dev-sleep-window-from-config (cut it yourself, off origin/main)
Host: any for development. See §8 — one verification step must run on the Mac.
Runtime: ~1–1.5 h. No metered RPC spend: do not call QuickNode or any live RPC.
Working directory: a scratch clone — NOT the operator's ~/ForteL2 checkout
Teardown: delete the clone after the PR is pushed
Landing: PR to main.

Silent-failure class: this bug makes the watcher quieter, not louder. Every test
passes today and the operator hears nothing when a wake fails. A fix that is
merely "more correct" but still hardcodes a schedule recreates it on the next
change.

## 1. Clone first — do not touch ~/ForteL2

A numbered step, not a header note. A previous worker ignored a clone named only in
a header and ran `git stash` in the shared checkout over another task's work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-sleepwindow.XXXXXX")
    trap 'rm -rf "$SCRATCH"' EXIT
    git clone https://github.com/StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git switch -c fix/dev-sleep-window-from-config origin/main

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and confirm deletion before hand-back.

Commit this brief verbatim as tasks/worker-prompts/dev-sleep-window-from-config.md.

## 2. Read before changing anything

- tasks/decisions.md — D-0026 (the nightly sleep/wake jobs), D-0141 (replica
  interval suppression; its §7 warned against a second copy of the boundaries),
  D-0142 (proposer awake-time subtraction; its own comment says "Grep 23:45 in both
  files if the sleep schedule ever moves" — that is exactly what happened),
  D-0143 (most recent entry).
- scripts/alert-watch.sh — in_dev_sleep_window() at 607 and ALL its consumers:
  interval_touches_dev_sleep() at 618 (line 635, 638), the recovery grace at 649,
  **stack-down's `want_up` at 811**, and awake_seconds() at ~1355 (line 1380).
- scripts/pipeline-snapshot.py — _DEV_SLEEP_START_MIN / _DEV_SLEEP_END_MIN at 58-59,
  in_dev_sleep_window() at 211, and **window_len = timedelta(hours=3, minutes=15)
  at 242**, which is a THIRD hardcoded copy derived independently of the other two.
- scripts/check-launchd.sh — the existing read-only repo-vs-installed drift check.
  It already parses StartCalendarInterval; reuse its approach rather than inventing
  a second parser if that is practical.
- launchd/com.steve.fortel2-sleep.plist and launchd/com.steve.fortel2-wake.plist.
- scripts/test-helpers.sh — the rp_* fixtures and rp_run's noon-PT clock pin
  (D-0141/D-0142); your new tests follow that shape.

## 3. Evidence — measured 2026-09-21

The operator moved the WAKE (not the sleep) to shorten the nightly outage ahead of a
deployment. What is actually installed:

    ~/Library/LaunchAgents/com.steve.fortel2-sleep.plist   Hour 23 Minute 45   (mtime Aug 31)
    ~/Library/LaunchAgents/com.steve.fortel2-wake.plist    Hour  0 Minute 15   (mtime Sep 20 17:07)

`launchctl print` confirms both are live on those schedules. The real nightly outage
is now **23:45 -> 00:15, about 30 minutes**, not 3 h 15 m. The 00:15 wake fired
successfully on 2026-09-21 (`fortel2-wake end rc=0`, L2 at 1269956), so the fdautil
allowlist survived the edit.

The repo still says 3:00, and the repo's own checker already fails on it:

    $ ./scripts/check-launchd.sh
    OK    com.steve.fortel2-sleep  schedule=23:45
    FAIL  com.steve.fortel2-wake   schedule mismatch: repo=3:0 installed=0:15
    Result: FAIL (1 issue(s), 0 warning(s)).

Every suppression path still assumes 23:45-03:00. Consequences, worst first:

  1. **stack-down is blind 00:15-03:00.** `want_up = not in_dev_sleep_window(now)`,
     so the 00:30, 01:30 and 02:30 probes believe the stack SHOULD be down. If a
     wake fails, nothing alerts until 03:30. D-0138 was an 82-minute outage found by
     a human; this hides a three-hour one.
  2. replica-losing-ground suppresses intervals overlapping 00:15-03:00, plus the
     post-wake grace out to 04:30.
  3. proposer-overdue subtracts up to 2 h 45 m of awake time it should not,
     understating age and delaying detection by the same amount.

None of this is hypothetical: it is live on the operator's machine right now.

## 4. What must hold when you are done

State these as properties; the implementation is yours.

**P1. One source of truth, and it is what actually runs the stack.** The window is
derived from the INSTALLED launchd jobs — the sleep job's StartCalendarInterval is
the start, the wake job's is the end. Not from a constant, not from the repo plists,
not from two copies. The operator changing launchd must not require a code change.

**P2. A documented fallback, and it must not lie.** CI, a fresh clone, and a
friend's machine have no such plists. When they are absent or unparseable, fall back
to a documented default and make that fact visible — `--help` and the emitted JSON
should let a reader tell "measured from launchd" from "assumed default". A fallback
that silently pretends to be measured is the same defect one layer up.

**P3. Both files agree, always.** `pipeline-snapshot.py` and `alert-watch.sh` remain
separate processes with no shared import, so they will each carry a reader. They must
produce the same window for the same inputs. D-0142's review differential-tested the
two awake-time implementations to 0 s divergence across a year including both DST
transitions — that property must survive. The third copy at pipeline-snapshot.py:242
(`window_len`) must be derived from the boundaries, not restated.

**P4. Non-wrapping windows are handled.** Today's window wraps midnight
(23:45 -> 00:15) and the existing `mins >= start or mins < end` is correct for that.
A future window that does NOT wrap (say 01:00 -> 03:00) makes that expression true
for everything at or after 01:00 — see §7. Both wrapping and non-wrapping must be
correct, and both must be tested.

**P5. The post-wake recovery grace is anchored to the wake, not to 03:00.** D-0141
gives replica-losing-ground one cycle of grace after the stack comes back
(`in_dev_sleep_window(now_ts - 3600.0)` at alert-watch.sh:649). That arithmetic
assumes a 03:00 wake. It must become "one watcher cycle after the window ends,"
whatever the end is.

**P6. Behaviour at the new 30-minute window is correct, and you have checked what
changed.** The watcher probes hourly at :30, so with a 23:45-00:15 window NO probe
instant falls inside it — only the 00:30 probe's *interval* [23:30, 00:30] overlaps.
Interval-based suppression is now doing all the work and instant-based checks do
almost none. Confirm `stack-down` now expects the stack up at 00:30, 01:30 and 02:30
(it should — a 30-minute outage falls between probes), and say so in your report.

**P7. `./scripts/check-launchd.sh` passes.** Update launchd/com.steve.fortel2-wake.plist
to 0:15 so repo and host agree. Do not touch the installed plists — see §6.

## 5. Pre-assigned identifier

This work is **D-0144**. This OVERRIDES any "find the highest and add one" convention
— main's next-free line reads D-0144 as of a93637e. If it is already taken when you
open the file, STOP and report rather than picking D-0145.

Write the entry in tasks/decisions.md in the existing format and append the
"Next free decision id is **D-0145**" line the convention requires. It must record:
the measured installed schedules and their mtimes; the three under-alerting
consequences above with stack-down named first; that the 00:15 wake fired
successfully so the allowlist survived; the new source of truth and its fallback;
and that D-0141's and D-0142's hardcoded-window comments are now obsolete.

Per the operator's standing rule on verdict entries: grep the whole repo for the OLD
claim and for obligation language before you finish — "23:45–03:00", "3h15m",
"3 h 15 m", "03:00", "sleep window" in prose. Read whole sections, not matched lines.
Sweep decisions.md (including D-0026, D-0034/D-0035, D-0141, D-0142), README.md,
launchd/README.md, AGENTS.md and the PRD. Fix every cross-reference in this PR and
list them in your report. Historical entries describing what was true then are dated
records — leave them, and say which you judged historical.

## 6. Scope

Freely changeable:
  scripts/alert-watch.sh
  scripts/pipeline-snapshot.py
  scripts/check-launchd.sh        (only if reusing its parser needs a refactor)
  scripts/test-helpers.sh          (append cases; do not restructure existing ones)
  scripts/test_pipeline_snapshot.py
  launchd/com.steve.fortel2-wake.plist   (schedule -> 0:15, per P7)
  .env.sepolia.example             (only if a documented fallback key is needed)
  tasks/worker-prompts/dev-sleep-window-from-config.md   (new — this brief)

Additive only:
  tasks/decisions.md               (one new D-0144 section + the next-free line;
                                    do NOT rewrite D-0026, D-0141, D-0142 or D-0143)
  README.md, launchd/README.md     (only the sentences stating the changed behaviour)

Do not touch:
  ~/Library/LaunchAgents/*.plist — the INSTALLED jobs are the operator's. You are
    making the code follow them, not the reverse. Reading them is fine; writing is not.
  launchd/com.steve.fortel2-sleep.plist — 23:45 is still correct.
  .env.sepolia — untracked, live secrets, operator-owned.
  refresh_health.sh — swallow-and-continue is load-bearing (D-0138/D-0139).
  The replica / cloudflared / proposer CONDITIONS themselves — you are changing the
    window they consult, not their predicates or cooldowns.
  Anything under batcher/, derivation/, contracts/, viewer/, dapp/, replica/.

If the task appears to require changing something outside this surface, STOP and
report rather than widening scope.

## 7. The trap

`in_dev_sleep_window()` is `mins >= start or mins < end`. That is correct ONLY for a
window that wraps midnight, which every window so far has. Make the boundaries
configurable and the first non-wrapping window silently marks most of the day as
"asleep":

    start 01:00, end 03:00  ->  mins >= 60 or mins < 180  ->  true from 01:00 to 23:59

Consequence: stack-down never fires, replica and proposer suppression swallow
everything, and the whole alerting surface goes quiet while every test that only
exercises a wrapping window stays green. That is this same bug with the volume at
maximum.

Detect wrap vs non-wrap from the boundaries themselves (start > end means it wraps)
and branch. Test both. The related failure is leaving the derived duration
(pipeline-snapshot.py:242) computed the old way — with a 30-minute window a 3 h 15 m
subtraction removes six times too much awake time.

## 8. What must survive

- Everything D-0140, D-0141, D-0142 and D-0143 added must still pass unmodified:
  the 600/601 exclusive boundary, the 98 -> 219 -> 340 sawtooth replay, the
  hourly-freeze fire, the sleep-window trap case, the first-probe-after-wake case,
  the wedged-replica case, and all the proposer-overdue and unknown-panel cases.
  Where one of those tests encodes the OLD 03:00 end, it must be re-anchored to the
  configured window rather than deleted — and you must declare that in the return
  block with before, after, and why it is a re-anchoring and not a weakening.
- pipeline-health.json existing keys, types and null semantics stay frozen.
- alert-watch's channel independence, cooldown and ALERT_REALERT_HOURS unchanged.
- ALERT_WATCH_* test-only names must not leak into any env file.
- The two implementations must stay numerically identical (P3).

## 9. Coverage, as properties

  - A wrapping window (23:45 -> 00:15) marks 23:50 and 00:05 asleep, and 00:30,
    01:30, 02:30 awake.
  - A NON-wrapping window (01:00 -> 03:00) marks 02:00 asleep and 14:00 awake —
    the §7 trap, asserted by itself.
  - stack-down: with the 30-minute window, `want_up` is TRUE at 00:30, 01:30 and
    02:30, so a failed wake alerts. Assert this explicitly — it is the defect.
  - replica-losing-ground: an interval spanning 23:45 -> 00:15 does not advance the
    streak; an interval wholly inside 00:15 -> 03:00 DOES (it no longer gets a pass).
  - The post-wake grace lands one watcher cycle after the configured end, not 03:00.
  - proposer awake-time: a 30-minute window removes 30 minutes, not 3 h 15 m; a gap
    spanning two nights removes two windows.
  - Both readers return the same window and the same awake-seconds for the same
    inputs, over a range that includes both 2026 DST transitions (D-0142's review
    measured 0 s divergence — keep it).
  - Missing/unparseable plists fall back to the documented default AND the result is
    marked as assumed rather than measured.

## 10. Verification

Offline. Do not call QuickNode or any live RPC.

Generate a .env CI-style first, as .github/workflows/ci.yml does (sed the two path
prefixes out of .env.example), or you will see three unrelated environmental
failures.

    python3 -m py_compile scripts/pipeline-snapshot.py
    for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX_FAIL $f"; done
    python3 -m unittest scripts/test_pipeline_snapshot.py
    ./scripts/test-helpers.sh
    ./scripts/alert-watch.sh --help

Reference numbers on macOS in a clean clone at a93637e: test-helpers ~697 PASS /
0 FAIL, test_pipeline_snapshot 42 tests. Confirm your own baseline, report both
counts, and diff the PASS *names* against main — a count alone hides a test that
stopped running.

Clock-independence, which no ordinary run performs:

    ALERT_WATCH_NOW="$(python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print("%.0f" % datetime(2026,9,22,1,30,tzinfo=ZoneInfo("America/Los_Angeles")).timestamp())')" ./scripts/test-helpers.sh

Same result as unpinned, or a test is reading wall-clock.

**On the Mac (this one cannot run in CI and is the point of the task):**

    ./scripts/check-launchd.sh

Must report `Result: PASS` with no wake mismatch. Then confirm the readers actually
see 23:45 -> 00:15 from the installed jobs rather than a fallback — print it via
`./scripts/alert-watch.sh --help` or an equivalent read-only path and paste the
output. If you cannot run on the Mac, say so plainly and leave it for the operator;
do not claim it passed.

At the MOMENT of hand-back, re-fetch and re-run — main has moved under three of the
last four tasks in this line of work:

    git fetch origin && git rebase origin/main
    ./scripts/test-helpers.sh && python3 -m unittest scripts/test_pipeline_snapshot.py

Migration: none.

Temp files: everything outside the repo under the $SCRATCH from §1, deleted before
hand-back, path on the TEMP: line.

## 11. Out of scope, with reasons

- Changing the installed launchd jobs. The 00:15 wake is a deliberate operator
  decision for a deployment; you make the code follow it.
- The Morning Briefing prompt. It lives outside this repo and the operator is fixing
  its separate `lag_unsafe_safe` defect directly. Do not go looking for it.
- A `sequencer.verdict` field. The briefing's invented "lag > 50" rule is a real
  defect but it is prompt-side, and a proper lag verdict needs its own threshold
  decision (it has to scale with batcher cadence, not be a constant). Name it in
  D-0144 as a candidate for D-0145; do not build it here.
- REPLICA_HEAD_STALE_SECS (10800). Still open from D-0141.
- Deploying. Merge is not deploy; ./scripts/deploy-agents.sh is the operator's call.

## 12. Operator decisions to return, not resolve

  - Whether a `sequencer.verdict` gets built, and on what predicate (§11).
  - Whether REPLICA_HEAD_STALE_SECS gets its own decision.
  - Whether the 00:15 wake is permanent or reverts after the friends' deployment.
    Your change makes either work without a code edit — say so, and flag that if it
    reverts to 03:00 nothing needs redoing.

## 13. Argue if this is wrong

If you think reading the installed plists is the wrong source of truth — an env key,
or a single shared module both files import, may be defensible — argue it with
evidence rather than implementing it half-heartedly. The bar: the operator changed
launchd on 2026-09-20 and the code did not follow. Whatever you propose must make
that specific sequence safe, not merely tidier.

## 14. Return format

Emit this whole block inside ONE fenced code block so the operator can copy it in a
single click. Disclosure in the last fields counts as diligence, not failure.

TASK:        D-0144 — dev-sleep window derived from the installed launchd jobs
LINE OF WORK: fix/dev-sleep-window-from-config
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: py_compile — pass/fail
              bash -n — pass/fail
              test_pipeline_snapshot.py — pass/fail, N tests
              test-helpers.sh — N PASS / N FAIL (main baseline: N PASS / N FAIL)
              test-helpers.sh pinned 01:30 PT — N PASS / N FAIL (must match)
              PASS-name diff vs origin/main — <added / removed / net>
              check-launchd.sh ON THE MAC — PASS/FAIL, or "not run, no Mac access"
              window actually read from launchd — <the printed window, or "fallback">
              alert-watch.sh --help — pass/fail
              (all re-run against origin/main as of hand-back, sha <sha>)
MIGRATION:   none

WINDOW SOURCE: <where the boundaries come from, and the fallback behaviour>
WRAP HANDLING: <how wrapping vs non-wrapping is decided, and both tested>
STACK-DOWN AT 00:30/01:30/02:30: <want_up value before and after this change>
TWO-READER PARITY: <how you showed both files agree, and over what range>
SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
CROSS-REFERENCES SWEPT: <every file/section grepped for 23:45–03:00 / 3h15m, what
                        you fixed, and which you judged historical and left>
IDENTIFIERS USED:     D-0144; next free id line set to D-0145
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this is a re-anchoring to
                          the configured window, not a weakening      (or: none)
CLONE:               deleted <path>
TEMP:                <every temp path outside the repo> — deleted: yes/no
DECISIONS NEEDED:    the three in §12, plus anything else you hit
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly

The standing goal below authorises fixing CI failures and review-bot findings on this
change set. It does NOT authorise widening the §6 file scope, weakening or skipping
checks to get green, editing the installed launchd jobs, or resolving the §12
operator decisions. Blocked by any of those: stop and report.
