# PRD: ForteL2 op-geth → op-reth migration (and thin friend node)

**Status:** Proposed — P:0 spike done; later tasks unstarted  
**Date:** 2026-08-29  
**Owner:** ForteL2 operator  
**Spike evidence:** `tasks/spike-op-reth.md` (Mini `--blocks 5` PASS 2026-08-29)  
**Parent roadmap:** `tasks/prd-l2-learning-chain.md` (parallel EL track; not a phase number)  
**Repositories:** `StephenForte/ForteL2`, `StephenForte/fortel2-replica`, proposed `StephenForte/fortel2-node`

This is an **execution-client migration**, not a new chain launch and **not** a Phase 7 wipe. It must not require an L1 contract redeploy, a new L2 genesis, a chain-ID change, or `karst_time`. Do **not** treat this document as authorization to cut over the sequencer, swap the Render replica image, or publish a friend node.

## 0. Spike evidence (P:0 — done)

`scripts/spike-op-reth.sh` is a throwaway sidecar. It does not replace `04-start-sequencer*.sh`. Mini darwin/arm64, 2026-08-29:

| Fact | Value |
|---|---|
| Pair that worked | Live `op-node` v1.19.2 + source-built `op-reth/v2.3.3` reporting `Reth Version: 2.3.0-dev` commit `9384bc53d8c0c77e59cac83fdaaf3b372c6d2216` (upstream reth pin inside that tag) |
| Engine | `--l2.enginekind=reth` attached; FCU to genesis accepted |
| L1 | QuickNode + `--l1.rpckind=quicknode`. PublicNode + `standard` is a **known FAIL** (`got 0 receipts but expected N`) |
| Genesis | replica = sidecar = `0xe242b1a3312b509e7df1496847f0bd0b115cb66676b1e973a355296c99e2386d` |
| Block 5 | replica = sidecar = sequencer-tip = `0xd9fd2a33ebadd2a734924d8f76bac945709ba4a1df352a7d4fd50383dee209e9` |
| Isolation | Sidecar ports `:19845/:19846/:19851/:19847/:30329`. Live `$DATA_DIR/l2/op-geth` and `:9545/:9546/:9547/:9551` untouched |
| RPC | `net_version`, `web3_clientVersion`, debug (some method), `txpool_status`, `eth_getProof` PASS |
| `debug_setHead` | **Answered.** Do not use on a keeper datadir. Derivation mid-chain needs another path |
| 901 trap | Mini `$DEPLOY_DIR/genesis.json` was chain **901**. Spike ignored it and fetched 852 genesis from fortel2-replica |

P:0 proved genesis + the first five L2 blocks hash-match on a sidecar. It did **not** prove sync-to-tip, safe/finalized sampled parity, fault-proof/historical proofs, sequencer cutover, Render, or a friend image.

## 1. Executive decision

Migrate maintained code and deployment paths to **op-reth before publishing a new friend-operated node**. The live sequencer must **not** be the first op-reth workload cut over.

Safe order:

1. **Done (P:0).** Sidecar verifier on Mini; first-N hash-match. Evidence: `tasks/spike-op-reth.md`.
2. Add opt-in op-reth support and migration checks to `ForteL2` (Task 2). Keep `op-geth` the default until Task 5.
3. Parallel Sepolia op-reth verifier: derive chain 852 from L1 to the **safe head**; sampled hash/state-root parity vs live op-geth + replica (Task 3). P:0 is a door, not this task.
4. Prove challenger / SafeDB / withdrawal-proof / proposer output-root needs against the candidate archive profile (Task 4).
5. Cut the Mac sequencer from op-geth to op-reth during a controlled write pause. Retain the op-geth datadir as the rollback asset (Task 5). **Operator-owned. Do not start unless asked.**
6. Observe (Task 6), then migrate the Render replica on a **new** service/disk (Task 7).
7. Extract the proven minimal verifier into `fortel2-node` for friends (Task 8). Remove op-geth compatibility after the rollback window (Task 9).

The op-geth and op-reth databases are **not** interchangeable. op-reth uses a new datadir and reconstructs canonical L2 from the committed 852 genesis and Sepolia data.

