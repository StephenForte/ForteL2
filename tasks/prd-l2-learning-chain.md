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
- Inspect the chain with `cast` / RPC tooling; defer Blockscout (container-heavy) unless a non-Docker explorer is added later
- Deploy and interact with a simple demo dApp on the L2
- Establish a phase roadmap that explicitly sequences: bridging, Sepolia migration, Render replica, per-component reimplementation, fault proofs, decentralized sequencer

## Phase Roadmap

| Phase | Scope | Status |
|---|---|---|
| **0** | Deployment-path spike: timeboxed test of Kurtosis `optimism-package` on Apple Silicon; decide Kurtosis vs. manual builds | **Done — verdict: manual builds** (OrbStack/Docker disrupted host networking; see `tasks/spike-notes.md`) |
| **1** | OP Stack devnet on Mac mini via **native binaries**: local L1 (Anvil), op-deployer, sequencer, batcher, proposer, demo dApp (genesis-funded accounts, no bridge); no Docker/Kurtosis on this host | This PRD |
| **1b** | Bridging: L1→L2 deposits via the Standard Bridge; L2→L1 withdrawals with a shortened challenge window (devnet config) | This PRD (stories included) |
| **2** | Migrate L1 from local devnet to **Sepolia** (new deployment of L1 contracts, testnet ETH funding, real gas/blob economics) | Future |
| **3** | Deploy a **replica node on Render**, syncing from the Mac mini sequencer over the public internet (peering, tunnel/port exposure, sync verification) | Future |
| **4** | **Reimplement the batcher** from scratch (read L2 blocks, compress, frame, submit to L1; swap out op-batcher) | Future |
| **5** | **Reimplement the proposer** from scratch (compute/fetch output roots, submit to the L2OutputOracle / DisputeGameFactory; swap out op-proposer) | Future |
| **6** | **Reimplement the derivation pipeline / minimal sequencer** (read batches from L1, derive L2 blocks; the deepest rebuild) | Future |
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
- [ ] Go toolchain + `just` + `yq` installed (versions recorded; sufficient to rebuild monorepo Go binaries)
- [ ] Optimism monorepo checked out at a pinned tag/commit; `just build-superchain-go` + native builds succeed for at least: `op-node`, `op-batcher`, `op-proposer`, and `op-deployer` (or equivalent deploy tooling)
- [ ] L2 execution client built natively: **op-geth** (verified in Phase 0) and/or **op-reth** if Rust tooling is installed
- [ ] Foundry installed (`cast --version` and `anvil --version` succeed)
- [ ] A `README.md` in the project repo records exact versions of every tool and the pinned monorepo / op-geth tags
- [ ] Explicitly documented: **no Docker/OrbStack/Kurtosis** on this host for Phase 1

### US-002: Launch the local L1 devnet
**Description:** As the operator, I want a local Ethereum L1 running so the L2 has a settlement layer I fully control.

**Acceptance Criteria:**
- [ ] Local L1 via **Anvil** (Foundry) producing blocks as a native process (preferred for simplicity); native geth/reth acceptable if Anvil proves insufficient for op-deployer / blob needs
- [ ] At least one prefunded L1 account with known private key, documented in `.env.example` (throwaway keys only — this is a devnet)
- [ ] `cast block-number --rpc-url <L1_RPC>` returns increasing values
- [ ] L1 RPC endpoint and chain ID documented in README
- [ ] Start/stop is a process (script or documented command), not a container

### US-003: Deploy L1 rollup contracts and generate L2 genesis
**Description:** As the operator, I want the OP Stack L1 contracts deployed and an L2 genesis created so the rollup has its on-chain anchor.

**Acceptance Criteria:**
- [ ] OP Stack L1 contracts deployed to the local L1 via **native `op-deployer`** (or documented Foundry/`op-chain-ops` equivalent) — OptimismPortal, SystemConfig, L2OutputOracle or DisputeGameFactory, Standard Bridge contracts
- [ ] Contract addresses captured in a checked-in `deployments.json`
- [ ] L2 genesis file includes at least 3 prefunded L2 accounts (this replaces bridging for Phase 1)
- [ ] `rollup.json` / chain config present and its key fields (chain ID, block time, batcher/proposer addresses) explained in README in the operator's own words

### US-004: Run the sequencer stack
**Description:** As the operator, I want the execution client + op-node running as native processes in sequencer mode so the L2 produces blocks.

