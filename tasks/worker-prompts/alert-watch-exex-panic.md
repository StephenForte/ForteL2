DISPATCH · alert-watch names an ExEx panic instead of just saying the stack is down
Runtime: ~2-3 h wall-clock. Basis: #234 touched the same file and the same test
         harness and landed in that band. Safe to dispatch any hour. No spend,
         no metered calls, no network.
Model: strong tier. Small surface, but a false page on this condition trains the
       operator to ignore the alarm that exists for a chain-down event.
Surface: Claude Code or Cursor.
Repository: StephenForte/ForteL2
            NOT fortel2-replica.
Baseline: origin/main @ 0d82dd8 (verify yourself: git fetch && git rev-parse origin/main —
          trust the repo over this brief)
Branch: feat/alert-watch-exex-panic
Host: any with bash and python3
Working directory: a fresh clone in a scratch dir. NEVER /Users/steveforte/ForteL2.
Teardown: delete the clone after the PR is pushed.
Landing: PR to main. Do not allocate a decision id; the planner writes the record at review.
Silent-failure class: a condition that pages on a historical panic. The operator's live
      op-reth.log contains one from 2026-08-31 RIGHT NOW while the chain is healthy.

## 0. FIRST — report what already exists

Run these and report the output verbatim as a STATE: block:

    git ls-remote --heads origin | grep -iE 'exex|panic|alert' || echo "no remote branch"
    git branch -a --list '*exex*' '*panic*' '*alert*' || echo "no local branch"
    ls tasks/worker-prompts/ 2>/dev/null | grep -iE 'exex|panic' || echo "no prior prompt file"

Then answer: prior work on this task? Did you write to /Users/steveforte/ForteL2, the
operator's shared checkout? If you ran git stash / switch / reset / checkout there, say so
plainly — that is recoverable only if we know.

If a branch already exists, STOP and report.

## 1. Clone — do not touch ~/ForteL2

A previous worker ignored a clone named only in a header and ran `git stash` in the shared
checkout over another task's uncommitted work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-exex.XXXXXX")
    git clone git@github.com:StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git checkout -b feat/alert-watch-exex-panic origin/main

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and delete it before handing back.

Commit this brief verbatim as tasks/worker-prompts/alert-watch-exex-panic.md.

## 2. Read first

- tasks/decisions.md — **D-0138** in full (the outage this closes consequence (3) of),
  **D-0114 Finding 3** (the OTHER ExEx failure, with the opposite remedy), D-0139
  (log rotation, which changes how much history a tail can see), D-0113 F2 / D-0134.
- scripts/alert-watch.sh — the whole file. In particular `cf_token_hint` (reads the last
  64 KiB of a log as a body enricher and is explicitly "never the detector" — your closest
  precedent), the cooldown machinery and `ALERT_REALERT_HOURS`, the `stack-missing` /
  `stack-down` conditions, the cloudflared block added in #234, and the `ALERT_WATCH_*`
  test-hook convention.
- scripts/test-helpers.sh — the `register_cleanup` / `register_tmp` registry from #235 and
  the `scripts/test-log-hygiene.inc.sh` pattern from #238 (a separate `.inc.sh` sourced in
  a few lines, rather than appending hundreds of lines to a 12k-line file).
- scripts/lib.sh — `start_bg`, `PID_DIR`, `LOG_DIR`.

## 3. Why this task exists — D-0138, measured

On 2026-09-15 a deliberate reboot left op-reth crash-looping **12 times** on:

    thread 'tokio-rt' panicked at crates/node/builder/src/launch/exex.rs:130:41:
    ExEx proofs-history crashed: Parent hash mismatch at block 1045407:
      expected 0x21da8fae…8740, got 0x4635c036…3e46
    ERROR Critical task `exex` panicked
    ERROR shutting down due to error

The chain produced no blocks for 1 h 22 m. `alert-watch` fired `stack-down` and
`stack-missing` — correctly — but neither said **why**, so the operator had to seek the tail
of a 1.6 GB log to find out. D-0138 consequence (3) records that gap. This task closes it.

## 4. The property that must hold

When the chain is down because an ExEx panicked, the alert the operator receives **names
that cause**, and names it precisely enough to pick the right remedy — without ever firing
on a historical panic.

Mechanism is yours. A strong candidate is enriching the existing `stack-missing` /
`stack-down` body rather than adding a standalone condition, following the `cf_token_hint`
precedent where the log is the *detail* and process state is the *trigger*. If you add a
distinct condition instead, it needs its own cooldown key and must not double-page
alongside `stack-down`. Argue whichever you choose.