**Karst is a separate decision.** Superchain Karst is active; ForteL2 `deployments/sepolia/rollup.json` has forks through `jovian_time: 0` and **no `karst_time`**. That is why op-geth still sequences today. This PRD does **not** set `karst_time`. EL swap first; Karst only if a later, explicit task asks.

## 2. Background

ForteL2 today:

- `op-geth v1.101702.2` execution client (live sequencer + `fortel2-replica`).
- `op-node v1.19.2` rollup client (`--l2.enginekind=geth` on the live path).
- Archive op-geth datadir on the Mac sequencer.
- Working `cannon-kona` challenger path (Phase 7 demonstration complete; no wipe from this PRD).
- Friend runbook `replica/FRIENDS.md` still points at the op-geth replica image. Do not publish a **new** friend node on op-geth once this migration is in motion (Task 8 is the replacement). Existing Phase 3 replica stays until Task 7.

OP Labs treats op-reth as the primary supported EL. op-geth EOS was 2026-05-31 for Karst-era public networks. ForteL2 is a custom chain, so EOS is **upgrade debt**, not an immediate halt. New friend distributions must not be built on op-geth.

Proven floor (may be the Task 1 pin, or a later coordinated pair may supersede it):

- `op-node` v1.19.2 (already live; Superchain Karst min is v1.19.1+ — unused here).
- `op-reth/v2.3.3` → `Reth 2.3.0-dev` `9384bc53`. Build in a **second** optimism clone so the shallow `op-node/v1.19.2` tree is not disturbed.

## 3. Goals

- Remove op-geth from every **actively maintained** ForteL2 runtime after the rollback window.
- Preserve chain **852**, current L1 contracts, genesis, rollup config, balances, contract state, and history.
- Keep a tested rollback path until the op-reth sequencer completes observation.
- Preserve batcher, proposer, deposit, withdrawal, public-read, authenticated-write, and challenger behavior.
- Give friends a small, auditable verifier repo: `op-node` + `op-reth --full` and the required artifacts only.
- Role-appropriate storage:
  - Mac sequencer / fault-proof: archive plus historical proofs the challenger/withdrawal path needs.
  - Ordinary friend verifier: `--full`, not archive.

## 4. Non-goals

- No Sepolia L1 contract redeploy. No `FORCE_SEPOLIA_REDEPLOY`. No Phase 7 Operator-sequence wipe.
- No new L2 genesis or chain ID. No `karst_time`.
- No change to sequencer ownership, sequencing decentralization, or P2P policy.
- No migration from `op-node` to `kona-node`.
- No batcher/proposer rewrite except RPC-surface compatibility.
- No public challenger in the first friend-node release.
- No deletion of op-geth datadirs during the rollback window.
- No in-place convert of an op-geth database.
- No Docker / OrbStack / Kurtosis on the Mini (Phase 0). Containers stay OK on Render and friend machines.
- No `lib.sh` `start_bg` / `stop_bg` edits without human review (CODEOWNERS).
- No `FORTEL2_ENV=.env.sepolia` on verifier/spike paths (do not load role keys).
- P:0 does **not** authorize Task 5.

## 5. Architecture after completion

| Role | Consensus | Execution | Storage |
|---|---|---|---|
| Mac sequencer | `op-node` | `op-reth` | Archive + historical proofs |
| Render replica / RPC | `op-node` | `op-reth` | Archive only if public RPC requires it; else `--full` |
| Friend verifier | `op-node` | `op-reth` | `--full` |
| Challenger | Existing `op-challenger` / Kona | Reads the candidate pair | SafeDB + historical proofs preserved |

## 6. Highest-impact findings

### P0 — Maintained runtime still depends on op-geth

**Evidence:** `scripts/04-start-sequencer.sh` and `04-start-sequencer-sepolia.sh` start `op-geth`; pins in `.env.example`; `fortel2-replica` still ships op-geth.

**Consequence:** Publishing another op-geth friend image creates upgrade debt. Do not recruit onto a new op-geth distribution after this PRD is accepted.

### P0 — L1 receipt fetch is a derivation hard stop

