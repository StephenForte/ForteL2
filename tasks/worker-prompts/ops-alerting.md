# Worker brief — ops-alerting: alert on funding-watch FAIL and a dead recovery agent

```
DISPATCH · Model: Sonnet 5 · Order: standalone; nothing else in flight touches these files
Surface: Claude Code worker session, launched by the operator via the desktop app (branch dropdown)
Baseline: main @ 5526ed2 · branch feat/ops-alerting (pre-created off that sha — use it, do not cut your own)
Host: the operator's Mac only (darwin) — launchd, osascript, and the live health artifacts exist nowhere else
Working directory: /Users/steveforte/ForteL2 (the app isolates the session; see working-copy rule below)
Landing: PR to main. The reviewer commits decision D-0089 onto this branch; merging closes the
"alerting" item from D-0088's cleanup tail.
```

Copy everything below the line into the worker.

---

## Task

ForteL2 has two silent-death blind spots. Close both with a watcher that notifies the operator
via a macOS notification banner AND an email through the Resend HTTP API.

**Read first** (these govern the work; trust the repo over this brief — every status claim here
is a snapshot from dispatch time):

- `scripts/funding-watch.sh` — full header comment (verdict semantics, endpoint trust model,
  and the `set -a` env-override note at ~L72).
- `refresh_health.sh` — how the daily 05:00 health agent invokes funding-watch.
- `launchd/com.steve.fortel2-resolve-games.plist` — both XML comments (calendar-interval
  rationale, log-path rule). Model your plist on this file.
- `scripts/check-launchd.sh` — header only: it auto-enumerates `launchd/com.steve.fortel2-*.plist`,
  so your new plist is picked up with zero changes there.
- `.env.sepolia.example` — the secret-hygiene rules in its comments, and the tripwire added by
  PR #145 (secret-named lines must stay empty in the example; leak reporting is names-only).
- `scripts/test-helpers.sh` — the funding-watch test block (~L1112) for harness idiom, and
  `_f710_key_leaked` for the no-leak assertion shape.

## Evidence — why this task exists

