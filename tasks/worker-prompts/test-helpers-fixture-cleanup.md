DISPATCH · test-helpers.sh leaks a fixture directory on every run
Runtime: ~1–2 h wall-clock. Mechanical change; the effort is in verification.
         Safe to dispatch at any hour. No spend, no metered calls.
Model: mid tier. Small surface, but it edits the file every other task appends to,
       and a careless fix silently disables existing cleanup.
Surface: Claude Code or Cursor.
Repository: StephenForte/ForteL2
            NOT fortel2-replica. scripts/test-helpers.sh lives in ForteL2.
Baseline: origin/main @ 71691ae (verify yourself: git fetch && git rev-parse origin/main —
          trust the repo over this brief)
Branch: fix/test-helpers-fixture-cleanup
Host: any with bash and python3
Working directory: a fresh clone in a scratch dir. NEVER /Users/steveforte/ForteL2.
Teardown: delete the clone after the PR is pushed.
Landing: PR to main. Do not allocate a decision id; the planner writes the record at review.
Silent-failure class: a "fix" that adds more `trap … EXIT` lines, which in bash REPLACE
      rather than accumulate — leaving the leak in place while looking fixed.

## 0. FIRST — report what already exists

Run these and report the output verbatim as a STATE: block:

    git ls-remote --heads origin | grep -iE 'cleanup|fixture|trap' || echo "no remote branch"
    git branch -a --list '*cleanup*' '*fixture*' || echo "no local branch"
    ls tasks/worker-prompts/ 2>/dev/null | grep -iE 'cleanup|fixture' || echo "no prior prompt file"

Then answer: have you done any work on this task before? Did you at any point write to
/Users/steveforte/ForteL2, the operator's shared checkout? If you ran git stash / switch /
reset / checkout there, say so plainly — that is recoverable only if we know.

If a branch already exists, STOP and report. Do not reset or force-push it.

## 1. Clone — do not touch ~/ForteL2

This is a step, not a note. A previous worker ignored a clone named only in a header and
ran `git stash` in the shared checkout over another task's uncommitted work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-fixclean.XXXXXX")
    git clone git@github.com:StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git checkout -b fix/test-helpers-fixture-cleanup origin/main

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and delete it before handing back.

Commit this brief verbatim as tasks/worker-prompts/test-helpers-fixture-cleanup.md.

## 2. Read first

- scripts/test-helpers.sh — you do not need to read all ~12k lines, but you must read every
  `trap … EXIT` site and the fixture setup around each. There are 27 cleanup functions
  registered on EXIT.
- The two patterns already in the file, so you match the working one:
    CORRECT   line 4664  trap cleanup_aw_fix EXIT
              line 5018  cleanup_aw_fix          <- explicit call
              line 5019  trap - EXIT             <- then clears
    BROKEN    line 10398 cleanup_prr() { rm -rf "$PRR_FIX"; }
              line 10399 trap cleanup_prr EXIT   <- registered, never called, never cleared
              line 10689 trap 'cleanup_wd_fix; cleanup_fixtures …' EXIT  <- REPLACES it
- tasks/decisions.md — D-0113 Finding 2 and D-0134 (merge is not deploy; launchd runs the
  pinned clone). Nothing in this task changes runtime behaviour, but say so in the handoff.

## 3. Why this task exists — measured 2026-09-15

Found during review of PR #234, on the operator's Mac:

    $ ls -d "${TMPDIR}"fortel2-pin-runtime-root.* | wc -l
    64
    $ du -shc "${TMPDIR}"fortel2-pin-runtime-root.*  | tail -1
    47M     total

A single gate run adds one more. The reviewer's own run created
`fortel2-pin-runtime-root.WUwP0X` at 18:20. Over 180 leaked entries totalling ~53 MB had
accumulated across `pin-runtime-root`, `wd-sepolia`, `viewer`, and `sepolia-env` prefixes
before they were cleaned by hand.

The mechanism, confirmed:

    $ bash -c 'trap "echo FIRST" EXIT; trap "echo SECOND" EXIT; true'
    SECOND

Bash `trap … EXIT` **replaces** the handler; it does not append. `cleanup_prr` is registered
at 10399 and then overwritten at 10689, so it never runs. That one is proven.

**What is NOT proven, and is yours to establish:** `wd-sepolia`, `viewer`, and
`sepolia-env` also leaked, even though `cleanup_wd_fix` and `cleanup_fixtures` DO appear in
the final inline trap at 10689. So there is at least one more mechanism — an early exit path
that skips the EXIT trap, a reassigned fixture variable, a subshell, or a `set -e` abort.
Do not assume the clobbering explanation covers all four. Find the actual cause for each
prefix and say what it was.

## 4. The property that must hold

**A full run of `./scripts/test-helpers.sh` leaves zero net new entries under `$TMPDIR`
and `/tmp`.** That is the acceptance test, and it is measurable:

    before=$(ls -d "${TMPDIR}"fortel2-* /tmp/fortel2-* 2>/dev/null | wc -l)
    ./scripts/test-helpers.sh > /dev/null 2>&1
    after=$(ls -d "${TMPDIR}"fortel2-* /tmp/fortel2-* 2>/dev/null | wc -l)
    echo "before=$before after=$after delta=$((after-before))"

`delta` must be **0**. Paste that output in the handoff, for a run that starts from a
already-clean $TMPDIR.

