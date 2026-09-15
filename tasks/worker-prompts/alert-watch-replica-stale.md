DISPATCH · alert-watch replica liveness
Repository: StephenForte/ForteL2
Baseline: origin/main @ 725963a (verify yourself: git fetch && git rev-parse origin/main —
          trust the repo over this brief)
Branch: feat/alert-watch-replica-stale
Landing: PR to main. Do not allocate a decision id; the planner writes the record at review.
Silent-failure class: a green suite that actually curls the live gateway, or a trend
predicate that pages on jitter or on a converging catch-up, is worse than no patch.

## 0. FIRST — report what already exists, before changing anything

Two earlier versions of this task may have been dispatched. Before you start, run these
and report the output verbatim as a STATE: block:

    git ls-remote --heads origin | grep -i alert-watch || echo "no remote branch"
    git branch -a --list '*alert-watch*' || echo "no local branch"
    ls tasks/worker-prompts/ 2>/dev/null | grep -i alert || echo "no prior prompt file"

Then answer, in your own words:
  - Have you done ANY work on this task already, in this session or a previous one?
  - If yes: what files did you change, is it committed, is it pushed, and was it built
    against the WITHDRAWN design (absolute head age as the primary predicate) or the
    current one (trend primary, absolute age as backstop)?
  - Did you at any point write to /Users/steveforte/ForteL2, the operator's shared
    checkout? If you ran git stash / switch / reset / checkout there, say so plainly —
    that is recoverable but only if we know.

If a branch already exists, STOP and report. Do not reset it, do not force-push it, do
not cut a differently-named branch to sidestep it. Wait for instruction.

If the answer is "no prior work," say so explicitly and continue to step 1.

## 1. Clone — do not touch ~/ForteL2

This is a step, not a note. A previous worker ignored a clone named only in a header and
ran `git stash` in the shared checkout over another task's uncommitted work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-aw-replica.XXXXXX")
    git clone git@github.com:StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git checkout -b feat/alert-watch-replica-stale origin/main

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and delete it before handing back.

Commit this brief verbatim as tasks/worker-prompts/alert-watch-replica-stale.md.

## 2. Read first

- tasks/decisions.md — D-0135 (the 12.7 h stall; its Consequence (1) is this task),
  D-0123 (free-vs-metered L1 provider rule), D-0134 (deploy-agents is separate from merge).
- scripts/alert-watch.sh — the whole file. Conditions, the per-condition×channel cooldown
  and ALERT_REALERT_HOURS, the resolve_nonzero_streak block (your precedent for
  "consecutive"), cloudflared-failing's refusal of Mac-sleep grace (your precedent for
  "Render does not sleep"), the ALERT_WATCH_* test-only override naming convention (these
  must never appear in env files — lib.sh sources with set -a), curl --max-time 20 on
  Resend, and the --help awk that prints header comments to the first non-comment line.
- scripts/test-helpers.sh — the evaluation fixtures aw_run, stk_run, cfw_run, plus the
  native invocation that does `env -u ALERT_WATCH_PID_DIR`. Also the --help assertions and
  the cooldown two-run case (it asserts curl.calls stays 1).
- README.md — the "Ops alerting:" paragraph. It is prose, not a table. Extend it.
- .env.sepolia.example — ops-alerting block, and the D-0065 rule: a new production knob
  ships COMMENTED so an empty KEY= cannot override the default.
- deployments/rail-interface.json — replica.readRpcUrl. Read it; do not edit deployments/.

## 3. Why this task exists

2026-09-14: the Render replica stopped deriving at 08:12:14 PDT (L2 head 982723, hash
0xa4792f33…8ad6 — identical on the sequencer, so stalled, not forked) and was found at
20:52 PDT, 12 h 40 m later, only because a human was reviewing an unrelated PR. It
answered JSON-RPC correctly the entire time. Only the head was frozen. Nothing in
alert-watch.sh can see this: every existing condition watches the Mac.

A duration-only design was considered and WITHDRAWN. It assumed replay is bounded, so a
3 h absolute age would catch a wedge and spare a healthy catch-up. That is false.
Measured 2026-09-15 after a restart on the public L1 endpoint: the replica derived at
0.35 L1 blocks/min against Sepolia's ~5/min and never converged — tip frozen 3 h+, gap
widening. A slow-but-healthy node and a wedged node both show a flat EL tip and a growing
head age. They are not separable by age alone.

