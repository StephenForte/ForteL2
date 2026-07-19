# PRD: Learning L2 — Base-Style Optimistic Rollup

## Introduction

Build and operate a personal Ethereum L2 modeled on Base's architecture (the OP Stack), for learning purposes only. The strategy is **run first, rebuild later**: Phase 1 stands up the real production OP Stack against a local L1 devnet on a Mac mini, so the operator learns how a rollup actually works by running one. Later phases progressively replace individual OP Stack components (batcher, proposer, derivation) with from-scratch reimplementations, migrate the L1 to Sepolia, add a remote replica node on Render, and eventually explore fault proofs and decentralized sequencing.

This is not a production chain. No real funds, no external users, no uptime commitments.

**Phase 0 decision (locked):** Phase 1 uses **native binaries only** on this host. Kurtosis / Docker / OrbStack are out of scope here — OrbStack disrupted host networking during the Phase 0 spike (`tasks/spike-notes.md`). Native arm64 builds of `op-node` and `op-geth` were verified.

**Terminology note (used throughout):** Base-style rollups do not have PoS-style validators. The roles are:
- **Sequencer** — orders transactions and builds L2 blocks (op-node + op-geth or op-reth in sequencer mode)
- **Batcher** — compresses L2 transaction data and posts it to L1 (op-batcher)
- **Proposer** — posts L2 state output roots to L1 (op-proposer)
- **Replica / verifier node** — syncs the L2 by deriving it from L1 data (op-node + execution client in non-sequencer mode)

## Goals

- Stand up a fully functioning OP Stack devnet (L1 + L2) on a single Mac mini using **native processes** (no containers on this host)
- Observe the full data pipeline: L2 block production → batch submission to L1 → state root proposal to L1
- Inspect the chain with `cast` / RPC tooling in Phase 1; DIY **pipeline viewer** in Phase 1c (+ mempool polish in 1d); defer hosted/container explorers until a non-loopback RPC is deliberately allowed
- Deploy and interact with a simple demo dApp on the L2
- Establish a phase roadmap that explicitly sequences: bridging, pipeline viewer, Phase 2 funding gate, Sepolia migration, Render replica (stock clients), per-component reimplementation (batcher → proposer → derivation), fault proofs, decentralized sequencer

## Phase Roadmap

| Phase | Scope | Status |
|---|---|---|
| **0** | Deployment-path spike: timeboxed test of Kurtosis `optimism-package` on Apple Silicon; decide Kurtosis vs. manual builds | **Done — verdict: manual builds** (OrbStack/Docker disrupted host networking; see `tasks/spike-notes.md`) |
| **1** | OP Stack devnet on Mac mini via **native binaries**: local L1 (Anvil), op-deployer, sequencer, batcher, proposer, demo dApp (genesis-funded accounts, no bridge); no Docker/Kurtosis on this host | **Done** — stack running; MetaMask guestbook verified; batcher 5‑min stop/restart observed |
| **1b** | Bridging: L1→L2 deposits via the Standard Bridge; L2→L1 withdrawals with a shortened challenge window (devnet config); **Phase 2 readiness gate** (new keys, separate deploy config, non-loopback review, sandbox/dry-run) | **Done** — deposit/withdraw scripts + US-012 docs/tripwires (operator runs against live stack) |
| **1c** | **Pipeline viewer**: loopback-only static UI showing sequencer / batcher / proposer / aggregate tx activity (not a full block explorer); hosted explorers remain deferred until non-loopback | **Done** — `viewer/` + `serve-viewer.sh` (US-013 / US-014) |
| **1d** | **Viewer polish + Phase 2 funding gate**: L2 mempool signal on the pipeline viewer; Sepolia ETH harvest checklist + fresh keys (never Foundry defaults / never project-exposed keys); Blockchair-style block/tx explorer UI stays deferred | Future (stories included) |
| **2** | Migrate L1 from local devnet to **Sepolia** (new deployment of L1 contracts, testnet ETH funding, real gas/blob economics) | Future |
| **3** | Deploy a **replica node on Render**, syncing from the Mac mini sequencer over the public internet (peering, tunnel/port exposure, sync verification) — still **stock** `op-geth`/`op-reth` + `op-node` verifier (not a custom client) | Future |
| **4** | **Reimplement the batcher** from scratch (read L2 blocks, compress, frame, submit to L1; swap out op-batcher) | Future |
| **5** | **Reimplement the proposer** from scratch (compute/fetch output roots, submit to the L2OutputOracle / DisputeGameFactory; swap out op-proposer) | Future |
| **6** | **Reimplement the derivation pipeline / minimal sequencer** (read batches from L1, derive L2 blocks; deepest rebuild — **separate detailed PRD** may split EL vs rollup-node work) | Future (stories scaffolded; expand or spin out PRD before start) |
| **7** | **Fault proofs**: run op-challenger, exercise a dispute game manually against a deliberately bad proposal | Future |
| **8** | **Decentralized sequencer** exploration (multiple sequencer candidates, leader election) | Future |

