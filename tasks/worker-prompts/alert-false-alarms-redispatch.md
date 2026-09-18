DISPATCH · RE-DISPATCH of D-0140 work — #242 rebase onto the competing merged fix
Model: mid tier · Order: single task, blocks the merge of #242
Surface: Cursor or Claude Code
Repository: StephenForte/ForteL2
Baseline: origin/main @ 01b26fa (verify: git fetch && git rev-parse origin/main —
          trust the repo over this brief, including over its confident assertions)
Branch: fix/alert-false-alarms-batcher-replica — ALREADY EXISTS at a6d38f8, pushed,
        open as PR #242. You continue on it. See §0.
Host: any — everything here runs offline against fixtures
Runtime: ~45–60 min. No metered RPC spend: do not call QuickNode or the live replica.
Working directory: a scratch clone — NOT the operator's ~/ForteL2 checkout
Teardown: delete the clone after the force-push
Landing: force-push to the existing branch; PR #242 updates in place. Do not open a new PR.

This is a re-dispatch. The previous attempt (#242, a6d38f8) was reviewed and approved,
then main moved underneath it. Its work is sound; it now conflicts with a competing fix
that merged first. You are rebasing and reworking it, not starting over — but read this
whole brief, because two of its decisions are reversed.

Silent-failure class: the naive rebase produces a suite that passes when you run it and
fails on CI every morning between 06:45 and 11:30 UTC. See §5.

## 0. The branch already exists — continue it, do not stop

Normally a pre-existing branch means STOP. Not here: a6d38f8 is the prior approved work
and PR #242 is open against it. You will rebase that commit, rework it, and force-push
the same branch.

Before anything else, run these and report the output verbatim as a STATE: block:

    git ls-remote --heads origin | grep alert-false-alarms
    gh pr view 242 --json state,mergeable,headRefOid --jq '.state, .mergeable, .headRefOid'
    git log --oneline -3 origin/main

Expected: branch present at a6d38f8, PR 242 OPEN and CONFLICTING, main at 01b26fa with
"Raise replica-losing-ground noise floor past one batcher channel (#241)" on top. If any
of that does not match — the PR is closed or merged, main has moved again, someone has
force-pushed the branch — STOP and report. Do not improvise around a changed world.

Then answer plainly: have you done any work on this task before, and did you at any
point write to /Users/steveforte/ForteL2, the operator's shared checkout?

## 1. Clone — do not touch ~/ForteL2

A numbered step, not a header note. A previous worker ignored a clone named only in a
header and ran `git stash` in the shared checkout over another task's uncommitted work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-redispatch.XXXXXX")
    trap 'rm -rf "$SCRATCH"' EXIT
    git clone https://github.com/StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git switch fix/alert-false-alarms-batcher-replica

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and confirm deletion before handing back.

## 2. What happened, and why two of your predecessor's decisions are reversed

Two workers were dispatched at the same problem independently. PR #241 merged first, at
2026-09-18T16:26Z, as commit 01b26fa. It is now main. It took the decision id D-0140.

What #241 did:
  - REPLICA_TREND_NOISE_SECS default 120 → 600 (not 900).
  - Rationale: SEPOLIA_BATCHER_MAX_CHANNEL_DURATION=30 caps a channel at 360 s, so 600 s
    sits above one channel. It reached that number from a 13-sample series of the same
    sawtooth #242 measured over 12 samples. Same phenomenon, same conclusion.
  - Files: .env.sepolia.example, README.md, scripts/alert-watch.sh, scripts/test-helpers.sh,
    tasks/decisions.md.

What #241 did NOT do, and deliberately so:
  - It did not touch the batcher scan window or add batcher.verdict. That half of #242 is
    unaffected and still wanted.
  - It did not fix the nightly sleep-window freeze. Its D-0140 Consequence states that a
    replica growing "+3600 s per hourly run" SHOULD still page. That describes the
    23:45–03:00 PT freeze, which is the deterministic, every-night half of the noise.
    #242's interval suppression remains the fix for it and is the main reason this PR
    still earns its merge.

### Decision A (REVERSED): keep 600. Drop the 900.

Your predecessor set the floor to 900. Do not restore it. Main's 600 stands, and the
floor change leaves #242 entirely.

This is measured, not deference to whoever merged first. Across 287 daytime batcher gaps
in the current op-batcher log — excluding any gap overlapping 23:45–03:00 PT:

    min 59 s   median 360 s   p95 360 s   p99 361 s   max 361 s
    gaps > 360 s: 8      gaps > 600 s: 0

The sawtooth is hard-bounded by the channel duration cap, not merely observed to be
small. 600 s is 1.67× a hard cap with zero exceedances. 900 s buys no additional
correctness and costs sensitivity. Remove the default change, the .env.sepolia.example
change, and every 900-based assertion; re-base the ones that still apply onto 600.

### Decision B (REVERSED): this work is D-0141, not D-0140.

D-0140 is taken by #241 and is on main. Main's next-free line reads D-0141. Renumber
this work to D-0141. This OVERRIDES any "find the highest and add one" convention. If
D-0141 is already taken when you open the file, STOP and report rather than picking
D-0142.

D-0141 does not rewrite D-0140. It SUPERSEDES the part of D-0140's Consequence that says
a +3600 s/hour grower always pages — repo precedent for this is D-0136, which supersedes
D-0135 rather than editing it. State the supersession explicitly in D-0141 and reference
D-0140 by id instead of restating its sawtooth analysis, which is now on main and does
not need duplicating.

## 3. What survives from a6d38f8 unchanged

All of this was independently reviewed and verified; keep it:

  - L1_SCAN_BLOCKS 8 → 60 in scripts/pipeline-snapshot.py, and the comment explaining it.
  - summarize_batcher() / batcher_verdict() and the additive batcher.verdict field
    (healthy | no-posts). Existing keys stay frozen in name, type and null semantics.
  - All of scripts/test_pipeline_snapshot.py (16 tests).
  - interval_touches_dev_sleep() and replica_losing_sleep_suppressed() in alert-watch.sh,
    and the suppression call site in replica_ok().
  - The ALERT_WATCH_NOW evaluator-clock override, and the test asserting that name never
    appears as an assignment in env example files.
  - The README / launchd README sentences about the 60-block scan and verdict values.
  - tasks/worker-prompts/alert-false-alarms-batcher-replica.md — leave the committed
    brief as the historical record of the first dispatch. Commit THIS brief alongside it
    as tasks/worker-prompts/alert-false-alarms-redispatch.md.

Verification of the suppression arithmetic, already done in review and not to be redone:
every hourly :30 probe of a full day, prev = now − 3600, suppresses at 00:30 / 01:30 /
02:30 (window) and 03:30 (grace), and alerts from 04:30 onward. Mutating the grace to
7200 flips 04:30 to suppressed, so the check can fail. Both 2026 DST boundaries behave
identically. Do not change the grace arithmetic; if you believe it is wrong, see §9.

## 4. What must hold when you are done

**P1.** PR #242 is MERGEABLE against origin/main @ 01b26fa with no conflict markers
anywhere in the tree.

**P2.** REPLICA_TREND_NOISE_SECS default is 600 everywhere it appears — the alert-watch
header, the env list, the code default, .env.sepolia.example, README.md. No 900 survives
except, if you wish, as prose in D-0141 explaining why 600 was kept. Main's own
600/601 exclusive-boundary tests and its 98 → 219 → 340 sawtooth replay must survive the
rebase and still pass.

**P3.** Sleep-window suppression still holds at the 600 s floor, with the same properties
the first dispatch proved: an interval overlapping 23:45–03:00 PT does not advance the
streak, including the trap case (current probe awake at 03:30, previous asleep at 02:30);
the first probe after 03:00 does not advance; a replica wedged outside the window still
reaches streak 2 and alerts.

**P4.** Every replica-trend test in the suite is clock-pinned. See §5 — this is the one
that will bite.

**P5.** D-0141 records: that #241 merged first and took D-0140; that 600 was kept on the
measured evidence in §2 rather than 900; the daytime gap distribution above; which clause
of D-0140 this supersedes and why; the batcher window and verdict work; and the
sleep-window suppression. Append the "Next free decision id is D-0142" line the file's
convention requires.

Per the operator's standing rule on verdict entries: grep the whole repo for the OLD
claims and for obligation language before you finish — "900", "D-0140" used to mean this
work, "Render does not sleep", any text asserting the +3600 s/hour grower always pages.
Read whole sections, not matched lines. Fix every cross-reference in this same PR and
list them in your report.

## 5. The trap

Main's hourly-freeze test — scripts/test-helpers.sh around line 11580, "200 → 3800 →
7400 fires at 7400" — calls rp_run with no ALERT_WATCH_NOW. It evaluates at real
wall-clock time. Under this PR's interval suppression, the second probe is suppressed
whenever the suite runs between 23:45 and 04:30 PT. On the GitHub Actions runner that is
06:45–11:30 UTC.

The consequence: the suite passes when you run it in the afternoon, CI passes when you
push in the afternoon, and CI fails every morning thereafter. A green run proves nothing
about the hour it did not run in.

Your predecessor's rp_run already defaults ALERT_WATCH_NOW to 12:00 PT when the caller
does not set it, which should pin main's test for free once the two versions of rp_run
are reconciled. **Verify that; do not assume it.** The rebase could equally resolve in
favour of main's rp_run, silently dropping the default.

Two related checks while you are there: confirm no OTHER alert-watch fixture in the file
(aw_run, stk_run, cfw_run) reaches replica-losing-ground with a grown delta and an
unpinned clock, and confirm the pinned default is a timestamp outside 23:45–04:30 PT.

## 6. Scope

Freely changeable:
  scripts/alert-watch.sh
  scripts/pipeline-snapshot.py
  scripts/test-helpers.sh          (reconcile; do not restructure unrelated cases)
  scripts/test_pipeline_snapshot.py
  .env.sepolia.example             (revert the 900 back to main's 600)
  README.md, launchd/README.md     (only the sentences stating changed behaviour)
  tasks/worker-prompts/alert-false-alarms-redispatch.md   (new — this brief)

Additive only:
  tasks/decisions.md               (one new D-0141 section + the next-free line;
                                    do NOT rewrite D-0140 or any earlier entry)

Do not touch:
  launchd/*.plist — schedules are correct and both plists are on the operator's fdautil
    allowlist; an edit means a supervised re-install, out of scope here.
  .env.sepolia — untracked, live secrets, operator-owned.
  refresh_health.sh — its swallow-and-continue structure is load-bearing (D-0138/D-0139).
  tasks/worker-prompts/alert-false-alarms-batcher-replica.md — historical record.
  Anything under batcher/, derivation/, contracts/, viewer/, dapp/, replica/.

If the task appears to require changing something outside this surface, STOP and report
rather than widening scope.

## 7. What must survive

- pipeline-health.json is consumed byte-for-byte by an external agent. Existing keys,
  types and null semantics are frozen; additions only.
- Everything #241 added must still pass: the 600/601 exclusive boundary, the
  98 → 219 → 340 sawtooth replay, and the hourly-freeze test (clock-pinned per §5, which
  is a pin, not a weakening — say so explicitly in your report).
- alert-watch's channel independence: banner and Resend email each fire when the other is
  broken, and any channel failure still exits nonzero.
- Per-condition cooldown and ALERT_REALERT_HOURS behaviour unchanged.
- replica-head-stale and replica-unreachable semantics unchanged.
- ALERT_WATCH_* names must not leak into any env file.
- Existing checks may not be weakened, skipped or deleted to resolve a conflict. Taking
  "ours" on a test hunk is deletion by another name — reconcile both sides. Declare every
  modified assertion in the return block with before, after, and why it strengthens.

## 8. Verification

Everything runs offline. Do not call QuickNode or the live replica gateway.

Reconcile first, then from a clean clone:

    git rebase origin/main
    python3 -m py_compile scripts/pipeline-snapshot.py
    for f in scripts/*.sh; do bash -n "$f" || echo "SYNTAX_FAIL $f"; done
    python3 -m unittest scripts/test_pipeline_snapshot.py
    ./scripts/test-helpers.sh
    ./scripts/alert-watch.sh --help

Reference numbers from the review of a6d38f8, run on macOS in a clean clone with a .env
generated CI-style from .env.example (sed the two path prefixes, as .github/workflows/ci.yml
does). Without that .env you will see three environmental failures on BOTH sides:

    main @ 009c91f   673 PASS / 0 FAIL
    a6d38f8          683 PASS / 0 FAIL      (+11 added, −1 replaced)

Main has since gained #241's cases, so expect your baseline and your result to both be
higher. Report the PASS count for origin/main @ 01b26fa and for your rebased branch, and
diff the PASS *names* between them — a count alone hides a test that silently stopped
running. Unexplained movement is itself a finding.

Then the §5 check, which no ordinary run performs:

    ALERT_WATCH_NOW="$(python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print("%.0f" % datetime(2026,9,19,1,30,tzinfo=ZoneInfo("America/Los_Angeles")).timestamp())')" ./scripts/test-helpers.sh

The suite must produce the same PASS/FAIL result with the evaluator clock pinned inside
the sleep window as it does unpinned. If it does not, a test is reading wall-clock and §5
is unresolved. Report both counts.

Finally, at the MOMENT of hand-back, re-fetch and re-run everything — main moved once
during this task already:

    git fetch origin && git rebase origin/main
    ./scripts/test-helpers.sh && python3 -m unittest scripts/test_pipeline_snapshot.py

Push with `git push --force-with-lease` (never plain --force) so a concurrent push is not
silently discarded. PR #242 updates in place.

Migration: none.

Temp files: everything outside the repo goes under the $SCRATCH from §1. Delete it before
hand-back and report the path on the TEMP: line. A temp folder is fine; leaving it behind
is not.

## 9. Out of scope, with reasons

- Re-litigating 600 vs 900. Settled in §2 on the measured gap distribution. If you have a
  counter-measurement, §10 — do not just implement 900.
- The Morning Briefing agent's DEGRADED verdict logic. Outside this repo; P2 of the first
  dispatch gives it batcher.verdict to read, and making it read that is the operator's
  change. Do not go looking for it.
- REPLICA_HEAD_STALE_SECS (10800). Left alone deliberately: it is the backstop that keeps
  the suppression safe. It sits ~900 s above a normal 02:30 PT sleep-window head age, so a
  late wake can trip it. Carry that observation into D-0141 as a named open item; a change
  needs its own decision.
- launchd schedules and any plist edit — see §6.
- Deploying. Merge is not deploy; launchd runs /Users/steveforte/fortel2-agents until
  deploy-agents.sh runs, and that is the operator's call.

## 10. Operator decisions to return, not resolve

Two, both on the DECISIONS NEEDED: line of your report:
  - The Morning Briefing prompt (§9).
  - Whether the REPLICA_HEAD_STALE_SECS margin gets its own decision, and when.

Do not decide either, and do not add a compatibility shim that guesses at the first one.

## 11. Argue if this is wrong

If you think keeping 600 is wrong, or the supersession should be an edit to D-0140
instead, or the §5 diagnosis is mistaken — argue it with evidence rather than
implementing it half-heartedly. The gap distribution in §2 is reproducible from
/Users/steveforte/src/fortel2/data-sepolia/logs/op-batcher.log on the operator's machine;
bring a counter-measurement, not a preference.

## 12. Return format

Emit this whole block inside ONE fenced code block so the operator can copy it in a
single click. Disclosure in the last fields counts as diligence, not failure.

TASK:        D-0141 — rebase #242 onto #241; keep 600, keep sleep suppression
LINE OF WORK: fix/alert-false-alarms-batcher-replica (force-with-lease, PR #242)
REVIEW ARTIFACT: https://github.com/StephenForte/ForteL2/pull/242
STATUS:      complete | complete-with-caveats | blocked

STATE:       <the §0 output, verbatim>
VERIFICATION: py_compile — pass/fail
              bash -n — pass/fail
              test_pipeline_snapshot.py — pass/fail, N tests
              test-helpers.sh unpinned — N PASS / N FAIL
              test-helpers.sh pinned to 01:30 PT — N PASS / N FAIL  (§5; must match)
              PASS-name diff vs origin/main — <added / removed / net>
              alert-watch.sh --help — pass/fail
              (all re-run against origin/main as of hand-back, sha <sha>)
MIGRATION:   none

CONFLICTS RESOLVED: <each hunk> — which side won and why
SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
CROSS-REFERENCES SWEPT: <every file/section grepped for 900 / stale D-0140 ownership /
                        "+3600 s always pages", and what you fixed>
IDENTIFIERS USED:     D-0141; next free id line set to D-0142
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens rather than
                          weakens. A clock pin is a pin — say so.   (or: none)
CLONE:               deleted <path>
TEMP:                <every temp path outside the repo> — deleted: yes/no
DECISIONS NEEDED:    the two in §10, plus anything else you hit
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly

The standing goal below authorises fixing CI failures and review-bot findings on this
change set. It does NOT authorise widening the §6 file scope, weakening or skipping
checks to resolve a conflict, restoring the 900 s floor, or resolving the §10 operator
decisions. Blocked by any of those: stop and report.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
