# Phase 5 spike notes — custom proposer

**Date:** 2026-07-26  
**PRD:** `tasks/prd-phase-5-proposer.md`  
**Code:** `proposer/`

## Specs consulted

- https://specs.optimism.io/fault-proof/stage-one/dispute-game-interface.html — DisputeGameFactory / create / game UUID
- Stock `op-proposer` (`proposer/driver.go`, `contracts/disputegamefactory.go`, `proposer/source/source.go`) as reference oracle

## Proposal path (DGF era)

```text
op-node optimism_syncStatus → proposeable L2 number (safe if allow-non-finalized)
op-node optimism_outputAtBlock(n) → outputRoot
extraData = 32 bytes; L2 sequence number in last 8 bytes (big-endian)
DisputeGameFactory.create(gameType=1, rootClaim=outputRoot, extraData) payable(initBonds)
→ PermissionedDisputeGame clone; withdrawals prove against respected games
```

This ForteL2 deploy has `L2OutputOracleProxy = 0x0`. Phase 5 does **not** call L2OO.

## Decisions (US-050)

| Question | Decision |
|---|---|
| Language | **Go** — matches Phase 4 / OP Stack tooling |
| Repo layout | `proposer/` in ForteL2 (not a separate repo) |
| Output root | **Fetch** via `optimism_outputAtBlock` in v1; recompute locally deferred |
| Game type | `PROPOSER_GAME_TYPE=1` (permissioned) — matches stock scripts |
| Sepolia | Inspect anytime; **submit** only after local US-052 + confirm gate |

## Done in this spike slice

- [x] `extraData` pack/unpack + unit tests
- [x] Factory ABI encode/decode helpers (`create`, `gameCount`, `gameAtIndex`, `initBonds`)
- [x] Read-only CLI `proposer/cmd/inspect-game`
- [x] Propose loop `proposer/cmd/propose-loop`
- [x] `USE_CUSTOM_PROPOSER=1` script switch (local + Sepolia confirm)

## US-052 notes

- Propose against **safe** head (`-allow-non-finalized=true`), matching stock Anvil config.
- Duplicate safeguard: `lastProposedL2` + `lastProposalTime`; init from latest factory game of type 1.
- Bond: `initBonds(gameType)` (local learning = `0.08 ether`) sent as `msg.value`.
- Recovery: restart stock `./scripts/06-start-proposer.sh`.

### Live local proof (2026-07-26)

Stack reset + redeploy with `preimageOracleChallengePeriod=1` (see below). Stock proposer stopped; custom `-once`:

```text
factory=0x2Ddb42910120B8a67eb82fEbc78F367a7Ac0E1B3
gameCount 0 → 1
l2=15 rootClaim=0x74928d3c…7693a6
extraData_sequence=15
creator=0x3C44CdDd…4293BC (PROPOSER)
l1_tx=0x94d39f7a…752882
```

### Deploy fix (local only)

Learning-short clocks (`clockExtension=5`, `maxClockDuration=10`) fail `create()` with `InvalidClockExtension` (`0x8d77ecac`) when the PreimageOracle still uses the stock `challengePeriod=86400`, because `initialize` requires:

`maxClockDuration >= max(2*clockExtension, clockExtension+challengePeriod)`.

Local `02-deploy-contracts.sh` now sets `preimageOracleChallengePeriod=1` (env `PREIMAGE_ORACLE_CHALLENGE_PERIOD`). **Pinned Sepolia deploy is unchanged** (Phase 7 redeploy gate).

## US-053 / US-054

- Local: `USE_CUSTOM_PROPOSER=1 ./scripts/06-start-proposer.sh` builds `$BIN_DIR/fortel2-proposer` under pid name `op-proposer`.
- Sepolia: same flag **plus** `CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1`; poll defaults to credit-budget **12s**. Documented max ~15 min + revert to stock.
- No `lib.sh` `start_bg`/`stop_bg` changes.

## US-055 — What an output root is (operator write-up)

An **output root** is a 32-byte commitment to L2 state at a specific block (versioned output hash). The proposer posts it to L1 by creating a dispute game whose `rootClaim` is that hash and whose `extraData` binds the L2 sequence number. Withdrawals later prove against a respected game that covers their L2 inclusion block.

On this solo learning chain the proposer key is trusted: whatever root it posts is what L1 will treat as the L2 tip for withdrawals. There is no independent challenger (Phase 7). If the proposer stops, new games stop appearing — existing games remain, but withdrawals that need a fresher root stall until proposals resume.

**Safe vs finalized:** stock (and our custom) proposer uses `--allow-non-finalized=true` on Anvil because L1 finality does not advance like mainnet. It proposes the **safe** L2 head (after batches land), not unsafe tip.

**What breaks if the proposer lies:** until Phase 7, nothing on-chain disputes a bad root. That is why Phase 5 learns the propose path from the inside before fault proofs.
