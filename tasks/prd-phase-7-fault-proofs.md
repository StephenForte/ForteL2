# PRD: Phase 7 — Fault proofs (redeploy gate + op-challenger)

## Introduction

Exercise a real OP Stack **dispute game** on Sepolia ForteL2 (chain **852**): choose new fault-game immutables, run the coordinated **redeploy gate**, then run `op-challenger` against a deliberately bad proposal.

This is a **learning phase**, not a mainnet launch. It is the first work allowed to break the pinned 2026-07-22 Sepolia deploy. Custom `batcher/` / `proposer/` / `derivation/` stay learning artifacts — production roles stay **stock** `op-batcher` / `op-proposer` / `op-node` (D-0018).

**Parent roadmap:** `tasks/prd-l2-learning-chain.md` Phase 7  
**Operator sequence (binding, this file):** § “Operator sequence” — knobs → notice → wipe → rail v7 → challenger.  
**Network reset procedure (same runbook, operator-facing):** README § “Network reset procedure”  
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
| Notice | SOS + every replica operator get **≥1 day** between announce and stop-writers / redeploy (D-0028 / D-0029) |
| Immutables | Choose **all six** delay/clock knobs (including `PREIMAGE_ORACLE_CHALLENGE_PERIOD`) in `.env.sepolia` **before** `FORCE_SEPOLIA_REDEPLOY=1`. File values win over inline env (README reset step 1). `02-deploy-contracts-sepolia.sh` refuses a combo that fails `PermissionedDisputeGame.initialize` |
| Prestate | The chain must end up running **game type 8** (`cannon-kona`) against a **Kona** absolute prestate the pinned `cannon` can execute (**stateVersion 8**). Types 0/1 are unplayable here — op-challenger binds them to the absent `op-program` (D-0060). **The registration is not part of the redeploy.** A Kona prestate commits to the *post-wipe* `rollup.json`, which does not exist until the redeploy has run, so the wipe registers only the standard game and the type-8 game is added by a **second `op-deployer apply` at step 8b** (D-0061). op-deployer 0.7.1's built-in default is a **cannon32** artifact and `02-deploy-contracts-sepolia.sh` **rewrites `intent.toml` on every run**, so a hand-edited intent does not survive — the override is written by the script from `FAULT_GAME_ABSOLUTE_PRESTATE`, which the script **refuses** while `FORCE_SEPOLIA_REDEPLOY=1` (D-0061). What must land **before the announcement** (step 0b) is the *code*, not the hash: D-0056 (1)–(3) resolved and F7-6 / F7-7 / F7-8 merged — reviewed code changes, not operator edits, so they cannot happen inside the notice window |
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

## Operator sequence

This is the Phase 7 order **for us**. User stories below are the same work split for tracking. README “Network reset procedure” is the same knobs → notice → wipe → v7 runbook in operator-facing form. **This PRD still does not authorize the wipe.**

Keep `deployments/rail-interface.json` at **v6** until step 9. v6 is the live SOS contract (chain 852, current proxies, public reads). A version bump with unchanged addresses is a false event — SOS keys off `version`.

> **STATUS 2026-08-22 — steps 2 through 9 are COMPLETE (D-0068). Do not re-run them.**
> The wipe executed: chain 852 is live on new L1 proxies, the replica derives the same chain, and
> `rail-interface.json` is at v7. Re-running step 3 would wipe the network a second time.
> **Step 10 (SOS recovery) is also complete — D-0069. Step 8b (fault-proof game, gate F7-12) is complete — D-0077, 2026-08-24. Step 11 (valid game watched, unattacked) is complete — D-0082. Step 12 (bad proposal defeated) is complete — D-0083. Step 13 (closeout note) is complete — D-0085.** The full reset → fault-proof sequence is done; no steps outstanding. Item 5's markers landed in #136.

