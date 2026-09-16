DISPATCH · alert-watch cloudflared edge-connection liveness
Runtime: ~1.5–3 h wall-clock (basis: the comparable replica-liveness task on this same
         file and test harness). No long phase; safe to dispatch at any hour.
Model: strong tier. Mechanically small, but it edits the alerting path that every other
       condition rides, and the failure mode is a silently disabled watcher.
Surface: Claude Code or Cursor.
Repository: StephenForte/ForteL2
            NOT fortel2-replica. These two repos are routinely conflated. alert-watch.sh
            lives in ForteL2. Merging ForteL2 deploys nothing to Render.
Baseline: origin/main @ b1dfa6c (verify yourself: git fetch && git rev-parse origin/main —
          trust the repo over this brief)
Branch: feat/alert-watch-cloudflared-edge
Host: any
Working directory: a fresh clone in a scratch dir. NEVER /Users/steveforte/ForteL2.
Teardown: delete the clone after the PR is pushed.
Landing: PR to main. Do not allocate a decision id; the planner writes the record at review.
Cost: zero. Loopback reads only. Adding a metered or authenticated call to close a
      monitoring gap is a defect (D-0123).
Silent-failure class: a watcher that passes its own tests while the existing 600+ tests
      quietly start talking to the operator's live cloudflared daemon.

## 0. FIRST — report what already exists, before changing anything

Run these and report the output verbatim as a STATE: block:

    git ls-remote --heads origin | grep -i cloudflared || echo "no remote branch"
    git branch -a --list '*cloudflared*' || echo "no local branch"
    ls tasks/worker-prompts/ 2>/dev/null | grep -i cloudflared || echo "no prior prompt file"

Then answer in your own words: have you done any work on this task before, in this or a
previous session? If yes — which files, committed, pushed? Did you at any point write to
/Users/steveforte/ForteL2, the operator's shared checkout? If you ran git stash / switch /
reset / checkout there, say so plainly. That is recoverable only if we know.

If a branch already exists, STOP and report. Do not reset it, force-push it, or cut a
differently-named branch to sidestep it.

If there is no prior work, say so explicitly and continue.

## 1. Clone — do not touch ~/ForteL2

This is a step, not a note. A previous worker ignored a clone named only in a header and
ran `git stash` in the shared checkout over another task's uncommitted work.

    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fortel2-aw-cfedge.XXXXXX")
    git clone git@github.com:StephenForte/ForteL2.git "$SCRATCH/ForteL2"
    cd "$SCRATCH/ForteL2"
    git fetch origin
    git checkout -b feat/alert-watch-cloudflared-edge origin/main

Run `pwd`. It must end in that clone path before any git switch, edit, or test.
Never stash / switch / reset in a folder whose branch you did not create.
Record $SCRATCH on the TEMP: line and delete it before handing back.

Commit this brief verbatim as tasks/worker-prompts/alert-watch-cloudflared-edge.md.

## 2. Read first

- scripts/alert-watch.sh — the whole file. In particular: the existing cloudflared-failing
  block (parse_cf_print, cf_token_hint, the cf_unhealthy ladder), the per-condition x channel
  cooldown and ALERT_REALERT_HOURS, the resolve_nonzero_streak block and the
  replica-unreachable streak (both are your precedent for "two consecutive, not one"), the
  ALERT_WATCH_REPLICA_* injection hooks (your precedent for offline test hooks), and the
  --help awk that prints header comments to the first non-comment line.
- scripts/test-helpers.sh — the cfw_run fixture around line 7730 onward, its launchctl shim
  that dispatches on print target, and the ALERT_WATCH_CLOUDFLARED_PLIST / _ERR overrides.
  Also aw_run and stk_run, and the native invocation that does `env -u ALERT_WATCH_PID_DIR`.
- tasks/decisions.md — D-0034 and D-0035 (the tunnel is dashboard-managed; origin is
  127.0.0.1:9555 only), D-0107 Finding 5 (why cloudflared-failing was added), D-0065 (a new
  production knob ships COMMENTED so an empty KEY= cannot override the default), D-0113
  Finding 2 and D-0134 (merge is not deploy).
