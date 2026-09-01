# Task 5 evidence — op-reth live Sepolia sequencer cutover

**STATUS: Phase A complete (scripts + selector; no live flip).** Phase B is the operator window. This file is the one `tasks/` write. L1 provider URLs, JWTs, and keys are never written here.

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

_Empty until the announced morning window. Record timestamps, block numbers, every command outcome (redacted). Next-morning sleep/wake result is part of this handoff (Task 6 entry)._

### §10 checklist (walk line-by-line in the window)

Copy the closed list from the PRD; tick here after the window, not in Phase A.

## Out of scope (this file)

Task 6 beyond night one; Render (7); friend repo (8); geth removal (9); `karst_time`; editing `.env.sepolia` or launchd plists in Phase A.
