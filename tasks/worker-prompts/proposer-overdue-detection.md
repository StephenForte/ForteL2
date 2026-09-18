DISPATCH · D-0142 — proposer.verdict + proposer-overdue alert condition
Model: mid tier · Order: single task, no dependencies
Surface: Cursor or Claude Code
Repository: StephenForte/ForteL2
Baseline: origin/main @ 702a456 (verify: git fetch && git rev-parse origin/main —
          trust the repo over this brief, including over its confident assertions)
Branch: feat/proposer-overdue-detection (cut it yourself, off origin/main)
Host: any — everything here runs offline against fixtures
Runtime: ~1–1.5 h. Do not call QuickNode or any live RPC during development.
Working directory: a scratch clone — NOT the operator's ~/ForteL2 checkout
Teardown: delete the clone after the PR is pushed
Landing: PR to main.

Silent-failure class: this task exists because a broken component currently looks
identical to a healthy one. A verdict that reports `healthy` when it could not
actually determine the answer recreates the exact defect, one layer up.

## 1. Clone first — do not touch ~/ForteL2

A numbered step, not a header note. A previous worker ignored a clone named only in a
header and ran `git stash` in a shared checkout over another task's uncommitted work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-proposer.XXXXXX")
    trap 'rm -rf "$SCRATCH"' EXIT
    git clone https://github.com/StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git switch -c feat/proposer-overdue-detection origin/main

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and confirm deletion before hand-back.

Commit this brief verbatim as tasks/worker-prompts/proposer-overdue-detection.md.

## 2. Read before changing anything

- tasks/decisions.md — D-0141 (merged today, #242: it added batcher.verdict and the
  sleep-window interval suppression; this task is the same pattern applied to the
  proposer, and you should reuse its shape rather than invent a new one), D-0140 (the
  600 s replica floor), D-0133/D-0134 (why the proposal interval is 8h: QuickNode credit
  budget — do not "fix" the interval), D-0113 Finding 2 (merge is not deploy).
- scripts/pipeline-snapshot.py — snapshot_proposer() at ~line 300, snapshot_batcher()
  and summarize_batcher()/batcher_verdict() as the pattern to follow, load_env_file()
  and env_get() in main() at ~line 415.