Decision recorded: fault proofs deferred (Q4 = A). On a solo devnet with one trusted proposer there is no adversary; the challenge game is best learned after Phase 5, when output roots are understood from the inside.

Decision recorded: Phase 1 deployment path = **manual native builds** (Phase 0 verdict). No Docker Desktop, OrbStack, or Kurtosis on the operator's workstation.

## User Stories — Phase 0

### US-000: Deployment-path spike (timeboxed)
**Description:** As the operator, I want a short, disposable test of the Kurtosis `optimism-package` on the Mac mini so Phase 1 starts on a known-working path instead of discovering ARM issues mid-build.

**Acceptance Criteria:**
- [x] Timebox set at 2 hours; if Kurtosis path is not producing L2 blocks by then, record where it failed and stop
- [x] Attempted: Kurtosis CLI install + `optimism-package` launch with default config on Apple Silicon
- [ ] Recorded for each launched service: image architecture (arm64 native vs. amd64 under Rosetta) — this predicts Phase 1 stability and performance *(N/A — enclave never became stable; networking stop)*
- [x] Verdict written in `tasks/spike-notes.md`: **Kurtosis** or **manual builds**, with one paragraph of reasoning and the exact versions tested
- [x] Everything from the spike is torn down afterward (`kurtosis clean -a`); Phase 1 starts from a clean machine *(OrbStack quit + Kurtosis killed; daemon down so final `kurtosis clean -a` N/A)*
- [x] If Kurtosis fails: a 30-minute secondary check that op-geth and op-node build from source on ARM before committing to the manual path *(PASS — native arm64 binaries; see `tasks/spike-notes.md`)*

## User Stories — Phase 1

Phase 1 runs entirely as **native host processes** (launchd, shell scripts, or a process supervisor). No Docker Desktop, OrbStack, Kurtosis, or other container runtime on this workstation.

### US-001: Provision the Mac mini toolchain
**Description:** As the operator, I want all required tooling installed so the devnet can be built and run locally without containers.

**Acceptance Criteria:**
- [x] Go toolchain + `just` + `yq` installed (versions recorded; sufficient to rebuild monorepo Go binaries)
- [x] Optimism monorepo checked out at a pinned tag/commit; `just build-superchain-go` + native builds succeed for at least: `op-node`, `op-batcher`, `op-proposer`, and `op-deployer` (or equivalent deploy tooling)
- [x] L2 execution client built natively: **op-geth** (verified in Phase 0) and/or **op-reth** if Rust tooling is installed
- [x] Foundry installed (`cast --version` and `anvil --version` succeed)
- [x] A `README.md` in the project repo records exact versions of every tool and the pinned monorepo / op-geth tags
- [x] Explicitly documented: **no Docker/OrbStack/Kurtosis** on this host for Phase 1

### US-002: Launch the local L1 devnet
**Description:** As the operator, I want a local Ethereum L1 running so the L2 has a settlement layer I fully control.

**Acceptance Criteria:**
- [x] Local L1 via **Anvil** (Foundry) producing blocks as a native process (preferred for simplicity); native geth/reth acceptable if Anvil proves insufficient for op-deployer / blob needs
- [x] At least one prefunded L1 account with known private key, documented in `.env.example` (throwaway keys only — this is a devnet)
- [x] `cast block-number --rpc-url <L1_RPC>` returns increasing values
- [x] L1 RPC endpoint and chain ID documented in README
- [x] Start/stop is a process (script or documented command), not a container

