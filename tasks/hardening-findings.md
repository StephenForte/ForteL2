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

---

## R-12 (2026-08-22) — Sepolia proposer drain is the type-1 init bond, not gas

Sampled 2026-08-23 05:38 UTC on the operator machine against live Sepolia, repo
`3a90f1c`. Every command below is a read. Nothing was sent, and the proposer
process was not restarted or reconfigured.

### 1. What is actually running

Stock `op-proposer` — not `fortel2-proposer`.

| Check | Result |
|---|---|
| `USE_CUSTOM_PROPOSER` in `.env.sepolia` | unset (stock path) |
| `CONFIRM_CUSTOM_PROPOSER_SEPOLIA` | unset |
| pidfile `$DATA_DIR/pids/op-proposer.pid` | `95838`, alive |
| `ps -p 95838 -o comm=` | `op-proposer` |
| binary (lsof, no argv — argv contains the key) | `/Users/steveforte/src/fortel2/optimism/op-proposer/bin/op-proposer` |
| uptime at sample | 7h53m (started with the post-wipe stack restart ~21:44Z) |
| `SEPOLIA_PROPOSER_INTERVAL` in `.env.sepolia` | **`5m`** (explicit; matches the script default) |
| txmgr knobs in `.env.sepolia` | all unset → script defaults: rebroadcast 36s, resubmission 72s, receipt-query 36s |
| `PROPOSER_GAME_TYPE` in `.env.sepolia` | **`1`** |
| live log | `proposalInterval=5m0s`; currently looping `insufficient funds for transfer` |

`scripts/06-start-proposer-sepolia.sh` was not edited. The live interval is the
configured 5m, confirmed independently by the log line and by the on-chain
cadence below.

### 2. What one proposal costs, and how many confirmed txs land per interval

Source: Blockscout `txlist` for `PROPOSER_ADDRESS`
`0x350A0F7becCE56598962C501CaA02f900F256803`, then five consecutive receipts
re-read with `cast receipt` / `cast tx` against `$L1_RPC_URL` (redacted).

The proposer has sent **exactly 36** confirmed L1 transactions since the
2026-08-22 wipe (nonces 0–35). Every one is:

- `to` = `DisputeGameFactoryProxy` `0x67f9e427c716586ecc0dc0b62baa8cd05e43262f`
- selector `0x82ecf2f6` = `create(uint32,bytes32,bytes)` (`cast sig` / `cast 4byte`)
- `value` = **80000000000000000 wei = 0.08 ETH**
- status `0x1`, type 2

`cast call $FACTORY 'gameCount()(uint256)'` → **`36`**. One factory game per
outgoing tx; no extras.

**Confirmed txs per ~5-minute window: one.** Consecutive nonces, 35 intervals,
34 of them **exactly 312 s** (26 × 12 s L1 blocks). The one exception is
nonce 5→6 at 924 s — the first dry-spell, after which an inbound top-up landed
and posting resumed. 300-second buckets over the 36 outgoing txs: 36 buckets,
none with more than one confirmation. Resubmission is **not** producing
multiple confirmed spends; replacements (if any) did not confirm separately.

Five consecutive cycles (nonces 31–35), `cast receipt` + `cast tx` verbatim
fields:

