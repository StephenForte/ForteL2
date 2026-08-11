# Worker prompt — CB-01: fund-event attribution + funding health signal (ChainBank repo)

**Cross-repo ask.** This prompt lives in the ForteL2 repo because ForteL2 is the *consumer*
defining a contract it needs; the work is done in **ChainBank**. Paste everything below the line
into a worker session opened on the ChainBank checkout.

> **DISPATCH** · Model: **mid tier** · Order: single task, nothing parallel
> Baseline `main`: **record the SHA at branch time** (the requester has not seen ChainBank source)
> Host: any — Node/Prisma repo, no special machine; use a scratch database, never the Render one
> Merge: standalone; closes the observability half of ForteL2's `hardening-findings.md`
> § "Batcher funding automation"

**Model-tier note:** the logging half is mechanical, but the health-endpoint half has a silent
failure mode (see **The trap**) that returns green while funding is dead — which is worse than no
endpoint at all. That hazard is what puts this above cheap tier.

---

You are working in the **ChainBank** repo. Before trusting anything below, read current `main` —
including the claims in this prompt. The requester has only observed this service from the
outside (Render logs); every file path here is **inferred from build output and must be
confirmed**, not assumed.

Branch: `agent/cb01-funding-observability` off current `main`. Record the base SHA in your handoff.

## Why this exists — the evidence

ChainBank's `wallet-reconciler` cron funds wallets belonging to a **different project**: it is the
sole funding mechanism for the ForteL2 rollup's L1 batcher address
`0x3D54FD6353cd66D143fb94D178c9eEB1aE98a31d`. If that wallet runs dry, ForteL2 keeps producing L2
blocks while batches silently stop reaching L1 — the worst failure shape for a settlement rail.
ForteL2 currently has **no way to tell** whether this cron is alive.

Observed from Render (service `chainbank-wallet-reconciler`, `crn-d9n89om417fc73cs30g0`, schedule
`0 */6 * * *`, entry `npm run cron:wallet-reconciler` → `dist/src/jobs/wallet-reconciler.js`):

```json
{"level":"info","service":"chainbank","role":"cron-reconciler","runId":"c6e39a96-…",
 "exitKind":"success","walletsAssessed":4,"walletsFunded":1,"walletsNoop":3,
 "walletsBlocked":0,"walletsFailed":0,"weiTransferred":"600000000000000000",
 "outgoingScanStatus":"complete","msg":"Wallet reconciler run completed"}
```

Verified funding history 2026-08-05 → 2026-08-11: `0.2722 ETH` (08-06 06:00 UTC), `0.600 ETH`
(08-06 18:00 UTC), `0.600 ETH` (08-08 18:00 UTC); every other run funded nothing.

**The gap:** the summary reports *how many* wallets were funded and the total wei, never *which
address*. With four wallets in scope, an outside consumer cannot tell whether a given send went to
ForteL2's batcher or to one of ChainBank's own wallets. The requester correlated the 08-06 event by
amount and timing alone — which happens to work with one funded wallet per run and breaks the
moment two are funded together.

## What to build

**1. Per-wallet fund-event logging.** When a wallet is funded, emit a structured log line
identifying it: wallet label/id, **full address**, chain id, amount in wei, resulting balance if
known, and the **transaction hash**. One line per funded wallet, in addition to (never replacing)
the existing run-completed summary. Do the same for `blocked` and `failed` outcomes — a wallet that
*should* have been funded and wasn't is exactly the signal a consumer needs, and today it is
invisible.

**2. A funding health endpoint**, served by `chainbank-web` (which already exposes
`/health/live`). Suggested `GET /health/funding`. Shape — treat as the contract ForteL2 will code
against, and push back if the repo's conventions differ:

```json
{
  "status": "ok | degraded | failing",
  "checkedAt": "2026-08-11T19:00:00Z",
  "lastRun": { "runId": "…", "finishedAt": "2026-08-11T18:00:31Z",
               "exitKind": "success", "ageSeconds": 3600 },
  "wallets": [
    { "label": "fortel2-batcher", "address": "0x3D54…a31d", "chainId": 11155111,
      "balanceWei": "672741447840395160", "policyMinWei": "600000000000000000",
      "lastFundedAt": "2026-08-08T18:00:39Z", "lastFundedWei": "600000000000000000",
      "lastFundedTxHash": "0x…", "status": "ok | below_policy | blocked | failed" }
  ]
}
```

Status semantics — state them in code comments so they survive:
- `failing` — no **successfully finished** run within **two schedule cycles (12 h)**, or any wallet
  below policy with no funding attempt inside that window.
- `degraded` — a wallet below policy but within the window, or the most recent run reported
  `walletsBlocked`/`walletsFailed` > 0.
- `ok` — otherwise.

Return HTTP 200 with the body in all three cases (the consumer reads `status`); reserve non-2xx
for the endpoint itself failing. Gate it behind a bearer token from env (e.g.
`FUNDING_HEALTH_TOKEN`) — the balances are public on-chain, but an unauthenticated inventory of
which wallets you fund and how much is gratuitous disclosure. ForteL2 will hold the token as a
secret under its own conventions. If you think token-gating is wrong here, argue it.

## The trap