- README.md — the "Ops alerting:" paragraph at line ~857. It is prose, not a table.
- .env.sepolia.example — the "Ops alerting" block at line ~273.
- launchd/README.md — the Cloudflare tunnel section. Read it; do not edit launchd/.

## 3. Why this task exists — measured, 2026-09-15

The existing cloudflared-failing condition checks whether the launchd *job* is running.
It cannot see a cloudflared process that is up and serving nothing. That is the same class
of defect the replica had on 2026-09-14: correct-looking liveness, no actual function,
found 12 h 40 m late by accident.

Evidence from the operator's Mac mini (supermini.local), collected 2026-09-15:

    $ launchctl print system/com.cloudflare.cloudflared | grep -E 'state|runs'
            state = running
            runs = 18624

    $ grep -c "Failed to read token file" /Library/Logs/com.cloudflare.cloudflared.err.log
    18622

    $ stat -f "%N birth=%SB" "/Library/Application Support/com.cloudflare.cloudflared/token"
    /Library/Application Support/com.cloudflare.cloudflared/token birth=Aug 27 12:41:51 2026

    $ sysctl -n kern.boottime
    { sec = 1787764782 } Wed Aug 26 10:19:42 2026

    first successful tunnel start in the err log:
    2026-08-27T19:41:57Z INF Starting tunnel tunnelID=64c3a080-44fa-4af6-9591-aba07d849757

Derivation. The plist sets ThrottleInterval=5 and KeepAlive SuccessfulExit=false. 18,622
instant failures x 5 s = 25.9 h of continuous crash-looping. Boot was Aug 26 10:19; the
token file was created Aug 27 12:41, 26.4 h later. Those two windows are the same window.
The tunnel was down for over a day after a reboot, and recovered only when a human noticed
and pasted a token from the dashboard. Rate: ~720 restarts/hour while looping.

A healthy daemon's `runs` counter does not move. The live one has sat at 18624 since
Aug 27. The current condition would not have alerted on a climbing counter, and it cannot
alert on a daemon with zero edge connections.

What is visible for free, on loopback, with no credential:

    $ curl -s http://127.0.0.1:20241/metrics | grep cloudflared_tunnel_ha_connections
    cloudflared_tunnel_ha_connections 4

That gauge is the number of registered edge connections. Four is healthy. Zero means the
process is running and the hostname is dark.

## 4. The property that must hold

The operator learns within hours that the write tunnel has stopped carrying traffic, even
while the launchd job reports `state = running`, using only loopback reads and no secret.

Use the existing cooldown machinery and ALERT_REALERT_HOURS. Do not invent a second
cooldown system. Do not weaken or reroute the existing cloudflared-failing condition — it
stays exactly as it is, and the new signals are additional distinct cooldown keys.

(a) NO EDGE CONNECTIONS. Alert when the daemon is running but the edge-connection count is
    zero. Mechanism is yours; the gauge above is the obvious source. State in the handoff
    what you read and how you parsed it.

(b) RESTART STORM. Alert when the launchd `runs` counter climbs between watcher runs. A
    healthy daemon holds a constant value; the measured loop added ~720/hour. Persist the
    previous observation in the existing alert-watch-state.json, following the
    resolve_nonzero_streak pattern. Choose a floor that tolerates a single legitimate
    restart (a brew upgrade, an operator kickstart adds 1) and fires on a loop. State the
    floor and the comparison operator in the handoff and test the exact boundary.

(c) METRICS UNREACHABLE is not an outage on one run. Follow the replica-unreachable
    precedent: two consecutive failed reads alert, a later success resets the streak. An
    explicit timeout is required — a hung read must never wedge the hourly :30 job.

(d) PLIST ABSENT STAYS QUIET. A host without /Library/LaunchDaemons/com.cloudflare.cloudflared.plist
    is a deliberate no-tunnel host. None of the new conditions may fire there. There is an
    existing test for this; it must stay green.

(e) NO MAC-SLEEP GRACE. The daemon is KeepAlive 24/7, not calendar-driven. Precedent is
    the existing cloudflared-failing condition, which already refuses the grace.

