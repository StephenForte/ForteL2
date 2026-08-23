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
