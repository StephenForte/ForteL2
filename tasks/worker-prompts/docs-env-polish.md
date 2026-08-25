# Worker brief — docs-env-polish: deposit-pairing README note + FUNDING_* env templating

```
DISPATCH · Model: Sonnet 5 · Order: parallel with feat/lib-key-guard-dedup and ci/prestate-negative-control (file-disjoint)
Surface: Claude Code worker session, launched by the operator via the desktop app (branch dropdown)
Baseline: main @ 137e679 · branch docs/deposit-note-and-funding-env (pre-created — use it, do not cut your own)
Host: any (docs + template edits; verification is offline)
Working directory: /Users/steveforte/ForteL2 (app-isolated; leave `main` checked out when you finish — an hourly launchd agent runs from this checkout)
Landing: PR to main. The reviewer writes the decision entry; do not touch tasks/decisions.md or allocate a decision id.
```

Copy everything below the line into the worker.

---

## Task

Two small documentation closures. Trust the repo over this brief.

**1. README sentence on the deposit pairing precondition** (D-0088 Finding 4, the Codex P2
deferred from #147). `scripts/deposit-eth-sepolia.sh` now refuses to send unless
`ADMIN_PRIVATE_KEY` derives `ADMIN_ADDRESS` — because `OptimismPortal.receive()` credits
`msg.sender`, a mismatched key mints ETH to the wrong L2 wallet with a successful tx and
nothing pointing at the cause. Add one or two sentences at the README's deposit usage
(the Phase 2 deposit instructions around the `deposit-eth-sepolia.sh` mention, ~line 82)
stating the precondition and why: the script refuses a wrong signer before moving value.
Match the surrounding voice; do not restructure the section.

**2. Template the funding-watch env keys in `.env.sepolia.example`.** `scripts/funding-watch.sh`
consumes six operator-settable keys that the tracked example does not document:
`FUNDING_POLICY_MIN_ETH` (default 0.6), `FUNDING_STALE_HOURS` (default 12),
`FUNDING_WATCH_ADDRESS` (optional), `FUNDING_HEALTH_TIMEOUT` (default 10),
`CHAINBANK_FUNDING_HEALTH_URL` (optional), `FUNDING_HEALTH_TOKEN` (**secret**).
(`FUNDING_HEALTH_JSON` is test-only — deliberately exclude it, with a comment if you like.)
Follow the file's established idiom: optional knobs with binary-affecting defaults stay
**commented** placeholders (an empty active `KEY=` must not be able to override a script
default — the D-0065 "last empty assignment wins" hazard); the secret line, if left active,
stays **empty** (the #145 tripwire fails CI on a populated `TOKEN=`). Read the file's own
header comments and the funding-watch.sh header (lines 30–39) before choosing which keys are
active-empty vs commented. Never put a real value, URL, or token in the example.

## Scope

- **Freely changeable:** none.
- **Additive only:** `README.md` (the deposit sentence; nothing else), `.env.sepolia.example`
  (the funding block; nothing else).
- **Do not touch:** everything else — in particular `scripts/` (three parallel tasks are in
  flight; `test-helpers.sh`, `lib.sh`, and `phase7-preflight.sh` belong to a sibling task)
  and `tasks/decisions.md` (reviewer-owned).
- If the task appears to need anything outside this surface, stop and report.

## The trap

A populated secret or real endpoint URL pasted into the tracked example. Consequence: a
credential in git history that survives deletion. The tripwire catches `TOKEN=`/`PRIVATE_KEY=`
patterns, but a URL is not tripwired — keep `CHAINBANK_FUNDING_HEALTH_URL` a commented empty
placeholder. You do not need and must not read the operator's local `.env.sepolia` (D-0049
bars agents from reading it).

## Verification — run at hand-back against main merged in

```
bash -c 'set -a; source .env.sepolia.example'   # exit 0
./scripts/test-helpers.sh                        # all existing PASS, 0 FAIL (no new tests expected; state the count)
./scripts/phase7-gate-parity.sh                  # 60 PASS, exit 0
./scripts/funding-watch.sh --help                # confirm your documented defaults match the script's
```

## Return format — verbatim

```
TASK:        docs-env-polish — deposit-pairing README note + FUNDING_* templating
LINE OF WORK: docs/deposit-note-and-funding-env
REVIEW ARTIFACT: <PR URL>
STATUS:      complete | complete-with-caveats | blocked
VERIFICATION: <each check named> — pass/fail, with counts (against main merged in at hand-back)
SHARED FILES TOUCHED: <path> — what changed, why additive   (or: none)
EXISTING CHECKS MODIFIED: none expected — declare any with before → after and why
DECISIONS NEEDED:    none | <question + interim choice>
RESIDUAL GAPS:       <plain statement>
```

If you think any choice here is wrong, argue it with evidence in the report rather than
implementing it half-heartedly.
