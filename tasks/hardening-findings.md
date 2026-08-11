# Hardening findings — Wave 6 (H1 security audit)

Audit date: 2026-08-04. Worker: H1 (`agent/h1-security-audit` off `wave6-base`).

| ID | Finding | Severity | Status | Notes |
|---|---|---|---|---|
| H1-001 | Shell scripts echo/banner `L1_RPC_URL` / `L2_*` without `redact_rpc_url` | **High** | **Fixed** | 17 echo sites wrapped; see handoff §3 |
| H1-002 | `batcher/` Go RPC helpers leak raw URL in transport errors | **High** | **Fixed** | `batcher/redact.go` + `cmd/*/rpc.go` + submit-loop dial |
| H1-003 | `proposer/` Go RPC helpers leak raw URL in transport errors | **High** | **Fixed** | `proposer/rpc.go` + propose-loop / inspect-game dial |
| H1-004 | Google Fonts CDN breaks static self-containment + CSP | **Medium** | **Fixed** | Sora/Syne vendored under `{viewer,blocks,dapp}/fonts/`; CSP `font-src 'self'` |
| H1-005 | `innerHTML` for on-chain strings in static apps | **Medium** | **Accepted (clean)** | Re-sweep: zero `innerHTML` in `viewer/`, `blocks/`, `dapp/` JS; all user/chain text via `textContent` |
| H1-006 | Serve paths must bind loopback only | **Medium** | **Accepted (clean)** | `serve-dapp.sh`, `serve-viewer.sh`, `serve-blocks.sh` all call `serve_static_loopback` |
| H1-007 | `.env` / key material in repo | **High** | **Accepted (clean)** | `.env`, `.env.sepolia`, `data/`, JWT paths gitignored; `.env.example` keys are public Foundry defaults only |
| H1-008 | `proposer/.gomodcache/` not in `.gitignore` | **Low** | **Escalated** | See E-H1-1 in `tasks/decisions.md` |
| H1-009 | `03-init-l2.sh` logs JWT **path** on first create | **Low** | **Accepted** | Path only, not secret bytes; operator-local |
| H1-010 | go-ethereum deep contract-call errors may embed dial URL | **Low** | **Accepted** | Dial sites redacted; deeper geth strings out of redaction-only scope |
| H1-011 | Sepolia L1 RPC token rotation after debugging | **Info** | **Operator** | Rotate QuickNode path token if logs were shared during development |

## Summary counts

| Status | Count |
|---|---|
| Fixed here | 4 |
| Escalated | 1 |
| Accepted (clean or with rationale) | 6 |

## H4 operator drill results (2026-08-04 evening → 2026-08-05 morning)

| Drill | Result | Evidence / notes |
|---|---|---|
| Local 901 redeploy (`start-all.sh` + `deploy-guestbook.sh`) | **PASS** | Fresh contract set; regenerated `deployments.json`/`guestbook.txt`/`intent.toml` committed (`31cb1d3`); guestbook at `0x0116…86Ef` |
| H3a stub double-run (fresh + `--no-wipe`) | **PASS** | Run 2 continued head 10 → block 11 **seq=10** (parentSeq+1) through 20 seq=19; follow-validate PASS both runs; reference tip untouched |
| `derivation-check.sh` 901 window 1–20 | **PASS** | All derived hashes match reference EL on the fresh chain |
| `demo-checklist.sh --sepolia` | **PASS** (exit 0) | After fixing H4-001; all live checks green incl. funds, batch nonce, syncStatus |
| `sepolia-fund-check.sh` | **PASS** (exit 0) | All roles ≥ floors; found + fixed H4-002 |
| Replica sync check | **PASS** | Web Shell method per D-0016: replica chain 852, head=safe=629995 == local safe 629995; lag vs local unsafe 630036 = 41 ≤ 50 (08:16 PT) |
| Dev-sleep/wake cycle | **PASS** (observed) | 21:00 sleep + 04:00 wake both fired via launchd; sequencer backfilled the sleep gap; wake-hour doc drift fixed (`859803a`) |
| Cold-start-under-30-min runbook | **PASS (~15 min)** | Operator-run 2026-08-05: stop 10:53:06 → `demo-checklist --sepolia` green ≤11:08 (log-verified from op-geth interrupt/start lines; operator-reported clock times were a paste error and were discarded) |