The public gateway proxies to op-reth, not op-node, so optimism_syncStatus and current_l1
are NOT reachable. Do not adopt a predicate that needs op-node.

What is visible for free is the head-age TREND across watcher runs.

## 4. The property that must hold

The operator learns within hours — not half a day — that the public replica has stopped
following the chain, using only free calls.

Two distinct cooldown keys; do not collapse them. Use the existing cooldown machinery and
ALERT_REALERT_HOURS. Do not invent a second cooldown system.

(a) PRIMARY — losing ground. Alert when head age increases across consecutive successful
    probes: the head timestamp advanced slower than wall clock. This is what both the
    hard wedge and the slow decay look like from the EL. It must NOT fire when a catch-up
    is converging (head age decreasing), and must NOT fire on a healthy follower whose
    age jitters around the normal ~3 min batch lag.

    A single sample cannot compute a trend. Persist the previous successful observation
    (wall time + head timestamp, or equivalent) in the existing alert-watch-state.json.
    Follow the resolve_nonzero_streak pattern: one observation is not an outage, two are.

    Pick an explicit noise floor so 3 min → 3 min + 5 s is not "losing ground." A
    following node jitters by seconds; an hourly sample on a frozen head grows by ~3600 s.
    The floor must sit clearly between those. State the floor and the comparison operator
    in the handoff.

(b) BACKSTOP — absolute age. Alert when a single successful probe shows head age past an
    absolute threshold, even with no prior sample: first run after deploy, wiped state,
    or the watcher itself down overnight. Suggested default 3 h (10800 s) — that would
    have fired at 11:12 PDT on 2026-09-14 with no prior state. This is no longer the
    replay/wedge discriminator; it is the safety net when trend has nothing to compare.
    If you pick a different value, argue it. State inclusive vs exclusive (health-stale
    uses age > threshold) and test the exact boundary.

(c) UNREACHABLE is not an outage on one run. Two consecutive failed observations
    (timeout, HTTP failure, garbage JSON, missing timestamp) alert; a later success
    resets the streak. Explicit --max-time; a hung gateway must never wedge the hourly
    :30 job. A failed probe must NOT overwrite the last successful head sample the trend
    depends on — say in the handoff how you handled that.

(d) ISOLATION FROM THE OTHER CONDITIONS. A replica-probe throw, timeout, or garbage
    return must not prevent funding-fail / health-stale / resolve-games / stack /
    cloudflared from evaluating and alerting on the same run.

(e) NO MAC-SLEEP GRACE. The replica is on Render; it does not sleep at 23:45. Precedent
    is cloudflared-failing. Across the 23:45–03:30 gap a healthy replica still has a small
    head age at 03:30; a frozen one has an age grown by the whole gap. Do not skip these
    conditions on slept == true.

(f) DO NOT alert on replica lag behind the sequencer. Different signal, different tuning,
    and it needs a second endpoint. Head-timestamp age and its trend are the predicates.

URL: the published public-read gateway, https://fortel2-replica-rpc.onrender.com,
hardcoded or defaulted. Never QuickNode — adding metered spend to close a monitoring gap
is a defect (D-0123). Never the Access write hostname. Never a loopback sequencer URL.
One eth_getBlockByNumber(latest) is enough; argue for any second live call.

If you think trend-plus-backstop is the wrong split, argue it with evidence rather than
implementing it half-heartedly.

## 5. Scope

Freely changeable: scripts/alert-watch.sh

Additive only:
- scripts/test-helpers.sh — append cases; do not reorder or delete existing tests.
  Fixture edits injecting a canned FRESH head into aw_run / stk_run / cfw_run / the
  native env -u path are REQUIRED (see the trap) and must be declared under EXISTING
  CHECKS MODIFIED as a strengthening of isolation, not a change to their assertions.
- README.md — the ops-alerting paragraph only.
- .env.sepolia.example — only if you add production-tunable thresholds; comment them
  (D-0065). No real URL that differs from rail-interface.json. Secret lines stay empty.
- tasks/worker-prompts/alert-watch-replica-stale.md — this brief, verbatim.

Do not touch: any other script (lib.sh, funding-watch.sh, resolve-games-sepolia.sh,
deploy-agents.sh, start/stop are adjacent and stable); launchd/ plists (the alerts job
already runs hourly at :30 and the new conditions ride it — changing the schedule
desynchronises the resolve-games two-cycle math); deployments/; gateway/; replica/;
L1_RPC_FORCE or any Render config (recovery is operator-owned and already done);
tasks/decisions.md (planner-owned — no decision entry, no id); a second alert channel.