**A health endpoint that reports the web service's health instead of the cron's.** The naive
implementation queries "the most recent reconciliation run" and returns `ok` if one exists. That
returns green when the cron has been dead for a week, because a stale row is still a row — and a
green health check that lies is worse than none, since it converts an outage into a silent one.

This repo already contains the exact data that breaks the naive version. The reconciler logs, on
every run:

```
"Prior reconciliation runs aborted before finish"
abortedRuns: [{ "startedAt": "2026-08-02T00:29:33.444Z", "outgoingScanStatus": "complete",
                "errorCode": null, "note": "finished_at IS NULL — treat as aborted, not a clean
                complete scan" }]
```

So there is at least one persisted run row with `finished_at IS NULL` that looks complete by its
scan status. **Health must key off successfully *finished* runs and compare `finishedAt` against
wall-clock now** — not "a row exists", not `startedAt`, not `outgoingScanStatus`. A `<=` where a
`<` belongs, or trusting `startedAt`, silently disables the whole check.

Second, smaller trap: `weiTransferred` values exceed `Number.MAX_SAFE_INTEGER`. Keep wei as
strings or BigInt end to end; a stray `Number()` in the serializer will quietly corrupt amounts.

## What must not change

- **Do not remove or rename any field in the existing run-completed summary line** —
  `walletsAssessed`, `walletsFunded`, `walletsNoop`, `walletsBlocked`, `walletsFailed`,
  `weiTransferred`, `exitKind`, `runId`. ForteL2's records cite them and its correlation depends on
  them. Add fields; never subtract.
- **Do not change funding policy, thresholds, amounts, or schedule.** This task is observability
  only. If you believe a threshold is wrong, report it — do not adjust it.
- **Never log private keys, mnemonics, or signer material.** Addresses and tx hashes are public;
  key material is not, and this job holds signing capability.
- **Do not weaken existing tests.** If a test must change because it pinned the old log shape, call
  it out explicitly in the handoff with reasoning.

## File scope

- **Owned:** the wallet-reconciler job and its tests; the new health route and its tests; any
  small query/service module you add for run/funding history.
- **Shared, additive only:** the logger module, route registration/index, `.env.example`, README.
  Append; do not restructure. List every one in the handoff.
- **Off-limits:** Prisma schema changes *unless* the data you need genuinely is not persisted —
  a migration here runs against a live database on deploy, so it needs its own review. Funding
  policy/threshold config. The treasury-monitor job (different concern).

**If you need something off-limits, stop and report rather than widening scope.** If a migration
is unavoidable, say so, explain what is missing from the current schema, and prove it applies
**forward on populated data**, not just to an empty database.

## Out of scope, deliberately

- Alerting/paging on `failing` — ForteL2 polls; routing is a later decision.
- Backfilling attribution for the three historical fund events — going forward is enough.
- The aborted-run row from 2026-08-02. Health must be *robust to* it; fixing whatever caused it is
  a separate task. Mention it in follow-ups if you learn the cause in passing.
- Any change on the ForteL2 side.

## The gate — run after rebasing onto current `main` at handoff time

Work that was green against a stale base says nothing about what it is merging into. Run the
repo's real commands (confirm from `package.json`; the following is the expected shape):

```
npm ci
npm run lint && npm run typecheck && npm run build
npm test                       # note the pass/skip counts before and after
```

Plus, exercised explicitly:
- The endpoint's three states, driven by fixtures: fresh successful run (`ok`); last successful run
  older than 12 h (`failing`); wallet below policy inside the window (`degraded`).
- **A run row with `finished_at IS NULL` must not satisfy the freshness check** — this is the
  regression test for the trap; name it for the property, not the file.
- A wei value above `Number.MAX_SAFE_INTEGER` survives a round trip through the endpoint unchanged.
- Fund-event attribution: a run funding **two** wallets emits two distinct, correctly-addressed
  fund lines — the case that defeats amount-and-timing correlation today.

If there is no harness for part of this, say so, **do not build one for this task**, and disclose
exactly what you hand-verified. Unexplained movement in test counts is itself a finding.

If you think this design is wrong — the endpoint shape, the token gate, the 12-hour window — say so
and argue it rather than implementing it half-heartedly.

## Hand back — this format, verbatim

```
TASK:        CB-01 — fund-event attribution + funding health signal
BRANCH:      agent/cb01-funding-observability
BASE SHA:    <sha of main at branch time>
PR:          <url>
STATUS:      complete | complete-with-caveats | blocked

GATE:        lint ✅  typecheck ✅  build ✅
             unit <N> passed (<N> skipped)   endpoint states verified: ok/degraded/failing
MIGRATION:   none | <name> — verified fresh AND forward on populated data

ENDPOINT CONTRACT:
  <final path, auth mechanism, and the JSON actually returned — paste one real response>

SHARED FILES TOUCHED:
  <path> — what changed, why it is additive
  (or: none)

EXISTING TESTS MODIFIED:
  <path> — <old assertion> → <new assertion>; why this strengthens rather than weakens
  (or: none)

DECISIONS NEEDED FROM OPERATOR:
  none | <question, and what you did in the meantime>

RISKS AND FOLLOW-UPS:
  What this does NOT cover; what was hand-verified vs automated; residual risk stated plainly.
```