### US-003: Deploy L1 rollup contracts and generate L2 genesis
**Description:** As the operator, I want the OP Stack L1 contracts deployed and an L2 genesis created so the rollup has its on-chain anchor.

**Acceptance Criteria:**
- [x] OP Stack L1 contracts deployed to the local L1 via **native `op-deployer`** (or documented Foundry/`op-chain-ops` equivalent) — OptimismPortal, SystemConfig, L2OutputOracle or DisputeGameFactory, Standard Bridge contracts
- [x] Contract addresses captured in a checked-in `deployments.json`
- [x] L2 genesis file includes at least 3 prefunded L2 accounts (this replaces bridging for Phase 1)
- [x] `rollup.json` / chain config present and its key fields (chain ID, block time, batcher/proposer addresses) explained in README in the operator's own words

### US-004: Run the sequencer stack
**Description:** As the operator, I want the execution client + op-node running as native processes in sequencer mode so the L2 produces blocks.

**Acceptance Criteria:**
- [x] L2 blocks produced at the configured block time (verify: `cast block-number --rpc-url <L2_RPC>` increases)
- [x] A simple ETH transfer between two prefunded L2 accounts confirms in an L2 block
- [x] Sequencer survives a restart (stop processes, restart, chain resumes from prior head — no re-genesis)
- [x] README documents which process plays which role (execution client = execution; op-node = consensus/derivation) and the `--l2.enginekind` value used (`geth` or `reth`)

### US-005: Run the batcher and verify data lands on L1
**Description:** As the operator, I want op-batcher posting L2 transaction data to L1 so I can see the DA pipeline that makes a rollup a rollup.

**Acceptance Criteria:**
- [x] Native `op-batcher` process running and submitting batch transactions to L1
- [x] At least one batch transaction located on L1 by inspecting the batcher address's transactions (`cast` query documented in README)
- [x] Written in README (own words, ~1 paragraph): what is inside a batch, and what "the L2 is derivable from L1" means
- [x] Observed and noted: what happens to batch submission when the batcher is stopped for 5 minutes, then restarted

### US-006: Run the proposer and verify output roots on L1
**Description:** As the operator, I want op-proposer posting state roots to L1 so withdrawals become possible later (Phase 1b) and I understand the trust model.

**Acceptance Criteria:**
- [x] Native `op-proposer` process running and submitting output roots on its configured interval
- [x] At least one output root read back from the L1 contract via `cast call` (command documented)
- [x] Written in README (own words): why the proposer is trusted in this setup, and what fault proofs would change (references Phase 7)

### US-007: Chain inspection without Blockscout
**Description:** As the operator, I want to inspect L2 blocks, transactions, and the demo contract without standing up a containerized explorer on this host.

**Acceptance Criteria:**
- [x] Documented `cast` / RPC recipes to: get block number, fetch a tx by hash, read contract storage/call, and list recent blocks (enough to find the US-004 test transfer)
- [x] Blockscout (and any docker-compose explorer stack) is **explicitly deferred** — requires containers; revisit only after non-loopback policy allows a reachable RPC, or on a different machine / native single-binary (e.g. Otterscan)
- [x] If a non-Docker explorer is added later, it must run as a native process and stay LAN-only until the US-012 non-loopback review says otherwise
- [x] DIY **pipeline viewer** (ops dashboard, not a full explorer) is scoped to **Phase 1c**, after bridging so deposits/withdrawals are observable

### US-008: Deploy and use a demo dApp
**Description:** As the operator, I want a simple contract + minimal frontend on my L2 so the chain is demonstrably usable end to end.

**Acceptance Criteria:**
- [x] A simple Solidity contract (e.g., guestbook or counter) deployed to the L2 via Foundry (`forge create` or `forge script`)
- [x] Deployment tx hash and contract address recorded; readable via `cast` (Blockscout not required)
- [x] Minimal frontend (single static page, ethers.js/viem + injected wallet) can read state and send a write transaction to the L2 — served by a trivial native static server (e.g. `python -m http.server`) or opened as a local file
- [x] MetaMask (or equivalent) configured with the custom L2 network; config steps documented
- [x] Verify write path in MetaMask (operator browser; guestbook messages confirmed on-chain)

