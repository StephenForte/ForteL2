# PRD: Phase 7 — Fault proofs (redeploy gate + op-challenger)

## Introduction

Exercise a real OP Stack **dispute game** on Sepolia ForteL2 (chain **852**): choose new fault-game immutables, run the coordinated **redeploy gate**, then run `op-challenger` against a deliberately bad proposal.

This is a **learning phase**, not a mainnet launch. It is the first work allowed to break the pinned 2026-07-22 Sepolia deploy. Custom `batcher/` / `proposer/` / `derivation/` stay learning artifacts — production roles stay **stock** `op-batcher` / `op-proposer` / `op-node` (D-0018).

**Parent roadmap:** `tasks/prd-l2-learning-chain.md` Phase 7  
**Network reset procedure (binding):** README § “Network reset procedure”  
**Companion:** `tasks/prd-mainnet-pilot.md` (Phase 9 track shares the same redeploy gate; do not conflate the two programs)  
**Predecessors:** Phase 5 proposer (output roots understood from the inside); Phase 6 derivation verifier

**This PRD does not authorize the wipe.** Writing or merging it must not set `FORCE_SEPOLIA_REDEPLOY`, pack/publish replica genesis, or change live immutables. Execution is operator-owned after US-070 chooses all six knobs in one sitting.

## Goals

- Understand the fault-proof trust model by running a dispute, not by reading the spec alone.
- Replace the learning-short clocks (`faultGameMaxClockDuration=10`) with minutes-to-hours values that a human can actually play.
- Run the coordinated network reset once — Mac sequencer, Render replica, every Phase 3b friend, and SettlementOS (D-0028 notice).
- Watch a valid proposal, then challenge a deliberately bad one with `op-challenger`.

## Non-goals

- Mainnet deploy or real-ETH economics (Phase 9 / `prd-mainnet-pilot.md`)
- Decentralized sequencing (Phase 8)
- Blob DA / beacon endpoints (D-0037 — not pursued)
- Changing SOS product contracts except the mandatory post-wipe redeploy they own
- Replacing stock proposer/challenger with a from-scratch challenger
- Publishing the Access write hostname
- Editing `scripts/lib.sh` `start_bg` / `stop_bg`

## Constraints

| Constraint | Rule |
|---|---|
| Host | Native binaries on the Mac mini; no Docker on this workstation |
| Keys | Never commit `.env.sepolia`; never ask the operator to paste keys |
| Notice | SOS + every replica operator get **≥1 day** before step 2 of the reset (D-0028 / D-0029) |
| Immutables | Choose **all six** delay/clock knobs (including `PREIMAGE_ORACLE_CHALLENGE_PERIOD`) in `.env.sepolia` **before** `FORCE_SEPOLIA_REDEPLOY=1`. File values win over inline env (README reset step 3). `02-deploy-contracts-sepolia.sh` refuses a combo that fails `PermissionedDisputeGame.initialize` |
| Replica | Pack → publish fortel2-replica → wipe Mac `data-sepolia` **and** Render `/data` together. Never one side |
| Friends | Same genesis/`rollup.json` as Render. Point them at `replica/FRIENDS.md` |
| Rollback | There is no rollback except another redeploy. A forgotten parameter is a second network-wide wipe |
| Privileged | No `lib.sh` `start_bg` / `stop_bg` edits |

## Why a redeploy is required

The 2026-07-22 deploy used learning-short fault-game immutables so Phase 1b withdrawals were a one-evening exercise. Those values (`faultGameClockExtension=5`, `faultGameMaxClockDuration=10`, short proof-maturity / finality delays) are too short for a realistic dispute. They are **constructor immutables** — they only change via a new L1 contract set and a new L2 genesis.

## Proposed immutable defaults (operator confirms in US-070)

Minutes-to-hours, not seconds, not mainnet’s multi-day values. Confirm or replace **all six** in one sitting before anyone wipes.

`PermissionedDisputeGame.initialize` requires:

```
maxClockDuration >= max(2 * clockExtension, clockExtension + preimageOracleChallengePeriod)
```

The 2026-07-22 deploy left `preimageOracleChallengePeriod` at op-deployer’s default **86400**. `600` / `7200` with that sixth parameter still in place cannot create a game (`InvalidClockExtension`). Proposed `PREIMAGE_ORACLE_CHALLENGE_PERIOD=3600` makes `7200 >= 600 + 3600` legal without using the local Anvil value of `1`.

| Env var | Current (pinned) | Proposed learning default | Intent |
|---|---|---|---|
| `FAULT_GAME_CLOCK_EXTENSION` | `5` | `600` (10 min) | Chess-clock extension per move |
| `FAULT_GAME_MAX_CLOCK_DURATION` | `10` | `7200` (2 h) | Must be ≥ max(2×extension, extension+preimage period). Long enough to run `op-challenger` by hand |
| `PREIMAGE_ORACLE_CHALLENGE_PERIOD` | implicit `86400` (not in intent) | `3600` (1 h) | Sixth constructor immutable. Stock 86400 makes 7200 illegal (`7200 < 600+86400`) |
| `PROOF_MATURITY_DELAY_SECONDS` | learning-short | `1800` (30 min) | Proof must sit before finalize |
| `DISPUTE_GAME_FINALITY_DELAY_SECONDS` | learning-short | `1800` (30 min) | Game finality delay |
| `FAULT_GAME_WITHDRAWAL_DELAY` | learning-short | `3600` (1 h) | Withdrawal delay after game |

Do **not** pass these as inline overrides on `02-deploy-contracts-sepolia.sh` — `scripts/lib.sh` sources `.env.sepolia` after start and the file wins. The Sepolia deploy script writes all six into `intent.toml` and exits before apply if the initialize inequality fails.