Drill-found fixes (post-wave, committed to main):

| ID | Finding | Fix |
|---|---|---|
| H4-001 | `test-helpers.sh` gen-viewer-config fixture failed under inherited `FORTEL2_ENV` (only visible via `demo-checklist --sepolia`) | `env -u FORTEL2_ENV` for the fixture run (`902c3aa`) |
| H4-002 | `sepolia-fund-check.sh` example `cast send` hints expanded the raw tokenized L1 URL (missed by H1's sweep — same class as H1-001) | Print literal `$L1_RPC_URL` (`d9713eb`) |
| H4-003 | Repo said wake=05:00; installed LaunchAgent fires 04:00 | Docs + checked-in plist trued up (`859803a`) |
| H4-004 | Wake actually fired 05:00:07 on 2026-08-05 despite plist file saying Hour=4 — launchd still runs the previously **loaded** definition; plist edits require `launchctl bootout` + `bootstrap` to take effect | Operator action: reload `com.steve.fortel2-wake` (one-liner provided); verify next-morning wake at 04:00 |

---

## R-wave (2026-08-05) — gas runway first live measurement

`scripts/gas-runway.sh` (R-05) went live the same day the review flagged P1-5 ("floors answer
*above the line?*, nobody answers *for how long?*"). Its first two real samples, 65 min apart on
2026-08-05 evening:

| Role | Balance | Floor | Burn | Runway |
|---|---|---|---|---|
| BATCHER | 0.1395 ETH | 0.15 | **0.169 ETH/day** | **below floor** (exit 2) |
| PROPOSER | 0.500 ETH | 0.15 | ~0 over the interval | n/a |

So P1-5 was not hypothetical: the batcher crossed under its floor on the day the meter shipped,
with roughly 20 h of runway left at that rate (less the nightly 23:00–04:00 sleep, which pauses
the burn). 0.169 ETH/day is the calldata + 30-block-channel + 5-min-proposal profile D-0018
already diagnosed as a tuning artifact — blobs + span batches + relaxed cadence are the P7-0 fix,
not a staging-time change. Operator response: a self-funding cron test was already in flight;
verification scheduled post-wake (~04:05) rather than mid-sleep-window.

Samples land in `$DATA_DIR/gas-samples.jsonl` (gitignored `data-sepolia/`), **not** repo `data/`
as the R-05 card assumed — accepted deviation: `$DATA_DIR` is where the Sepolia stack already
keeps state, and it keeps samples out of the repo tree entirely.

### H4-004 — CLOSED (2026-08-06)

The wake agent fired at **04:00** as configured: `~/Library/Logs/fortel2-wake.out.log` last written
`Aug 6 04:00`, run reaching `=== Sepolia L2 stack is up ===` with L2 block 652942 on chain 852.
This was the proof outstanding since 2026-08-05, when wake fired 05:00 despite `Hour=4` in the
plist file — launchd runs the *loaded* definition, so plist edits need `bootout` + `bootstrap`
(the operator reloaded it, and `scripts/check-launchd.sh` now verifies repo-vs-installed on demand).
Full nightly cycle is therefore confirmed end to end: sleep 23:00, wake 04:00, stack self-restarts.

### Batcher self-funding — first observed top-up

| Time (PT) | BATCHER | Δ | L2 block |
|---|---|---|---|
| 2026-08-05 18:15 | 0.1472 ETH | — | 648006 |
| 2026-08-05 19:20 | 0.1395 ETH | −0.0077 (65 min → **0.169 ETH/day**) | 649967 |
| 2026-08-06 04:05 | 0.3958 ETH | **+0.2563** (operator self-fund cron) | 653608 |

The cron works. `gas-runway.sh` correctly skipped the top-up interval rather than reporting a
negative burn — the R-05 edge case, confirmed against real data — and kept the last genuine burn
measurement, so it still reports `0.169 ETH/day` and now `days_to_floor=1.452`, exit **2**
(under the 3-day `GAS_RUNWAY_MIN_DAYS` default).

**Standing implication:** a ~0.256 ETH top-up buys roughly 1.5 days at the measured evening burn
rate (less in practice, since the nightly 23:00–04:00 sleep pauses the burn — call it ~1.8 days).
The cron must therefore run at least daily, or top up a larger amount, to keep the batcher off the
floor. This is a staging-economics artifact of the current calldata + 30-block-channel + 5-minute-
proposal profile; the structural fix (blobs + span batches + relaxed cadence) is P7-0 in
`tasks/prd-mainnet-pilot.md`, not a change to make on 852.

### Batcher funding automation (2026-08-11) — supersedes the standing implication above

The note above ("the cron must therefore run at least daily, or top up a larger amount") is
**answered and superseded**: the operator increased both the amount sent and the trigger policy.
Observed state after the change:

| | Before | After |
|---|---|---|
| BATCHER balance | 0.3958 ETH | **0.6727 ETH** |
| `days_to_floor` (vs 0.15) | 1.45 | **3.09** |
| `gas-runway.sh` exit | **2** (under `GAS_RUNWAY_MIN_DAYS`) | **0** |

**Two floors now exist and must not be conflated.** `0.15 ETH` is the *tooling* floor, inherited
from `sepolia-fund-check.sh`, and is what `days_to_floor` measures against — time until batching
actually breaks. `~0.6 ETH` is the *funding policy* minimum the automation maintains — the level
at which a top-up fires. A reader seeing `days_to_floor=3.089` should not read 0.15 as the policy.

**Measurement caveat (matters for P7-0).** `gas-runway.sh` skips any interval where the balance
rose, so each automated top-up destroys a burn-measurement window. Four samples now span five days
and the burn figure still rests on a single 65-minute pre-top-up interval (0.169 ETH/day, measured
awake-hours and extrapolated to 24 h; the real rate on the 23:45–03:00 schedule is nearer 0.146).
Good automation therefore *hides* the signal the mainnet cost model needs. Fix either by letting
the balance draw down across an uninterrupted stretch, or by having the funding job emit its
transfers so the script can subtract them instead of skipping.

**Mechanism — IDENTIFIED 2026-08-11** (supersedes the "not verified" note first written here).
The funder is the Render cron **`chainbank-wallet-reconciler`** (`crn-d9n89om417fc73cs30g0`), built
from the **ChainBank** repo (`npm run cron:wallet-reconciler` -> `dist/src/jobs/wallet-reconciler.js`),
schedule **`0 */6 * * *`** (00/06/12/18 UTC = 17/23/05/11 local). Each run assesses **4 wallets** and
funds those under policy. Verified funding history since 2026-08-05:

| Run (UTC) | walletsFunded | weiTransferred |
|---|---|---|
| 2026-08-06 06:00 | 1 | 0.2722 ETH |
| 2026-08-06 18:00 | 1 | 0.600 ETH |
| 2026-08-08 18:00 | 1 | 0.600 ETH |
| every other run | 0 | 0 |

The 06:00 send of 0.2722 ETH matches the +0.2563 ETH observed on BATCHER across the surrounding
samples (the ~0.016 gap is burn inside the window), which is what ties this job to this wallet. The
last two sends are a flat **0.600 ETH**, consistent with the operator's "bumped the ETH sent"; no
funding has fired since 2026-08-08, consistent with the balance sitting above policy.

**Correction to the measurement note above:** the job *already* logs its transfers — `walletsFunded`,
`weiTransferred`, `walletsAssessed` per run. So subtracting top-ups from the burn calculation needs
no new instrumentation on the ChainBank side; the data exists and is queryable via the Render MCP or
dashboard. Wiring it into `gas-runway.sh` is the only missing piece.

**Residual observability gap.** The run summary reports *how many* wallets were funded and the total
wei, but not *which* address. With four wallets in scope, ForteL2's batcher cannot be distinguished
from ChainBank's own wallets by log inspection alone — the correlation above relies on amount and
timing. If the mainnet pilot is going to depend on this job (P7-0/P7-1), it should log the funded
address, and ForteL2 should treat the job as an external dependency with its own health signal:
today a silent failure of a cron in *another* project's repo takes the rail down with no alert on
this side.

**Unrelated pre-existing warning** seen while inspecting: the reconciler reports one aborted prior
run (`startedAt 2026-08-02`, `finished_at IS NULL`). ChainBank's issue, noted only so it is not
rediscovered as a ForteL2 symptom.