**Evidence:** Mini first run (`tasks/spike-op-reth.md`): PublicNode + `--l1.rpckind=standard` looped `got 0 receipts but expected 105`. Head stayed 0. Same binary PASSed after QuickNode + `quicknode`. Phase 1 `.env` Anvil `L1_RPC_URL` clobbers an exported QuickNode URL unless the script snapshots the caller value before sourcing `lib.sh`.

**Consequence:** Every Sepolia verifier/sequencer path in this migration must use a receipts-capable L1 (live default: QuickNode) and `--l1.rpckind=quicknode` (override `SEPOLIA_L1_RPC_KIND` / `SPIKE_L1_RPC_KIND`). PublicNode is refused for derivation. Caller `L1_RPC_URL` must survive `.env` load.

### P0 — Sequencer/challenger storage ≠ friend verifier

**Evidence:** Mac EL is archive; challenger uses operator node, SafeDB, debug/archive, Kona. Friends only need canonical derivation.

**Consequence:** One generic op-reth command is unsafe. `--full` everywhere can break proofs; archive for friends is waste.

### P1 — Sequencer-first cutover is the highest-value experiment

**Evidence:** The Mac sequencer is the only producer and feeds batcher, proposer, write path, viewer, SettlementOS.

**Consequence:** Task 5 stays last among P0 tasks and operator-owned.

### P1 — Tooling assumes geth names and `debug_setHead`

**Evidence:** Scripts use `require_bin op-geth`, `$DATA_DIR/l2/op-geth`, `--l2.enginekind=geth`, geth log names. Spike: `debug_setHead` **answered** on op-reth.

**Consequence:** Replacing only the binary leaves health/status/reset inconsistent. **Never** rewind a keeper (live or candidate-to-keep) with `debug_setHead`. Mid-chain derivation uses a fresh datadir or a documented non-destructive path.

### P1 — 901 genesis is sitting next to 852 artifacts

**Evidence:** Spike ignored `$DEPLOY_DIR/genesis.json` (chainId 901) and fetched replica genesis.

**Consequence:** Task 2/3 must require chainId **852** genesis (`deployments/sepolia/` or the packed replica file). Refuse 901.

### P1 — `fortel2-replica` is not a thin friend distribution

**Evidence:** Gateways, SettlementOS routing, Access, provider schedule, Render IDs, disk recovery.

**Consequence:** Extract `fortel2-node` only after the op-reth verifier config is proven (Task 8).

## 7. Migration invariants

1. L1 chain ID `11155111`; L2 chain ID `852`.
2. Existing `genesis.json`, `rollup.json`, L1 addresses, and `rail-interface.json` addresses unchanged. No `karst_time`.
3. op-geth datadir retained read-only for rollback until Task 9 sign-off.
4. op-reth datadir is a different explicit path (`$DATA_DIR/l2/op-reth` or `$DATA_DIR/l2/spike-op-reth` for throwaway). Never `$DATA_DIR/l2/op-geth`.
5. No operator key, JWT, provider token, or Cloudflare credential committed or printed.
6. op-node and EL remain a 1:1 pair over a shared JWT Engine API.
7. Operator RPC and op-node admin RPC stay loopback. Public reads stay the two named diskless gateways (D-0047).
8. No cutover while the sequencer has unsafe blocks not yet at the safe head.
9. Rollback never deletes or rewrites either EL datadir.
10. Sepolia L1 for derivation is receipts-capable; `--l1.rpckind` defaults to `quicknode`.
11. Genesis used to init op-reth is chain **852**.
12. This work is **not** a Phase 7 redeploy gate. Do not edit the four wipe-precondition documents to add an EL-swap step.

## 8. Implementation tasks

### Task 1 — P0: Pin a coordinated supported OP release

**Objective:** Record the `op-node` / `op-reth` pair used for all later tasks.

**Why:** Mixing tags can break Engine API or hardfork alignment.

**Already true:** Mini P:0 ran live `op-node` v1.19.2 against `op-reth/v2.3.3` (`Reth 2.3.0-dev` `9384bc53`) for first-N blocks. That pair is the **proven floor**. Task 1 may keep it or replace it with a later coordinated pair after reading current release notes — a bump still needs a Mini re-run of the sidecar hash-match before Task 3.