If the task appears to need something outside this surface, stop and report rather than
widening scope.

## 6. The trap — three ways this goes wrong

(1) EXISTING TESTS WILL START EXERCISING YOUR PROBE the moment you add it.
    - If the probe curls the live gateway whenever hooks are unset, every aw_run /
      stk_run / cfw_run hits the network (forbidden) and can false-alert against a
      genuinely stale replica, breaking "fresh JSON + fresh logs is quiet."
    - If you reuse ALERT_WATCH_CURL without a canned-head short-circuit, the existing
      Resend shim returns {"id":"mock-resend"} for every URL. That is garbage input. The
      cooldown test runs the watcher twice, replica-unreachable fires on the second, and
      the assertion that curl.calls stays 1 goes red.

    Required property (mechanism is yours): test-only ALERT_WATCH_REPLICA_* hooks that
    inject a canned head number and timestamp, and can inject unreachable/throw. When
    set, no network. EVERY existing evaluation path must default them to a FRESH head so
    current tests stay offline and quiet. Document the new keys in the alert-watch.sh
    header so --help prints them; do not replace the content-anchored awk with a
    hard-coded line range.

(2) A FIXED "FRESH" TIMESTAMP IS A FROZEN HEAD. The cooldown test runs the watcher twice
    within about a second. If both evaluations see the same unix timestamp, head age grew
    by that second, and a naive age2 > age1 pages replica-losing-ground and breaks the
    cooldown count. Do NOT weaken the production noise floor to "any increase" to make
    back-to-back tests green — that would also page healthy jitter. Fresh must mean
    age ≈ 0 at evaluation time, each run. Trend tests that need "an hour of freeze" seed
    the PRIOR observation in the state file instead.

(3) THE PREDICATE ITSELF. Prove it against both real measurements, not invented ones:
    - healthy follower, age oscillating around ~180 s        -> must stay quiet
    - the 2026-09-15 decay, age growing ~3600 s per hourly run -> must fire
    - a converging catch-up, age falling 12000 s -> 90 s      -> must stay quiet
    That third case is the one a careless trend predicate gets wrong, and it is exactly
    what the replica did this morning while recovering.

## 7. Tests

Offline, always. Cover at minimum: fresh head; trend losing ground (fires on the second
consecutive observation, not the first); trend converging (quiet); jitter at the noise
floor (quiet) and just past it (fires); backstop with no prior state; backstop exact
boundary; unreachable once (quiet); unreachable twice (fires); success after failure
resets the streak; probe throws and the other five conditions still evaluate; cooldown
respected across two runs.

MUTATION TEST before handing off and paste the results. Break it in at least three ways —
invert the trend comparison, remove the noise floor, drop the unreachable-streak reset —
and name the specific test that goes red for each. A guard whose tests pass against
broken code is worse than no guard.

## 8. Deployment reality — put this in the handoff

launchd runs /Users/steveforte/fortel2-agents, a SEPARATE clone, not ~/ForteL2. Merging
changes nothing on the live host until ./scripts/deploy-agents.sh runs (D-0113 Finding 2;
D-0134 was caught by exactly this). Say so explicitly so the operator knows merge ≠ deploy.

## 9. Return block

STATE:        (from step 0 — prior work, branches, whether ~/ForteL2 was written to)
TASK:         alert-watch replica liveness — <one line>
REVIEW ARTIFACT: <PR url>
STATUS:       complete | complete-with-caveats | blocked
VERIFICATION: each check named, pass/fail with counts, run against origin/main as of
              hand-back (give the sha you compared to)
MUTATION:     three breaks, and the named test that went red for each
SHARED FILES TOUCHED: <path> — what changed, why additive   (or: none)
EXISTING CHECKS MODIFIED: <path> — before → after; why this strengthens isolation
                          rather than weakening an assertion
DECISIONS NEEDED: none | the question, and what you did in the interim
CLONE:        deleted <path>
TEMP:         none | every temp path created outside the repo — deleted: yes/no
RESIDUAL GAPS: must include — merge is not deploy (deploy-agents.sh); the noise floor you
              chose and why; backstop inclusive or exclusive; how a failed probe treats
              the last good sample; what you verified by hand vs automatically.
