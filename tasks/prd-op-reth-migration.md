# PRD: ForteL2 op-geth → op-reth migration (and thin friend node)

**Status:** In execution — P:0 + **Tasks 1–5 done** (Task 5 cutover 2026-09-02, closed D-0121); Task 6 observation running (≥72 h from 2026-09-02 13:17); Tasks 7–9 unstarted  
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
- op-node: `--l2.enginekind=reth`, `--l1.rpckind` from `SEPOLIA_L1_RPC_KIND` / `SPIKE_L1_RPC_KIND` (default `quicknode` when L1 is QuickNode), `--l1.trustrpc=true`, `--l1.beacon.ignore=true` (same class as live Sepolia).
- Snapshot caller `L1_RPC_URL` before `source lib.sh`.
- Storage: default archive prune gave `eth_getProof` on the sidecar (not a Task 4 proof).

**Scope:** Init/start/stop/status/reset helpers, env examples, process/log/datadir **and pid** names, helper tests. Prefer extending `scripts/lib.sh` helpers. **`start_bg` / `stop_bg` edits need human review.**

**Phase 7 lesson:** after the wipe, launchd **sleep/wake** failed because start/stop/status still assumed the old process set and port occupancy. An EL rename that updates `04-start-sequencer-sepolia.sh` but not `stop-all-sepolia.sh`, `status.sh`, `alert-watch.sh`, `demo-checklist.sh`, and `dev-sleep.sh` will fail the same way. Decide the pid name in this task (`op-reth` vs a neutral `l2-el`) and treat §10 stray-surface list as the closed update set.

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
3. Derive from Sepolia. Default L1 is the live QuickNode URL with `--l1.rpckind=quicknode` (`SEPOLIA_L1_RPC_KIND`). Refuse PublicNode (receipts return 0). If a different receipts-capable provider is used, set `SEPOLIA_L1_RPC_KIND` / `SPIKE_L1_RPC_KIND` to **that** provider (`alchemy`, `infura`, `standard`, …). Do not force `quicknode` on a non-QuickNode URL — a mismatched kind breaks derivation (D-0105 Finding 3).
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
2. Disable the authenticated external write path (Access / write filter). That does **not** stop block production.
3. Pause sequencing through op-node admin (`admin_stopSequencer` on loopback `--rpc.enable-admin`). The live start path is `--sequencer.enabled=true --sequencer.stopped=false` (`scripts/04-start-sequencer-sepolia.sh`). Until admin-stopped, op-node keeps producing empty unsafe blocks every `L2_BLOCK_TIME` (2s), so the batcher can never make `safe` catch `unsafe`.
4. Wait until the latest sequenced block is safe/L1-derived. Force or wait for the batcher to publish remaining channels. Verify `unsafe == safe` at the intended cutover height **after** sequencing is paused.
5. Record cutover number/hash, safe/finalized, output root, versions, batcher/proposer L1 tx state.
6. Stop in documented order. Preserve the complete op-geth datadir and logs.
7. Candidate op-reth already at the recorded safe point (from Task 3/4).
8. Start op-reth (`sequencer_faultproof`), then op-node sequencer + `--l2.enginekind=reth`.
9. Start write filter, batcher, proposer, challenger in the existing dependency order.
10. Re-enable writes only after block production, batch submission, proposals, and challenger health.
11. Immediate rollback (§9) if it cannot produce, changes the expected state root, breaks batch/propose, or cannot support fault-proof checks.

**Out of scope:** Deleting op-geth; changing L1 contracts or public URLs; `karst_time`.

**Success:** First op-reth block extends the recorded parent; no accepted tx lost; batcher posts; proposer root expected; challenger healthy; deposit / L2 transfer / authenticated write / withdrawal pass.

**Verification:** Existing status, smoke-transfer, bridge, viewer, batcher, proposer, challenger checks plus parity at the cutover boundary. Each check must be able to fail.

**Dependencies:** Tasks 1–4.

### Task 6 — P1: Observe and keep rollback ready

**Objective:** Stability through restarts, nightly sleep/wake, L1 derivation, and one proposer/challenger lifecycle.