**Scope:** Build/setup docs, `.env.example`, `.env.sepolia.example`, version assertions, replica image pins (no live image swap).

**Instructions:**

1. Review current Optimism coordinated releases. Default to the proven floor unless a newer pair is explicitly supported together.
2. Record exact tags and, where images are used later, immutable digests.
3. Native arm64 binaries; second optimism clone for op-reth (`~/src/fortel2/optimism-op-reth`). Do not `git checkout` the shallow live `op-node/v1.19.2` tree.
4. Confirm the pin supports the current rollup (through Jovian; **no** Karst required).
5. Scriptable version check that fails on `op-geth` when the selector is `reth`, and fails on mismatched pins.

**Out of scope:** Starting or stopping the live chain; setting `karst_time`.

**Success:** Exact versions documented; arm64 `--version` matches; assertion fails on a wrong input (must be able to go red).

**Dependencies:** None. P:0 already supplies the floor.

### Task 2 — P0: Role-specific op-reth configuration in ForteL2

**Objective:** Main repo can start op-reth as a shadow verifier (and later the sequencer) **without** changing the op-geth default.

**Why:** Exercise config before the live sequencer depends on it.

**Learn from P:0 (do not promote the spike script to production):**

- Datadir `$DATA_DIR/l2/op-reth` (production) vs `$DATA_DIR/l2/spike-op-reth` (throwaway). Guard: refuse `$DATA_DIR/l2/op-geth`.
- Flags that worked: `--http.addr=127.0.0.1`, `--authrpc.jwtsecret`, `--http.api=eth,net,web3,debug,txpool`, `--chain` + `op-reth init --chain`.
- op-node: `--l2.enginekind=reth`, `--l1.rpckind=quicknode`, `--l1.trustrpc=true`, `--l1.beacon.ignore=true` (same class as live Sepolia).
- Snapshot caller `L1_RPC_URL` before `source lib.sh`.
- Storage: default archive prune gave `eth_getProof` on the sidecar (not a Task 4 proof).

**Scope:** Init/start/stop/status/reset helpers, env examples, process/log/datadir names, helper tests. Prefer extending `scripts/lib.sh` helpers. **`start_bg` / `stop_bg` edits need human review.**

**Instructions:**

1. Explicit EL selector; `op-geth` remains default until Task 5.
2. New datadir; never open the geth path.
3. Init from **852** genesis only; refuse 901.
4. Replace geth-specific flags; include `--rollup.disable-tx-pool-gossip` where appropriate for a verifier.
5. Set `--l2.enginekind=reth` when paired with op-reth. Do not drop the flag unless a test proves the selected op-node default is reth.
6. Two storage profiles: `sequencer_faultproof` (archive + historical proofs) and `verifier` (`--full`).
7. Neutral process names or dual-client handling during migration.
8. Tests: stale geth-only path or `enginekind=geth` under the reth selector fails; pointing reth datadir at geth refuses.

**Out of scope:** Live cutover; removing the geth rollback path; Docker on Mini.

**Success:** Fresh op-reth EL from current 852 artifacts; op-node attaches with `reth`; geth datadir never opened; storage mode explicit.

**Verification:** Helper tests (can go red). Disposable start (local 901 **or** isolated 852 sidecar — do not require a 901 op-reth path if 852 sidecar is the chosen proof). Deliberate geth-path refuse.

**Dependencies:** Task 1 (or explicit “use P:0 floor”).

### Task 3 — P0: Parallel Sepolia verifier to safe head

**Objective:** Derive existing chain 852 into a fresh op-reth database without touching the live sequencer.

**Why:** Lowest-risk proof that clients, 852 genesis, rollup, and hardforks agree with the live chain **beyond block 5**.

**P:0 is not this task.** First-N match is necessary and already done. This task requires catching the **current safe head** and sampled parity.

**Instructions:**