- scripts/alert-watch.sh — the whole file. In particular: the header comment block
  documenting every condition (it is the contract), in_dev_sleep_window() at ~line 552,
  interval_touches_dev_sleep() and replica_losing_sleep_suppressed() added by D-0141,
  the replica_unreachable_streak pattern (your precedent for "two consecutive failures
  before alerting"), the per-condition cooldown and ALERT_REALERT_HOURS, the
  ALERT_WATCH_* test-only override convention (these names must NEVER appear in env
  files — lib.sh sources with set -a), ALERT_WATCH_NOW, and the --help awk.
- scripts/test-helpers.sh — the rp_* fixtures added by D-0141, especially rp_run's
  noon-PT clock pin and rp_pt_now. Your new condition's tests follow that shape.
- scripts/test_pipeline_snapshot.py — where snapshot regressions live.

## 3. Evidence — measured 2026-09-18, reproduce it if you doubt it

### 3a. The proposer is healthy. Nothing about it is currently monitored.

Three consecutive proposals from the live log
(/Users/steveforte/src/fortel2/data-sepolia/logs/op-proposer.log, operator's machine —
you do not need it, this is the evidence):

    2026-09-17 12:40:26 PT
    2026-09-17 20:42:25 PT   (+8h 02m)
    2026-09-18 04:44:17 PT   (+8h 02m)

Configured `SEPOLIA_PROPOSER_INTERVAL=8h` (.env.sepolia:81, default 8h in
scripts/06-start-proposer-sepolia.sh:27). The live process confirms it:
`--proposal-interval=8h --poll-interval=120s`. Observed jitter across those cycles is
about 2 minutes.

Note the middle gap spans the nightly 23:45–03:00 PT sleep window and is still 8h02m.
That is because the due time (04:42) fell outside the window. That does not generalise —
see §4 P2.

### 3b. The gap this closes.

Two snapshots, five and a half hours apart, both reporting the same proposal:

    captured 2026-09-18T12:00:02Z   index 485, timestamp 1789731864, age_sec 944
    captured 2026-09-18T17:40:15Z   index 485, timestamp 1789731864, age_sec 21392

Both are correct and the proposer is fine. But the operator read the second one as an
outage, and the snapshot gave them nothing to decide with: a raw `age_sec` with no
threshold, no interval, and `errors: []`. That is exactly the batcher defect D-0141
fixed — raw counts with the interpretation left to the reader.

`scripts/alert-watch.sh` mentions the proposer exactly once, at line 736, as a pidfile
name in the stack-missing process list. Confirm that yourself:

    grep -in proposer scripts/alert-watch.sh

So a proposer whose PROCESS is alive but which is not PROPOSING — wallet below the gas
floor, transactions reverting, L1 endpoint failing, game type misconfigured — is
completely unmonitored today. Only a dead process is caught. D-0121 Finding 12 is the
precedent for the wallet case: "the proposer is below its funding floor and nothing
warned."

## 4. What must hold when you are done

State these as properties; the implementation is yours.

**P1. `proposer.verdict` in pipeline-health.json, additive.**
A closed set of strings, documented in the README section describing pipeline-health.json.
Existing keys under `proposer` — `factory`, `game_count`, `latest` and every field inside
`latest` — keep their names, types and null semantics. An external agent reads this file
byte-for-byte; additive only.

The set must distinguish three states, not two:
  - the proposer is within its expected cadence;
  - it is past due;
  - **the snapshot could not determine the answer** — `game_count` is 0, `latest` is
    null, the eth_call failed, or the interval could not be parsed.
The third value is the point of the task. A verdict that collapses "cannot tell" into
"healthy" reproduces the defect it is fixing.

Also emit the configured interval as a number of seconds alongside the verdict, so a
downstream reader can see what the verdict was judged against instead of assuming 8h.

**P2. The threshold is interval-derived and sleep-aware. ASSIGNED, not derived:**

> **overdue when the proposer's age, EXCLUDING any time inside 23:45–03:00 PT,
> exceeds the configured interval + 2 h.**

For the current 8h interval that is 10 awake-hours. Reasoning, so you can recognise
variants: observed jitter is ~2 minutes, so 2 h is roughly 60× the worst observed
slack — generous without waiting a whole extra cycle. The sleep exclusion is required
because the proposer stops with the stack: a due time landing at 23:45 cannot be served
until ~03:00, so raw age can legitimately reach 8 h + 3 h 15 m ≈ 11 h 15 m with nothing
wrong. A naive `age > 10h` alarms every time a due time lands in the window.

The interval must be READ FROM CONFIG (`SEPOLIA_PROPOSER_INTERVAL`, default 8h), never
hardcoded. The legacy `PROPOSER_INTERVAL` key is a Phase-1 Anvil knob and must be
IGNORED — scripts/06-start-proposer-sepolia.sh:22-27 documents why. Parse the duration
suffix form (`8h`, `30m`, `12s`); an unparseable value yields the "cannot tell" verdict,
never a default that silently disagrees with what the proposer is actually running.

**P3. A new `proposer-overdue` condition in alert-watch.sh**, with its own cooldown key,
firing on the same predicate as P2 and carrying the game index, the age, the configured
interval and the threshold in its body.

It needs its own L1 read (hourly; the snapshot is daily and far too stale for this). Use
`L1_RPC_URL`. **This is the first metered dependency in this watcher — disclose it in
D-0142.** Cost basis: two `eth_call`s per run, 24 runs/day ≈ 48 calls/day, negligible
against the 3M/day warn line, but it is a new class of dependency for this script and
the record should say so.

Fail quiet, not loud: a failed or garbage L1 read must NOT page. Follow the
`replica_unreachable_streak` precedent — one failure is quiet, and the condition only
speaks after two consecutive failures, with a later success resetting the streak. An
alerting path that pages on a provider blip trains the operator to ignore it, which is
the cry-wolf class this whole line of work exists to remove.

**P4. Nothing else in alert-watch changes behaviour.** The replica conditions, the
cloudflared conditions, stack-missing / stack-down, funding-fail, health-stale and
resolve-games all keep their current triggers and their current cooldown semantics.

**P5. Every new test is clock-pinned**, following rp_run's noon-PT default. D-0141's
review proved this is load-bearing: mutating that pin into the sleep window turns four
replica assertions red. A wall-clock-reading test here fails on CI between 06:45 and
11:30 UTC and passes whenever you happen to run it.

**P6. The contract stays self-describing.** The alert-watch header condition list and
`--help` output both document `proposer-overdue`, its threshold, and the sleep exclusion.
The README's ops-alerting paragraph and the pipeline-health.json paragraph both gain the
new behaviour.

## 5. Pre-assigned identifier

This work is **D-0142**. This OVERRIDES any "find the highest and add one" convention —
main's next-free line reads D-0142 as of 702a456. Do not allocate a different one. If
D-0142 is already taken when you open the file, STOP and report rather than picking
D-0143.

Write the entry yourself in tasks/decisions.md in the existing format, and append the
"Next free decision id is **D-0143**" line the file's convention requires. It must
record: the three proposal timestamps and the 8h configured interval; that the proposer
was HEALTHY throughout and this closes a monitoring gap rather than a fault; the assigned
threshold and why the sleep exclusion is required; that alert-watch now makes a metered
L1 call hourly; and that D-0121 Finding 12 (proposer below its funding floor, nothing
warned) is the precedent this condition would have caught.

Per the operator's standing rule on verdict entries: grep the repo for obligation
language before you finish — anything saying proposer health "must" be added, is "not
monitored", or that pipeline-health has no proposer verdict. Read whole sections, not
matched lines. Sweep decisions.md, README.md, launchd/README.md, AGENTS.md and the PRD.
Fix every cross-reference in this PR and list them in your report.

## 6. Scope

Freely changeable:
  scripts/pipeline-snapshot.py
  scripts/alert-watch.sh
  scripts/test_pipeline_snapshot.py
  scripts/test-helpers.sh          (append cases; do not restructure existing ones)
  .env.sepolia.example             (only if a new commented threshold key is needed)
  tasks/worker-prompts/proposer-overdue-detection.md   (new — this brief)

Additive only (other work appends here; never rewrite or reorder):
  tasks/decisions.md               (one new D-0142 section + the next-free line)
  README.md, launchd/README.md     (only the sentences stating the changed behaviour)

Do not touch:
  scripts/06-start-proposer-sepolia.sh and SEPOLIA_PROPOSER_INTERVAL — the 8h interval is
    a deliberate credit-budget decision (D-0133/D-0134). You are measuring against it,
    not changing it.
  launchd/*.plist — schedules are correct and both plists are on the operator's fdautil
    allowlist; an edit means a supervised re-install, out of scope here.
  .env.sepolia — untracked, live secrets, operator-owned.
  refresh_health.sh — its swallow-and-continue structure is load-bearing (D-0138/D-0139).
  The replica / cloudflared / stack conditions in alert-watch.sh — see P4.
  Anything under batcher/, derivation/, contracts/, viewer/, dapp/, replica/.

If the task appears to require changing something outside this surface, STOP and report
rather than widening scope.

## 7. The trap

You will be tempted to compute awake-age by subtracting a fixed 3h15m whenever the age
"looks like" it spans a night, or to write a second copy of the 23:45–03:00 boundaries
next to your new code.

Both are wrong, and both pass a naive test. The age can span zero, one, or several sleep
windows depending on how long the proposer has been silent, and a dead proposer at 30 h
must have two windows removed, not one. D-0141 already warns about the second failure:
two definitions of the window drift apart the next time the sleep schedule moves.

Reuse `in_dev_sleep_window()` — it is already in this file and D-0141's
`interval_touches_dev_sleep()` shows the established way to walk an interval against it.
Compute the actual overlap between `[last_proposal_ts, now]` and the window, however many
windows that spans.

The consequence of getting it wrong: subtract too little and the condition pages on a
normal night; subtract too much and a proposer dead for a day and a half still reads
healthy — which is worse, because it is the failure this task exists to catch.

## 8. What must survive

- pipeline-health.json is consumed byte-for-byte by an external agent. Existing keys,
  types and null semantics are frozen; additions only. The Morning Briefing prompt now
  reads `batcher.verdict`; do not rename or restructure it.
- alert-watch's channel independence: banner and Resend email each fire when the other is
  broken, and any channel failure still exits nonzero.
- Per-condition cooldown and ALERT_REALERT_HOURS behaviour unchanged.
- Everything D-0140 and D-0141 added must still pass, unmodified: the 600/601 exclusive
  boundary, the 98 → 219 → 340 sawtooth replay, the hourly-freeze fire, the sleep-window
  trap case, the first-probe-after-03:00 case, and the wedged-replica case.
- ALERT_WATCH_* names must not leak into any env file.
- Existing checks may not be weakened, skipped or deleted. A test may legitimately change
  when it encoded the very behaviour being corrected — declare any such change in the
  return block with before, after, and why it is a strengthening.

## 9. Coverage, as properties

Add regressions asserting the PROPERTY, not the line:

  - A proposal 8h02m old (the measured real cadence) is NOT overdue.
  - A proposal at exactly the threshold is NOT overdue; one second past it IS
    (state which operator you chose and assert both sides of it).
  - A proposal whose age spans one full sleep window and whose AWAKE age is under the
    threshold is NOT overdue — the case a naive `age >` check gets wrong.
  - A proposal whose age spans TWO sleep windows is judged on awake time, not on one
    window's worth of subtraction (the §7 trap).
  - A proposal well past the threshold on awake time IS overdue and DOES alert.
  - `game_count` 0, `latest` null, a failed eth_call, and an unparseable interval each
    yield the "cannot tell" verdict — never `healthy`.
  - The verdict is judged against the CONFIGURED interval: set a different interval in
    the fixture env and confirm the same age flips the verdict.
  - One failed L1 read in alert-watch is quiet; two consecutive fire; a later success
    resets the streak.
  - Existing pipeline-health.json proposer keys keep their names and types.

## 10. Verification

Everything runs offline. Do not call QuickNode or any live RPC.

    python3 -m py_compile scripts/pipeline-snapshot.py
    for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX_FAIL $f"; done
    python3 -m unittest scripts/test_pipeline_snapshot.py
    ./scripts/test-helpers.sh
    ./scripts/alert-watch.sh --help

Generate a .env CI-style before running test-helpers, as .github/workflows/ci.yml does —
sed the two path prefixes out of .env.example. Without it you will see three
environmental failures unrelated to your change.

Reference numbers from the D-0141 review, run on macOS in a clean clone:

    main @ 702a456 expected ≈ 682 PASS / 0 FAIL   (confirm your own baseline)
    test_pipeline_snapshot.py: 16 tests

Report the PASS count for origin/main and for your branch, and diff the PASS *names*
between them. A count alone hides a test that silently stopped running. Unexplained
movement is itself a finding.

Then the clock-independence check, which no ordinary run performs — the suite must give
the same result with the evaluator clock pinned inside the sleep window:

    ALERT_WATCH_NOW="$(python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print("%.0f" % datetime(2026,9,19,1,30,tzinfo=ZoneInfo("America/Los_Angeles")).timestamp())')" ./scripts/test-helpers.sh

Report both counts. If they differ, a test is reading wall-clock and P5 is unresolved.

Finally, at the MOMENT of hand-back, re-fetch and re-run everything — main moved twice
under the previous task in this line of work:

    git fetch origin && git rebase origin/main
    ./scripts/test-helpers.sh && python3 -m unittest scripts/test_pipeline_snapshot.py

There is no harness that exercises alert-watch against a live L1 and you must not build
one. State in your report exactly what you exercised by hand, if anything.

Migration: none.

Temp files: everything outside the repo goes under the $SCRATCH from §1. Delete it before
hand-back and report the path on the TEMP: line. A temp folder is fine; leaving it behind
is not.

## 11. Out of scope, with reasons

- Changing the 8h proposal interval. It is a deliberate QuickNode credit-budget decision
  (D-0133/D-0134). You measure against it.
- The batcher and replica conditions — D-0140 and D-0141 closed those; see P4.
- REPLICA_HEAD_STALE_SECS (10800). Named as open in D-0141; it sits ~900 s above a normal
  02:30 PT sleep-window head age. Still needs its own decision. Not this task.
- A proposer condition based on GAME OUTCOMES (games resolving, bonds recovered). That is
  resolve-games territory and a different failure mode. This task is liveness only:
  is a new game appearing on schedule.
- Deploying. Merge is not deploy (D-0113 Finding 2); launchd runs
  /Users/steveforte/fortel2-agents until ./scripts/deploy-agents.sh runs, and that is the
  operator's call.

## 12. Operator decisions to return, not resolve

  - Whether REPLICA_HEAD_STALE_SECS gets its own decision, and when (§11).
  - Whether the Morning Briefing prompt should also read `proposer.verdict`. It was
    updated to read `batcher.verdict` on 2026-09-18. That prompt lives OUTSIDE this repo;
    do not go looking for it. Emit the field, document its values, and put the question on
    the DECISIONS NEEDED: line.

Do not decide either, and do not add a compatibility shim that guesses at the second.

## 13. Argue if this is wrong

If you think the threshold is wrong — interval + 2 h on awake time — or that the sleep
exclusion should be handled somewhere else entirely, argue it with evidence rather than
implementing it half-heartedly. The proposal timestamps in §3a are reproducible from
/Users/steveforte/src/fortel2/data-sepolia/logs/op-proposer.log on the operator's machine.
Bring a counter-measurement, not a preference.

## 14. Return format

Emit this whole block inside ONE fenced code block so the operator can copy it in a
single click. Disclosure in the last fields counts as diligence, not failure.

TASK:        D-0142 — proposer.verdict + proposer-overdue alert condition
LINE OF WORK: feat/proposer-overdue-detection
REVIEW ARTIFACT: <PR url>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: py_compile — pass/fail
              bash -n — pass/fail
              test_pipeline_snapshot.py — pass/fail, N tests
              test-helpers.sh — N PASS / N FAIL (main baseline: N PASS / N FAIL)
              test-helpers.sh pinned to 01:30 PT — N PASS / N FAIL (must match)
              PASS-name diff vs origin/main — <added / removed / net>
              alert-watch.sh --help — pass/fail
              (all re-run against origin/main as of hand-back, sha <sha>)
MIGRATION:   none

THRESHOLD IMPLEMENTED: <the predicate, in one line, and how awake-time is computed>
METERED COST:  <calls per run × runs/day, and the basis>
SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
CROSS-REFERENCES SWEPT: <every file/section grepped for "not monitored" / "must add"
                        proposer obligation language, and what you fixed>
IDENTIFIERS USED:     D-0142; next free id line set to D-0143
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens rather than
                          weakens                                  (or: none)
CLONE:               deleted <path>
TEMP:                <every temp path outside the repo> — deleted: yes/no
DECISIONS NEEDED:    the two in §12, plus anything else you hit
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly

The standing goal below authorises fixing CI failures and review-bot findings on this
change set. It does NOT authorise widening the §6 file scope, weakening or skipping
checks to get green, changing the 8h interval, or resolving the §12 operator decisions.
Blocked by any of those: stop and report.