**Instructions:** ≥72 hours, ≥2 **launchd** sleep/wake cycles (`com.steve.fortel2-sleep` / `com.steve.fortel2-wake` via `run_dev_{sleep,wake}.sh` → `dev-sleep.sh`). After Phase 7 the jobs failed because start/stop still assumed the pre-wipe process set — treat a missed 03:00 wake or a `status.sh` / `alert-watch.sh` “op-geth stopped” false-negative as a Task 6 fail, not a footnote. Also: health snapshot (`com.steve.fortel2-health`), alerts (`com.steve.fortel2-alerts`), resolve-games (`com.steve.fortel2-resolve-games`), one controlled `stop-all-sepolia` / `start-all-sepolia` restart, keep geth binary/selector/datadir, dated promote / extend / rollback decision.

**Success:** No unexplained divergence or missed wake; `alert-watch` expected-stack names match the running EL pid; resources fit the Mac; dated decision before Task 7.

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

**Instructions:** End the window only after Mac + Render observation and at least one friend clean sync; walk the §10 stray-surface list and remove geth startup options from every **active** path; keep dated records; archive or separately-approved delete of geth datadirs; CI/search guard against new `op-geth` pins or `enginekind=geth` on the live selector. Learning oracles (`derivation-check.sh`, `sequencer-stub-demo.sh`) need an explicit keep-on-geth exception or a follow-up task — do not leave them as silent live-path leftovers.

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

Procedure (do **not** run stock `04-start-sequencer-sepolia.sh` as the first rollback step — it sets `--sequencer.enabled=true --sequencer.stopped=false`):

1. Stop authenticated writes.
2. Stop the op-reth pair. Leave the op-reth datadir untouched for diagnosis.
3. Start the preserved op-geth + op-node in **verifier-only** mode (`--sequencer.enabled=false`, or start then `admin_stopSequencer`). The preserved geth database ends at the **original cutover height**. If Task 6 already published op-reth blocks to L1, enabling sequencing immediately builds an alternate unsafe branch instead of deriving those blocks.
4. Wait until the rollback pair’s **safe** number and hash match the current canonical safe head (L1-derived, including post-cutover op-reth blocks that were batched).
5. Only then enable sequencing (`admin_startSequencer`).
6. Verify hash continuity, then re-enable writes.

Do not delete or mutate either datadir during rollback.

## 10. Final QA checklist

This section is the **closed list** for “did we forget a file.” The Phase 7 failure class was launchd sleep/wake still assuming the old process set. An EL swap that updates only `04-start-sequencer-sepolia.sh` will fail the same way. Search active files for `op-geth`, `enginekind=geth`, and the pid name `op-geth` before calling Task 5 or Task 9 done.

### Chain continuity

- [ ] L1 11155111, L2 852.
- [ ] Genesis, rollup, L1 contracts unchanged. No `karst_time`.
- [ ] Sampled safe/finalized hashes and state roots match across candidate verifier, sequencer, Render replica, and friend node.
- [ ] First post-cutover block extends the recorded parent.
- [ ] No unsafe/unbatched tx discarded at cutover.
- [ ] Cutover used `admin_stopSequencer` before `unsafe == safe`.
- [ ] If rollback ran after op-reth blocks were on L1: geth came up **verifier-only**, caught canonical safe, then `admin_startSequencer`.

### Core services

- [ ] Sequencer produces before and after restart.
- [ ] Batcher posts new channel data to Sepolia.
- [ ] Proposer posts the expected output root / game type.
- [ ] Challenger judges valid games without attacking them.
- [ ] SafeDB queries succeed.
- [ ] Historical proof / withdrawal requirements satisfied.

### End-to-end

- [ ] Ordinary L2 transfer (`scripts/smoke-transfer.sh`).
- [ ] L1→L2 deposit (`deposit-eth-sepolia.sh`).
- [ ] L2→L1 initiate/prove/finalize.
- [ ] Authenticated SettlementOS submit + receipt poll.
- [ ] Pipeline viewer (`serve-viewer.sh`) and block viewer (`blocks/`) correct.
- [ ] Public read gateways still reject writes.
- [ ] Guestbook dApp still reads via loopback `JsonRpcProvider`.

### Security

- [ ] No role key, provider token, Cloudflare secret, or JWT committed or logged.
- [ ] EL and op-node admin RPC loopback/private.
- [ ] Friend nodes receive no operator key.
- [ ] New Render and friend services use independent JWTs (and preferably independent L1 credentials).
- [ ] Write filter still proxies loopback EL (`rpc-method-filter.py` → `:9545`); cloudflared still dials `:9555`, never the raw EL.