| nonce | UTC | tx | gasUsed | effectiveGasPrice | gas ETH | value ETH | wallet drain | confirmed txs in window |
|---|---|---|---|---|---|---|---|---|
| 31 | 2026-08-23 00:35:48 | [`0x9af5cc85…42bbc6`](https://sepolia.etherscan.io/tx/0x9af5cc85048a181b2e8599e4add68c0c490d67182373e783203507c5c942bbc6) | 509274 | 2122094506 (2.1221 gwei) | 0.001080728 | **0.080** | 0.081080728 | 1 |
| 32 | 2026-08-23 00:41:00 | [`0xd3a169f0…eb7311f`](https://sepolia.etherscan.io/tx/0xd3a169f065514ac61d6f732387e1566e0a05953891321c8ef385402baeb7311f) | 509274 | 2054389874 (2.0544 gwei) | 0.001046247 | **0.080** | 0.081046247 | 1 |
| 33 | 2026-08-23 00:46:12 | [`0xc2c7eb3e…f37f29`](https://sepolia.etherscan.io/tx/0xc2c7eb3e23897e351cbb4b4ed349231181a64390e73f06c3b62d4ab7b2f37f29) | 509274 | 2046690427 (2.0467 gwei) | 0.001042326 | **0.080** | 0.081042326 | 1 |
| 34 | 2026-08-23 00:51:24 | [`0x642f2185…ae7575`](https://sepolia.etherscan.io/tx/0x642f2185e66c27ca4ec430cace22712383107eba6a469ec649898a15e9ae7575) | 509274 | 1974457123 (1.9745 gwei) | 0.001005540 | **0.080** | 0.081005540 | 1 |
| 35 | 2026-08-23 00:56:36 | [`0x335e7b66…e9eb51`](https://sepolia.etherscan.io/tx/0x335e7b66133fb8a42ee788bc10f675281a0e513b55a7d9507064b23d02e9eb51) | 509274 | 1996200821 (1.9962 gwei) | 0.001016613 | **0.080** | 0.081016613 | 1 |

Commands for the last of those (the others differ only by hash):

```text
cast receipt 0x335e7b66133fb8a42ee788bc10f675281a0e513b55a7d9507064b23d02e9eb51 --rpc-url $L1_RPC_URL --json
  status=0x1  gasUsed=509274  effectiveGasPrice=1996200821  to=0x67f9e427c716586ecc0dc0b62baa8cd05e43262f
cast tx      0x335e7b66133fb8a42ee788bc10f675281a0e513b55a7d9507064b23d02e9eb51 --rpc-url $L1_RPC_URL --json
  value=80000000000000000  nonce=35  type=0x2
```

All 36 outgoing: **2.880 ETH in `value`** + **0.037148 ETH in gas** =
**2.917148 ETH** wallet drain. Gas is ~1.3% of the drain. The operator's
"0.08 ETH every 5 minutes" is the **`msg.value`**, not the gas. The brief's
`0.08 × 12 × 24 = 23.04 ETH/day` is therefore the **bond rate at a 5-minute
cadence**, and it is arithmetically right. At the measured 312 s interval it
is `86400/312 × 0.08 = 22.15 ETH/day` in bonds, plus ~0.29 ETH/day gas
(~22.4 ETH/day total) for as long as the wallet stays funded enough to post.

Posting stopped after nonce 35 (2026-08-23 00:56:36 UTC). Live logs since
then are estimate-fail retries (`insufficient funds`); those do not confirm
and do not spend.

### 3. `initBonds` — D-0063 checked on chain, not cited

Factory address re-read from `deployments/sepolia/deployments.json`:
`DisputeGameFactoryProxy` = `0x67f9e427c716586ecc0dc0b62baa8cd05e43262f`
(unchanged from the brief).

```text
$ cast call 0x67f9e427c716586ecc0dc0b62baa8cd05e43262f 'initBonds(uint32)(uint256)' 8 --rpc-url $L1_RPC_URL
0

$ cast call 0x67f9e427c716586ecc0dc0b62baa8cd05e43262f 'initBonds(uint32)(uint256)' 1 --rpc-url $L1_RPC_URL
80000000000000000 [8e16]

$ cast call 0x67f9e427c716586ecc0dc0b62baa8cd05e43262f 'gameImpls(uint32)(address)' 8 --rpc-url $L1_RPC_URL
0x0000000000000000000000000000000000000000

$ cast call 0x67f9e427c716586ecc0dc0b62baa8cd05e43262f 'gameImpls(uint32)(address)' 1 --rpc-url $L1_RPC_URL
0x103B2CEb06Bb4888d59FaE894023a86020f8fB8c
```

D-0063 Finding 3(d) is **true right now** for type 8: `initBonds(8) = 0`.
It is **not** the cause of this drain. The proposer is on type **1**, and
`initBonds(1) = 0.08 ETH`, which is exactly the `value` on every `create`.
`gameImpls(8) = 0x0` — type 8 is not registered (step 8b has not run).
D-0063 does not need a correction entry; a reader who carried "bonds are 0"
across to the *currently configured* game type would be repeating the
paraphrase-as-verification failure the brief named.

Local learning already documented this number: `tasks/spike-phase-5-proposer.md`
("Bond: `initBonds(gameType)` (local learning = `0.08 ether`)").

### Where the 0.08 ETH actually goes

Not to L1 validators, and not gone. Each `create` deposits the bond into
`DelayedWethPermissionedGameProxy`
`0xa9db650cd2959a127083bf6448074e6b01b14b80` (current
`deployments/sepolia/deployments.json`). Evidence on the nonce-35 receipt:
log[0] is a WETH `Deposit` at that address, `dst` = the new game proxy
`0xEBd4248164d2D85bdEb83f93E1a81F551F893c4f`; log[1] is
`DisputeGameCreated` on the factory.

```text
$ cast balance 0x67f9e427c716586ecc0dc0b62baa8cd05e43262f --ether --rpc-url $L1_RPC_URL
0.000000000000000000          # factory does not keep it

$ cast balance 0xa9db650cd2959a127083bf6448074e6b01b14b80 --ether --rpc-url $L1_RPC_URL
2.880000000000000000          # 36 × 0.08, exact

$ cast call $FACTORY 'gameAtIndex(uint256)(uint32,uint64,address)' 35 --rpc-url $L1_RPC_URL
1
1787446596
0xEBd4248164d2D85bdEb83f93E1a81F551F893c4f

$ cast balance 0xEBd4248164d2D85bdEb83f93E1a81F551F893c4f --ether --rpc-url $L1_RPC_URL
0.000000000000000000          # game proxy immediately deposits into DelayedWETH
```

Same pattern on games 31–34: type 1, proxy balance 0, DelayedWETH holds the
sum. The 2.88 ETH is locked as game credit. It is recoverable only through
whatever DelayedWETH / game-resolution path applies — not by the proposer
wallet going dry.

### 4. Current proposer balance and Sepolia gas

```text
$ cast balance 0x350A0F7becCE56598962C501CaA02f900F256803 --rpc-url $L1_RPC_URL
32852421044487658

$ cast balance 0x350A0F7becCE56598962C501CaA02f900F256803 --ether --rpc-url $L1_RPC_URL
0.032852421044487658

$ cast nonce 0x350A0F7becCE56598962C501CaA02f900F256803 --rpc-url $L1_RPC_URL
36

$ cast gas-price --rpc-url $L1_RPC_URL
980177917

$ cast base-fee --rpc-url $L1_RPC_URL
979177917
```

Latest block at that sample: number **11548013**, `baseFeePerGas` `0x3a5d11bd`
(= 979177917). "Already run dry" as a number: **0.03285 ETH**, below the
0.15 tooling floor and below the 0.08 ETH the next `create` must attach.
That is why the live log is `insufficient funds for transfer` rather than
a high-gas failure.

Sepolia gas during the posting window was ~2.0 gwei effective; at sample
time it was ~0.98 gwei. Gas-price swing changes the **~0.001 ETH** gas
leg, not the **0.08 ETH** bond. It does not explain the reported rate.

Wallet accounting over the 36-game window closes:

| | ETH |
|---|---|
| inbound (all history on this address, Blockscout) | 2.950 |
| outbound bonds | 2.880 |
| outbound gas | 0.037 |
| residual (cast balance) | 0.033 |

Today's inbound top-ups (0.65 + 1.80 ETH) came from
`0x16cae6aeed87e00bcbcd60062286ab604cfe8b2b`, which is **not**
`HARVEST_ADDRESS`, `ADMIN_ADDRESS`, `BATCHER_ADDRESS`, or
`PROPOSER_ADDRESS`. July inflows included 0.15 from `HARVEST_ADDRESS`.
`chainbank-wallet-reconciler` is not identified as the sender of today's
proposer top-ups.

### `gas-runway.sh` / `funding-watch.sh` (verification, not the cost model)

The brief expected a first-run `INSUFFICIENT SAMPLES`. That is **not** what
happened: `$DATA_DIR/gas-samples.jsonl` already had history.

```text
$ FORTEL2_ENV=.env.sepolia ./scripts/gas-runway.sh
# exit 2
appended sample ts=1787463506 l2_block=15109
Samples file: …/data-sepolia/gas-samples.jsonl (17 sample(s))
role=BATCHER  balance_eth=1.790716  burn_eth_per_day=0.032325  days_to_floor=50.757  floor_eth=0.15
role=PROPOSER balance_eth=0.032852  burn_eth_per_day=0.027187  days_to_floor=-4.309  floor_eth=0.15

$ FORTEL2_ENV=.env.sepolia ./scripts/funding-watch.sh
# exit 1
VERDICT: FAIL — the funder's own health endpoint reports status=failing
         — chainbank-wallet-reconciler … last run 5.6 h ago, our wallet=ok
batcher: 1.7907 ETH   policy_min: 0.60
```

`gas-runway.sh`'s proposer `0.027 ETH/day` is **not** the posting-rate
drain. It skips intervals where the balance rose (the 0.65 / 1.80 top-ups
erase the 0.08-per-game windows), and the wallet has been too empty to post
for hours. Trust the tx table, not that burn figure, for a funding decision.
`funding-watch.sh` FAIL is about the batcher's external funder health
endpoint, not the proposer; surfaced because the brief asked for the
verdict.

### Ranked root-cause hypotheses (by evidence, not plausibility)

1. **The configured type-1 init bond is 0.08 ETH, and stock `op-proposer`
   pays it as `msg.value` on every `create`, every 5 minutes.** Direct:
   `initBonds(1) = 8e16`, every outgoing tx `value = 8e16`,
   `PROPOSER_GAME_TYPE=1`, `proposalInterval=5m0s`, 36/36 txs match.
   This is the cause. Confidence: high.

2. **The ETH is locked in `DelayedWethPermissionedGameProxy`, not burned
   as L1 gas.** Direct: factory balance 0, game proxies 0, DelayedWETH
   balance = 2.880 ETH = 36 × 0.08, Deposit logs on each receipt.
   Confidence: high.

3. **Type-8-is-free (D-0063) is true and irrelevant to today's drain.**
   `initBonds(8) = 0`, but `gameImpls(8) = 0x0` and the proposer is on
   type 1. Confidence: high.

4. **Duplicate confirmed resubmissions are not happening.** One
   confirmation per 312 s window; sequential nonces; `gameCount = 36`.
   Confidence: high for this window (nonces 0–35, post-wipe).

5. **Sepolia gas price does not explain the 0.08 figure.** Gas ≈ 0.001 ETH
   at ~2 gwei; current base fee ~1 gwei. Confidence: high.

6. **`gas-runway.sh` 0.027 ETH/day is a measurement artifact**, not a
   second rate. Confidence: high (see above).

7. **Custom-proposer bug.** Ruled out — stock binary, `USE_CUSTOM_PROPOSER`
   unset. Confidence: high.

### Mitigation options (menu, not a verdict)

Choosing among these is an operator decision. Effects are against the
**~23 ETH/day wallet-drain figure while funded and posting type-1 games
every 5 minutes**. None of these was applied.

| Option | What it would change | Effect on ~23 ETH/day |
|---|---|---|
| A. Lengthen `SEPOLIA_PROPOSER_INTERVAL`, stay on type 1 | Still pays 0.08 ETH bond + ~0.001 ETH gas **per game** | 30m → ~3.9 ETH/day; 1h → ~1.94; 6h → ~0.32; 24h → ~0.081. Linear in game count. Does not unlock the 2.88 already in DelayedWETH. |
| B. Finish step 8b (register type 8) **and** switch `PROPOSER_GAME_TYPE` to 8, then stop+start the proposer (D-0063 Finding 7) | `initBonds(8)` is already 0; `gameImpls(8)` is still `0x0`, so this cannot be done *before* 8b | Gas-only: ~0.29 ETH/day at 5m, ~0.024 at 1h. Drops the 23 ETH/day figure by ~98.7%. Type 1 left running after 8b would keep paying 0.08 **and** post non-respected games (D-0063 Finding 3c). |
| C. `setInitBond(1, 0)` without registering type 8 | L1PAO call; changes the type-1 security model; does not make type 1 playable (D-0061: types 0/1 cannot play on this pin) | Same gas-only rate as B at type 1. Does not advance 8b. |
| D. Pause / leave the proposer dry until 8b | Already the de-facto state (0.03285 ETH, estimate-fail loop) | Drain ≈ 0 until refunded. Anchor stops advancing (already stopped). |
| E. Fund the proposer at the current rate | Faucet ~0.3 ETH/day and reconciler ≤2.4 ETH/day cannot cover ~23 ETH/day. Today's 2.45 ETH from `0x16cae6ae…` bought ~30 games (~2.5 h). | Does not change the rate; only how long until the next dry. |
| F. Recover the 2.88 ETH from DelayedWETH after games resolve | One-time, path not exercised here; unresolved type-1 games hold the credit | Recovers stock, does not change the posting rate. |

This finding gates step 8b's *economics*, not its other preconditions
(prestate / F7-12 / operator sequence). Type 8 being free is verified.
Type 8 being unimplemented is also verified. Whether 8b is "worth
attempting" on funding grounds: staying on type 1 at 5m is not
fundable from the documented sources; switching to a registered
type-8 game is the option that removes the 0.08 ETH `value` without
giving up a 5-minute cadence. That is a description of the data, not a
recommendation to run 8b tonight.

---

## R-13 (2026-08-23) — type-1 bond comes back: 0.08 ETH returned after resolve + two delays

Sequel to **R-12**. Live Sepolia, operator machine, repo `8f68056` at start.
Exactly **one** game was resolved (index 0). At hand-back `gameCount` is 42
(the 1h proposer posted games 41 and 42); **41 others stay `IN_PROGRESS`**.
`PROPOSER_GAME_TYPE` was left at `1`. No `scripts/` changes. `.env.sepolia`
was edited for `SEPOLIA_PROPOSER_INTERVAL` only (gitignored; not in this
commit).

The round trip is transaction-proven. The 0.08 ETH init bond from game 0
landed back in `PROPOSER_ADDRESS`. Recovery is not a single call: it is
`resolveClaim` → `resolve` → wait `disputeGameFinalityDelaySeconds = 1800`
→ `claimCredit` (unlock) → wait `DelayedWETH.delay() = 3600` →
`claimCredit` (withdraw). R-12's 10800s float window missed the 1800s
finality airgap. The **protocol-delay lower bound** is
`7200 + 1800 + 3600 = 12600s`, assuming resolve/unlock/withdraw land
the instant each gate opens. This run did not measure that: game 0
`createdAt = 1787435052`, unlock `withdrawals.timestamp = 1787505900`,
withdraw ready 3600s later → **74448s** (20.68 h) create-to-withdraw.
Calling 12600s "measured" would understate operational float.

### Step 0 — throttle to 1h (done before any resolve)

Overnight `launchd` sleep (23:45 PT) had already stopped the stack. The
03:00 wake failed: proposer 0.008 ETH and batcher 0.145 ETH, both under the
0.15 start floor. By this run the proposer was 0.308 ETH and the batcher
1.790 ETH. Pidfile was gone; `pgrep` found no `op-proposer`.

`SEPOLIA_PROPOSER_INTERVAL` was `5m`; set to `1h`. Then `stop_bg
op-proposer` (confirmed down) and `dev-sleep.sh wake` so L2 existed for
the start script's `wait_for_rpc`. A re-run of `06-start-proposer-sepolia.sh`
alone would have failed on a dead L2, and `start_bg` would have been a
silent no-op had the pid still been alive (D-0063 Finding 7).

| | Value |
|---|---|
| old pid | **none** (pidfile missing). Last live pid before sleep was **95838** (R-12 / sleep log). |
| `stop_bg` | `op-proposer not running (no pidfile)` |
| new pid | **29994** (`ps` `op-proposer`, started 2026-08-23 09:52 PT) |
| `PROPOSER_GAME_TYPE` | still `1` |
| factory started against | `0x67f9e427c716586ecc0dc0b62baa8cd05e43262f` (post-wipe) |

Live log — not the script's exit 0:

```text
t=2026-08-23T09:52:22-0700 lvl=info msg="No proposals found for at least proposal interval, submitting proposal now" proposalInterval=1h0m0s
```

The restart immediately posted game 41 (last proposal was >9 h earlier):
`tx=0x942a3b9cf15873376f49875ff15312da209f13519a22e0423ff1fc94a8b4b8a9`
nonce 40 → 41, `gameCount` 40 → 41. That is the "keep posting, throttled"
condition. Next `create` is due ~1 h later. Resolve txs used nonces 41–42
after that create confirmed, so there was no nonce race.

### Re-read of game 0 (before any send)

Factory `0x67f9e427c716586ecc0dc0b62baa8cd05e43262f`, L1 block 11551244.
Every value matched R-12 / the brief:

```text
$ cast call $FACTORY 'gameCount()(uint256)'
40

$ cast call $FACTORY 'gameAtIndex(uint256)(uint32,uint64,address)' 0
1
1787435052
0xb5acB19f808296Bb555318cBCF862CbBD9b33c4A

$ cast call $GAME 'status()(uint8)'
0
$ cast call $GAME 'resolvedAt()(uint64)'
0
$ cast call $GAME 'createdAt()(uint64)'
1787435052
$ cast call $GAME 'rootClaim()(bytes32)'
0x9cee12dda25fa9d7560f21c748781b6cc2508dc8be6221c8a0664e6905e333fc
$ cast call $GAME 'l2BlockNumber()(uint256)'
21
$ cast call $GAME 'claimDataLen()(uint256)'
1
$ cast call $GAME 'maxClockDuration()(uint64)'
7200
$ cast call $GAME 'anchorStateRegistry()(address)'
0x8f98EB7f5EbB9a0de0AcF8Fa7916b67b9295F480
$ cast call $GAME 'credit(address)(uint256)' 0x350A0F7becCE56598962C501CaA02f900F256803
0
$ cast call $GAME 'weth()(address)'
0xA9DB650cd2959A127083bf6448074E6b01b14B80
$ cast call $GAME 'getChallengerDuration(uint256)(uint64)' 0
7200

$ cast call $WETH 'delay()(uint256)'
3600
$ cast call $WETH 'withdrawals(address,address)(uint256,uint256)' $GAME $PROPOSER
0
0
$ cast balance $WETH --ether
3.200000000000000000

$ cast call $FACTORY 'initBonds(uint32)(uint256)' 1
80000000000000000
$ cast call $FACTORY 'gameImpls(uint32)(address)' 8
0x0000000000000000000000000000000000000000

$ cast call $ASR 'disputeGameFinalityDelaySeconds()(uint256)'
1800
$ cast call $ASR 'respectedGameType()(uint32)'
1
```

Static `resolveClaim(0,0)` from `address(0)` returned `0x` (would succeed).
Static `resolve()` from `address(0)` reverted `0x9a076646` =
`OutOfOrderResolution()`. Static `claimCredit` / `closeGame` reverted
`0xc105260a` = `GameNotResolved()`. `resolveClaim` / `resolve` are **not**
`onlyAuthorized` on `PermissionedDisputeGame` — only `move` / `step` /
`initialize` are. Resolution is permissionless; a non-proposer wallet can
pay the gas. This run still used `PROPOSER_ADDRESS` so the nonce/balance
delta is on the same wallet.

### 1. `resolveClaim(0, 0)` — real transaction

Immediately before send, L1 block 11551316. Proposer 0.227692960434396282 ETH
(the 0.308 → 0.227 drop is game 41's 0.08 bond + create gas, not resolve).
Nonce 41. `status = 0`, `credit = 0`.

```text
$ cast send $GAME 'resolveClaim(uint256,uint256)' 0 0
# from 0x350A0F7becCE56598962C501CaA02f900F256803

$ cast receipt 0x1f673629e8cc9fb2e6d23429a8d1f4910c2dac226abe6a4685c99aa18cc3569a --json
  transactionHash=0x1f673629e8cc9fb2e6d23429a8d1f4910c2dac226abe6a4685c99aa18cc3569a
  status=0x1
  gasUsed=0x1b134          # 110900
  effectiveGasPrice=0x4078049d  # 1081607325
  blockNumber=0xb04256
  to=0xb5acb19f808296bb555318cbcf862cbbd9b33c4a
  type=0x2
  cost = 110900 * 1081607325 = 119950252342500 wei = 0.000119950252342500 ETH
```

Immediately after:

```text
$ cast call $GAME 'status()(uint8)'
0
$ cast call $GAME 'resolvedAt()(uint64)'
0
$ cast call $GAME 'credit(address)(uint256)' $PROPOSER
80000000000000000
```

`credit` became 0.08 ETH on `resolveClaim`, while the game was still
`IN_PROGRESS`. `_distributeBond` writes `normalModeCredit`; `resolve()`
only flips status. R-12's "credit reads 0 now" is therefore the unresolved
state, not a missing method.

### 2. `resolve()` — real transaction; outcome `DEFENDER_WINS`

```text
$ cast send $GAME 'resolve()'

$ cast receipt 0x3ed2f9edb88922edb261549051440858d8caee9046bc483bcdba56f08099cf2f --json
  transactionHash=0x3ed2f9edb88922edb261549051440858d8caee9046bc483bcdba56f08099cf2f
  status=0x1
  gasUsed=0x9193           # 37267
  effectiveGasPrice=0x38106c7e  # 940600446
  blockNumber=0xb04258
  to=0xb5acb19f808296bb555318cbcf862cbbd9b33c4a
  type=0x2
  cost = 37267 * 940600446 = 35053356821082 wei = 0.000035053356821082 ETH
```

```text
$ cast call $GAME 'status()(uint8)'
2
$ cast call $GAME 'resolvedAt()(uint64)'
1787504028
$ cast call $ASR 'isGameResolved(address)(bool)' $GAME
true
$ cast call $ASR 'isGameFinalized(address)(bool)' $GAME
false
```

`2 = DEFENDER_WINS`. Unchallenged root, `counteredBy == 0`. **Not**
`1 = CHALLENGER_WINS`. Scan of all 41 factory games: the only non-zero
`status` is index 0. Games 1, 39, 40 (and the rest) remain `0`.

### Anchors — unchanged by resolve itself

```text
# immediately BEFORE resolveClaim (L1 11551316)
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 1
0xdead000000000000000000000000000000000000000000000000000000000000
0
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 8
0xdead000000000000000000000000000000000000000000000000000000000000
0

# immediately AFTER resolve()
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 1
0xdead000000000000000000000000000000000000000000000000000000000000
0
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 8
0xdead000000000000000000000000000000000000000000000000000000000000
0
```

The brief expected `resolve()` to advance `anchors(1)`. It does not.
`FaultDisputeGame.resolve()` only sets `status` / `resolvedAt`.
`setAnchorState` runs later, inside `closeGame()`, which `claimCredit`
calls once `isGameFinalized` is true (`resolvedAt + 1800s`, i.e.
2026-08-23 17:23:48 UTC).

**Type-8 interaction (read the deployed ASR, not the brief's mental
model):** `AnchorStateRegistry` v3.9.0 has a **single** `anchorGame`, not
per-type slots. `anchors(GameType)` is a legacy alias that **ignores**
the argument and returns `getAnchorRoot()`. So if/when `closeGame`
succeeds, **both** `anchors(1)` and `anchors(8)` will display the same
new root — that is one shared view, not type 8 being overwritten as a
separate store. Recorded here so a later `anchors(8)` change is not
misread as a step-8b collision. `respectedGameType()` is still `1`.

### 3. Claim leg — unlock, then ETH returns after the WETH delay

Deployed sequence (read from
`optimism/packages/contracts-bedrock/src/dispute/FaultDisputeGame.sol`
`claimCredit` / `closeGame` and `DelayedWETH.sol`):

1. `claimCredit(proposer)` — first call after finality: `closeGame()`
   (sets bond mode, `try setAnchorState`), then `weth.unlock(recipient,
   credit)` and **returns**. ETH does not move yet.
2. Wait `DelayedWETH.delay() = 3600`.
3. `claimCredit(proposer)` again — `weth.withdraw` + ETH transfer to
   the proposer.

```text
$ cast call $GAME 'claimCredit(address)' $PROPOSER   # ~1 min after resolve
# revert 0x4851bd9b = GameNotFinalized()

$ cast call $ASR 'isGameFinalized(address)(bool)' $GAME   # 17:24:21Z
true

$ cast send $GAME 'claimCredit(address)' $PROPOSER
# first call = closeGame + unlock

$ cast receipt 0x700f5c0df64110619896327a3bf265dac239fa47b88ad0826dddd86c60927746 --json
  transactionHash=0x700f5c0df64110619896327a3bf265dac239fa47b88ad0826dddd86c60927746
  status=0x1
  gasUsed=0x3d039          # 249913
  effectiveGasPrice=0x3dc3d548  # 1036244296
  blockNumber=0xb042f1
  to=0xb5acb19f808296bb555318cbcf862cbbd9b33c4a
  type=0x2
  cost = 249913 * 1036244296 = 258970920746248 wei = 0.000258970920746248 ETH
```

Immediately after unlock:

```text
$ cast call $ASR 'anchorGame()(address)'
0xb5acB19f808296Bb555318cBCF862CbBD9b33c4A
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 1
0x9cee12dda25fa9d7560f21c748781b6cc2508dc8be6221c8a0664e6905e333fc
21
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 8
0x9cee12dda25fa9d7560f21c748781b6cc2508dc8be6221c8a0664e6905e333fc
21
$ cast call $ASR 'respectedGameType()(uint32)'
1
$ cast call $WETH 'withdrawals(address,address)(uint256,uint256)' $GAME $PROPOSER
80000000000000000
1787505900
$ cast call $GAME 'credit(address)(uint256)' $PROPOSER
80000000000000000
$ cast balance $PROPOSER --ether
0.227278985904486452
$ cast balance $WETH --ether
3.280000000000000000
$ cast call $GAME 'claimCredit(address)' $PROPOSER
# revert: DelayedWETH: withdrawal delay not met
```

**`anchors(8)` displayed a new value.** That is the stop-and-report
condition in the brief. It is **not** a separate type-8 slot being
written: `anchors(GameType)` ignores its argument and both calls now
return the single `anchorGame` (game 0, L2 block 21). Type 8 is still
unregistered (`gameImpls(8) = 0x0`); `respectedGameType` is still `1`.
No other game was resolved after this observation. The remaining
permitted action was this same game's DelayedWETH withdraw after 3600s
(`unlock` timestamp 1787505900 → withdraw ready 2026-08-23 18:25:00Z).

Proposer wallet after unlock (nonce 44): `0.227278985904486452` ETH.
Still no +0.08 at that instant. DelayedWETH still held 3.28 ETH
(41 × 0.08). During the 1h WETH wait the throttled proposer posted
game 42 (`tx=0x3db3571e…a176db`, nonce 44, confirmed ~10:55 PT) and an
inbound top-up arrived — so the next wallet snapshot is not a clean
continuation of 0.227.

### 3b. `claimCredit` #2 — ETH lands

Immediately before withdraw (L1 11551774), after the intervening create
+ top-up:

```text
$ cast balance $PROPOSER --ether
0.446177692598508052
$ cast nonce $PROPOSER
45
$ cast balance $WETH --ether
3.360000000000000000
$ cast call $WETH 'withdrawals(address,address)(uint256,uint256)' $GAME $PROPOSER
80000000000000000
1787505900
$ cast call $GAME 'credit(address)(uint256)' $PROPOSER
80000000000000000
$ cast call $GAME 'claimCredit(address)' $PROPOSER --from $PROPOSER
0x

$ cast send $GAME 'claimCredit(address)' $PROPOSER

$ cast receipt 0x30f1d19ce7c05fef501a23a8554a526ae4b220028ed3a36a5c59c0078b4638b2 --json
  transactionHash=0x30f1d19ce7c05fef501a23a8554a526ae4b220028ed3a36a5c59c0078b4638b2
  status=0x1
  gasUsed=0x15c91          # 89233
  effectiveGasPrice=0x4187a2b2  # 1099408050
  blockNumber=0xb0441f
  to=0xb5acb19f808296bb555318cbcf862cbbd9b33c4a
  type=0x2
  cost = 89233 * 1099408050 = 98103478525650 wei = 0.000098103478525650 ETH
```

Immediately after:

```text
$ cast balance $PROPOSER --ether
0.526079589119982402
$ cast nonce $PROPOSER
46
$ cast balance $WETH --ether
3.280000000000000000
$ cast call $WETH 'withdrawals(address,address)(uint256,uint256)' $GAME $PROPOSER
0
1787505900
$ cast call $GAME 'credit(address)(uint256)' $PROPOSER
0
$ cast call $GAME 'status()(uint8)'
2
$ cast call $FACTORY 'gameCount()(uint256)'
42
```

**Wallet delta on the withdraw tx: +0.079901896521474350 ETH**
(`0.526079589119982402 − 0.446177692598508052`), which is
`0.08 − 0.000098103478525650` gas. DelayedWETH dropped by exactly
0.08 (`3.36 → 3.28`). That is the ETH-back-in-the-wallet line R-12
could not claim. Scan of all 42 factory games: the only non-zero
`status` is still index 0 (`2`). Anchors after withdraw are unchanged
from after unlock (same shared `anchorGame`).

Do not read the whole-session wallet delta as the recovery number.
Between unlock and withdraw the proposer created game 42 (another
0.08 out) and received an inbound top-up. The withdraw-leg pair above
is the isolated proof.

### 4. Whole-sequence cost, and implied 1h-cadence scale

| Step | Proven by | Gas | ETH |
|---|---|---|---|
| `resolveClaim(0,0)` | transaction `0x1f673629…cc3569a` | 110900 | 0.000119950252342500 |
| `resolve()` | transaction `0x3ed2f9ed…099cf2f` | 37267 | 0.000035053356821082 |
| `claimCredit` #1 (unlock) | transaction `0x700f5c0d…0927746` | 249913 | 0.000258970920746248 |
| `claimCredit` #2 (withdraw) | transaction `0x30f1d19c…4638b2` | 89233 | 0.000098103478525650 |
| **recovery total** | | 487313 | **0.000512078008435480** |

At a 1h interval (~24 games/day):

| | Per game | Per day (×24) |
|---|---|---|
| Recovery gas (measured) | 0.000512 ETH | **0.0123 ETH** |
| Create gas (R-12, ~0.001) | ~0.001 ETH | ~0.024 ETH |
| Bond (recycled, not burned) | 0.08 ETH | 1.92 ETH posted / 1.92 ETH returned after the window |

Steady-state **float** is bonds locked in the unrecoverable window, not
a burn rate. R-12 used `7200 + 3600 = 10800s` → 0.24 ETH at 1h. The
deployed path adds the 1800s finality airgap **between** resolve and
unlock. The protocol-delay lower bound is
`7200 + 1800 + 3600 = 12600s` (3.5 h), not a measured round trip —
this game's create-to-withdraw was 74448s because resolution waited
for this task, not for clock expiry.

A 3.5 h minimum at a 1h interval means posts at hours 0, 1, 2, and 3
are all still locked when hour 3 posts: **four** 0.08 ETH bonds,
**0.32 ETH**, before the first can return at 3.5 h. The time-average
`3.5 × 0.08 = 0.28` is not a funding floor — it leaves the fourth
`create` unfunded even if every recovery hits the theoretical
minimum. 5m divides 12600s evenly (42 games), so average and ceiling
match.

| Interval | R-12 (10800s, average) | Protocol-min average (12600s) | Protocol-min **funding floor** (⌈window/interval⌉ × 0.08) |
|---|---|---|---|
| 5m | ~2.77 ETH | 3.36 ETH | **3.36 ETH** (42 bonds) |
| 1h | ~0.24 ETH | 0.28 ETH | **0.32 ETH** (4 bonds) |

All four questions were answered by transaction, not inference:
(1) `resolveClaim` succeeded, (2) `resolve` → `DEFENDER_WINS`,
(3) 0.08 ETH returned to the proposer wallet, (4) recovery gas
0.000512 ETH/game.

### `gas-runway.sh` at hand-back

```text
$ FORTEL2_ENV=.env.sepolia ./scripts/gas-runway.sh
# exit 0
appended sample ts=1787509689 l2_block=38201
Samples file: …/data-sepolia/gas-samples.jsonl (18 sample(s))
role=BATCHER  balance_eth=1.786662  burn_eth_per_day=0.031002  days_to_floor=52.792  floor_eth=0.15
role=PROPOSER balance_eth=0.526080  burn_eth_per_day=0.027187  days_to_floor=13.833  floor_eth=0.15
```

Same artifact as R-12: the proposer `0.027 ETH/day` skips top-up
intervals and is not the posting-rate drain. Recorded; not the answer.

### What this does *not* decide

Whether to automate resolution of the remaining 41 `IN_PROGRESS` games,
and at what cadence, is an operator call. Recovery of the ~3.28 ETH
still in DelayedWETH is a one-time follow-up, not executed here.
Switching to type 8 is still step 8b (`gameImpls(8) = 0x0`). Resolution
is permissionless (static `resolveClaim` from `address(0)` returned
`0x`; `onlyAuthorized` does not wrap `resolve` / `resolveClaim` /
`claimCredit`), so recovery gas need not compete with the proposer's
bond budget — observed, not acted on.

---

## R-14 (2026-08-23) — reusable resolution script; game 1 resolved; remainder is a re-run

Sequel to **R-13**. Live Sepolia, operator machine, repo `beaebc1` at
start (still `origin/main` at hand-back). New script
`scripts/resolve-games-sepolia.sh` (mode 755). Dry-run is the default;
`--execute` is required to broadcast. Resolution stays permissionless;
the script signs with `ADMIN_ADDRESS` so it never shares a nonce with
the hourly proposer. `claimCredit`'s recipient is always
`PROPOSER_ADDRESS`.

This session proved the planner, the one-game execute, and idempotency
by transaction. It did **not** finish every leg on every game: the two
mandatory waits still apply, and the bulk `--execute` of games 2–42 was
not sent from this session. The script is left so the operator can run
the same command again.

`PROPOSER_GAME_TYPE` is still `1`. `gameImpls(8)` is still `0x0`.
Nothing under `data/` is tracked. `scripts/lib.sh` and the proposer
start script were not edited.

### Independent re-read (before any send)

L1 block 11552668, now `1787520530` (2026-08-23 21:28:50 UTC). RPC
passed through `redact_rpc_url`.

```text
$ cast call $FACTORY 'gameCount()(uint256)'
45

$ cast balance $WETH --ether
3.520000000000000000          # 44 × 0.08; game 0 already withdrawn in R-13

$ cast call $FACTORY 'initBonds(uint32)(uint256)' 1
80000000000000000 [8e16]

$ cast call $FACTORY 'gameImpls(uint32)(address)' 8
0x0000000000000000000000000000000000000000

$ cast call $ASR 'disputeGameFinalityDelaySeconds()(uint256)'
1800
$ cast call $WETH 'delay()(uint256)'
3600
$ cast call $ASR 'respectedGameType()(uint32)'
1
$ cast call $ASR 'anchorGame()(address)'
0xb5acB19f808296Bb555318cBCF862CbBD9b33c4A
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 1
0x9cee12dda25fa9d7560f21c748781b6cc2508dc8be6221c8a0664e6905e333fc
21
```

Sampled games (clock = 7200s):

| index | createdAt | age | status | credit | claimDataLen |
|---|---|---|---|---|---|
| 0 | 1787435052 | 85486s | 2 | 0 | 1 |
| 1 | 1787435364 | 85174s | 0 | 0 | 1 |
| 42 | 1787511192 | 9346s | 0 | 0 | 1 |
| 43 | 1787514816 | 5722s | 0 | 0 | 1 |
| 44 | 1787518440 | 2098s | 0 | 0 | 1 |

42 games (indexes 1–42) are clock-expired and still `IN_PROGRESS`.
42 × 0.08 = **3.36 ETH** recoverable this pass. Games 43–44 hold the
other 0.16 ETH and are not eligible yet. `SEPOLIA_PROPOSER_INTERVAL`
is still `1h`; pid `29994` (`op-proposer`) has been up since the R-13
restart. Create spacing on 41→44 is 3624s.

ADMIN `0xBB3E19811B2c3423069B54BDFF3e90Dd8094bb0F` ≠ PROPOSER
`0x350A0F7becCE56598962C501CaA02f900F256803`. ADMIN 1.542 ETH
(nonce 47); PROPOSER 0.283 ETH (nonce 49). Enough ADMIN gas; no
reason found to share the proposer nonce.

### 1. Dry-run (default) — all games, txs_sent=0

```text
$ FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh
# exit 0
mode=dry-run
gameCount=45
weth_balance_eth=3.520000000000000000
selected_count=42
selected_indexes=1,2,…,42
actions_ready=84
txs_sent=0
recoverable_eth=3.360000000000000000
locked_unexpired_eth=0.160000000000000000
estimated_gas_eth=0.006195014662426506   # resolveClaim+resolve only, this pass
game 0 SKIP zero_credit
game 1 ACTION resolveClaim,resolve
…
game 42 ACTION resolveClaim,resolve
game 43 SKIP clock_unexpired ready_at=1787522016 age=5760
game 44 SKIP clock_unexpired ready_at=1787525640 age=2136
dry-run: sending nothing (pass --execute to broadcast)
```

Matches the independent read: 42 eligible, 3.36 ETH, 0.16 ETH still
clock-locked, nothing sent. ADMIN nonce stayed 47.

### 2. `--execute --max-games 1` — game 1, two txs

Game 1 = `0x107f9CF7453FbD55F9b344F4537FAC0Fc3BEb99B`. Sender ADMIN.

```text
$ FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh --execute --max-games 1
# exit 0
selected_indexes=1
sending game=1 leg=resolveClaim to=0x107f9CF7453FbD55F9b344F4537FAC0Fc3BEb99B
SENT leg=resolveClaim tx=0xd9d03f87d12d571037b32ded10e22f959f55f7ec3596f9c50dce31b95b816fcd gasUsed=110900 effectiveGasPrice=1047334132 cost_wei=116149355238800
sending game=1 leg=resolve to=0x107f9CF7453FbD55F9b344F4537FAC0Fc3BEb99B
SENT leg=resolve tx=0xa3b7b2c4afba7a620c85892cf92744cc3ed8334e93c62e871ce95f803d942ee1 gasUsed=37267 effectiveGasPrice=937714697 cost_wei=34945813613099
game 1 wait finality
txs_sent=2
```

Receipts re-read:

```text
$ cast receipt 0xd9d03f87d12d571037b32ded10e22f959f55f7ec3596f9c50dce31b95b816fcd --json
  status=0x1  gasUsed=0x1b134 (110900)  effectiveGasPrice=0x3e6d0cf4
  from=0xbb3e19811b2c3423069b54bdff3e90dd8094bb0f
  to=0x107f9cf7453fbd55f9b344f4537fac0fc3beb99b

$ cast receipt 0xa3b7b2c4afba7a620c85892cf92744cc3ed8334e93c62e871ce95f803d942ee1 --json
  status=0x1  gasUsed=0x9193 (37267)  effectiveGasPrice=0x37e46409
  from=0xbb3e19811b2c3423069b54bdff3e90dd8094bb0f
  to=0x107f9cf7453fbd55f9b344f4537fac0fc3beb99b
```

Immediately after:

```text
$ cast call $GAME1 'status()(uint8)'
2
$ cast call $GAME1 'resolvedAt()(uint64)'
1787521068
$ cast call $GAME1 'credit(address)(uint256)' $PROPOSER
80000000000000000
$ cast call $ASR 'isGameResolved(address)(bool)' $GAME1
true
$ cast call $ASR 'isGameFinalized(address)(bool)' $GAME1
false
```

`2 = DEFENDER_WINS`. Gas units match R-13 exactly (110900 / 37267).
Cost 0.000151095 ETH (gas price a touch under R-13's). ADMIN nonce
47 → 49. PROPOSER nonce stayed **49**. PROPOSER balance unchanged
(0.282828 ETH). DelayedWETH still 3.52 ETH — resolve does not move
the bond. No 0.08 returned yet; that is the two `claimCredit` legs
after `resolvedAt + 1800` and `unlock + 3600`.

### Anchors — unchanged by resolve, as R-13 said

```text
# before and after the two game-1 txs
$ cast call $ASR 'anchorGame()(address)'
0xb5acB19f808296Bb555318cBCF862CbBD9b33c4A
$ cast call $ASR 'anchors(uint32)(bytes32,uint256)' 1
0x9cee12dda25fa9d7560f21c748781b6cc2508dc8be6221c8a0664e6905e333fc
21
```

Monotonic-advance watch: **no movement**. `setAnchorState` still
runs inside `closeGame` on the first `claimCredit`. Type 8 is still
unregistered. Nothing other than "resolve does not touch the shared
anchor" was observed; the 8b question stays open until unlocks run.

### 3. Idempotency re-run — txs_sent=0

```text
$ FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh --execute --max-games 1
# exit 0
selected_indexes=1
action_games=0 wait_games=1
actions_ready=0
txs_sent=0
game 1 WAIT finality ready_at=1787522868 ready_in=1743
EXECUTE done
txs_sent=0
gas_spent_wei=0
```

ADMIN nonce still 49. The script distinguished "already resolved,
not finalized" from "needs resolve" by `status` / `resolvedAt` /
`isGameFinalized` timing, not by counting prior calls. Demonstrated
by transaction (a second send would have incremented the nonce).

### 4. Remainder — operator re-runs the same script

Games 2–42 were **not** resolved in this session (bulk `--execute`
was not sent). Games 43–44 were not eligible. Game 1 is waiting on
finality until `resolvedAt + 1800 = 1787522868`
(2026-08-23 22:07:48 UTC), then `claimCredit` unlock, then
`DelayedWETH.delay() = 3600` before withdraw.

```text
FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh              # dry-run
FORTEL2_ENV=.env.sepolia ./scripts/resolve-games-sepolia.sh --execute    # ready legs only
```

Each invocation does whatever legs are currently possible and
reports what it is waiting on. It does not sleep. Re-running after
either delay is the intended path.

The two `claimCredit` legs are distinguished by
`DelayedWETH.withdrawals(game, proposer)`:
amount=0 and timestamp=0 → unlock; amount>0 and delay not met →
wait; amount>0 and delay met → withdraw; amount=0 and timestamp>0
and credit=0 → skip (`zero_credit`). A game with
`claimDataLen() ≠ 1` is skipped as `multi_claim` (none seen).

### Offline tests

`test-helpers.sh` 194 → 202 PASS (8 appended; none removed). Cases
drive `--analyze-only` over a snapshot JSON, no cast / RPC /
`.env.sepolia`:

- unexpired clock is not selected
- `status=2` with `resolvedAt` set is not re-resolved
- unlocked but inside the WETH delay reports `WAIT weth_delay`
- zero remaining credit is skipped
- dry-run / analyze-only reports `txs_sent=0` and never `cast send`
- `--max-games 3` selects exactly indexes 1,2,3
- `--execute` is rejected with `--analyze-only`

`bash -n scripts/resolve-games-sepolia.sh` passes. Mode 755.

### `gas-runway.sh` at hand-back

```text
$ FORTEL2_ENV=.env.sepolia ./scripts/gas-runway.sh
# exit 0
appended sample ts=1787521379 l2_block=44045
Samples file: …/data-sepolia/gas-samples.jsonl (19 sample(s))
role=BATCHER  balance_eth=1.784749  burn_eth_per_day=0.030777  days_to_floor=53.116  floor_eth=0.15
role=PROPOSER balance_eth=0.282828  burn_eth_per_day=0.041021  days_to_floor=3.238  floor_eth=0.15
```

Same artifact as R-12/R-13: the proposer burn figure skips top-up
intervals and is not the posting-rate drain. Recorded; not the
answer. PROPOSER 0.283 ETH is above the 0.15 floor and covers the
next 0.08 create plus gas.

### Measured costs so far (one game, resolve legs only)

| Step | Proven by | Gas | ETH |
|---|---|---|---|
| `resolveClaim(0,0)` | `0xd9d03f87…5b816fcd` | 110900 | 0.000116149355238800 |
| `resolve()` | `0xa3b7b2c4…3d942ee1` | 37267 | 0.000034945813613099 |
| **this session** | | 148167 | **0.000151095168851899** |

R-13's full four-leg total was 0.000512 ETH/game. This session did
not reach unlock/withdraw, so it does not replace that number.
42 remaining resolve-pairs at this gas price are ~0.006 ETH of ADMIN
gas (dry-run estimate 0.006195 for 42, of which game 1 is done).

### What this does *not* decide

Whether to schedule the script (launchd / cron / daily health), and
which wallet should own recovery gas long-term. ADMIN worked; that
is not a standing assignment. What a much newer shared anchor means
for step 8b is still unanswerable — this run never called
`closeGame`. Type 8 is still `gameImpls(8) = 0x0`.