**Acceptance Criteria:**
- [ ] L2 blocks produced at the configured block time (verify: `cast block-number --rpc-url <L2_RPC>` increases)
- [ ] A simple ETH transfer between two prefunded L2 accounts confirms in an L2 block
- [ ] Sequencer survives a restart (stop processes, restart, chain resumes from prior head — no re-genesis)
- [ ] README documents which process plays which role (execution client = execution; op-node = consensus/derivation) and the `--l2.enginekind` value used (`geth` or `reth`)

### US-005: Run the batcher and verify data lands on L1
**Description:** As the operator, I want op-batcher posting L2 transaction data to L1 so I can see the DA pipeline that makes a rollup a rollup.

**Acceptance Criteria:**
- [ ] Native `op-batcher` process running and submitting batch transactions to L1
- [ ] At least one batch transaction located on L1 by inspecting the batcher address's transactions (`cast` query documented in README)
- [ ] Written in README (own words, ~1 paragraph): what is inside a batch, and what "the L2 is derivable from L1" means
- [ ] Observed and noted: what happens to batch submission when the batcher is stopped for 5 minutes, then restarted

### US-006: Run the proposer and verify output roots on L1
**Description:** As the operator, I want op-proposer posting state roots to L1 so withdrawals become possible later (Phase 1b) and I understand the trust model.

**Acceptance Criteria:**
- [ ] Native `op-proposer` process running and submitting output roots on its configured interval
- [ ] At least one output root read back from the L1 contract via `cast call` (command documented)
- [ ] Written in README (own words): why the proposer is trusted in this setup, and what fault proofs would change (references Phase 7)

### US-007: Chain inspection without Blockscout
**Description:** As the operator, I want to inspect L2 blocks, transactions, and the demo contract without standing up a containerized explorer on this host.

**Acceptance Criteria:**
- [ ] Documented `cast` / RPC recipes to: get block number, fetch a tx by hash, read contract storage/call, and list recent blocks (enough to find the US-004 test transfer)
- [ ] Blockscout (and any docker-compose explorer stack) is **explicitly deferred** — requires containers; revisit only on a different machine or if a native single-binary explorer (e.g. Otterscan) is chosen later
- [ ] If a non-Docker explorer is added later, it must run as a native process and stay LAN-only (no public exposure)

### US-008: Deploy and use a demo dApp
**Description:** As the operator, I want a simple contract + minimal frontend on my L2 so the chain is demonstrably usable end to end.

**Acceptance Criteria:**
- [ ] A simple Solidity contract (e.g., guestbook or counter) deployed to the L2 via Foundry (`forge create` or `forge script`)
- [ ] Deployment tx hash and contract address recorded; readable via `cast` (Blockscout not required)
- [ ] Minimal frontend (single static page, ethers.js/viem + injected wallet) can read state and send a write transaction to the L2 — served by a trivial native static server (e.g. `python -m http.server`) or opened as a local file
- [ ] MetaMask (or equivalent) configured with the custom L2 network; config steps documented
- [ ] Verify in browser using dev-browser skill

### US-009: Operator's runbook
**Description:** As the operator, I want start/stop/reset procedures documented so the devnet is reproducible after weeks away from it.

**Acceptance Criteria:**
- [ ] Documented: cold start from nothing, clean shutdown, full reset/re-genesis — all as **process** start/stop (scripts preferred), never containers
- [ ] Documented: where each component's logs live (files or stdout redirection) and one known-good log line per component to confirm health
- [ ] A diagram (hand-drawn or mermaid) of the Phase 1 topology: L1 (Anvil), sequencer (op-node + EL), batcher, proposer, dApp, and the arrows between them

## User Stories — Phase 1b (Bridging)

### US-010: Deposit ETH from L1 to L2
**Description:** As the operator, I want to deposit ETH through the OptimismPortal/Standard Bridge so I understand how value enters an L2.

**Acceptance Criteria:**
- [ ] ETH deposited from a fresh L1 account (not genesis-funded on L2) via the bridge contract
- [ ] Balance appears on L2 for the corresponding address within the expected confirmation window
- [ ] The deposit transaction traced on both sides: L1 bridge tx → L2 deposit tx (tx hashes recorded)
- [ ] Written in README: how deposits differ from normal L2 txs (deposited transactions come via L1, cannot be censored by the sequencer)

### US-011: Withdraw ETH from L2 to L1
**Description:** As the operator, I want to complete a full withdrawal so I understand the prove/finalize flow and the challenge window.