**The two ExEx failures have OPPOSITE remedies and must not be conflated:**

| panic text | meaning | remedy |
|---|---|---|
| `Proofs storage not initialized` | store missing (D-0114 F3) | run `op-reth proofs init` — the start script already does this idempotently |
| `Parent hash mismatch at block N` | store divergent (D-0138) | **delete** `$DATADIR/historical-proofs`, then start |

An alert that says "ExEx panicked" without distinguishing these sends the operator toward
init when they need deletion, or the reverse. Quote enough of the matched line that the
operator can tell, or classify explicitly.

## 5. The trap — five ways this goes wrong

(1) **THE LIVE LOG ALREADY CONTAINS A PANIC AND THE CHAIN IS HEALTHY.** This is not
    hypothetical and it is the whole difficulty of this task. On the operator's Mac right
    now, `data/logs/op-reth.log` (1.6 GB) contains:

        2026-08-31T15:46:28Z ERROR Critical task `exex` panicked:
          `ExEx proofs-history crashed: Proofs storage not initialized…`

    …from **sixteen days ago**, while op-reth is running normally (pid alive). A condition
    that greps the log for the panic string pages immediately, against a healthy chain,
    citing a stale line, and recommends the wrong remedy. **Your condition must be silent
    on the operator's real host today.** Say in the handoff how you establish that a match
    is current. mtime of the log is NOT sufficient — the file is appended constantly by
    unrelated lines. Anchors worth considering: the op-reth pidfile and whether that pid is
    alive; the process start time; the position of the match relative to the last start
    banner; whether the match is in the final N bytes. Pick one, justify it, and test the
    stale case explicitly.

    Context for why this trap is stated so forcefully: during D-0138 the planner read stale
    lines from an untimestamped log as current **three times in one evening** and produced
    three confident wrong claims. Do not rebuild that failure inside the alerting system.

(2) **DO NOT READ A 1.6 GB FILE.** #238 caps logs at 100 MiB with five copies, but that is
    only applied from the next start and the existing file is untouched. Read a bounded
    tail. `cf_token_hint` reads the last 64 KiB; match that order of magnitude or justify
    more. The watcher runs hourly on the machine running the chain — it must not cause
    a multi-second read or a memory spike.

(3) **ISOLATION.** A missing log, an unreadable one, a garbage decode, or a throw inside
    your scan must not prevent funding-fail, health-stale, resolve-games, stack-*,
    cloudflared-*, or the three replica conditions from evaluating and alerting on the same
    run. #234 established this pattern; follow it.

(4) **EXISTING TESTS WILL START EXERCISING YOUR SCAN.** Every alert-watch fixture will now
    hit whatever path you add. If it reads a real host path when hooks are unset, the suite
    touches the operator's live 1.6 GB log. Provide `ALERT_WATCH_*` test hooks that inject
    a canned log path or canned contents, default every existing runner to a HEALTHY/quiet
    value, and document the new keys in the alert-watch.sh header so `--help` prints them.
    **`ALERT_WATCH_*` names must never appear in any env file** — `lib.sh` sources with
    `set -a`, so an env-file copy would override the hook in production.

(5) **DO NOT `trap … EXIT` IN test-helpers.sh.** #235 replaced 45 clobbering traps with one
    registry; adding a trap drops the list. Use `register_cleanup` / `register_tmp`, and
    prefer a new `scripts/test-exex-alert.inc.sh` sourced in a few lines over appending
    hundreds of lines, as #238 did.

## 6. Scope

Freely changeable: scripts/alert-watch.sh

Additive only:
- scripts/test-helpers.sh — a few lines sourcing your new `.inc.sh`. Do not reorder or
  delete existing tests.
- scripts/test-exex-alert.inc.sh — new file, your tests.
- README.md — the "Ops alerting:" paragraph (prose, not a table).
- .env.sepolia.example — only if you add a production-tunable threshold, COMMENTED (D-0065).
- tasks/worker-prompts/alert-watch-exex-panic.md — this brief, verbatim.

Do not touch:
- launchd/ plists — the alerts job already runs hourly at :30 and this rides it. Changing
  the schedule desynchronises the resolve-games two-cycle math.