## Phase roadmap

| Story | Scope | Status |
|---|---|---|
| **US-070** | Choose all immutables + write the operator brief (no on-chain spend) | **Spec ready** |
| **US-071** | Announce (≥1 day) + stop writers + redeploy Sepolia L1 + new genesis | Not started — operator |
| **US-072** | Pack / publish replica artifacts + coordinated wipe + hash cross-check | Not started — operator |
| **US-073** | Stock proposer posts a valid game; `op-challenger` watches and does not fault it | Not started |
| **US-074** | Deliberately bad proposal; `op-challenger` wins the dispute | Not started |
| **US-075** | Operator write-up: what the game proved, what is still trusted | Not started |

## User stories

### US-070: Immutable selection (no wipe)

**Description:** As the operator, I want every fault-game delay chosen and written into `.env.sepolia` (gitignored) plus a one-page brief, so the redeploy is a mechanical apply rather than an on-the-spot guess.

**Acceptance Criteria:**

- [ ] All six knobs in the table above are written into local `.env.sepolia` (never committed)
- [ ] Brief in `tasks/spike-phase-7-immutables.md` records chosen values, why they are minutes-to-hours, the preimage-oracle period, and the SOS/friend notice date
- [ ] `.env.sepolia.example` documents the **names** (including `PREIMAGE_ORACLE_CHALLENGE_PERIOD`) and the “choose in one sitting” rule without publishing the Phase 7 chosen numbers as the file’s applied defaults
- [ ] No `FORCE_SEPOLIA_REDEPLOY`, no pack/publish, no datadir wipe in this story

### US-071: Redeploy gate (L1 contracts + genesis)

**Description:** As the operator, I want a fresh Sepolia contract set whose clocks I can actually play, knowing SOS and replica operators were warned.

**Acceptance Criteria:**

- [ ] SOS + Render + every Phase 3b friend notified ≥1 day ahead (D-0028)
- [ ] Mac writers stopped: `FORTEL2_ENV=.env.sepolia ./scripts/stop-all-sepolia.sh`
- [ ] `FORTEL2_ENV=.env.sepolia FORCE_SEPOLIA_REDEPLOY=1 ./scripts/02-deploy-contracts-sepolia.sh` after the file knobs are set (script must echo `preimageOracleChallengePeriod` and must have refused any illegal clock combo)
- [ ] New addresses recorded under `deployments/sepolia/`; Phase 1 Anvil tree untouched
- [ ] New contract addresses sent to SOS once they exist
- [ ] Foundry default keys still refused (`L2_CHAIN_ID=852`)

### US-072: Coordinated network reset

**Description:** As the operator, I want every verifier on the same new genesis so chain 852 does not silently fork.

**Acceptance Criteria:**

- [ ] `FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh` **after** US-071 (packing first republishes the old genesis)
- [ ] New `genesis.json` / `rollup.json` published to [fortel2-replica](https://github.com/StephenForte/fortel2-replica)
- [ ] Mac `reset-sepolia.sh` **and** Render `/data` wipe **and** every friend wipe, then all restart
- [ ] Same L2 block hash at the same number on Mac vs Render vs each friend
- [ ] `rail-interface.json` version bump if bridge proxies changed (addresses are a versioned contract)

### US-073: Watch a valid game

**Description:** As the operator, I want `op-challenger` running against a honest stock proposal so I know the happy path before I inject a fault.

**Acceptance Criteria:**

- [ ] Stock `op-proposer` (not `USE_CUSTOM_PROPOSER=1`) posts at least one accepted game on the new factory
- [ ] Native `op-challenger` process documented in README (start/stop, logs, no keys in git)
- [ ] Challenger does **not** attack the valid game
- [ ] Game proxy / `rootClaim` / L2 sequence recorded with `cast` (no Blockscout)

### US-074: Challenge a bad proposal

**Description:** As the operator, I want to see a dispute resolve against a deliberately wrong output root so “fault proof” is a thing I have done, not a slogan.

**Acceptance Criteria:**

- [ ] A bad proposal is created in a documented, isolated way (stock test hook or a one-shot script). Do not leave a hostile proposer running
- [ ] `op-challenger` takes the challenger side and the game resolves in favor of the honest claim
- [ ] Tx hashes + game address recorded
- [ ] Kill switch: stop the bad-proposal path; stock proposer remains the only writer

### US-075: Trust-model write-up

**Description:** As the operator, I want a short README note in my own words covering what the challenger proved and what is still trusted (sequencer honesty, DA permanence, key custody).

**Acceptance Criteria:**

- [ ] README Phase 7 subsection: commands, what a pass looks like, pointer at the recorded game
- [ ] Explicit leftover: `derivation/` still compares to the operator node unless US-P7-005 lands — a won dispute is not independent verification for a counterparty

## Success metrics

- One honest game observed; one dishonest game challenged and won
- Every replica (Render + friends) matches Mac hashes after the wipe
- SOS redeployed or adopted new 852 addresses without discovering the wipe from a failed read
- No second redeploy caused by a forgotten immutable (including the preimage-oracle period)

## Out of scope until a later plan

- Cannon / Kona prestates pinning for production
- Permissionless game bonds sized for mainnet
- Moving the sequencer off the Mac mini (pilot P7-1)

## References

- README Network reset procedure
- `tasks/prd-l2-learning-chain.md` Phase 7 row
- `tasks/decisions.md` D-0018, D-0028, D-0029, D-0037, D-0046
- Dispute game interface: https://specs.optimism.io/fault-proof/stage-one/dispute-game-interface.html