### US-009: Operator's runbook
**Description:** As the operator, I want start/stop/reset procedures documented so the devnet is reproducible after weeks away from it.

**Acceptance Criteria:**
- [x] Documented: cold start from nothing, clean shutdown, full reset/re-genesis — all as **process** start/stop (scripts preferred), never containers
- [x] Documented: where each component's logs live (files or stdout redirection) and one known-good log line per component to confirm health
- [x] A diagram (hand-drawn or mermaid) of the Phase 1 topology: L1 (Anvil), sequencer (op-node + EL), batcher, proposer, dApp, and the arrows between them

## User Stories — Phase 1b (Bridging)

### US-010: Deposit ETH from L1 to L2
**Description:** As the operator, I want to deposit ETH through the OptimismPortal/Standard Bridge so I understand how value enters an L2.

**Acceptance Criteria:**
- [x] ETH deposited from a fresh L1 account (not genesis-funded on L2) via the bridge contract
- [x] Balance appears on L2 for the corresponding address within the expected confirmation window
- [x] The deposit transaction traced on both sides: L1 bridge tx → L2 deposit tx (tx hashes recorded)
- [x] Written in README: how deposits differ from normal L2 txs (deposited transactions come via L1, cannot be censored by the sequencer)

### US-011: Withdraw ETH from L2 to L1
**Description:** As the operator, I want to complete a full withdrawal so I understand the prove/finalize flow and the challenge window.

**Acceptance Criteria:**
- [x] Devnet chain config uses a shortened finalization/challenge window (seconds–minutes, not 7 days); the config parameter changed is named in README
- [x] Full withdrawal executed: initiate on L2 → prove on L1 → finalize on L1 (three distinct transactions, hashes recorded)
- [x] Written in README: why mainnet uses 7 days, and what the honest-proposer assumption means without fault proofs

### US-012: Phase 2 readiness gate (before Sepolia)
**Description:** As the operator, I want Phase 1b to leave a hard gate before Phase 2 so local throwaway keys, loopback assumptions, and deploy config cannot accidentally follow the stack onto Sepolia.

**Acceptance Criteria:**
- [x] **New keys for any non-local chain:** document and enforce that Foundry/Anvil default mnemonic keys must never be funded or reused on Sepolia (or any public net). Scripts that broadcast fail closed when `L2_CHAIN_ID != 901` (local learning ID) if a known Foundry default private key is still configured
- [x] **Separate deploy config:** Phase 2 uses a distinct env/deploy artifact set (not a reused Phase 1 `.env` + `deployments/.deployer` tree). README names what is replaced: L1 contracts, L2 genesis/rollup, RPC URLs, chain IDs, funded accounts
- [x] **Non-loopback policy review:** before any RPC, batcher, proposer, or dApp bind/advertise moves off `127.0.0.1`/`localhost`, record an explicit go/no-go in README (what is exposed, to whom, auth model, and rollback). Default remains loopback-only until that review is written
- [x] **Sandbox / dry-run gate (not shadow mode):** Phase 2 cutover is validated on a disposable Sepolia deployment + dry-run scripts first; guestbook has no meaningful shadow mode — do not invent dual-write production shadowing
- [x] Agent-permission / tool-access audit (deferred from Phase 1) is scheduled as a Phase 2 prerequisite checklist item in README, not skipped

## User Stories — Phase 1c (Pipeline viewer)

Phase 1c comes **after** Phase 1b so the viewer can show bridge-related activity (deposits advancing the L2, proposer output roots enabling withdrawals) as well as the steady-state sequencer → batcher → proposer pipeline. It is an **ops / learning dashboard**, not a Blockscout/Etherscan replacement.

### US-013: Pipeline viewer UI
**Description:** As the operator, I want a polished, loopback-only **pipeline viewer** screen so I can watch sequencer block building, batcher L1 posts, proposer output activity, and aggregate L2 transaction throughput without standing up a full block explorer.