### Operations — launchd / sleep / wake (P7 miss)

These jobs do not name `op-geth` in the plists; they call scripts that do. A pid-name change that misses one of them is a silent overnight fail.

- [ ] `FORTEL2_ENV=.env.sepolia ./scripts/dev-sleep.sh sleep` stops the new EL (and the rest of the Sepolia set).
- [ ] `dev-sleep.sh wake` starts it again (funds preflight + orphan cleanup still work).
- [ ] `launchd/com.steve.fortel2-sleep.plist` → `run_dev_sleep.sh` still matches repo (`check-launchd.sh`).
- [ ] `launchd/com.steve.fortel2-wake.plist` → `run_dev_wake.sh` — **two scheduled 03:00 wakes** after Task 5.
- [ ] `launchd/com.steve.fortel2-health.plist` → `refresh_health.sh` writes `data/pipeline-health.json`.
- [ ] `launchd/com.steve.fortel2-alerts.plist` → `alert-watch.sh` expected-stack list includes the **new** EL pid (today: `op-geth`). A leftover `op-geth` expect after a rename is a false `stack-missing`.
- [ ] `launchd/com.steve.fortel2-resolve-games.plist` still recovers bonds through the sleep window.
- [ ] `scripts/check-launchd.sh` is green after the pid/script change.
- [ ] No leftover crontab double-start (`launchd/README.md`).

### Stray surfaces — Mac start/stop/status (must match pid + enginekind)

- [ ] `scripts/03-init-l2.sh` — 852 genesis only; op-reth init path; refuse 901 / `$DATA_DIR/l2/op-geth` when selector is reth.
- [ ] `scripts/04-start-sequencer.sh` (local 901) — selector, datadir, `--l2.enginekind`.
- [ ] `scripts/04-start-sequencer-sepolia.sh` — `require_bin`, `$DATA_DIR/l2/op-reth`, `--l2.enginekind=reth`, `--l1.rpckind` from `SEPOLIA_L1_RPC_KIND` (not hardcoded).
- [ ] `scripts/start-all.sh` / `start-all-sepolia.sh` — still start EL + node + filter + batcher + proposer (+ optional challenger/proxy).
- [ ] `scripts/stop-all.sh` / `stop-all-sepolia.sh` — `stop_bg` name matches `start_bg` name.
- [ ] `scripts/status.sh` — `procs=(…)` includes the new EL.
- [ ] `scripts/reset.sh` / `reset-sepolia.sh` — wipe the **reth** datadir when that is the live EL; never wipe the preserved geth rollback dir by default.
- [ ] `scripts/07-start-rpc-filter-sepolia.sh` — `wait_for_rpc` label/upstream still the live EL HTTP port.
- [ ] Log path: `data/logs/op-reth.log` (or documented alias). README “known-good log lines” updated.

### Stray surfaces — monitors, checklists, helpers

- [ ] `scripts/alert-watch.sh` expected list (`op-geth` today).
- [ ] `scripts/demo-checklist.sh` process arrays (local + Sepolia).
- [ ] `scripts/demo-live.sh` talk-track / health if it names the EL.
- [ ] `scripts/test-helpers.sh` — `STK_CORE`, start/stop symbol lists, any `STOP=… op-geth` greps. Dual-client tests until Task 9, then geth-only live path must go red.
- [ ] `.env.example` pin comment (`op-geth v1.101702.2`).
- [ ] `AGENTS.md` / `README.md` process tables, architecture diagram (`Geth["op-geth :9545"]`), sequencer-restart paragraph.
- [ ] `.cursor/rules/fortel2.mdc` if it still says the live EL is only op-geth after Task 9.

### Stray surfaces — keep-on-geth unless a follow-up says otherwise

Learning oracles. Do not silently break them at Task 5, and do not treat them as the live sequencer.

- [ ] `scripts/derivation-check.sh` + `$DATA_DIR/l2/derivation-op-geth` / `derivation-anchor-op-geth`.
- [ ] `scripts/sequencer-stub-demo.sh` + `$DATA_DIR/l2/sequencer-stub-op-geth`.
- [ ] Document the exception in the Task 9 closeout, or file a follow-up to retarget them.

### Stray surfaces — replica / friends / rail (Task 7–8)