(f) ISOLATION. A metrics read that throws, times out, or returns garbage must not prevent
    funding-fail, health-stale, resolve-games, stack, cloudflared-failing, or the three
    replica conditions from evaluating and alerting on the same run.

If you think the split above is wrong — if one condition should cover both signals, or if
the runs counter is not worth persisting — argue it with evidence rather than implementing
it half-heartedly.

## 5. The trap — four ways this goes wrong

(1) DO NOT PROBE THE ORIGIN, AND DO NOT PROBE THE HOSTNAME END TO END.
    The origin 127.0.0.1:9555 is deliberately dark every night from 23:45 to 03:00 while
    the sequencer sleeps (D-0034 / D-0035). The tunnel stays up across that window by
    design. A probe of :9555, or of https://fortel2-write.ente.ltd, would page the operator
    every single night and be muted within a week — which is worse than having no watcher.
    Edge-connection count is the predicate because it is true while the origin is asleep.

(2) THE METRICS PORT IS NOT GUARANTEED.
    The installed plist does not pass --metrics. 127.0.0.1:20241 is cloudflared's default,
    but it binds elsewhere if that port is taken, and nothing in the repo pins it. Do not
    hardcode 20241 as the only possibility and call the task done. The err log records the
    real address on every start, in this exact form:
        2026-08-27T19:41:57Z INF Starting metrics server on 127.0.0.1:20241/metrics
    Whatever you choose — parse that line, default-with-override, or something better —
    say so in the handoff and explain how a moved port degrades. Degrading to condition (c)
    is acceptable; silently never alerting is not.

(3) EXISTING TESTS WILL START EXERCISING YOUR PROBE THE MOMENT YOU ADD IT.
    cfw_run, aw_run, stk_run and the native `env -u` path all evaluate the cloudflared
    block. If your probe reads loopback whenever hooks are unset, the suite talks to the
    operator's live daemon — and on a developer machine with no tunnel it will read nothing
    and start alerting, breaking "fresh JSON plus fresh logs is quiet."
    Required property, mechanism yours: test-only ALERT_WATCH_CLOUDFLARED_* hooks that
    inject canned metrics text and a canned runs value, and can inject unreachable/throw.
    When set, no socket is opened. EVERY existing evaluation path must default them to a
    HEALTHY daemon so current tests stay offline and quiet. Document the new keys in the
    alert-watch.sh header so --help prints them; do not replace the content-anchored awk
    with a hard-coded line range.

(4) DO NOT START A LISTENING SERVER IN THE TESTS.
    Not on 20241 — the live daemon holds it on the operator's machine — and not on a random
    port either. Inject canned metrics text through the hooks above. Never bind 9545-9551
    in tests under any circumstances. A test that leaves a listener behind is a finding
    against this task at review.

## 6. Scope

Freely changeable: scripts/alert-watch.sh

Additive only:
- scripts/test-helpers.sh — append cases; do not reorder or delete existing tests. Fixture
  edits injecting a canned HEALTHY daemon into cfw_run / aw_run / stk_run / the native
  env -u path are REQUIRED (see trap 3) and must be declared under EXISTING CHECKS MODIFIED
  as a strengthening of isolation, not a change to their assertions.
- README.md — the "Ops alerting:" paragraph only.
- .env.sepolia.example — only if you add production-tunable thresholds. Ship them COMMENTED
  (D-0065). ALERT_WATCH_* names must NEVER appear in any env file: lib.sh sources with
  `set -a`, so an env-file copy would silently override the test hooks in production.
  Secret lines stay empty.
- tasks/worker-prompts/alert-watch-cloudflared-edge.md — this brief, verbatim.

Do not touch:
- launchd/ plists — the alerts job already runs hourly at :30 and the new conditions ride
  it. Changing the schedule desynchronises the resolve-games two-cycle math.
- /Library/LaunchDaemons/com.cloudflare.cloudflared.plist or anything under
  /Library/Application Support — host configuration, operator-owned, and a separate open
  item. Fixing the token's durability is NOT this task.
- scripts/check-launchd.sh — its cloudflared section is deliberately read-only. Extending
  it is a reasonable idea and a different task.