Mechanism is yours. Options include calling each cleanup explicitly then `trap - EXIT`
(matching the working pattern at 4664/5018/5019), or a single accumulating cleanup registry
that one EXIT trap drains. If you choose the registry, it must survive the file's existing
convention that parallel tasks append new fixture blocks at the end — say in the handoff how
a future appender registers correctly, because they will not read this brief.

Do not "fix" this by adding more `trap … EXIT` lines. That is the bug.

## 5. Scope

Freely changeable: scripts/test-helpers.sh

Additive only:
- tasks/worker-prompts/test-helpers-fixture-cleanup.md — this brief, verbatim.

Do not touch:
- scripts/resolve-games-sepolia.sh — line 1202 creates `fortel2-resolve-one.XXXXXX` and 67
  of those were also found on the host. It is a REAL leak, but that script is the live
  hourly L1 bond-recovery agent — a money path. It is deliberately excluded and is an
  operator decision, not yours. Do not touch it even if a test you are fixing exercises it.
- scripts/alert-watch.sh and every other script — the cloudflared work just landed there
  (#234) and nothing in this task requires it.
- launchd/, deployments/, gateway/, .env.sepolia.example, tasks/decisions.md (planner-owned).
- Any test ASSERTION. You are changing cleanup, not what is asserted.

If the task appears to need something outside this surface, stop and report rather than
widening scope.

## 6. The trap — three ways this goes wrong

(1) ADDING TRAPS INSTEAD OF FIXING THEM. Covered above. Every `trap … EXIT` you add
    silently disables the previous one. If your change increases the number of EXIT trap
    registrations, you have probably made it worse, not better.

(2) DELETING A DIRECTORY A LATER TEST STILL NEEDS. Some fixtures are created early and
    referenced hundreds of lines later. If you move a cleanup call earlier to make the
    accounting tidy, tests that read that path will fail — possibly not the test you were
    looking at. The suite must still pass at its full count (see §7). If a test goes red,
    that is the signal, not an inconvenience to work around by skipping it.

(3) CLEANUP THAT RUNS ON SUCCESS BUT NOT ON FAILURE. The point of an EXIT trap is that it
    fires when the script dies. If your fix only cleans on the happy path, an aborted run
    still litters — and aborted runs are exactly when a developer is iterating and running
    the suite over and over. Prove this: kill the suite partway (`SIGINT` after ~20 s) and
    show $TMPDIR is still clean afterwards. Include that measurement.

## 7. Tests and verification

Baseline on the operator's platform, measured 2026-09-15 on `b1dfa6c` in a clean clone with
no `.env`: **635 PASS / 3 FAIL**. The three FAILs are the `.env.example` env-default tests
(`FORTEL2_CUTOVER_GAME_L2_BLOCK`, `safedb-enable-l1`, `pre-enable-l1`), each reporting
`WARN: no .env found`. They are not a regression. Read the FAIL lines, do not just count
them — a grep piped into `head` has truncated failures out of view on this repo before.

Required in the handoff:
  - PASS/FAIL counts against origin/main as of hand-back, with the sha you compared to.
    Unexplained movement in either direction is itself a finding.
  - The `delta=0` measurement from §4, for a clean-start run.
  - The interrupted-run measurement from trap (3).
  - A count of `trap … EXIT` registrations before and after your change.

No new test framework. If you add a self-check that the suite leaves no litter, it must not
itself create a listener or a fixture it fails to remove.

Do not bind anything in ports 9545–9551 — that range is the operator's live sequencer.

## 8. Return block

Emit the whole block inside ONE fenced code block so it can be copied in a single click.

    STATE:        (from step 0 — prior work, branches, whether ~/ForteL2 was written to)
    TASK:         test-helpers.sh fixture cleanup — <one line>
    LINE OF WORK: fix/test-helpers-fixture-cleanup
    REVIEW ARTIFACT: <PR url>
    STATUS:       complete | complete-with-caveats | blocked
    VERIFICATION: PASS/FAIL counts vs origin/main <sha>; the §4 delta=0 measurement;
                  the interrupted-run measurement; trap-registration count before/after
    MECHANISM:    for EACH leaking prefix (pin-runtime-root, wd-sepolia, viewer,
                  sepolia-env) — what actually caused it to leak, and what you changed
    MIGRATION:    none
    SHARED FILES TOUCHED: <path> — what changed, why additive   (or: none)
    IDENTIFIERS USED:     none (planner allocates the decision id at review)
    EXISTING CHECKS MODIFIED: <path> — before → after; why this strengthens rather than
                              weakens                            (or: none)
    CLONE:        deleted <path>
    TEMP:         none | every temp path created outside the repo — deleted: yes/no
                  Also: did any test bind a listening port? Which?
    DECISIONS NEEDED: none | the question, and what you did in the interim
    RESIDUAL GAPS: must include — how a future appender registers cleanup correctly;
                  whether resolve-games-sepolia.sh:1202 still leaks (it is out of scope,
                  so the answer is yes — say so rather than fixing it); what you verified
                  by hand vs automatically.

Disclosure in the last three fields counts as diligence, not failure.

If you think the whole approach is wrong — if the leak should be fixed some other way, or
if you find the cause is something other than trap clobbering — argue it with evidence
rather than implementing this half-heartedly.

The standing goal below authorises fixing CI and review-bot findings on this change set. It
does not authorise widening the file scope in §5, weakening or skipping checks to go green,
or touching resolve-games-sepolia.sh. If it pushes against those boundaries, stop and report.

/goal keep this PR merge-ready: fix failing CI checks and bot review comments until everything passes.
