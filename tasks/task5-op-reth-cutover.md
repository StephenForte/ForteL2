# Task 5 evidence — op-reth live Sepolia sequencer cutover

**STATUS: Phase B cutover held (2026-09-02). Overnight PASS. Viewer CORS bounce PASS. Closeout deposit + smoke + Access write PASS. Reth withdrawal initiate PASS (2026-09-03); prove/finalize not done.** Live EL is **op-reth**. First reth block **473032** extends **473031**. Access write L2 `0x9aaf10bf…`. Withdraw initiate L2 `0x1d3c00cc…` (0.0002 ETH, block **510822**). **STATUS complete is not true** until prove + finalize on reth (no Anvil warp) are evidenced. Phase A remains merged (#192/#193/#195). #201 merged. This file is the one `tasks/` write. L1 provider URLs, JWTs, and keys are never written here.

**Date opened:** 2026-09-01  
**PRD:** `tasks/prd-op-reth-migration.md` §8 Task 5 / §9 / §10  
**Decisions consumed:** D-0109 (selector + pid name), D-0110 (identifiers; live start now honors reth), D-0114 (candidate datadir), D-0116 (finalize gate)  
**Branch:** `feat/op-reth-task5-cutover`  
**Lever:** `FORTEL2_EL` in `.env.sepolia` (default `geth`). Merging Phase A flips nothing.

## SafeDB (the open design question)

**Decision (Phase A, argued here):** the live sequencer op-node **keeps `$DATA_DIR/safedb`**. The sidecar store `$DATA_DIR/l2/op-reth-safedb` **stays with the sidecar role**. Do not copy, merge, or swap.

Evidence:

1. SafeDB is an op-node L1→L2 safe-head index, not an EL artifact. Task 3/4 proved the same L1-derived L2 hashes on geth and reth, so existing live records stay valid after `enginekind=reth`.
2. D-0116 / D-0082: the store is **enable-forward**. Live `$DATA_DIR/safedb` has records since Phase 7 (D-0082). Sidecar SafeDB only records from the Task 4 enable L1 (~11609838). Switching the live op-node onto the sidecar store would make pre-Task-4 `optimism_safeHeadAtL1Block` fail the same way games 63–65 did — the challenger still queries those L1 heads.
3. The brief's "sidecar path stays with the sidecar" constraint forbids stealing that directory for the live role. A second op-node (sidecar) and the live op-node must not share a store.
4. `fortel2_live_safedb_path` refuses `OP_NODE_SAFEDB_PATH` when it equals the sidecar path (helper test can go red). Live reth start passes `--safedb.path=$DATA_DIR/safedb` (or the operator's existing `OP_NODE_SAFEDB_PATH` if it is not the sidecar).

Interim: Phase B health must include a live `optimism_safeHeadAtL1Block` on a **pre-Task-4** L1 and a post-cutover L1 (both must answer).

## Phase A deliverables

| Artifact | Role |
|---|---|
| `fortel2_live_el_pid` / `fortel2_live_enginekind` / `fortel2_live_el_log` / `fortel2_live_safedb_path` | selector helpers (default geth) |
| `scripts/04-start-sequencer-sepolia.sh` | honors `FORTEL2_EL`; `--verifier-only` for §9; `--print-plan` for tests |
| `scripts/sequencer-admin.sh` | loopback `admin_stopSequencer` / `start` / `status` |
| `scripts/cutover-to-reth-sepolia.sh` | `--rehearse` / `--preflight-only` / `--execute` (tty + `FORTEL2_CUTOVER_EXECUTE=1`) |
| `scripts/rollback-to-geth-sepolia.sh` | `--rehearse` verifier-first; `--execute` never stock 04-start |
| §10 surfaces | `status.sh`, `alert-watch.sh`, `dev-sleep.sh`, `start/stop-all-sepolia.sh`, `demo-checklist.sh`, `07-start-rpc-filter-sepolia.sh`, log names via helper |

Local 901 (`04-start-sequencer.sh`) still refuses reth. Learning oracles stay on geth. `reset-sepolia.sh` geth path no longer `rm -rf $DATA_DIR/l2` (preserves the candidate / rollback reth datadir).

Sidecar `admin_startSequencer` on :19547 is **refused** (would sequence the candidate while live geth is the producer). status/stop against the sidecar are allowed. Live admin RPC stays `:9547`.

## Mechanical rehearsal (Phase A)

### rollback verifier-first (fixtures)

```
$ ./scripts/rollback-to-geth-sepolia.sh --rehearse
PLAN rollback-to-geth-sepolia
  1. stop authenticated writes
  2. stop the op-reth pair …
  3. START_GETH=04-start-sequencer-sepolia.sh --verifier-only
     FORBIDDEN_FIRST_START=04-start-sequencer-sepolia.sh
  5. sequencer-admin.sh start
```

Helper tests: `--rehearse` must contain `--verifier-only` and `FORBIDDEN_FIRST_START`; stock 04-start as first start fails the test.

### sequencer-admin (loopback fixture + sidecar policy)

`scripts/test-helpers.sh` stands up a loopback JSON-RPC fixture and runs stop → status (`false`) → start. Non-loopback URLs refuse. Sidecar `:19547` start refuses unless `FORTEL2_ADMIN_ALLOW_SIDECAR_START=1`.

Live sidecar paste (2026-09-01, Phase A; candidate process was started **before** `--rpc.enable-admin` landed, so admin methods are not registered — fail-closed, not a start):

```
$ lsof -nP -iTCP:19547 -sTCP:LISTEN
op-node 88446  127.0.0.1:19547

$ ./scripts/sequencer-admin.sh status --rpc http://127.0.0.1:19547
admin status → http://127.0.0.1:19547 (admin_sequencerActive)
Error: … -32601: the method admin_sequencerActive does not exist/is not available

$ ./scripts/sequencer-admin.sh start --rpc http://127.0.0.1:19547 --dry-run
ERROR: refusing admin_startSequencer on sidecar :19547 — that would sequence the candidate datadir
```

Do not restart the sidecar in Phase A just to enable admin (candidate datadir). The next sidecar start (script now has `--rpc.enable-admin`) will accept status/stop; start stays refused on :19547. Fixture stop→status(false)→start is the mechanical proof.

## Phase B execution log (append only after Steve's go)

Window dispatched 2026-09-02 (announced 08:30 PT; this session started 11:45 PT). Next-morning sleep/wake result is part of this handoff (Task 6 entry). Secrets redacted.

### Step 0 — sidecar restart + catch-up (2026-09-02)

**Overnight context (not this session's mutation):**

| Item | Evidence |
|---|---|
| 23:45 sleep 2026-09-01 | `~/Library/Logs/fortel2-sleep.out.log` — stopped live geth stack **and** sidecar (`op-reth` / `op-reth-node`) |
| 03:00 wake | Did **not** run on schedule. First successful wake this morning is **11:14–11:15 PT** (`fortel2-wake.out.log`). `fortel2-wake.err.log` has `fdautil` permission errors (D-0118 class) plus earlier fund-floor refusals that later cleared |
| 11:30 alerts | `fortel2-alerts.out.log` — `active conditions: 0` |
| Pinned agents tree | `/Users/steveforte/fortel2-agents` at `bcac677` (#197) when this session started; `~/ForteL2` fast-forwarded to `3d04800` (#199). `check-launchd.sh` exit 0 (1 fdautil warning) |

**Live producer (unchanged — no `.env.sepolia` `FORTEL2_EL` line):**

| When (PT) | Item | Value |
|---|---|---|
| 11:15 wake | L2 head | 469806 |
| 11:15 wake | L1 | 11621262 |
| 11:48:26 | `status.sh` | op-geth 79296, op-node 79307, filter 79402, batcher 79503, proposer 79601, challenger 79855 — all RUNNING |
| 11:48:26 | L2 / L1 | L2 470809 / L1 11621427 |
| 11:48:26 | enginekind | live `geth` (confirmed via listen :9545 / :9547; sidecar ports empty before restart) |
| 11:54 | role funds | harvest / admin / batcher / proposer all above `sepolia-fund-check.sh` floors |

**Sidecar restart** (documented env; **not** `FORTEL2_ENV=.env.sepolia`; **not** `--wipe`):

```
unset FORTEL2_ENV
export L1_RPC_URL=…   # from .env.sepolia; not printed
export DATA_DIR=/Users/steveforte/src/fortel2/data-sepolia
export FORTEL2_EL=reth FORTEL2_RETH_PROFILE=sequencer_faultproof
export SEPOLIA_L1_RPC_RATE_LIMIT=10
./scripts/start-op-reth-verifier.sh
```

| Item | Outcome |
|---|---|
| Time | 11:48:26 PT |
| proofs init | already initialized; genesis `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d` |
| op-reth | pid 86439 — HTTP :19545 auth :19551 — EL head **449023** at attach |
| op-reth-node | pid 86508 — RPC :19547 — `--l2.enginekind=reth` `--rpc.enable-admin` rate-limit 10 |
| SafeDB | `$DATA_DIR/l2/op-reth-safedb` (sidecar only; live `$DATA_DIR/safedb` untouched) |
| Live lever | `.env.sepolia` still has **no** `FORTEL2_EL` line |

**Catch-up (in progress at first append — not yet lag ≤ 2):**

The brief's "~15 min at measured rates" assumed a near-tip sidecar. The candidate EL woke at **449023**; live safe was **470888**. Safe-head lag **21865**. Sidecar first walked recorded safe from 448405 → 449023, then walked L1 origins (~180 L1/min) with EL still at 449023.

| Time (PT) | live safe | side safe | safe lag | side EL | side current_l1 | live L1 head |
|---|---|---|---|---|---|---|
| 11:48:55 | 470726 | 448405 | 22321 | 449023 | (not sampled; L1 head 11621428) | 11621428 |
| 11:49:55 | 470726 | 449023 | 21703 | 449023 | (not sampled; L1 head 11621433) | 11621433 |
| 11:51:49 | 470888 | 449023 | 21865 | 449023 | 11618243 | 11621441 |
| 11:54:39 | 470888 | 449023 | 21865 | 449023 | 11618762 | 11621456 |
| 11:55:39 | 470888 | 449423 | 21465 | 449425 | 11618878 | (EL insert started; +402 L2 / 30s) |

`--preflight-only` **not run** while lag > 2. Window steps 1–7 **not started**. Neither datadir wiped. Learning oracles still on geth.

**Catch-up closed (12:19:12 PT) — lag 0, hashes match:**

| Time (PT) | live safe | side safe | safe lag | side EL | note |
|---|---|---|---|---|---|
| 12:17:12 | 471506 | 469811 | 1695 | 469811 | inserting ~400–500 L2 / 30s |
| 12:18:42 | 471662 | 471257 | 405 | 471257 | |
| 12:19:12 | 471662 | 471662 | **0** | 471662 | `CATCHUP_OK`; safe hash `0xc5e8bac5464cc4aa…` both sides |
| 12:35:16 | 472136 | 472136 | **0** | 472136 | still matched (`0x71bd97c8d3e35d91…`) while live unsafe 472214 |

Independent loopback `optimism_syncStatus` on :9547 vs :19547. Live lever still geth. Sidecar pids unchanged (86439 / 86508).

**`--preflight-only` (this session):** first sandboxed attempts died on L1 connect before any gate (not a chain red). Unsandboxed re-run **12:38 PT** → `PREFLIGHT_EXIT=0` / `PREFLIGHT PASS`. Aux files timestamped Sep 2 12:38:

| Gate | Result |
|---|---|
| `game216_status` + `withdrawal_finalized` | included in PREFLIGHT PASS (script fail-closed) |
| `safe_head_lag` | 0 (independent loopback: live safe 472286 == sidecar 472286, hash `0xfc2c2754f3cd7015…`) |
| `verify-reth-parity` | PASS (20 blocks; full-match candidate = live = replica; heads safe 472136) |
| `verify-reth-faultproof` | PASS (output-root incl game L2 471206; SafeDB post-enable; historical eth_getProof) |
| `check-el-pins` | ok op-node v1.19.2 `da197e45`; op-reth/v2.3.3 `9384bc53`; `FORTEL2_EL=geth` |
| batcher + proposer funded | included in PREFLIGHT PASS |
| `check-launchd` | Result: OK with 1 warning (wake fdautil wrapper; pinned tree `bcac677`) |

Live lever still geth.

### Window step 1 — write path disabled (2026-09-02 ~12:52 PT)

Steve approved in-session. Stopped **only** `l2-rpc-filter` via `stop_bg` (pid 79402). Did not stop cloudflared, live geth stack, or sidecar. Did not edit `.env.sepolia`.

| Check | After |
|---|---|
| :9555 | not listening; `cast` to write filter fails |
| :9545 / :9547 | still listening (geth 79296 / op-node 79307) |
| L2 | 472748 → 472750 (+4s) then 472761 at 12:53:30 — production continued |
| pidfile | `l2-rpc-filter.pid` removed; batcher/proposer/challenger/geth/node/sidecar pidfiles remain |
| Access hostname (unauthenticated GET) | HTTP 403 (Access still in front; origin :9555 is dark) |
| `FORTEL2_EL` | still absent |

### Window step 2 — sequencer paused + drained (2026-09-02 ~13:03 PT)

Steve approved `proceed`. `FORTEL2_ENV=.env.sepolia ./scripts/sequencer-admin.sh stop` then drain. Independent re-read 13:04:51 PT:

| Field | Value |
|---|---|
| `admin_sequencerActive` | **false** |
| drain | ~70s; unsafe caught safe |
| **cutover height/hash** | **473031** / `0x7f526029bfd86b4f466fe09aeb5c9b2f6265fc58d42ebff7b7dc89cd473ebe9e` |
| unsafe == safe | yes (same hash both; EL `:9545` same) |
| finalized | 472436 / `0x3198650e8378b1832386ac6b979a29129e636a8cb17d7fe147a4f0a3937a6663` |
| output root (`optimism_outputAtBlock(473031)`) | `0x59baf49616e16e9c1e780abfdef8059510b89561633655943518a90640a8d9d6` |
| sidecar safe | 473031 same hash (lag 0) |
| batcher L1 nonce | 11452 @ `0x3D54FD6353cd66D143fb94D178c9eEB1aE98a31d` |
| proposer L1 nonce | 252 @ `0x350A0F7becCE56598962C501CaA02f900F256803` |
| write filter `:9555` | still down |
| `FORTEL2_EL` | still absent (geth still live EL) |

Geth / op-node / batcher / proposer / challenger / sidecar left running. **CHECKPOINT 1 — proceed (stop geth + flip lever) or abort (`admin_startSequencer` + re-enable filter).**

### Window steps 3–5 — stop geth, flip lever, start reth (2026-09-02 13:17–13:22 PT)

Steve approved `proceed` (typed `procees`). Did **not** re-run `cutover-to-reth-sepolia.sh --execute` (no tty; steps 1–2 already done). Ran the script’s post-Checkpoint-1 body: record heads → `stop-all-sepolia.sh` → operator `.env.sepolia` flip → `start-all-sepolia.sh`.

**Re-read immediately before stop (13:17:17 PT):** still **473031** / `0x7f526029bfd86b4f466fe09aeb5c9b2f6265fc58d42ebff7b7dc89cd473ebe9e`; `admin_sequencerActive=false`; sidecar lag 0 same hash; filter down; no `FORTEL2_EL` line.

**Step 3 — `FORTEL2_ENV=.env.sepolia ./scripts/stop-all-sepolia.sh` (13:17:29 PT):**

Stopped challenger, l1-batch-proxy, proposer, batcher, op-node, op-geth, sidecar op-reth + op-reth-node. Live + sidecar ports empty. Both datadirs + live JWT + live SafeDB **PRESENT** (no wipe). Geth datadir left read-only.

**Step 4 — `.env.sepolia` lever (13:17:52 PT):** appended `FORTEL2_EL=reth` and `FORTEL2_RETH_PROFILE=sequencer_faultproof`. `--print-plan`: `EL=op-reth` `ENGINEKIND=reth` `SEQUENCER_STOPPED=false` datadir `$DATA_DIR/l2/op-reth` SafeDB `$DATA_DIR/safedb` (sidecar SafeDB untouched) `PROFILE=sequencer_faultproof`.

**Step 5 — `FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh` (13:17:52–13:18:29 PT, exit 0):**

| Item | Value |
|---|---|
| op-reth | pid 3634 — HTTP `:9545` — attach head **473031** — `sequencer_faultproof` |
| op-node | pid 3642 — `:9547` — `--l2.enginekind=reth` — live SafeDB `$DATA_DIR/safedb` |
| proofs init | already initialized; genesis `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d` |
| filter / batcher / proposer / challenger | started with the stack (filter pid 3729 `:9555`) |
| op-geth datadir | still PRESENT; start path never opened it |

**First reth block extends the recorded parent:**

| Block | Hash | Parent |
|---|---|---|
| 473031 (cutover) | `0x7f526029bfd86b4f466fe09aeb5c9b2f6265fc58d42ebff7b7dc89cd473ebe9e` | `0x9ecbca302743414efe750fc5b3304cfdb373751720f29fa9769481d2bd003d75` |
| **473032 (first reth)** | `0x554b5258fe3eadb14d367f70a85497326d034caa07995aba46a794c74121bb59` | **`0x7f526029…` (match)** |
| 473033 | `0x0fce70e1b98bd800baf77d1bd70a9fda379ea65ce8c127d015233327a8e85cdc` | `0x554b5258…` |

`optimism_outputAtBlock(473031)` still `0x59baf49616e16e9c1e780abfdef8059510b89561633655943518a90640a8d9d6`.

**Batcher first start died (13:18:17 PT):** stock `op-batcher` exited `miner_setMaxDASize unavailable at :9545` (geth miner API; op-reth does not expose it). Sequencer kept producing. Restarted 13:20:04 with `OP_BATCHER_THROTTLE_UNSAFE_DA_BYTES_LOWER_THRESHOLD=0` (also appended to `.env.sepolia` so launchd wake on the pinned tree inherits it via the env symlink). Log: `Throttling loop is DISABLED due to 0 throttle-threshold`. No new critical after restart. Published nonce **11452** (channel oldest L2 **473032** → latest **473570**); next nonce **11453**. Safe advanced to **473570** / `0x3232ec2ce9097d851b226f1907e7093a16f58d50742d2a40df3b994992cfcb6a` by 13:21:16.

**Independent re-read 13:22:10 PT:**

| Field | Value |
|---|---|
| `FORTEL2_EL` | **reth** (`sequencer_faultproof`) |
| `admin_sequencerActive` | **true** |
| live EL | op-reth 3634 `:9545` — chain **852** — head 473621 |
| unsafe | 473621 / `0xd5b37c5fc265d54502e14e726ea8c9b4a9ccde40d4d73f8c2b1ae5d769c6df2e` |
| safe | 473570 / `0x3232ec2ce9097d851b226f1907e7093a16f58d50742d2a40df3b994992cfcb6a` |
| finalized | 472436 / `0x3198650e8378b1832386ac6b979a29129e636a8cb17d7fe147a4f0a3937a6663` |
| batcher L1 nonce | **11453** (was 11452 at Checkpoint 1) |
| proposer L1 nonce | 252 (1h interval; no new game expected yet) |
| challenger | pid 4183 — `starting monitoring` / `game service start completed` |
| `check-el-pins` | ok op-node v1.19.2 `da197e45`; op-reth/v2.3.3 `9384bc53`; `FORTEL2_EL=reth` |
| sidecar `:19545` / `:19547` | down (stop-all; shared `$DATA_DIR/l2/op-reth` now bound on live ports) |
| geth datadir | PRESENT (rollback asset) |

**Still open after Checkpoint 2 (not blockers for leaving writes up):**

- `smoke-transfer.sh` — DEMO_A/B L2 balance **0** (estimate fail `have 0`; not an EL reject).
- Viewer — not re-served this step.
- Overnight 23:45 sleep / 03:00 wake / 03:30 alert-absence — required before the fenced handoff.

### Window health — L1→L2 deposit (2026-09-02 13:40–13:42 PT)

Steve approved `deposit`. Stack still `FORTEL2_EL=reth` (same pids as step 5). `FORTEL2_ENV=.env.sepolia ./scripts/deposit-eth-sepolia.sh` → **exit 0** in ~87s.

| Item | Value |
|---|---|
| Amount | 0.01 ETH via `L1StandardBridge.bridgeETH` |
| Bridge / portal | `0x113aad08047e9a9b1556627a658f87f0ebef85a7` / `0xf8c7da6c009d5d05bb98f8cd8286b9b838a3b54e` |
| L1 tx | `0xfcc9f786e761ba21e13981fff65aa4f00413c3f906b831d12e40c7e5bf81b875` |
| L1 receipt | status `0x1`, block **11621975**, `to` bridge |
| ADMIN L2 before | 998993188453469 wei |
| ADMIN L2 after | 10998993188453469 wei (**+10000000000000000**) |
| L2 deposit tx | not in last-40 / last-200 tip scan (script + follow-up); **balance rise is the inclusion proof** |
| Live after | op-reth 3634 still producing; L2 474218; batcher nonce **11457**; safe **474188**; finalized **473570** (first reth channel now finalized) |

**CHECKPOINT 2 — health green enough to leave the filter up, or abort → `rollback-to-geth-sepolia.sh` (verifier-first).** Overnight 23:45 / 03:00 still required before the fenced handoff.

### Window step 7 — Checkpoint 2 proceed; writes left enabled (2026-09-02 13:46 PT)

Steve approved `proceed`. Did not run rollback. Filter was already up from `start-all`; this step **leaves it up** and treats the authenticated write path as re-enabled (step 1 had stopped only the filter; Access / cloudflared were never taken down).

Independent re-read 13:46:28 PT:

| Check | Result |
|---|---|
| `FORTEL2_EL` | **reth** (`sequencer_faultproof`; throttle-off still set) |
| live stack | same pids: op-reth 3634, op-node 3642, batcher 4637, proposer 3936, filter 3729, challenger 4183 |
| `admin_sequencerActive` | **true** |
| L2 / filter | 474350 chain **852** on both `:9545` and `:9555` |
| filter `admin_` | refused (allowlist) |
| Access hostname unauthenticated GET | **HTTP 403** (Access still in front) |
| public replica / sequencer-tip `eth_sendRawTransaction` | **-32601 method not allowed** both gateways |
| 473032 parent | still cutover `0x7f526029…` |
| unsafe / safe / finalized | 474351 / 474188 / **473720** |
| batcher L1 nonce | **11458** (still posting) |
| proposer L1 nonce | 252 |
| geth datadir | PRESENT (rollback asset) |

Window summary comment lands on the evidence PR. Overnight 23:45 / 03:00 was still required at this timestamp; it is recorded below.

### Overnight — manual cycle (2026-09-02 15:28 → 15:31 PT) — PASS

Planner read from launchd logs (`~/Library/Logs/fortel2-sleep.out.log` / `fortel2-wake.out.log`; older `fortel2-dev-*.log` files are stale). PR #200 comment 2026-09-02 22:51Z.

- **Sleep** stopped the renamed set by name: `Stopping op-reth (pid 3634)`, plus op-node/batcher/proposer/challenger/filter/proxy. `op-geth not running (no pidfile)`. op-reth.log SIGTERM 15:28:02.
- **Wake** started reth (`reth 2.3.0-dev (9384bc5) starting`); proofs store idempotent; six services RUNNING under new pids; RPC green (L2 477422, filter `:9555` up). Zero stderr for this run.
- **Proposer under reth:** L1 proposals 14:03→14:05:33 and 15:03→15:05:44.
- alert-watch 15:35: `active conditions: 0`. Kickstarting alerts while slept (daytime) sent a real “stack is down” email — expected.

### Overnight — scheduled cycle #2 (2026-09-02 23:45 → 2026-09-03 03:00) — PASS

Planner read 07:08 PT 2026-09-03 from the same launchd logs + service logs. PR #200 comment 2026-09-03 14:09Z.

- **Sleep 23:45:** `Stopping op-reth (pid 97073)` + node/batcher/proposer/challenger/filter. `Mac stack is down. Datadir kept`.
- **Wake 03:00:** `Sepolia sequencer up (FORTEL2_EL=reth). L2 block=492311`; six services RUNNING under new pids (wake op-reth pid **45707**); status L2 492467.
- **Challenger:** attempt 1/3 died in the 15 s grace (`failed to register cannon-kona game type` — D-0107 429 class); attempt 2/3 survived. #168 retry doing its job.
- Overnight error-level lines 04:00–08:00: 36 challenger, all QuickNode 429 `50/second` — background; no derivation or batcher errors.
- alert-watch 06:30: `active conditions: 0` (no 03:30 email). Health 05:00 snapshot `captured_at` `2026-09-03T12:00:03Z`.
- Morning re-probe: `:9545` = `reth/v2.3.0-9384bc5`, blocks advancing. Public replica + sequencer-tip: `eth_chainId` `0x354`, `eth_sendRawTransaction` **-32601**.

Two launchd cycles on the renamed process set are on record. #201 merged 15:11 PT 2026-09-02 (stock batcher `--throttle.unsafe-da-bytes-lower-threshold=0` only when `fortel2_el` is `reth`; leftover env unset in the start script).

### Closeout still open (2026-09-03 morning)

Three sends still keep STATUS incomplete. CORS bounce is closed below.

| Item | Evidence as of 2026-09-03 08:05 PT |
|---|---|
| `smoke-transfer.sh` | **PASS 2026-09-03** — see smoke section. |
| Access authenticated write | **PASS 2026-09-03** — see Access section. Unauthenticated hostname still HTTP 403. |
| L2→L1 withdrawal on reth | **Initiate PASS.** Prove/finalize not run. See withdraw section. |
| Viewer CORS | **PASS 2026-09-03 ~08:04 PT.** See bounce section. |
| L1→L2 deposit (closeout) | **PASS 2026-09-03** — see deposit section. |

### Closeout — L1→L2 deposit on reth (2026-09-03) — PASS

Steve `go`. `FORTEL2_ENV=.env.sepolia ./scripts/deposit-eth-sepolia.sh` → exit 0 (~79s). Live EL still op-reth (pid 96834).

| Item | Value |
|---|---|
| Amount | 0.01 ETH via `L1StandardBridge.bridgeETH` |
| Bridge / portal | `0x113aad08047e9a9b1556627a658f87f0ebef85a7` / `0xf8c7da6c009d5d05bb98f8cd8286b9b838a3b54e` |
| L1 tx | `0x0bacc586cbc5ab246637cb90514f1591b521d30453c0fc5bd60b896c7104ec23` |
| L1 receipt | status `0x1`, block **11627725**, `to` bridge |
| ADMIN L2 before | 498986505471363 wei |
| ADMIN L2 after | 10498986505471363 wei (**+10000000000000000**) |
| L2 deposit tx | not in recent tip scan; **balance rise is the inclusion proof** |

### Closeout — ADMIN→DEMO_A fund (2026-09-03) — PASS

Steve `go`. Sent **0.01 ether** (not 0.0105 — ADMIN L2 after the deposit was 10498986505471363 wei, below 0.0105). Loopback L2 only.

| Item | Value |
|---|---|
| L2 tx | `0x823ae0cfa9dc8260efffbc55701e143c7749b95c5c63a131ca3d98c3ac01bafc` |
| Receipt | status `0x1`, L2 block **509937** |
| DEMO_A before | 499993317017894 wei |
| DEMO_A after | 10499993317017894 wei (**+1e16**) |
| ADMIN L2 after | 498979044744876 wei (value + gas) |

### Closeout — smoke-transfer on reth (2026-09-03) — PASS

Steve `go`. `FORTEL2_ENV=.env.sepolia ./scripts/smoke-transfer.sh` → exit 0. Live EL op-reth.

| Item | Value |
|---|---|
| L2 tx | `0xf15d5ac860a0fac78d54fd38b4103fb429d4c69f172fb9f98485c9ac13c997c8` |
| Receipt | status 1, L2 block **510093** |
| DEMO_A | 10499993317017894 → 499986613572233 wei (0.01 + gas) |
| DEMO_B | 10000000000000000 → **20000000000000000** wei (**+1e16**) |

### Closeout — Access authenticated write (2026-09-03) — PASS

Steve ran the write from his Terminal (service token never entered chat or git). Independent loopback re-read on `:9545`:

| Item | Value |
|---|---|
| L2 tx | `0x9aaf10bfabddde19adb964629e28886f9d4b35da7c687817c493a61f48970a86` |
| Receipt | status `0x1`, L2 block **510751** |
| Value | 10000000000000 wei (0.00001 ETH) DEMO_A → DEMO_B |
| DEMO_B after | **20010000000000000** wei |
| Unauthenticated `https://fortel2-write.ente.ltd` | still **HTTP 403** (no chain id) |

### Closeout — reth withdrawal initiate (2026-09-03) — PASS

Steve `GO`. Did **not** run stock `withdraw-initiate.sh` (`assert_local_rpc_urls` fails on remote Sepolia L1). Same L2 `initiateWithdrawal` on loopback `:9545`, `WITHDRAW_AMOUNT=0.0002ether`. Artifact `$DATA_DIR/bridge/last-withdrawal.json` (not committed).

| Item | Value |
|---|---|
| L2 tx | `0x1d3c00cc633c3a2c221864a21d0e8bfde776d7af044a6af7157043c9197ee51d` |
| Receipt | status `0x1`, L2 block **510822** (`0x7cb66`) |
| Amount | 0.0002 ETH to ADMIN via `L2ToL1MessagePasser` |
| ADMIN L2 | 498979044744876 → 298971746925903 wei |
| Next | prove after a type-8 game covers 510822; then real portal clocks (~1800s + 1800s); finalize **without** `evm_increaseTime` |

### Closeout — viewer CORS bounce (2026-09-03 08:03–08:05 PT) — PASS

Steve `go` for EL+node-only bounce. Did **not** run stock `04-start-sequencer-sepolia.sh` (`assert_l2_ports_free` also wants batcher/proposer ports empty). Did not `debug_setHead`, wipe, or flip `FORTEL2_EL`.

**Before (08:03 PT):** op-reth pid **45707**, op-node **45731**, batcher **46065**, proposer **46186**, filter **45938**. Sequencer active. L2 **507270** / `0x7f93551c…`. `:9545` OPTIONS **405** (no CORS). Viewer Sequencer/Aggregate **Failed to fetch**.

**Pause:** `sequencer-admin.sh stop` → pause tip **507288** / `0xb391d74d61356aa7eec371445bd2084751091dfa1ef097ebfbe250a0d1252d12`. `stop_bg` op-node then op-reth. Ports 9545/9546/9551/9547 free. Batcher still **46065**. Geth datadir PRESENT, not opened. Live SafeDB `$DATA_DIR/safedb`.

**Start (CORS branch flags, this checkout):** op-reth pid **96834** with `--http.corsdomain=*`; op-node pid **96844** `enginekind=reth` `--sequencer.stopped=false`. Attach head **507288** chain **852**.

**Continuity:** first new block **507289** / `0xd725826f…` parent = pause `0xb391d74d…`. Tip advanced (507292+). `admin_sequencerActive=true`. Batcher/proposer/filter pids **unchanged**. Batcher closed a channel at 08:05:22 covering L2 507156–507287 (pre-pause).

**CORS after:** `:9545` OPTIONS **200** `access-control-allow-origin: *` `allow-methods: GET,POST`. Browser `fetch` to `:9545` **200** (`eth_blockNumber`). Viewer `:8081` **LIVE** — Sequencer UNSAFE ~507325 interval 2.0s; Aggregate mempool reads; no “Failed to fetch”.

### §10 checklist (PRD closed list; tick only with evidence)

Copied from `tasks/prd-op-reth-migration.md` §10. Unticked rows are unproven or out of this task, not implied-green.

#### Chain continuity

- [x] L1 11155111, L2 852 (live `:9545` / `:9547` / public reads `0x354`).
- [x] Genesis, rollup, L1 contracts unchanged. No `karst_time` (cutover attach at 473031; output root unchanged).
- [ ] Sampled safe/finalized hashes match across candidate verifier, sequencer, Render replica, and friend node. **Unticked:** sidecar was stopped at cutover (shared datadir now live); Render/friend are Task 7–8.
- [x] First post-cutover block extends the recorded parent (473032 parent = 473031 / `0x7f526029…`).
- [x] No unsafe/unbatched tx discarded at cutover (`admin_stopSequencer` then drain until unsafe == safe at 473031).
- [x] Cutover used `admin_stopSequencer` before `unsafe == safe`.
- [x] Rollback did **not** run. Verifier-first rollback remains `--rehearse` / fixture-proven (Phase A). Geth datadir kept.

#### Core services

- [x] Sequencer produces before and after restart (cutover + both launchd cycles).
- [x] Batcher posts new channel data to Sepolia (first reth channel 473032–473570; nonce 11452→11458+; #201 for the throttle-off start).
- [x] Proposer posts after cutover (L1 14:05 and 15:05 PT 2026-09-02).
- [x] Challenger stays up (overnight 1/3 grace death then 2/3; 429s background).
- [x] SafeDB queries succeed (live `:9547`, 2026-09-03). Pre-Task-4 L1 **11600000** → recorded L1 **11599983**, safe L2 **336960** / `0xe79b7e23…`. Post-cutover L1 **11621975** (deposit block) → recorded L1 **11621951**, safe L2 **474026** / `0xe3a1666b…` (after first reth 473032). Current L1 **11627298** → recorded L1 **11627283**, safe L2 **507005** / `0xf1f83269…` (matches viewer SAFE).
- [ ] Historical proof / withdrawal requirements satisfied. **Unticked:** D-0116 finalize was 2026-09-01 on **geth**. Reth-era initiate PASS (`0x1d3c00cc…`, L2 **510822**). Prove + finalize not run.

#### End-to-end

- [x] Ordinary L2 transfer (`scripts/smoke-transfer.sh`) 2026-09-03 on live reth. L2 tx `0xf15d5ac8…`, DEMO_B +1e16 wei.
- [x] L1→L2 deposit (`deposit-eth-sepolia.sh`) 2026-09-02 13:40 PT, L1 tx `0xfcc9f786…`.
- [ ] L2→L1 initiate/prove/finalize on reth.
- [x] Authenticated write via Access hostname (2026-09-03). L2 tx `0x9aaf10bf…` status `0x1`; unauthenticated GET still 403.
- [x] Pipeline viewer (`serve-viewer.sh`) correct after #203 bounce (LIVE, Sequencer + Aggregate read `:9545`). Block viewer (`blocks/`) not re-served this window (same EL CORS now).
- [x] Public read gateways still reject writes (`-32601` on both; `eth_chainId` `0x354`). Re-probed 2026-09-03.
- [ ] Guestbook dApp still reads via loopback `JsonRpcProvider`. **Skip on 852:** `demo-checklist.sh` treats Guestbook as Phase 1 local demo (optional on Sepolia). No 852 deploy artifact under `deployments/sepolia/`. Not a closeout blocker.

#### Security

- [x] No role key, provider token, Cloudflare secret, or JWT committed or logged in this file / PR #200.
- [x] EL and op-node admin RPC stay loopback (`:9545` / `:9547`).
- [x] Friend nodes receive no operator key (no Task 8 publish this window).
- [ ] New Render and friend services use independent JWTs. **Out of scope** (Task 7–8).
- [x] Write filter still proxies loopback EL (`:9555` → `:9545`); Access origin is the filter. Unauthenticated Access hostname stays 403.

#### Operations — launchd / sleep / wake (P7 miss)

- [x] `dev-sleep.sh sleep` stops the new EL (manual 15:28 + scheduled 23:45 named `op-reth`).
- [x] `dev-sleep.sh wake` starts it again (`FORTEL2_EL=reth`; L2 492311 at 03:00).
- [x] Sleep/wake plists still match the pinned agents tree (`check-launchd.sh` green at cutover; jobs ran).
- [x] Two wakes after Task 5: daytime supervised + scheduled 03:00.
- [x] Health plist wrote `data/pipeline-health.json` (`captured_at` `2026-09-03T12:00:03Z`).
- [x] `alert-watch.sh` expected-stack includes `op-reth` (`active conditions: 0` through 06:30).
- [x] `resolve-games` still scheduled (untouched this window; D-0116 used it on 09-01).
- [x] `check-launchd.sh` green at cutover preflight.
- [x] No leftover crontab double-start (existing `launchd/README.md` rule; not re-introduced).

#### Stray surfaces — Mac start/stop/status

Ticked as Phase A shipped + live start-all/stop-all/status used those helpers under `FORTEL2_EL=reth`. Local 901 still refuses reth.

- [x] `03-init-l2.sh` / `04-start-sequencer.sh` (901 refuse reth) / `04-start-sequencer-sepolia.sh` / `start-all-sepolia.sh` / `stop-all-sepolia.sh` / `status.sh` / `reset-sepolia.sh` (geth rollback dir preserved) / `07-start-rpc-filter-sepolia.sh` / log `op-reth.log`.
- [x] Live reth `start_bg` CORS on the **running** process (#203 bounce 08:04 PT; OPTIONS `*`).

#### Stray surfaces — monitors, checklists, helpers

- [x] `alert-watch.sh` / `demo-checklist.sh` / `dev-sleep.sh` honor the selector (overnight is the proof).
- [x] `test-helpers.sh` dual-client until Task 9 (#201 + #203 helpers).
- [x] `.env.example` / `AGENTS.md` / `README.md` / `.cursor/rules/fortel2.mdc` live-EL truth-up via #202 (`docs/d0120-task5-cutover`).
- [x] Learning oracles stay on geth (Phase A exception; not retargeted).

#### Stray surfaces — replica / friends / rail (Task 7–8)

- [ ] `replica/FRIENDS.md` / Render image / `fortel2-node` / rail wording. **Out of scope.**

#### Operations (other)

- [x] Mac `stop-all-sepolia` / `start-all-sepolia` on the reth datadir (cutover 13:17).
- [ ] Render restart on a new disk. **Task 7.**
- [x] Rollback mechanically validated verifier-first (`--rehearse`); geth support not removed.
- [x] `status.sh` names `op-reth`; no live `op-geth` pidfile after cutover.

#### Repository boundaries

- [x] `ForteL2` still owns sequencing. Replica / friend repos not cut over.

## D-0116 gate cleared (2026-09-01)

Live L1 reads + one ADMIN `finalizeWithdrawal` send. No Phase B flip. Live stack and both datadirs untouched. Hourly `resolve-games` agent untouched.

**On-chain (factory / game 216 / portal) before any send this session:**

| Item | Value |
|---|---|
| factory `gameAtIndex(216)` proxy | `0xbD43A40dED613aabf89e14d2a91CE6E194A3e2Ed` (type 8) |
| `status()` | **2 DEFENDER_WINS** (already resolved; resolveClaim/resolve skipped) |
| `resolvedSubgames(0)` | true |
| `createdAt` | 1788235464 |
| `resolvedAt` | **1788285852** (2026-09-01 11:04:12 PT) |
| `disputeGameFinalityDelaySeconds` | **1800** |
| readyAt (`resolvedAt+delay`) | **1788287652** (2026-09-01 11:34:12 PT) |
| `proofMaturityDelaySeconds` | 1800 |
| withdrawal hash | `0x06de34692e590ce003bddfa4dcbe9fe78c7360d753773b9804d6f3f9074a8abd` |
| `provenWithdrawals(hash, ADMIN)` | game `0xbD43A40d…e2Ed`, `provenAt` 1788235512 |
| `finalizedWithdrawals` before send | false |

Hourly agent reached 216 first (success, not a conflict). From `~/Library/Logs/fortel2-resolve-games.out.log` and the game’s `Resolved` log:

| Leg | Tx | Notes |
|---|---|---|
| `resolveClaim(0,0)` | `0x9b72c9cc5b68c04967310914aed505b004ae065146e748f2dd91245166263b45` | zero-bond; credit 0 |
| `resolve()` | `0xe051fc39c47a2442c15318addff2ef2d1d2199e386e7778e8282d08c31d478ce` | L1 block 11614238; status topic = 2 |

Waited on-chain until L1 timestamp **1788287676** ≥ readyAt. No Anvil `evm_increaseTime`. `withdraw-finalize.sh` / `finalize.mjs` were not run.

**Finalize** (node from `scripts/bridge`, viem `finalizeWithdrawal`, Sepolia `deployments.json`; no time-warp):

| Item | Value |
|---|---|
| L1 tx | `0x96e29fe38c602ab2fbc2761fd6f3d496087e4dec8457178a2f7769cb3c2aefea` |
| receipt | status `0x1`, L1 block **11614388**, `to` portal `0xf8c7da6c…b54e` |
| L1 timestamp at send | 1788287700 (48s after readyAt) |
| `finalizedWithdrawals` after | **true** (independent `cast` re-read) |
| game `status` after | still 2 |

**Preflight** (shipped flag is `--preflight-only`; there is no `--preflight`):

```
$ FORTEL2_ENV=.env.sepolia ./scripts/cutover-to-reth-sepolia.sh --preflight-only
PREFLIGHT FAIL
verify_reth_faultproof want exit 0 got 2
```

D-0116 subset is green: `game216_status` and `withdrawal_finalized` were not in the FAIL list. Independent casts at the same moment: `status()=2`, `finalizedWithdrawals=true`. Other live gates that passed this run: sidecar safe-head lag 0, `verify-reth-parity.sh` exit 0, `check-el-pins.sh` exit 0, batcher/proposer funded, `check-launchd.sh` exit 0. Remaining red (window-day, not fixed here): `verify-reth-faultproof.sh` exit 2 because live mode requires `--game-l2-block N` and the cutover script invokes it with no args (`/tmp/fortel2-cutover-fp.out`).

## Out of scope (this file)

Task 6 beyond night one; Render (7); friend repo (8); geth removal (9); `karst_time`; editing `.env.sepolia` or launchd plists in Phase A.