1. `op-reth` + `op-node` verifier-only; committed 852 genesis + `deployments/sepolia/rollup.json`.
2. Separate datadir, ports, JWT, names, logs. Reserved sequencer ports (`9545 9546 9547 9551`) stay untouched.
3. Derive from Sepolia. L1 = QuickNode (or equivalent receipts RPC) + `l1.rpckind=quicknode`. Refuse PublicNode.
4. Wait until the verifier’s safe head matches live safe (or a documented lag bound).
5. Compare ≥20 sampled safe blocks (recent + older checkpoints): number, hash, parent hash, state root, receipts root, tx count.
6. Compare contract storage, balances, receipts, deposits, withdrawal-related state.
7. Restart and resume without re-init or diverge.
8. Record versions, configs, sample heights, results in a dated evidence file under `tasks/` (not a rewrite of this PRD).

**Out of scope:** Sequencing on op-reth; public RPC routing; `karst_time`.

**Success:** Safe-head catch-up; every sample matches; restart OK; live geth + Render replica untouched.

**Verification:** A parity script exits 0 only on full match and exits nonzero when a fixture field is deliberately altered.

**Dependencies:** Tasks 1–2.

### Task 4 — P0: Fault-proof and historical workflows

**Objective:** Prove challenger, proposer, and withdrawal-proof needs against the candidate sequencer storage profile.

**Why:** Block-hash parity does not prove archive/debug/historical endpoints.

**P:0 gap:** `eth_getProof` PASSed on default archive prune. Historical-proof store, SafeDB, challenger judge, and withdrawal prove were **not** run.

**Instructions:**

1. Enable the historical-proof store from **first** start of the candidate datadir; do not assume retroactive fill.
2. New explicit SafeDB path; `optimism_safeHeadAtL1Block` for newly recorded L1 heads.
3. Non-signing / isolated challenger validation against candidate endpoints.
4. Known-valid claim judged, not attacked.
5. Withdrawal prove/finalize appropriate to the current shortened Sepolia learning clocks.
6. Proposer output root identical to live at the same L2 block.
7. Document RPC namespace differences; do not silently widen the public surface.
8. **`debug_setHead` is not a rewind tool** on this datadir.

**Out of scope:** Posting a deliberately false claim as migration prep (that stays a Phase 7 operator action).

**Success:** Matching output roots; SafeDB queries work for post-enable heads; valid game judged correctly; withdrawal path succeeds or a named blocker is resolved before Task 5.

**Verification:** Redacted commands/outputs; negative check when SafeDB or historical endpoint is missing (must be able to fail).

**Dependencies:** Task 3.

### Task 5 — P0: Cut over the Mac Sepolia sequencer

**Objective:** op-reth becomes the live chain 852 sequencer with a non-destructive rollback.

**Operator-owned. Do not execute this task unless explicitly asked.**

**Why:** Removes the producer from op-geth only after verifier + fault-proof parity.

**Instructions:**

1. Announce a maintenance window. No genesis-wipe notice (chain config unchanged). This is **not** a Phase 7 reset announcement.
2. Disable authenticated external write before stopping the sequencer.
3. Stop intake; wait until latest sequenced block is safe/L1-derived; batcher has published remaining channels; `unsafe == safe` at the cutover height.
4. Record cutover number/hash, safe/finalized, output root, versions, batcher/proposer L1 tx state.
5. Stop in documented order. Preserve the complete op-geth datadir and logs.
6. Candidate op-reth already at the recorded safe point (from Task 3/4).
7. Start op-reth (`sequencer_faultproof`), then op-node sequencer + `--l2.enginekind=reth`.
8. Start write filter, batcher, proposer, challenger in existing order.
9. Re-enable writes only after production, batches, proposals, and challenger health.
10. Immediate rollback if it cannot produce, changes the expected state root, breaks batch/propose, or cannot support fault-proof checks.

**Out of scope:** Deleting op-geth; changing L1 contracts or public URLs; `karst_time`.

**Success:** First op-reth block extends the recorded parent; no accepted tx lost; batcher posts; proposer root expected; challenger healthy; deposit / L2 transfer / authenticated write / withdrawal pass.

**Verification:** Existing status, smoke-transfer, bridge, viewer, batcher, proposer, challenger checks plus parity at the cutover boundary. Each check must be able to fail.

**Dependencies:** Tasks 1–4.

### Task 6 — P1: Observe and keep rollback ready