- scripts/rotate-logs.sh or the start scripts — #238 just landed there.
- scripts/resolve-games-sepolia.sh — money path, unrelated.
- Anything that would make alert-watch *act* on a panic. This condition reports; it never
  restarts a service, deletes a store, or touches DATA_DIR. Recovery from a divergent
  proofs store is operator-run by decision (D-0138) because it destroys tens of GB.
- tasks/decisions.md (planner-owned), deployments/, gateway/.

If the task appears to need something outside this surface, stop and report.

## 7. What must survive

- Every existing condition, its id string, its cooldown key, and its tests.
- `stack-missing` / `stack-down` keep firing on their existing triggers whether or not a
  panic is found. The panic is extra information, never a replacement trigger.
- Plist-absent silence for the cloudflared conditions; OK/WARN/INSUFFICIENT never alert.
- Channel independence and the nonzero exit on channel failure.
- `--help` output stays generated from the header comments by the content-anchored awk.

Existing checks may not be weakened, skipped, or deleted. If one legitimately must change,
declare it with before, after, and why it is a strengthening.

## 8. Tests and verification

Offline, always. No test may read a real host log path.

Cover at minimum: a fresh panic with op-reth down (alerts, names the cause); the **stale**
panic with op-reth healthy (**silent** — this is the headline test); both panic classes
distinguished from each other (`Proofs storage not initialized` vs `Parent hash mismatch`);
log missing; log unreadable; log present with no panic; a throw inside the scan while every
other condition still evaluates; cooldown respected across two runs; and a tail-bounded read
proven against a file larger than your window.

Baseline after #238: **650 PASS / 3 FAIL** in a clean clone with no `.env`. The three are the
`.env.example` env-default tests (`FORTEL2_CUTOVER_GAME_L2_BLOCK`, `safedb-enable-l1`,
`pre-enable-l1`) reporting `WARN: no .env found`. **Read the FAIL lines in full, do not just
count them.**

Gotcha that has cost two reviewers a detour: the `gas-runway fixture output leaked
private/quiknode` assertion greps case-insensitively for `private|quiknode` in output
containing fixture paths, so it **false-fails when your clone's path contains "private"** —
on macOS that includes the real `/private/tmp`. Check your path before reporting it.

Do not bind ports 9545–9551 — the operator's live sequencer owns that range.
Do not leave a listener running.

MUTATION TEST before handing off and paste the results. Break it four ways — remove the
recency anchor, remove the two-class distinction, remove the tail bound, and remove the
isolation guard — and name the specific test that goes red for each.

## 9. Deployment reality — put this in the handoff

launchd executes /Users/steveforte/fortel2-agents, a SEPARATE pinned clone. Merging changes
nothing until `./scripts/deploy-agents.sh` runs (D-0113 F2 / D-0134). Say so explicitly.

## 10. Return block

Emit the whole block inside ONE fenced code block.

    STATE:        (from step 0)
    TASK:         alert-watch ExEx panic attribution — <one line>
    LINE OF WORK: feat/alert-watch-exex-panic
    REVIEW ARTIFACT: <PR url>
    STATUS:       complete | complete-with-caveats | blocked
    VERIFICATION: 650/3 counts vs origin/main <sha>; the stale-panic-silent result;
                  the two-class distinction result; the tail-bound proof
    MUTATION:     four breaks, and the named test that went red for each
    MECHANISM:    enrichment vs standalone condition and why; the recency anchor you chose
                  and why mtime alone is insufficient; the tail window and why
    MIGRATION:    none
    SHARED FILES TOUCHED: <path> — what changed, why additive   (or: none)
    IDENTIFIERS USED:     none (planner allocates the decision id at review)
    EXISTING CHECKS MODIFIED: <path> — before → after; why this strengthens  (or: none)
    CLONE:        deleted <path>
    TEMP:         none | every temp path created outside the repo — deleted: yes/no
                  Did any test bind a listening port? Which?
    DECISIONS NEEDED: none | the question, and what you did in the interim
    RESIDUAL GAPS: must include — merge is not deploy; whether your condition would be
                  silent on the operator's real host today given the 2026-08-31 panic in
                  the live log, and how you know; what you verified by hand vs automatically.

Disclosure in the last three fields counts as diligence, not failure.

If you think enrichment is the wrong shape — or that this belongs somewhere other than
alert-watch — argue it with evidence rather than implementing this half-heartedly.

The standing goal below authorises fixing CI and review-bot findings on this change set. It
does not authorise widening the file scope in §6, weakening or skipping checks to go green,
or making alert-watch take any recovery action. If it pushes against those boundaries, stop
and report.