**Acceptance Criteria:**
- [x] A static frontend (same class as the guestbook: ESM, vendored ethers or equivalent, no bundler) is served on loopback only (e.g. `127.0.0.1`, assert via existing serve helpers)
- [x] The UI is named and documented as the **pipeline viewer** (not “explorer”)
- [x] Four live panels, each fed by L1/L2 RPC polls (no Docker indexer, no log-tail daemon required):
  1. **Sequencer** — L2 head / recent blocks, block interval, unsafe vs safe (and finalized if available) from `optimism_syncStatus` or equivalent
  2. **Batcher** — recent L1 submissions from the batcher address to the batch inbox (cadence + last tx hash / age)
  3. **Proposer** — recent output-root / dispute-game activity on L1 (last proposal age + pointer into DisputeGameFactory or equivalent)
  4. **Aggregate transactions** — L2 tx rate / empty vs non-empty blocks over a short rolling window
- [x] After a Phase 1b deposit and withdrawal, the operator can point at the viewer and relate: deposit → L2 inclusion / sync heads; withdrawal → need for proposer output before prove/finalize
- [x] README documents how to start the viewer, which RPCs it uses, and what each panel means in one short paragraph
- [x] Hosted / SaaS explorers (e.g. Ethernal) and containerized explorers (e.g. Blockscout) remain **out of scope** for Phase 1c — deferred until a non-loopback RPC is deliberately allowed (US-012 review) or a container-capable host is used; optional native single-binary explorers (e.g. Otterscan) may be noted but are not required to close 1c

### US-014: Pipeline viewer polish and runbook fit
**Description:** As the operator, I want the pipeline viewer to feel intentional (clear hierarchy, readable refresh, failure states) and to sit cleanly next to `status.sh` / the guestbook in the everyday runbook.

**Acceptance Criteria:**
- [x] Layout is a single composition with the four panels above — not a generic multi-widget “dashboard” cluttered with unrelated stats
- [x] RPC / process-down failures surface as plain status text (no silent stale panels); refresh cadence is visible or documented
- [x] Start path is a documented script or extension of existing serve helpers (loopback assert); stop does not require tearing down the chain
- [x] Topology / roadmap docs mention Phase 1c and the viewer’s place relative to guestbook vs deferred explorers

## User Stories — Phase 1d (Viewer polish + Phase 2 funding gate)

Phase 1d sits **between** the closed pipeline viewer (1c) and Sepolia cutover (2). It does **not** deploy to Sepolia. It hardens the local ops UI slightly and makes Sepolia funding / key hygiene an explicit gate so Phase 2 does not start underfunded or with project-exposed keys.

**Out of scope for 1d:** Blockchair/Etherscan-style latest-blocks + tx detail pages, hosted explorers, non-loopback RPCs, custom execution clients.

### US-015: Pipeline viewer mempool signal
**Description:** As the operator, I want a small **L2 mempool** readout on the pipeline viewer so I can see pending local txs (e.g. after MetaMask submit, before inclusion) without turning the viewer into a block explorer.

**Acceptance Criteria:**
- [ ] Pipeline viewer shows L2 mempool summary from existing loopback EL RPC (e.g. `txpool_status` pending/queued counts; optional short pending-tx sample — **not** full mempool dump / search)
- [ ] Signal lives in the existing composition (extend Aggregate or a slim fifth strip) — still one ops surface, not a multi-widget dashboard
- [ ] RPC failure for mempool is isolated (same plain-status pattern as other panels); refresh cadence unchanged or documented
- [ ] README notes what the mempool signal means vs Sequencer heads / Aggregate inclusion
- [ ] Explicit non-goal remains: no Blockchair-like block list, tx detail pages, address search, or “latest transactions” explorer UI in 1d (deferred; see open questions / future explorer story)

### US-016: Sepolia funding + key harvest gate (before Phase 2)
**Description:** As the operator, I want a written funding and key checklist so I accumulate enough **Ethereum Sepolia** ETH on **fresh** keys that never touch this repo’s Foundry defaults or agent-visible `.env`, before Phase 2 deploy burns gas.