**Objective:** Stability through restarts, nightly sleep/wake, L1 derivation, and one proposer/challenger lifecycle.

**Instructions:** ≥72 hours, ≥2 scheduled sleep/wake cycles; track production, lag, batches, games, challenger, memory, disk, L1 usage; one controlled restart; keep geth binary/selector/datadir; dated promote / extend / rollback decision.

**Success:** No unexplained divergence or missed wake; resources fit the Mac; wakes recover; dated decision before Task 7.

**Dependencies:** Task 5.

### Task 7 — P1: Render replica on a new service/disk

**Objective:** Replace the operated replica EL without destroying the geth rollback disk.

**Instructions:** New private service + new disk + distinct hostname; sync from Sepolia; sampled parity vs op-reth sequencer; load-test the existing read allowlist; measure memory/disk before plan size; repoint diskless public replica gateway and SOS private read only after health/parity; keep old service recoverable. Do not convert the replica Private Service to Web or publish the Access write hostname.

**Out of scope:** Changing sequencer-tip or authenticated write unless a concrete incompatibility appears.

**Success:** Independent derive; hashes match; public read restrictions unchanged; routing rollback without disk mutation.

**Dependencies:** Task 6.

### Task 8 — P1: Thin `fortel2-node` friend repo

**Objective:** Friends deploy without seeing operator RPC infrastructure.

**Instructions:** Extract proven `op-node` + `op-reth --full`; commit 852 genesis/rollup with hashes in README; require friend L1 execution (+ beacon if required); recommend a receipts-capable L1 (document PublicNode failure); auto JWT, never an operator JWT; loopback default on Compose; no gateways/Access/SOS/QuickNode router/operator IDs; Render Blueprint only with a measured disk/plan (no free-tier claim without a measured deploy); parity command vs a user-supplied reference RPC without trusting it for derivation; then update `replica/FRIENDS.md` to the new repo and op-reth.

**Out of scope:** Challenger, public RPC commitment, sequencer, batcher, proposer, rewards, staking.

**Success:** Clone + L1 endpoints + disk; exactly one op-node and one op-reth; no operator secret; safe hash matches operator/Render; README has no operator-only Render/SOS runbook.

**Verification:** Clean-room deploy. Missing L1, bad genesis hash, or absent disk fails closed (not a fake healthy).

**Dependencies:** Tasks 1–7.

### Task 9 — P2: Remove op-geth after the rollback window

**Objective:** op-reth is the only supported EL in actively maintained code.

**Instructions:** End the window only after Mac + Render observation and at least one friend clean sync; remove geth startup options; keep dated records; archive or separately-approved delete of geth datadirs; CI/search guard against new `op-geth` pins or `enginekind=geth`.

**Dependencies:** Tasks 5–8 and expiry of the declared window.

## 9. Cutover rollback triggers

Rollback the Mac sequencer to preserved op-geth if any of these occur in Task 5 or early Task 6:

- op-reth cannot extend the recorded safe parent.
- A block or output root differs for the same canonical inputs.
- Batcher cannot publish or repeatedly rejects EL data.
- Proposer root inconsistent with the verifier.
- Challenger attacks a supposedly valid op-reth-derived proposal.
- Deposit/withdrawal proof fails for missing historical data/RPC.
- Authenticated writes accepted but txs disappear across restart/cutover.
- Memory, disk, or restart exceeds the declared envelope.

Procedure: stop writes, stop op-reth, restart preserved op-geth at last safe point, verify hash continuity, re-enable writes. Do not delete or mutate the op-reth datadir during rollback.

## 10. Final QA checklist

### Chain continuity

- [ ] L1 11155111, L2 852.
- [ ] Genesis, rollup, L1 contracts unchanged. No `karst_time`.
- [ ] Sampled safe/finalized hashes and state roots match across candidate verifier, sequencer, Render replica, and friend node.
- [ ] First post-cutover block extends the recorded parent.
- [ ] No unsafe/unbatched tx discarded at cutover.

### Core services