- scripts/08-run-cloudflared-write.sh, config/cloudflared-write.yml.example — the retired
  manual-yaml path. Whether to migrate to it is an open operator decision, not yours.
- lib.sh, funding-watch.sh, resolve-games-sepolia.sh, deploy-agents.sh, start/stop scripts.
- deployments/, gateway/, replica/, tasks/decisions.md (planner-owned — no decision entry,
  no id), and any second alert channel.
- Any Cloudflare Access credential. Do not add CF_ACCESS_CLIENT_ID / _SECRET to this
  watcher. Loopback needs no auth, and putting a service token in the alerting path would
  be the first secret this script ever handled.

If the task appears to need something outside this surface, stop and report rather than
widening scope.

## 7. What must survive

- The existing cloudflared-failing condition, its id string, its body enrichment from the
  err log, and its plist-absent silence. All its tests stay green unchanged.
- Plist absent is never an alert, on any of the new conditions.
- OK / WARN / INSUFFICIENT never alert.
- Channel independence: banner and Resend each fire when the other is broken; any channel
  failure still exits nonzero.
- The --help output remains generated from the header comments by the content-anchored awk.

Existing checks may not be weakened, skipped, or deleted to make this change pass. If a
test legitimately must change because it encoded the behaviour being corrected, declare it
in the return block with before, after, and why it is a strengthening.

## 8. Tests

Offline, always. Cover at minimum: healthy daemon with edge connections (quiet); zero edge
connections while state is running (fires); runs counter constant (quiet); runs counter
climbing past your floor (fires); runs counter up by exactly one legitimate restart (quiet);
the exact boundary of whichever floor you chose; metrics unreachable once (quiet); twice
(fires); success after failure resets the streak; metrics read throws and all other
conditions still evaluate; plist absent and every new condition stays quiet; cooldown
respected across two runs.

Baseline: the suite is 622 tests. A clean clone with no .env shows 619 PASS / 3 FAIL —
those three are env-default tests reading .env.example and are not a regression. Report
your counts against that. Unexplained movement is itself a finding.

MUTATION TEST before handing off and paste the results. Break it in at least three ways —
invert the zero-edge comparison, remove the runs-counter floor, drop the unreachable-streak
reset — and name the specific test that goes red for each. A guard whose tests pass against
broken code is worse than no guard.

## 9. Deployment reality — put this in the handoff

launchd executes /Users/steveforte/fortel2-agents, a SEPARATE pinned clone, not ~/ForteL2.
Merging this PR changes nothing on the live host until ./scripts/deploy-agents.sh runs
(D-0113 Finding 2; D-0134 was caught by exactly this). Say so explicitly in your report so
the operator knows merge is not deploy.

## 10. Return block

Emit the whole block inside ONE fenced code block so it can be copied in a single click.

    STATE:        (from step 0 — prior work, branches, whether ~/ForteL2 was written to)
    TASK:         alert-watch cloudflared edge liveness — <one line>
    LINE OF WORK: feat/alert-watch-cloudflared-edge
    REVIEW ARTIFACT: <PR url>
    STATUS:       complete | complete-with-caveats | blocked
    VERIFICATION: each check named, pass/fail with counts, run against origin/main as of
                  hand-back (give the sha you compared to)
    MUTATION:     three breaks, and the named test that went red for each
    MIGRATION:    none
    SHARED FILES TOUCHED: <path> — what changed, why additive   (or: none)
    IDENTIFIERS USED:     none (planner allocates the decision id at review)
    EXISTING CHECKS MODIFIED: <path> — before → after; why this strengthens isolation
                              rather than weakening an assertion
    CLONE:        deleted <path>
    TEMP:         none | every temp path created outside the repo — deleted: yes/no
                  Also state plainly: did any test bind a listening port? Which?
    DECISIONS NEEDED: none | the question, and what you did in the interim
    RESIDUAL GAPS: must include — merge is not deploy (deploy-agents.sh); how you located
                  the metrics address and how it degrades if the port moves; the runs-counter
                  floor you chose and why; inclusive or exclusive comparisons; what you
                  verified by hand vs automatically.

Disclosure in the last three fields counts as diligence, not failure. A declared assertion
change is reviewable; a silent one is how a guarantee dies.