**Acceptance Criteria:**
- [ ] README (or linked runbook section) states: **Base Sepolia ≠ Ethereum Sepolia** — L2 testnet balances cannot pay L1 Sepolia deploy/batcher gas
- [ ] Documented target balances before Phase 2 start: **≥ ~0.5 ETH** Sepolia to attempt L1 contract deploy; **~1.0 ETH** recommended before running batcher+proposer for any sustained period (buffer for retries / gas spikes)
- [ ] Operator generates **new** Sepolia keys **outside** this project tree (e.g. `cast wallet new` locally; private keys in a password manager or encrypted store — **never** committed, never pasted into agent chat, never written to `.env.example`)
- [ ] Funding path documented: faucet(s) → operator-controlled harvest address → transfer only to the Sepolia deployer/batcher/proposer addresses when ready; project scripts continue to refuse Foundry defaults when `L2_CHAIN_ID != 901`
- [ ] Phase 2 remains blocked until US-012 items + this funding floor are met; 1d does not run `op-deployer` against Sepolia

## User Stories — Phase 6 (Derivation / minimal sequencer — scaffold)

Phase 6 is the deepest rebuild: replace (parts of) the rollup derivation path and/or a minimal sequencer using the **OP Stack specs** and the running reference stack as the oracle. **Phase 3 does not require this** — a Render replica uses stock `op-geth`/`op-reth` + `op-node` in verifier mode.

Before implementation starts, either expand these stories in-place **or** spin out a dedicated PRD (recommended if splitting EL vs `op-node`-shaped work).

### US-060: Spec-aligned derivation spike
**Description:** As the operator, I want a timeboxed spike that reads L1 batches for this learning chain and derives a short L2 span offline, so Phase 6 scope is grounded in the real frame/channel format—not guesswork.

**Acceptance Criteria:**
- [ ] Spike notes cite ethereum-optimism/specs sections used (batch/frame/channel, derivation pipeline stages)
- [ ] Tooling can decode at least one real batch from the Phase 1/2 L1 history and relate it to known L2 blocks from the reference `op-node`
- [ ] Explicit decision: implement a **verifier-only** derivation tool first vs a **block-building sequencer** stub; recorded in spike notes
- [ ] Non-goal for the spike: production performance, P2P, full EVM reimplementation

### US-061: Minimal derivation verifier (replace op-node verifier path for a demo window)
**Description:** As the operator, I want a from-scratch (or substantially custom) derivation verifier that can advance a safe/unsafe head over a bounded window by reading L1, comparable to `optimism_syncStatus` from reference `op-node`.

**Acceptance Criteria:**
- [ ] Separate binary/crate/module with its own README; does not patch upstream `op-node` in place for the learning demo
- [ ] Inputs: L1 RPC + rollup config / batch inbox / deposit contract addresses from the active deploy tree
- [ ] Outputs: derived L2 block numbers / hashes for a documented window; mismatch vs reference `op-node` is detectable and logged
- [ ] Runbook: how to start reference stack, run custom verifier, interpret diffs
- [ ] Safe to run alongside Phase 1/2 stack on loopback without replacing sequencer until US-062

### US-062: Optional minimal sequencer stub (after verifier)
**Description:** As the operator, I want an optional next step that builds L2 blocks (sequencer path) only after the verifier path is trustworthy, so sequencing complexity does not block derivation learning.

**Acceptance Criteria:**
- [ ] Sequencer stub is explicitly gated on US-061 acceptance
- [ ] Engine API integration target named (`op-geth` or `op-reth`) with `--l2.enginekind` equivalent documented
- [ ] Can produce at least N consecutive L2 blocks that the reference verifier (or US-061 tool) can follow
- [ ] Clear kill switch: revert to stock `op-node` sequencer without re-genesis if possible; else documented reset procedure
- [ ] Out of scope unless separately approved: full tx-pool policy parity, P2P block gossip, decentralized sequencing (Phase 8)

## Functional Requirements