- [ ] `replica/FRIENDS.md` still says op-geth until Task 8; then points at `fortel2-node`.
- [ ] `scripts/pack-replica-artifacts.sh` — artifacts unchanged (no new genesis).
- [ ] `fortel2-replica` image pin / Dockerfile (sibling repo; Task 7).
- [ ] `deployments/rail-interface.json` notes that mention op-geth bind (URLs stay; wording).
- [ ] `config/cloudflared-write.yml.example` still forbids pointing at raw EL admin ports.

### Operations (other)

- [ ] Mac: controlled `stop-all-sepolia` / `start-all-sepolia` restart on the new datadir.
- [ ] Render: restart on the **new** disk (Task 7).
- [ ] Resource use within declared limits.
- [ ] Rollback rehearsed or mechanically validated (verifier-first) before removing geth support.
- [ ] `./scripts/status.sh` and logs say the live EL name.

### Repository boundaries

- [ ] `ForteL2` owns sequencing, fault proofs, canonical artifacts.
- [ ] `fortel2-replica` owns operated Render RPC.
- [ ] `fortel2-node` is only the friend verifier.
- [ ] One source of truth for published config + hash check.

## 11. Open questions

Answer during Task 1 or 2 unless noted.

| # | Question | Status after P:0 |
|---|---|---|
| 1 | Exact coordinated `op-node` / `op-reth` pin? | **Closed (Task 1, #176, D-0109).** v1.19.2 (`da197e45`) + `op-reth/v2.3.3` (reports `2.3.0-dev` `9384bc53`); enforced by `scripts/check-el-pins.sh`. Bump = Mini sidecar re-run first. |
| 2 | Does 852 hardfork config need adjustment for that pin (without changing genesis)? | **No change needed for first-N.** Rollup has no `karst_time`; Task 1 research: Jovian minimums far older, no getPayloadV5 required. **Reconfirmed at safe-head (Task 3, D-0114):** full 20-block three-way parity genesis→394470. |
| 3 | Which historical-proof flags/retention does `cannon-kona` + shortened withdrawal window need? | **Closed (Task 4, #189, D-0116):** `--proofs-history` with `op-reth proofs init --proofs-history.skip-backfill` before FIRST start of the datadir (store fills forward; no retroactive backfill). Judge + withdrawal-prove + deep `eth_getProof` all ran against this profile. |
| 4 | Does Render public RPC need archive, or is `--full` enough? | **Open.** Task 7. |
| 5 | Disk/RAM of a clean 852 op-reth sync on Render under current RPC load? | **Open.** Task 7. |
| 6 | Mid-chain rewind without `debug_setHead` on a keeper? | **Settled (Task 2, D-0110):** wipe the reth datadir + re-derive from 852 genesis; `debug_setHead` never. Task 3 may revisit only with evidence. |
| 7 | Beacon requirement for friends if `--l1.beacon.ignore=true` stays operator-only? | **Open.** Live Sepolia and the spike ignore beacon (calldata DA). Task 8 must not require a beacon unless a later pin does. |

## 12. Inspection limits

- **Done:** Mini P:0 sidecar (first-N hash-match; `tasks/spike-op-reth.md`). Task 1 pin + assertion (#176, D-0109). Task 2 selector/guards + 852 sidecar start (#178, D-0110). Task 3 safe-head catch-up (lag 0) and 20-sample three-way parity + restart/resume (#184, D-0114; `tasks/task3-op-reth-safe-head-parity.md`).
- **Done (Task 4, #189, D-0116):** SafeDB post-enable, historical proofs, output-root parity, judged-valid claim, withdrawal initiate+prove from candidate artifacts. Finalize tail = Task 5 gate (D-0116).
- **Done (Task 5 Phase B, D-0120):** live cutover to op-reth at 473031→473032, two launchd cycles clean on the renamed process set; unsafe-tip behavior now proven by production (reth is the producer).
- **Done (Task 5 closeout, #200/#203, D-0121):** L2 transfer, authenticated write, reth-era withdrawal initiate→prove→finalize on real clocks, viewer CORS on reth.
- **Not done:** Task 6 sign-off (observation in progress); Render image (Task 7); friend repo (Task 8); geth removal (Task 9).
- Codex review on `a00920d` (pause sequencing before `unsafe == safe`; verifier-first rollback; rpckind matches provider) is incorporated here. The `admin_stopSequencer` / `admin_startSequencer` helper that review asked for is `scripts/sequencer-admin.sh` (Task 5 Phase A, #192) and was used live at cutover (D-0120).
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
