# Task 5 evidence — op-reth live Sepolia sequencer cutover

**STATUS: Phase B window step 1 done (2026-09-02).** Write filter `:9555` stopped; live geth still producing. Step 0 preflight PASS. Steps 2–7 not started. Phase A remains merged (#192/#193/#195). This file is the one `tasks/` write. L1 provider URLs, JWTs, and keys are never written here.

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

Window steps 2–7 not started. Next: `sequencer-admin.sh stop` after Steve's go, then drain `unsafe == safe`.

### §10 checklist (walk line-by-line in the window)

Copy the closed list from the PRD; tick here after the window, not in Phase A.

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