- FR-1: The system must run the unmodified OP Stack (`op-node`, `op-batcher`, `op-proposer`, plus a supported execution client — `op-geth` and/or `op-reth`) — no forks or custom patches in Phase 1
- FR-2: The L1 must be a local devnet chain fully controlled by the operator; no public networks in Phase 1
- FR-3: All Phase 1 components must run as **native binaries/processes** on a single Apple Silicon Mac (this workstation). **No Docker Desktop, OrbStack, Kurtosis, or other container runtime** for Phase 1 on this host
- FR-4: The L2 must use a distinct chain ID not colliding with any public chain
- FR-5: L2 accounts must be funded via genesis allocation in Phase 1; the bridge is not used until Phase 1b
- FR-6: Batch data and output roots must be independently verifiable on L1 using `cast` commands documented in the runbook
- FR-7: Chain inspection for Phase 1 is via documented `cast`/RPC recipes. Phase 1c adds a DIY loopback **pipeline viewer**; Phase 1d may add a small L2 mempool signal. Full explorers (hosted SaaS such as Ethernal, or containerized such as Blockscout) and Blockchair-style block/tx pages are not required on this host and stay deferred until non-loopback RPC exposure is approved (or a dedicated explorer story)
- FR-8: The demo dApp must perform at least one read and one write against the L2 through a browser wallet
- FR-9: All keys used are throwaway learning keys; nothing in the repo may ever hold value. Phase 2+ keys are generated outside the project and never committed
- FR-10: Every phase boundary in the roadmap table must be preserved in this document as phases complete (edit status column, don't delete rows)
- FR-11: L1 contract deployment and L2 genesis generation must use native tooling (`op-deployer` or documented equivalent), not Kurtosis-generated artifacts
- FR-12: Before Phase 2, Foundry/Anvil default keys must be rejected for any `L2_CHAIN_ID` other than the local learning ID (901); Phase 2 must use a separate deploy/env tree and an explicit non-loopback policy review (US-012); Phase 1d adds the Sepolia ETH funding floor checklist (US-016)
- FR-13: Phase 3 replica uses unmodified OP Stack EL + `op-node` (verifier). Custom derivation/sequencer work is Phase 6 (US-060–062), optionally a separate PRD

## Non-Goals (Out of Scope for Phase 1 / 1b / 1c / 1d)

- No Docker Desktop, OrbStack, Kurtosis, docker-compose, or other container runtime on this workstation (Phase 0 verdict)
- No Blockscout (or other containerized explorer) on this host in Phase 1 / 1b / 1c / 1d
- No hosted / SaaS block explorers (e.g. Ethernal) against this stack until the US-012 non-loopback policy review allows a reachable RPC (hosted explorers cannot see `127.0.0.1`)
- No full address/tx search explorer and no Blockchair-style “latest blocks / latest transactions” pages in Phase 1c / 1d — the deliverable is a **pipeline viewer** (+ optional mempool signal), not Etherscan/Blockscout feature parity
- No Sepolia cutover in Phase 1d (funding/key prep only; deploy is Phase 2)
- No node on Render or any remote infrastructure (Phase 3)
- No custom/reimplemented batcher, proposer, or derivation — Phases 4–6
- No custom execution client required for Phase 3 (stock op-geth/op-reth)
- No fault proofs, op-challenger, or dispute games (Phase 7)
- No decentralized or shared sequencing (Phase 8)
- No ERC-20 bridging (ETH only in Phase 1b)
- No public RPC exposure, no external users, no uptime targets
- No alt-DA (blobs vs. calldata tuning is fine to observe, but no EigenDA/Celestia experiments)
- No mainnet anything, ever, in this project

## Technical Considerations

- **Deployment path (locked):** Phase 1 is **manual native builds**. Kurtosis + `optimism-package` was attempted in Phase 0 and abandoned on this host (OrbStack killed networking). Build from the optimism monorepo + op-geth (and optionally op-reth) using Go/`just`/`yq`; orchestrate with shell scripts. The monorepo's old `make devnet-up` flow remains deprecated — do not rely on it; use `op-deployer` + process scripts instead.
- **op-node build prerequisite:** `just build-superchain-go` must run before Go binaries that `//go:embed` `superchain-configs.zip` will compile (needs `yq`, `zip`, and the `superchain-registry` submodule). Documented in `tasks/spike-notes.md`.
- **Execution client choice:** Phase 0 verified **op-geth** on arm64. Upstream is moving public networks to **op-reth** (op-geth end-of-support for Karst-era mainnets). For a private learning L1/L2, op-geth is acceptable in Phase 1; prefer op-reth if/when Rust tooling is installed, and set `--l2.enginekind` accordingly.
- **Apple Silicon:** native `darwin/arm64` binaries only — no Rosetta container emulation path.
- **Resources:** without Blockscout/Postgres, RAM needs are modest (Anvil + op-node + EL + batcher + proposer + optional static pipeline viewer). Keep logs on disk with rotation so long runs stay manageable.
- **Pipeline viewer (Phase 1c / 1d):** prefer client-side RPC polls against existing loopback L1/L2 endpoints (same pattern as the guestbook). Do not introduce an indexer DB or container stack. Phase 1d may add `txpool_*` mempool signals; Blockchair-style UIs stay deferred.
- **Explorer deferral (locked for now):** hosted explorers (Ethernal, etc.) need a non-loopback RPC; self-hosted Blockscout/Ethernal need containers. Both wait until after the US-012 non-loopback review (or a different host). Optional native single-binary explorers remain an open later choice, not a 1c/1d requirement.
- **L1 / blobs open question:** Anvil may or may not cover every batcher DA mode (calldata vs 4844 blobs). If blobs are required and Anvil cannot provide them, fall back to native geth/reth as L1 — still no containers.
- **Phase 2 dependency:** the local-L1 contract deployment in Phase 1 does not carry to Sepolia; Phase 2 is a fresh contract deployment and fresh L2 genesis. The Phase 1 chain will not "migrate" — it gets replaced. Structure the runbook so redeployment is cheap. Phase 1d US-016 funding floor applies before cutover.
- **Phase 3 note:** a Render replica may use containers *on Render*; that does not reintroduce Docker on this Mac mini for Phase 1. Replica = stock EL + `op-node` verifier. Custom client/derivation is Phase 6.
- **Phase 4–6 dependency:** the OP Stack's rollup node exposes RPCs (`optimism_syncStatus`, etc.) and the spec repo (ethereum-optimism/specs) defines batch/frame formats — reimplementation phases should target the spec, using the running stack as the reference implementation to diff against. Phase 6 may be split into a separate PRD before coding starts.

## Success Metrics

- Cold start to producing L2 blocks in under 30 minutes using only the runbook
- The full pipeline demonstrable in one sitting: L2 tx → batch on L1 → output root on L1, each step shown with a `cast` command
- Operator can explain, without notes, what each of the four OP Stack components does and what breaks when each one stops
- Phase 1b: one deposit and one full withdrawal completed with all tx hashes recorded
- Phase 1c: pipeline viewer shows live sequencer / batcher / proposer / aggregate tx panels on loopback; operator can narrate a deposit→batch→propose path from the screen
- Phase 1d: mempool signal visible on the viewer; operator has ≥ ~1.0 Sepolia ETH (or documented floor) on fresh keys before Phase 2
- Phase 6 (when started): custom verifier derives a bounded window that matches reference `op-node` within documented tolerance

## Open Questions

- Blob transactions vs. calldata for the batcher on Anvil — if Anvil lacks 4844, use calldata-only batches in Phase 1 or switch L1 to native geth/reth?
- L2 block time: 2s (Base-like) or slower to make log-watching easier while learning?
- op-geth vs op-reth for Phase 1 EL — stick with verified op-geth, or invest in Rust tooling for op-reth now?
- After non-loopback is allowed: hosted explorer (e.g. Ethernal) vs native single-binary (e.g. Otterscan) vs staying on `cast` + pipeline viewer only?
- For Phase 3 (Render): tunnel (Tailscale/cloudflared) vs. port forwarding for sequencer→replica peering — defer decision, but note Render's egress/ingress constraints may force the tunnel option
- Phase 6: keep stories in this PRD vs spin out `tasks/prd-derivation-client.md` before US-061 coding?

### Resolved decisions

- **Explorer path (Phase 1c):** DIY **pipeline viewer** on loopback after bridging (US-013 / US-014). Hosted/SaaS and containerized explorers deferred until non-loopback (or another host).
- **Phase 1d scope:** mempool signal + Sepolia funding/key gate only. Blockchair-style latest blocks/txs **deferred** (not 1d).
- **Phase 3 vs Phase 6:** Render replica uses **stock** OP Stack EL + `op-node` verifier. Custom derivation/sequencer is **Phase 6** (optional separate PRD).
- **Sepolia funding:** Base Sepolia balances do not count; target ~**1.0 ETH** on Ethereum Sepolia before sustained Phase 2 batcher/proposer; ~**0.5 ETH** minimum to attempt deploy. Keys generated **outside** this repo; never Foundry defaults; never paste private keys into agent chats.
