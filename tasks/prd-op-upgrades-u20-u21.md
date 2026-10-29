# PRD: OP contract upgrades U20 → U21 (super-root fault proofs, ETHLockbox)

**Track:** **OPU**. It runs parallel to the roadmap (like **EL**) and is not a phase number. Decision: D-0157.
**Chain:** ForteL2 Sepolia, L2 chain **852**. This is an L1 contract upgrade done in place. There is **no redeploy, no wipe, and no L2 hard fork**.
**Parent roadmap:** `tasks/prd-l2-learning-chain.md` (OPU row).
**Sources:** OP notices [Upgrade 20](https://docs.optimism.io/notices/archive/upgrade-20) and [Upgrade 21](https://docs.optimism.io/notices/upgrade-21) (provisional; read 2026-10-29).

**This PRD does not authorize any L1 transaction.** The `OPCM.upgrade()` calls are operator-run in a declared window (OPU-4, OPU-6). Merging this file changes nothing on chain.

## Why

ForteL2 is not superchain-governed, so nothing forces either upgrade. But U21 (op-contracts v9.0.0) requires every chain to be on U20 (v8.0.0) first. Skipping v8 therefore means skipping v9 too. Later op-proposer and op-challenger releases will eventually stop supporting output-root games, but no date has been published. Super-root games (U20) are the format interop is built on, and they are worth learning for the same reason Phase 7 was.

## Measured starting point (2026-10-29)

- **Contracts are op-contracts v7.0.0.** Public Sepolia RPC: SystemConfig `version()` `3.14.2` with impl `0x42ad0173…` (the registry's v7.0.0 Sepolia impl, exact). DisputeGameFactory `1.6.1` with impl `0x72b97171…` (v7.0.0, exact). OptimismPortal `5.6.1` (v7.0.0 version; impl `0x3f5507d6…`).
- **Fault proofs:** `respectedGameType()` = **8** (cannon-kona, permissionless). `gameImpls`: 1 = `0x103B2CEb…`, 8 = `0x84c0889A…`, and 0 / 5 / 9 = zero. `ethLockbox()` = zero.
- **v8 OPCM on Sepolia:** `op_contracts_manager` 8.0.1 at `0x6abfabbc793883add5fa308a97163e8225a9f4ca`. Source: `superchain-registry/validation/standard/standard-versions-sepolia.toml` in the d6620202 tree. v8.0.0 SystemConfig is `4.0.0`, Portal `5.8.0`, MIPS unchanged (`0xacc005dc…`, stateVersion 8).
- **The live op-node already serves super roots.**
  - op-node v1.19.11 at :9547, with SafeDB on, serves `superroot_atTimestamp(finalized ts 1793288088)`, which returned `chain_ids ["852"]` and `super_root 0xe8d95c4d…5e60`.
  - The chain entry's output equals `optimism_outputAtBlock(2927400)` = `0x65f433d3…76cf`.
  - The super root recomputes exactly as `keccak256(0x01 ‖ uint64 timestamp ‖ uint256 852 ‖ outputRoot)`.
  - A timestamp one day older is also served.
- **Release tags (peeled):**

  | Tag | Commit |
  |---|---|
  | `kona-client/v1.7.0` | `64b043ea` |
  | `op-challenger/v1.9.5` | `e907fe51` |
  | `op-challenger/v1.11.0` | `1286a886` |
  | `op-deployer/v0.8.1` | `319e3da9` |
  | `op-contracts/v8.0.0` | `f45a5ccf` |
  | `op-dispute-mon/v1.6.0` | `e92bda11` |

  `op-contracts/v9.0.0` **does not exist yet**.
- **Published standard prestate, U20:** kona 1.7.0 `cannon64-kona-interop` = `0x031ac6f15c19010da258f5cb633ef6ca9318c2d0f244bea6b2045ce6b790e1df`. That hash is for registry chains only. A custom chain builds its own (`KONA_CUSTOM_CONFIGS_DIR`, variant `kona-client-int` / `prestate-artifacts-cannon-interop`). The stock build reproducing that hash is the negative control.
- **SettlementOS surface:** `deployments/rail-interface.json` (v7) carries only `optimismPortalProxy` and `disputeGameFactoryProxy` among fault-proof fields. U20 keeps both proxies, and the coordination doc has no withdrawal or prove flow. Expected impact is a notice only. This is unverified against the SOS repo.

## Component pins this track moves to

| Binary | Now | Target | Where |
|---|---|---|---|
| op-node | v1.19.11 `43c071cb` | **v1.20.0 `d6620202`** | built 2026-10-29 in `~/src/fortel2/optimism-op-reth-v2.8.0` → `op-node version v1.20.0-d6620202-1792673968` |
| op-proposer | untagged `43c071cb` | **v1.17.0 `0130abb2`** | new clone `~/src/fortel2/optimism-op-proposer-v1.17.0` (tag object `bbaa87bf` → rc tag `d9285d4f` → commit `0130abb2`), built → `op-proposer version v1.17.0-0130abb2-1793109963` |
| op-batcher | v1.18.0 `d6620202` | unchanged | D-0156 |
| op-reth | 2.8.0 `d6620202` | unchanged | D-0155 |
| op-challenger + kona-host | `da197e45` tree, stopped (D-0132) | v1.11.0 + kona-host v1.9.0, **only when OPU-5/OPU-6 need it** | — |

Neither bump changes behaviour for us. Neither is required by U20; U20's minimums are proposer ≥ v1.16.4 and op-node ≥ v1.19.6.
- **op-node v1.20.0** removes P2P req/resp, which we don't use, adds GIWA Sepolia, and changes `genesis l2`. All flags in `04-start-sequencer-sepolia.sh` are accepted exactly as by v1.19.11.
- **op-proposer v1.17.0** has proposer code identical to `43c071cb`; only the `op-service/eth` Holesky entry and a help string differ. Every flag `06-start-proposer-sepolia.sh` passes exists.

## Tasks (run order)

| ID | What | Owner | Order |
|---|---|---|---|
| **OPU-0** | Pin op-node v1.20.0 @ d6620202 and op-proposer v1.17.0 @ 0130abb2 in `check-el-pins.sh`. The planner does the live swap after merge. | worker (T4) → planner | **Done 2026-10-29** (#272; live 10:13 PT; D-0158) |
| **OPU-1** | `build-prestate.yml`: add a kona-client v1.7.0 **interop** variant build with our custom configs, plus the stock interop negative control (must equal `0x031ac6f1…`). Run it, then the operator downloads and re-verifies the artifact. | worker | now, parallel with OPU-0 |
| **OPU-2** | **Fork rehearsal, no spend.** Use an Anvil fork of Sepolia at head.<br>• Impersonate the L1 ProxyAdmin owner (ADMIN) and run op-deployer v0.8.1 `upgrade` v7 → v8 through OPCM 8.0.1, with our OPU-1 prestate for game type 9.<br>• Assert the post-state: SystemConfig 4.0.0, `gameImpls(9)` set, its `gameArgs` prestate = ours, the respected type, and type-8 games still resolvable.<br>• Run op-proposer v1.17.0 in super-root mode against the fork plus the live op-node, and create one type-9 game.<br>• Resolve it on the fork after warping time.<br>• Prove and finalize one withdrawal with viem ≥ 2.51 using `l2Timestamp`. | worker | after OPU-1 artifact |
| **OPU-3a** | Tooling for type 9:<br>• `06-start-proposer-sepolia.sh` super-root mode (`--superroot-rpcs`, `OP_PROPOSER_GAME_TYPE=9`, switchable at cutover)<br>• `resolve-games-sepolia.sh` for types 8 and 9<br>• `scripts/bridge` viem bump + `l2Timestamp`<br>• viewer / `pipeline-snapshot.py` proposer panel (`proposed_sequence_number` is a timestamp for super roots)<br>• `create-bad-proposal-sepolia.sh` and `09-start-challenger-sepolia.sh` for `super-cannon-kona` | worker | after OPU-2 findings |
| **OPU-3b** | **Port `proposer/` and `derivation/` to super roots (OD-2).**<br>• Phase 5 custom proposer: build the super root, propose a type-9 game; keep type-8 inspection for old games.<br>• `bad-proposal` / `inspect-game`: support type 9 (`rootClaimByChainId`).<br>• Phase 6 `derivation/proposal_compare*`: compare type-9 claims.<br>The super root it builds must equal op-node `superroot_atTimestamp` for the same timestamp. | worker | after OPU-2 findings; parallel with OPU-3a (disjoint files) |
| **OPU-4** | **Live U20 cutover** (operator window):<br>• challenger/config staged first<br>• `OPCM.upgrade()` from ADMIN<br>• proposer switched in the same window<br>• verify on chain<br>• SOS notice before and after | operator + planner | after OPU-2 green and OPU-3a merged (OPU-3b is not a cutover gate) |
| **OPU-5** | Re-prove on type 9: one withdrawal end-to-end; bad-proposal + challenge demonstration (see OD-1). | operator + planner | after OPU-4 |
| **OPU-6** | **U21** (v8 → v9): ETHLockbox migration, kona-client v1.9.0 prestate, op-challenger v1.11.0, pause/balance tooling to the lockbox. Same rehearse-then-cutover shape. | — | **not before** `op-contracts/v9.0.0` is tagged **and** OP's governed Sepolia execution (target 2026-11-09) has happened |

## Gates

- **OPU-4 does not run** unless all of these hold:
  - OPU-2 passed on a fork of the exact contracts it will touch.
  - The prestate passed OPU-1's independent re-verification.
  - OPU-3a is merged.
  - `~/fortel2-agents` is pulled.
- The upgrade transaction is irreversible. Rollback is not a supported recovery. Old type-8 games still resolve under their own impl after the upgrade (U20 notice), and that is the only "rollback" property relied on.
- **Proposer cutover:** switch at the upgrade or immediately after it, never with a deliberate gap. Proposals fail against type 9 until the proposer is switched (U20 notice § Update order).

## Open operator decisions (must be answered before the task that needs them is dispatched)

- **OD-1 (before OPU-5):** the challenger for the type-9 bad-proposal demonstration. It has been stopped since D-0132 for QuickNode cost. Choose:
  - (a) run it for a bounded window with a measured cost cap;
  - (b) demonstrate on the OPU-2 fork only;
  - (c) skip the demonstration.
- ~~**OD-2**~~ **Resolved (operator, 2026-10-29): port** `proposer/` and `derivation/` to super roots. This is task OPU-3b.
- **OD-3:** the Render replica's op-node (v1.19.11, fortel2-replica R-0029). Bump it to v1.20.0 or leave it? U20 needs nothing from the replica; it derives the same L2.
- **OD-4 (before OPU-4):** the cutover window and the SOS notice wording.

## Non-goals

- Interop, `OPCM.migrate`, or a shared dispute setup (U21 ships the contracts but does not call it).
- Moving the sequencer, the replica, or any L2 state; a redeploy or wipe.
- op-dispute-mon (we don't run it).