**Acceptance Criteria:**
- [ ] Devnet chain config uses a shortened finalization/challenge window (seconds–minutes, not 7 days); the config parameter changed is named in README
- [ ] Full withdrawal executed: initiate on L2 → prove on L1 → finalize on L1 (three distinct transactions, hashes recorded)
- [ ] Written in README: why mainnet uses 7 days, and what the honest-proposer assumption means without fault proofs

## Functional Requirements

- FR-1: The system must run the unmodified OP Stack (`op-node`, `op-batcher`, `op-proposer`, plus a supported execution client — `op-geth` and/or `op-reth`) — no forks or custom patches in Phase 1
- FR-2: The L1 must be a local devnet chain fully controlled by the operator; no public networks in Phase 1
- FR-3: All Phase 1 components must run as **native binaries/processes** on a single Apple Silicon Mac (this workstation). **No Docker Desktop, OrbStack, Kurtosis, or other container runtime** for Phase 1 on this host
- FR-4: The L2 must use a distinct chain ID not colliding with any public chain
- FR-5: L2 accounts must be funded via genesis allocation in Phase 1; the bridge is not used until Phase 1b
- FR-6: Batch data and output roots must be independently verifiable on L1 using `cast` commands documented in the runbook
- FR-7: Chain inspection for Phase 1 is via documented `cast`/RPC recipes (and optionally a native single-binary explorer). Blockscout is not required on this host
- FR-8: The demo dApp must perform at least one read and one write against the L2 through a browser wallet
- FR-9: All keys used are throwaway devnet keys; nothing in the repo may ever hold value
- FR-10: Every phase boundary in the roadmap table must be preserved in this document as phases complete (edit status column, don't delete rows)
- FR-11: L1 contract deployment and L2 genesis generation must use native tooling (`op-deployer` or documented equivalent), not Kurtosis-generated artifacts

## Non-Goals (Out of Scope for Phase 1/1b)

- No Docker Desktop, OrbStack, Kurtosis, docker-compose, or other container runtime on this workstation (Phase 0 verdict)
- No Blockscout (or other containerized explorer) on this host in Phase 1
- No Sepolia or any public L1 (Phase 2)
- No node on Render or any remote infrastructure (Phase 3)
- No custom/reimplemented components — batcher, proposer, derivation rebuilds are Phases 4–6
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
- **Resources:** without Blockscout/Postgres, RAM needs are modest (Anvil + op-node + EL + batcher + proposer). Keep logs on disk with rotation so long runs stay manageable.
- **L1 / blobs open question:** Anvil may or may not cover every batcher DA mode (calldata vs 4844 blobs). If blobs are required and Anvil cannot provide them, fall back to native geth/reth as L1 — still no containers.
- **Phase 2 dependency:** the local-L1 contract deployment in Phase 1 does not carry to Sepolia; Phase 2 is a fresh contract deployment and fresh L2 genesis. The Phase 1 chain will not "migrate" — it gets replaced. Structure the runbook so redeployment is cheap.
- **Phase 3 note:** a Render replica may use containers *on Render*; that does not reintroduce Docker on this Mac mini for Phase 1.
- **Phase 4–6 dependency:** the OP Stack's rollup node exposes RPCs (`optimism_syncStatus`, etc.) and the spec repo (ethereum-optimism/specs) defines batch/frame formats — reimplementation phases should target the spec, using the running stack as the reference implementation to diff against.

## Success Metrics

- Cold start to producing L2 blocks in under 30 minutes using only the runbook
- The full pipeline demonstrable in one sitting: L2 tx → batch on L1 → output root on L1, each step shown with a `cast` command
- Operator can explain, without notes, what each of the four OP Stack components does and what breaks when each one stops
- Phase 1b: one deposit and one full withdrawal completed with all tx hashes recorded

## Open Questions

- Blob transactions vs. calldata for the batcher on Anvil — if Anvil lacks 4844, use calldata-only batches in Phase 1 or switch L1 to native geth/reth?
- L2 block time: 2s (Base-like) or slower to make log-watching easier while learning?
- op-geth vs op-reth for Phase 1 EL — stick with verified op-geth, or invest in Rust tooling for op-reth now?
- Optional native explorer later (Otterscan, etc.) vs. staying on `cast`-only until a container-capable host exists?
- For Phase 3 (Render): tunnel (Tailscale/cloudflared) vs. port forwarding for sequencer→replica peering — defer decision, but note Render's egress/ingress constraints may force the tunnel option