- [ ] Sequencer produces before and after restart.
- [ ] Batcher posts new channel data to Sepolia.
- [ ] Proposer posts the expected output root / game type.
- [ ] Challenger judges valid games without attacking them.
- [ ] SafeDB queries succeed.
- [ ] Historical proof / withdrawal requirements satisfied.

### End-to-end

- [ ] Ordinary L2 transfer.
- [ ] L1→L2 deposit.
- [ ] L2→L1 initiate/prove/finalize.
- [ ] Authenticated SettlementOS submit + receipt poll.
- [ ] Pipeline viewer and block viewer correct.
- [ ] Public read gateways still reject writes.

### Security

- [ ] No role key, provider token, Cloudflare secret, or JWT committed or logged.
- [ ] EL and op-node admin RPC loopback/private.
- [ ] Friend nodes receive no operator key.
- [ ] New Render and friend services use independent JWTs (and preferably independent L1 credentials).

### Operations

- [ ] Mac: controlled restart + two sleep/wake cycles.
- [ ] Render: restart on the new disk.
- [ ] Resource use within declared limits.
- [ ] Rollback rehearsed or mechanically validated before removing geth support.
- [ ] Docs/status/logs say op-reth.

### Repository boundaries

- [ ] `ForteL2` owns sequencing, fault proofs, canonical artifacts.
- [ ] `fortel2-replica` owns operated Render RPC.
- [ ] `fortel2-node` is only the friend verifier.
- [ ] One source of truth for published config + hash check.

## 11. Open questions

Answer during Task 1 or 2 unless noted.

| # | Question | Status after P:0 |
|---|---|---|
| 1 | Exact coordinated `op-node` / `op-reth` pin? | **Floor:** v1.19.2 + `op-reth/v2.3.3` (`9384bc53`). Confirm or bump in Task 1. |
| 2 | Does 852 hardfork config need adjustment for that pin (without changing genesis)? | **No change needed for first-N.** Rollup has no `karst_time`. Reconfirm at safe-head (Task 3). |
| 3 | Which historical-proof flags/retention does `cannon-kona` + shortened withdrawal window need? | **Open.** Task 4. |
| 4 | Does Render public RPC need archive, or is `--full` enough? | **Open.** Task 7. |
| 5 | Disk/RAM of a clean 852 op-reth sync on Render under current RPC load? | **Open.** Task 7. |
| 6 | Mid-chain rewind without `debug_setHead` on a keeper? | **Open.** Spike: method answered; forbidden on keeper. Task 2/3 must pick a path. |
| 7 | Beacon requirement for friends if `--l1.beacon.ignore=true` stays operator-only? | **Open.** Live Sepolia and the spike ignore beacon (calldata DA). Task 8 must not require a beacon unless a later pin does. |

## 12. Inspection limits

- **Done:** Mini P:0 sidecar (native arm64 op-reth, isolated ports, QuickNode L1, first-N hash-match). Recorded in `tasks/spike-op-reth.md`.
- **Not done:** Sync-to-tip, 20-sample safe-head parity, challenger/SafeDB/withdrawal on op-reth, sequencer cutover, Render image, friend repo.
- Mac live datadir internals, `.env.sepolia` values, and Render dashboard state were not copied into git.
- Do not paste provider URLs or tokens into this file.

## 13. References

- Spike: `tasks/spike-op-reth.md`
- Script: `scripts/spike-op-reth.sh`
- Live Sepolia sequencer L1 kind: `scripts/04-start-sequencer-sepolia.sh` (`SEPOLIA_L1_RPC_KIND:-quicknode`)
- Roadmap: `tasks/prd-l2-learning-chain.md`
- Phase 7 (do not wipe from here): `tasks/prd-phase-7-fault-proofs.md`
- Friend runbook (stays op-geth until Task 8): `replica/FRIENDS.md`
- ForteL2: <https://github.com/StephenForte/ForteL2>
- Operated replica: <https://github.com/StephenForte/fortel2-replica>
- OP node selection: <https://docs.optimism.io/use-cases/choose-your-node-stack>
- OP op-reth sequencer setup: <https://docs.optimism.io/chain-operators/tutorials/create-l2-rollup/op-reth-setup>
- OP op-reth run: <https://docs.optimism.io/node-operators/op-reth/run/opstack>