| # | When | What | Story |
|---|---|---|---|
| — | Now | Do not bump rail-interface, do not pack genesis, do not set `FORCE_SEPOLIA_REDEPLOY` | pre-wipe |
| 0 | Before anyone is notified | Write **all six** immutables into local `.env.sepolia` + `tasks/spike-phase-7-immutables.md` (notice date included) | **US-070** |
| 0b | Before anyone is notified, blocking | **Phase 7 code gate (D-0056 / D-0059 / D-0060 / D-0061) — COMPLETE, D-0063.** Everything that must exist *before* the wipe has landed: `02-deploy-contracts-sepolia.sh` emits the `dangerousAdditionalDisputeGames` stanza (**F7-6**, #104), the CI prestate workflow (**F7-7**, proven by run `32416709442`), and `kona-host` 1.0.2 is on the mini (**F7-8**). **The prestate itself is deliberately not built here** — it commits to a rollup config that does not exist until after the redeploy (E-D0059-1, resolved by D-0061). D-0049's rule is that notice goes out only once all Phase 7 *coding* work is done; those three are closed. **One further pre-announcement item was added after D-0063 was written: F7-10**, the `ADMIN_PRIVATE_KEY` / `ADMIN_ADDRESS` pairing guard (D-0063 Finding 4). `02-deploy-contracts-sepolia.sh` refuses when the key is empty or does not derive `ADMIN_ADDRESS` (case-insensitive), before any spend or `$DEPLOY_DIR` wipe. It exists to protect the step 0 edit itself, so it lands *before* the notice rather than after. F7-10 merged as #107 (**D-0064**). **Step 0 is done and verified** — the six values are in local `.env.sepolia` with no duplicate assignments (**D-0065**, 2026-08-21). **F7-11 has landed:** `02-deploy-contracts-sepolia.sh` refuses a duplicated assignment of any of the six immutables on every run (the last assignment would otherwise silently win), and refuses an absent or empty one when `FORCE_SEPOLIA_REDEPLOY=1` or `FAULT_GAME_ABSOLUTE_PRESTATE` is set — the two irreversible paths. It exists because step 0's edit silently shadowed four of the six, and **three of the six are guarded by no other refusal at all** (D-0065 Findings 1-2). README step 2 gates the notice on all coding **and config** work being complete; the **the notice went out 2026-08-21 20:00Z (D-0067), so step 1 is done and the order from here is step 2** — gated on **2026-08-22T20:00Z** and preceded by `scripts/phase7-preflight.sh`, which must print `ALL CHECKS PASSED`. | **US-071** (pre) |
| 1 | ≥1 day before stop/redeploy | Announce to SOS + Render + every Phase 3b friend. Write path is already live and **unpublished** (D-0035); do not couple this wipe to publishing that hostname (D-0029) | **US-071** (start) |
| 2 | **DONE 2026-08-22 ≈21:05Z** — after the notice window | Stop Mac writers: `FORTEL2_ENV=.env.sepolia ./scripts/stop-all-sepolia.sh` | **US-071** |
| 3 | **DONE 2026-08-22 21:14:51Z**, spend 0.10781 ETH — file knobs set and step 0b done | `FORTEL2_ENV=.env.sepolia FORCE_SEPOLIA_REDEPLOY=1 ./scripts/02-deploy-contracts-sepolia.sh` — pairs `ADMIN_PRIVATE_KEY` to `ADMIN_ADDRESS` first (F7-10); a mismatch aborts before `rm -rf`. Then refuses a duplicated assignment of any of the six immutables, and an absent or empty one (F7-11) | **US-071** |
| 4 | **DONE 2026-08-22** (notice sent; SOS recovery is step 10) — new L1 proxies exist | Send new addresses to SOS (from `deployments/sepolia/deployments.json`) | **US-071** |
| 5 | **DONE 2026-08-22**, published to fortel2-replica at `bebddc3` — after step 3, never before | `FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh` → publish genesis/rollup to fortel2-replica | **US-072** |
| 6 | **DONE 2026-08-22 ≈21:40Z** — together, never one side | Wipe Mac `data-sepolia` **and** Render `/data` **and** every friend | **US-072** |
| 7 | **DONE 2026-08-22 21:44Z** — after wipe | Restart all against the new artifacts | **US-072** |
| 8 | **DONE 2026-08-22 21:50Z — matched first try** (blocks 0/1/50/100/200) — before calling the network healthy | Same L2 block hash at the same number on Mac vs Render vs each friend | **US-072** |
| 8b | **DONE 2026-08-24 (D-0077)** — network healthy, **outside the outage window** | **Register the fault-proof game (D-0061 / D-0063).** Four parts, in order. **(1)** Commit the new `rollup.json` to `deployments/sepolia/` (public by design — the replica repo already receives it) and run the CI workflow to build a **Kona** prestate with that config baked in. **(2) Gate, not a formality:** verify the commitment locally with `cannon witness --input` *before* applying. Registration is once-only twice over — `shouldDeployAdditionalDisputeGames` skips when state already holds a game, and on-chain `SetDisputeGameImpl` requires `gameImpls(8) == address(0)` ("SDGI-10"), so a wrong hash cannot be corrected by re-running apply; the fix is a manual L1PAO `setImplementation` or another network-wide wipe (D-0063 Finding 5). **(3)** Set `FAULT_GAME_ABSOLUTE_PRESTATE` to that commitment and run `02-deploy-contracts-sepolia.sh` **without** `FORCE_SEPOLIA_REDEPLOY`; `shouldDeployAdditionalDisputeGames` compares intent against state, so this adds the game without redeploying anything already live. The signer must hold **both** L1ProxyAdminOwner *and* Guardian — `MakeRespected` calls `setRespectedGameType`, which is Guardian-gated (D-0063 Finding 3a). **(4) Stop the proposer, then start it on game type 8 — a plain "restart" is not enough.** `start_bg` returns 0 when the pidfile's process is still alive (`scripts/lib.sh:122-125`), so re-running `06-start-proposer-sepolia.sh` after editing `PROPOSER_GAME_TYPE` prints `op-proposer already running` and changes nothing — the type-1 proposer keeps going. The stock branch of that script does **not** stop a live proposer first; only the `USE_CUSTOM_PROPOSER` branch does. Use the kill-switch idiom from README § Phase 5 (`$DATA_DIR` comes from `.env.sepolia`): `kill "$(cat "$DATA_DIR/pids/op-proposer.pid")" && rm -f "$DATA_DIR/pids/op-proposer.pid"`, set `PROPOSER_GAME_TYPE=8`, then `FORTEL2_ENV=.env.sepolia ./scripts/06-start-proposer-sepolia.sh`. Confirm the new process logs `game-type=8`. This matters because the apply flips the chain's respected game type from 1 to 8: existing games keep their `wasRespectedGameTypeWhenCreated` flag and nothing in flight breaks, but **new** type-1 games are not respected, cannot prove a withdrawal, and cannot advance the anchor (D-0063 Finding 3c). The same `start_bg` hazard applies to any service reconfigured in place, `op-challenger` included | **US-073** (pre) |
| 9 | **DONE 2026-08-22** (PR #115) — after step 3 addresses are in git | Bump `rail-interface.json` to **v7** with the new `bridge.*` proxies. Leave v6 until this step | **US-072** |
| 10 | **DONE 2026-08-22 (D-0069)** — SOS-owned. Full deploy, *not* adopt: the overlay survived while the contracts did not. Settlement pair escrow `0x1f75f257…4c96` / settlement `0x4a17351c…a5cc`, both `status=0x1`; explorer re-keyed (settlementos-explorer#58). **The old contract addresses are reassigned, not empty** — two invert token decimals (D-0069 Finding 2) | SOS redeploys-or-adopts on 852, re-seeds wallets, re-verifies one settlement, republishes their address book | G5 |
| 11 | **DONE 2026-08-24 16:23 PDT (D-0082)** — network healthy | Stock proposer posts a valid game; `op-challenger` does not fault it | **US-073** |
| 12 | **DONE 2026-08-24 18:52 PDT (D-0083)** — isolated | Deliberately bad proposal; challenger wins; kill the bad path | **US-074** |
| 13 | **DONE 2026-08-24 (D-0085)** — closeout | README note: what the game proved vs what is still trusted | **US-075** |

What **survives** the wipe: `networkId` `fortel2-sepolia`, chain IDs 852 / 11155111, public read URLs, unpublished Access write path, nightly 23:45–03:00 window. What is **rewritten**: every `bridge.*` proxy, SOS escrow / mocks / `TokenizedMMF`, cited tx hashes.

## Phase roadmap

| Story | Scope | Status |
|---|---|---|
| **US-070** | Choose all immutables + write the operator brief (no on-chain spend) | **Done except the notice date.** Values confirmed (D-0049); `tasks/spike-phase-7-immutables.md` written; local `.env.sepolia` written and verified 2026-08-21 (**D-0065**) — all six present, no duplicate assignments, the script's own clock gate passes. Notice sent **2026-08-21 13:00 PDT / 20:00Z** (D-0067); the D-0049 rule resolved to that date. **US-070 complete.** |
| **US-071** | Announce (≥1 day) + stop writers + redeploy Sepolia L1 + new genesis | **DONE 2026-08-22 (D-0068).** Notice 2026-08-21 20:00Z (D-0067); writers stopped ≈21:05Z; apply completed 21:14:51Z, spend 0.10781 ETH; 13 L1 proxies rotated |
| **US-072** | Pack / publish replica artifacts + coordinated wipe + hash cross-check | **DONE 2026-08-22 (D-0068).** Published to fortel2-replica at `bebddc3`; both datadirs wiped; stack restarted 21:44Z; hash cross-check matched first try 21:50Z; `rail-interface.json` at v7 (#115). **Step 10 also complete — D-0069** |
| **US-073** | Stock proposer posts a valid game; `op-challenger` watches and does not fault it | **Done 2026-08-24 (D-0082)** — game 66 unattacked through its full lifecycle, resolved DEFENDER_WINS |
| **US-074** | Deliberately bad proposal; `op-challenger` wins the dispute | **Done 2026-08-24 (D-0083)** — game 69 defeated CHALLENGER_WINS |
| **US-075** | Operator write-up: what the game proved, what is still trusted | Not started |

## User stories

### US-070: Immutable selection (no wipe)

**Description:** As the operator, I want every fault-game delay chosen and written into `.env.sepolia` (gitignored) plus a one-page brief, so the redeploy is a mechanical apply rather than an on-the-spot guess.

**Acceptance Criteria:**

- [x] All six knobs in the table above are written into local `.env.sepolia` (never committed) — **done 2026-08-21, operator-only** (the file holds signing keys; no agent touched it, D-0049). Verified: all six present, **no variable assigned twice**, the deploy script's own clock gate passes. A stale Phase 2b block lower in the file had been shadowing four of the six — see **D-0065** before editing this file again
- [x] Brief in `tasks/spike-phase-7-immutables.md` records chosen values, why they are minutes-to-hours, the preimage-oracle period, and the SOS/friend notice date — values + rationale recorded 2026-08-18 (D-0049); the notice date is recorded as a **rule** (notice only after all Phase 7 work is done, wipe ≥24h after notice), not a fixed calendar date, per operator direction
- [x] `.env.sepolia.example` documents the **names** (including `PREIMAGE_ORACLE_CHALLENGE_PERIOD`) and the “choose in one sitting” rule without publishing the Phase 7 chosen numbers as the file’s applied defaults — already true (D-0046), reverified 2026-08-18
- [x] No `FORCE_SEPOLIA_REDEPLOY`, no pack/publish, no datadir wipe in this story

### US-071: Redeploy gate (L1 contracts + genesis)

**Description:** As the operator, I want a fresh Sepolia contract set whose clocks I can actually play, knowing SOS and replica operators were warned.

**Acceptance Criteria:**

- [x] **Phase 7 code landed before the notice goes out (D-0060 / D-0061 / D-0065, sequence step 0b)** — **done 2026-08-22 (D-0066).** All five: `02-deploy-contracts-sepolia.sh` emits the `[[chains.dangerousAdditionalDisputeGames]]` stanza (**F7-6**, #104); the CI Kona-prestate workflow exists and has been run (**F7-7**); `kona-host` 1.0.2 is on the mini (**F7-8**); the script refuses an `ADMIN_PRIVATE_KEY` that does not derive `ADMIN_ADDRESS` (**F7-10**, #107); and it refuses duplicate or absent/empty Phase 7 immutables (**F7-11**, #112). **The prestate artifact itself is deliberately NOT part of this criterion** — it commits to the post-wipe `rollup.json`, which does not exist until after the redeploy (E-D0059-1, resolved by D-0061), so building it, verifying its commitment with `cannon witness --input`, and registering the type-8 game are acceptance criteria of **US-073**, at sequence step 8b.
- [x] SOS + Render + every Phase 3b friend notified ≥1 day ahead (D-0028) — **sent 2026-08-21 13:00 PDT / 20:00Z (D-0067)** to SettlementOS, SOS Explorer, L2Replica and ChainBank. No Phase 3b friends notified: none are active (operator determination, D-0067 Finding 2). **Step 2 is gated on 2026-08-22T20:00Z.**
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
- [ ] `rail-interface.json` bumped to **v7** with the new `bridge.*` proxies after they exist in `deployments/sepolia/deployments.json`. **v6 stays until this step** — do not bump before the wipe

### US-073: Watch a valid game

**Description:** As the operator, I want `op-challenger` running against a honest stock proposal so I know the happy path before I inject a fault.

**Acceptance Criteria:**

- [x] **Step 8b, in order (D-0061 / D-0063) — done 2026-08-24 (D-0077), commitment `0x034c90f0…796b8d`, first type-8 game at index 63:** post-wipe `rollup.json` committed to `deployments/sepolia/`; Kona prestate built from it by the CI workflow; **its commitment verified locally with `cannon witness --input` *before* applying** — registration is once-only twice over (`shouldDeployAdditionalDisputeGames` skips, and on-chain `SetDisputeGameImpl` requires `gameImpls(8) == address(0)`), so a wrong hash is correctable only by a manual L1PAO `setImplementation` or another wipe
- [x] Second `op-deployer apply` registers the type-8 game with `MakeRespected`, signed by a key holding **both** L1ProxyAdminOwner and Guardian (`setRespectedGameType` is Guardian-gated, D-0063 Finding 3a) — **done 2026-08-24 (D-0077)**: impl `0x84c0…8584`, `respectedGameType` = 8, `gameArgs(8)` carries the commitment
- [x] **`PROPOSER_GAME_TYPE` switched to 8 and the proposer stopped and restarted — done 2026-08-24 (D-0077), game 63 is type 8, respected, prestate matches** — a plain re-run of the start script is a no-op (`start_bg` returns 0 on a live pid, D-0064 Finding 7); games created before the flip keep their respected flag, but a proposer left on type 1 posts games that cannot prove a withdrawal or advance the anchor
- [x] Stock `op-proposer` (not `USE_CUSTOM_PROPOSER=1`) posts at least one accepted game on the new factory — **done (D-0082)**: games 63–68, `USE_CUSTOM_PROPOSER` unset
- [x] Native `op-challenger` process documented in README (start/stop, logs, no keys in git) — **done**: README § Phase 7 challenger, extended by #139 (proxy)
- [x] Challenger does **not** attack the valid game — **done (D-0082)**: game 66 judged via safedb, claims stayed 1 through the full clock, resolved DEFENDER_WINS; challenger tx ledger is resolution-only
- [x] Game proxy / `rootClaim` / L2 sequence recorded with `cast` (no Blockscout) — **done (D-0082)**: `0xBEBD…7609` / `0xa0718701…b771` / 86560, rootClaim == op-node outputRoot

### US-074: Challenge a bad proposal

**Description:** As the operator, I want to see a dispute resolve against a deliberately wrong output root so “fault proof” is a thing I have done, not a slogan.

**Acceptance Criteria:**

- [x] A bad proposal is created in a documented, isolated way (stock test hook or a one-shot script). Do not leave a hostile proposer running — **done (D-0083)**: one-shot `create-bad-proposal-sepolia.sh` with `CONFIRM_BAD_PROPOSAL_SEPOLIA=1` + `-i-understand-this-posts-a-false-claim`; exits after one create
- [x] `op-challenger` takes the challenger side and the game resolves in favor of the honest claim — **done (D-0083)**: game 69 attacked at depth 1 with the true root, resolved status 1 CHALLENGER_WINS; `respectedGameType` stayed 8, anchor unpoisoned
- [x] Tx hashes + game address recorded — **done (D-0083)**: proxy `0xd39B5353…9349`, L2 seq 90970, corrupted root `0x9fe3…f27a` vs true `0x9fe3…f285`; **create** `0xe669394f…55ac`, **challenger counter (attack)** `0x95fe72bb…7b36`, **resolveClaim** `0x1708686a…a910` + `0xaf69a2ce…d4d6`, **resolve** `0x27afa0fd…9e32`
- [x] Kill switch: stop the bad-proposal path; stock proposer remains the only writer — **done (D-0083)**: one-shot tool leaves nothing running; stock proposer restarted post-run

### US-075: Trust-model write-up

**Description:** As the operator, I want a short README note in my own words covering what the challenger proved and what is still trusted (sequencer honesty, DA permanence, key custody).

**Acceptance Criteria:**

- [x] README Phase 7 subsection: commands, what a pass looks like, pointer at the recorded game — **done (D-0085)**: README § "Fault proofs: what this proved" points at games 66 and 69
- [x] Explicit leftover: `derivation/` still compares to the operator node unless US-P7-005 lands — a won dispute is not independent verification for a counterparty — **done (D-0085)**: stated in the closeout note

## Success metrics

- One honest game observed; one dishonest game challenged and won
- Every replica (Render + friends) matches Mac hashes after the wipe
- SOS redeployed or adopted new 852 addresses without discovering the wipe from a failed read
- No second redeploy caused by a forgotten immutable (including the preimage-oracle period)

## Out of scope until a later plan

- Cannon / Kona prestate *build reproducibility* for production — but **not** pinning the redeploy's `faultGameAbsolutePrestate`, which D-0056 moved in scope and made a US-071 prerequisite
- Permissionless game bonds sized for mainnet
- Moving the sequencer off the Mac mini (pilot P7-1)

## References

- README Network reset procedure (same knobs → notice → wipe → v7 runbook)
- `tasks/prd-l2-learning-chain.md` Phase 7 row
- `tasks/decisions.md` D-0018, D-0028, D-0029, D-0037, D-0046, D-0048
- Dispute game interface: https://specs.optimism.io/fault-proof/stage-one/dispute-game-interface.html