1. **A FAIL verdict is currently invisible.** `refresh_health.sh` runs
   `funding-watch.sh --json data/funding-health.json ... || true` daily at 05:00
   (com.steve.fortel2-health). The `|| true` swallows the exit code; the verdict lands in
   `data/funding-watch.out` and `data/funding-health.json` and nobody looks. This is not
   hypothetical: during the R-12 incident the funder endpoint reported `status=failing` for
   days and it was only found by a manual session (see D-0087 in `tasks/decisions.md`).
   The verdict logic itself was just fixed (#146, #147 era) — correct verdict, zero observers.
2. **A dead recovery agent is equally invisible.** `com.steve.fortel2-resolve-games` runs
   hourly at :00 recovering bonds. If launchd stops running it, or it starts exiting nonzero
   every run, the only symptom is silence in
   `~/Library/Logs/fortel2-resolve-games.{out,err}.log`. Nothing watches.

## Outcome — the properties that must hold

Build `scripts/alert-watch.sh` (new) plus `launchd/com.steve.fortel2-alerts.plist` (new,
suggested cadence hourly at Minute=30, offset from resolve-games' :00) such that:

1. `data/funding-health.json` with `"verdict": "FAIL"` → banner + email within one watcher
   cycle, message carrying the verdict's `reason`.
2. `data/funding-health.json` older than **26 h** → alert ("health pipeline stale") — this one
   condition covers a dead health agent, a funding-watch crash that never reached its JSON
   write, and stale gas sampling.
3. A resolve-games agent that has stopped running or is persistently exiting nonzero is
   alerted within **≤ 2 of its hourly cycles**, without false-alarming across a normal
   overnight Mac-sleep gap. Mechanism is your choice — log mtime with a generous threshold,
   read-only `launchctl print` state, or both. Read-only launchctl only: never
   bootout/bootstrap/kickstart from the watcher.
4. A condition that persists re-alerts every `ALERT_REALERT_HOURS` (default 6), not every
   cycle; a **second, distinct** condition alerts immediately even while the first is inside
   its cooldown. Cooldown state lives under `data/` (gitignored).
5. The two channels are independent: the banner must fire even when email config is missing
   or Resend is unreachable, and vice versa. Any channel failure is loud — logged and a
   nonzero exit so the launchd err log records it. Missing `RESEND_API_TOKEN` = banner still
   fires, email skipped with a visible warning, nonzero exit.
6. Verdicts `OK`, `WARN`, `INSUFFICIENT` → no alert, exit 0 (WARN is inside the documented
   tolerance window; alerting on it is cry-wolf, the defect class #146 just removed).
7. `alert-watch.sh --test` sends a synthetic alert, clearly tagged TEST, through both
   channels — this is the operator's post-install shakeout.

**Fixed choices (the why matters):**

- **Email = Resend HTTP API** (`POST https://api.resend.com/emails`), plain curl. The operator
  already holds an account and API key.
- **The secret env key is named `RESEND_API_TOKEN`** — exactly this name. The #145 tripwire
  in `test-helpers.sh` covers keys matching `TOKEN`, so the existing guard against a pasted
  secret in the tracked example covers this key for free. Do not name it `RESEND_API_KEY`.
- Sender/recipient are env-configured: `ALERT_EMAIL_FROM` (default `onboarding@resend.dev`,
  which needs no verified domain but only delivers to the Resend account owner's own address)
  and `ALERT_EMAIL_TO`. Template all three keys in `.env.sepolia.example` with **empty
  values** and a comment; real values go only in the local untracked `.env.sepolia`, which
  the operator fills in himself. Never put a real token or a real email address in the example.
- **The token never appears on argv or in output.** `ps` argv exposure is a standing concern
  on this box. Pass the Authorization header to curl via stdin (`--config -` or
  `--header @-`), not `-H "Authorization: Bearer $TOKEN"`. Tests must assert the token is
  absent from the mock's recorded argv and from all script output — full value and any
  8-character slice, the `_f710_key_leaked` shape.
- **bash 3.2 compatible** (macOS system bash): expanding an empty `"${arr[@]}"` under
  `set -u` crashes; no bash-4 features.
- `lib.sh` sources the env file with `set -a`, so env-file values **override** caller-supplied
  variables (see the comment at funding-watch.sh ~L72). Test-only overrides must therefore use
  variable names that never appear in env files, or flags.
- Plist: `StartCalendarInterval` (check-launchd.sh parses it; StartInterval would read as a
  missing schedule), logs under `~/Library/Logs/` (launchd opens log paths before the program
  runs; repo `data/` may not exist on a fresh clone — same lesson as the resolve-games plist).

Everything not fixed above is yours: state-file format, message wording, liveness mechanism.

## Scope

**Freely changeable:** `scripts/alert-watch.sh`, `launchd/com.steve.fortel2-alerts.plist`
(both new).

**Additive only** (other tail tasks also touch these):

- `scripts/test-helpers.sh` — append your tests; currently **249 PASS 0 FAIL** on main; do not
  reorder or renumber existing tests.
- `.env.sepolia.example` — add the three keys; the tripwire tests assert secret lines stay empty.
- `README.md` — one short subsection on alerting (see runbook requirement below).

**Do not touch, with reasons:**

- `refresh_health.sh` — the Morning Briefing depends on its exit semantics; the watcher derives
  everything from the artifacts it already writes.
- `scripts/funding-watch.sh`, `scripts/resolve-games-sepolia.sh` — proven and in production;
  the hourly agent executes resolve-games from this very checkout.
- `scripts/lib.sh` — CODEOWNERS-gated; the helper dedup is a separate deferred task.
- `tasks/decisions.md` — reviewer-owned. **D-0089 is pre-assigned to this task's review and the
  reviewer writes it.** Do not add an entry and do not derive "highest + 1" yourself; this
  assignment overrides that convention. If anything about the id looks wrong, stop and ask.
- Existing `launchd/*.plist` files.

**Escape hatch:** if the task appears to require changing anything outside this surface, stop
and report — do not widen scope.

**Working-copy rule:** the hourly resolve-games agent runs from this checkout. Your changes are
additive, so having `feat/ops-alerting` checked out while you work is safe — but never leave
the tree dirty, and leave `main` checked out whenever you pause or finish.

## The trap

**A fail-open watcher recreates the exact blind spot it exists to close.** Every failure path
that ends in "silently do nothing" — an `|| true` around a channel send, a cooldown bug that
suppresses a new condition, sourcing an env file without `RESEND_API_TOKEN` and treating email
as an optional no-op, a plist that never loads because its log directory doesn't exist — turns
back into R-12: a FAIL verdict standing unnoticed for days. When a branch is ambiguous, bias
toward alerting loudly and exiting nonzero. The consequence of the opposite bias is not noise;
it is silence, which here is the failure.

Second trap, from this project's recent history: **never-run-end-to-end scripts break on first
live run** (steps 11–12 of Phase 7 surfaced four latent integration gaps in a row). Your curl
mock proves logic, not delivery. `--test` is the operator's live shakeout — treat it as a
first-class code path, not a debug leftover.

## What must survive

- `test-helpers.sh`: all 249 existing PASS.
- `phase7-gate-parity.sh`: 60 PASS, exit 0.
- The #145 tripwire semantics: secret-named lines empty in the example; leak reporting names-only.
- `check-launchd.sh` logic unmodified (it should accept your plist as-is once installed; if it
  can't, stop and report).
- No existing check weakened, skipped, or deleted. If a test legitimately must change, declare
  it in the return report: before, after, and why it is a strengthening.

## Coverage — as properties, offline

Tests run with **no network** and mock `curl`/`osascript` via PATH shims that record argv:

1. FAIL-verdict JSON → both channels invoked; email payload contains the verdict reason.
2. Stale `funding-health.json` → alert.
3. Fresh OK JSON + fresh agent logs → no alert, exit 0.
4. Same condition twice inside the cooldown → exactly one send; a distinct second condition
   still alerts while the first is suppressed.
5. Token absent from shim-recorded argv and from all output (full value and any 8-char slice).
6. Missing `RESEND_API_TOKEN` → banner fires, email skipped loudly, nonzero exit.

## Verification — run at hand-back, against main merged into your branch as of that moment

```
bash -n scripts/alert-watch.sh
plutil -lint launchd/com.steve.fortel2-alerts.plist
./scripts/test-helpers.sh          # expect 249 + N additive PASS, 0 FAIL — state N;
                                   # unexplained movement in the count is itself a finding
./scripts/phase7-gate-parity.sh    # expect 60 PASS, exit 0
bash -c 'set -a; source .env.sepolia.example'   # expect exit 0
```

**Not yours to run:** a live Resend send (you have no token — do not read `.env.sepolia`) and
the launchd install (do not `bootstrap`/`bootout` anything). Those are operator verification,
post-merge. Your README subsection must therefore include an **Install & shakeout** runbook of
complete single commands, one per block, run-button style: copy the plist to
`~/Library/LaunchAgents/`, `launchctl bootout` (tolerating not-loaded) then `bootstrap`
(file copy alone is not sufficient — check-launchd.sh header, D-0026), then
`scripts/alert-watch.sh --test`. Keep any restart/undo command adjacent to the action that
needs it, not at the end. List everything only hand- or mock-verified under RESIDUAL GAPS.

## Out of scope, with reasons

- Shortening funding-failure detection latency — bounded by the daily gas-sampling cadence,
  documented in funding-watch.sh's header; not this task.
- Alerting on other agents (sleep/wake/health beyond the staleness check — condition 2 already
  covers the health agent).
- Any additional channel (Slack, SMS) — operator chose banner + Resend email.
- `lib.sh` dedup of `require_admin_key_matches_address` — separate deferred task.
- Touching `refresh_health.sh` — see scope.

## Unresolved decisions

None — destination (banner + email), mechanism (Resend, existing account), and the secret's
name are operator-settled. One conditional: if it turns out `onboarding@resend.dev` cannot
deliver to the configured `ALERT_EMAIL_TO`, do **not** create accounts or verify domains;
ship with the default, note it under DECISIONS NEEDED, and let the operator swap
`ALERT_EMAIL_FROM` after domain verification.

If you believe any part of this approach is wrong — the cadence, the staleness threshold, the
fixed key name, the two-file shape — argue it with evidence in your report rather than
implementing it half-heartedly. The brief's author is sometimes wrong, including about things
stated confidently above.

## Return format — verbatim, these labels, this order

```
TASK:        ops-alerting — alert on funding-watch FAIL and dead recovery agent
LINE OF WORK: feat/ops-alerting
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked

VERIFICATION: <each check named> — pass/fail, with counts
              (run against main merged in as of hand-back)
MIGRATION:   none

SHARED FILES TOUCHED: <path> — what changed, why it is additive   (or: none)
IDENTIFIERS USED:     D-0089 reserved for the reviewer — not consumed by me
EXISTING CHECKS MODIFIED: <path> — <before> → <after>; why this strengthens
                          rather than weakens                      (or: none)
DECISIONS NEEDED:    none | <the question, and what you did in the interim>
RESIDUAL GAPS:       what this does not cover; what was verified by hand vs
                     automatically; risk stated plainly
```

Disclosure in the last three fields counts as diligence, not failure: a declared assertion
change is reviewable, a silent one is how a guarantee dies.
