# PRD: ForteL2 Money Rail (payments-shaped OP Stack)

## Introduction

Specialize ForteL2 as the **home settlement rail** for [SettlementOS](https://github.com/StephenForte/settlementos). Payment orchestration, compliance, FX, escrow, and the JLTXX-inspired `TokenizedMMF` stay in SettlementOS. This PRD covers only what the L2 operator must publish and operate so SOS can land.

**Infra status (learning chain):** Phases **0–6 are done**, including Sepolia-backed L2 (chain **852**), the Render replica ([fortel2-replica](https://github.com/StephenForte/fortel2-replica)), and the authenticated write path. Money-rail work left in this repo is trigger-gated (MR-3/4/5) plus the parked public-read URL (MR-2).

**Companion docs**

| Doc | Audience |
|---|---|
| `tasks/coordination-settlementos.md` | Both — ownership / no-duplicate-work |
| `tasks/prd-l2-learning-chain.md` | ForteL2 — OP Stack learning phases |
| **This file** | **ForteL2** — money-rail track |
| `~/settlementos/tasks/prd-fortel2-integration.md` | **SettlementOS** — handoff |

Give SOS the **integration PRD**, not this file alone.

---

## When SettlementOS may come on the L2

| Gate | Learning-chain status | SOS may… | Notes |
|---|---|---|---|
| **G0 — blocked** | Before Phase 1 blocks | Nothing | — |
| **G1 — earliest code** | Phase 1 local L2 (901) up | Optional offline adapter against `fortel2-local` | Ephemeral; resets freely |
| **G2 — recommended start (NOW)** | Phase **2c+** Sepolia L2 **852** + batcher/proposer | **F1–F5**: registry, deploy contracts, single-chain settle, MMF | Pin: no Sepolia redeploy until the redeploy gate (Phase 7 / mainnet-pilot entry) |
| **G3 — preferred reads** | Phase **3** Render replica ✅ | Point explorer / heavy reads at replica RPC | Writes: authenticated Access hostname `fortel2-write.ente.ltd` (D-0035). Reads: Render private `fortel2-replica:10000` (D-0032). |
| **G4 — partner-facing** | Replica stable + SOS settle demo green | Demo to partners on 852 | Best-effort uptime; personal L2 |
| **G5 — after wipe** | redeploy gate (Phase 7 / mainnet-pilot entry) | Redeploy SOS contracts; update explorer address book | Coordinated with replica pack/publish |

**Do not wait for:** Phase 3b (friends), Phase 4–6 client rebuilds, paymaster, or canonical USDC before SOS starts.

**Default invitation:** SettlementOS starts **now** against chain **852** once `deployments/rail-interface.json` is published (this PRD’s MR-0).

---

## Replica — do we need to update it?

**Short answer:** Replica is already **built and verified** (Phase 3). You do **not** rebuild it for SOS. You **do** keep a checklist so it is never forgotten on resets or when SOS/explorer consume it.

| Event | Update replica? | Action |
|---|---|---|
| SOS first deploy on 852 | **No** genesis change | Document SOS/explorer as **read consumers**; prefer replica RPC for reads if reachable |
| Routine Mac sequencer restart | **No** | Replica derives from L1; verify with `replica-sync-check.sh` if tips diverge |
| redeploy gate (Phase 7 / mainnet-pilot entry) Sepolia redeploy / network wipe | **YES — mandatory** | Announce → redeploy → `pack-replica-artifacts.sh` → push genesis/rollup to fortel2-replica → wipe Mac **and** Render `/data` → hash cross-check (see README Network reset procedure) |
| Accidental one-sided wipe | **Recover** | Never leave Mac and Render on different genesis under chain 852 |
| Opening public replica RPC later | Config only | fortel2-replica service exposure; keep keys out of this repo |

**Pinned through Phase 6:** do not pack/publish “just in case.” Packing without a redeploy republishes the same genesis. Next expected replica artifact update = the **redeploy gate** (Phase 7 / mainnet-pilot entry).

---

## Who does what (RACI)

| Work item | ForteL2 | SettlementOS |
|---|---|---|
| OP Stack / Sepolia L1 contracts / sequencer | **R/A** | I |
| Render replica + pack/publish on redeploy | **R/A** | I |
| Publish `rail-interface.json` | **R/A** | I |
| Add `fortel2-sepolia` (852) network + deploy SOS contracts | I | **R/A** |
| Payment / compliance / FX / MMF product logic | — | **R/A** |
| Rebuild escrow/MMF as L2 system features | **Forbidden** | **Forbidden** |

---

## Phase roadmap (money rail)

| Phase | Scope | Status |
|---|---|---|
| **MR-0** | Publish rail interface + SOS/Replica lifecycle gates (this PRD) | **Done** (2026-08-04) |
| **MR-1** | SOS can deploy + settle on **852** (Mac sequencer RPC) | **Done** (2026-08-13, D-0036) — first settlement on 852 through the authenticated write path |
| **MR-2** | Document replica as preferred read path; optional read URL in rail interface | **Done** (2026-08-18, D-0045) — public replica `https://fortel2-replica-rpc.onrender.com`; sequencer-tip `https://fortel2-sequencer-rpc.onrender.com`. Write hostname stays unpublished. SOS in-Render still uses private `http://fortel2-replica:10000` (D-0032). |
| **MR-3** | Fee/paymaster spikes (only if SOS needs them) | **Parked** — trigger-gated (D-0005). No worker until SOS asks. |
| **MR-4** | Canonical USDC path | **Parked** — trigger-gated (D-0005). No worker until SOS needs Circle bridged-USDC. |
| **MR-5** | Optional predeploy / AuditAnchor | **Parked** — trigger-gated (D-0005). After SOS is stable on 852 *and* asks. |

Learning-chain Phases **4–6** are done. Do **not** redeploy L1 or break SOS addresses before the redeploy gate (Phase 7 / mainnet-pilot entry).

**Program closeout (D-0017 + D-0036 + D-0045):** ForteL2 money-rail on-ramp is closed. MR-1 settled on-chain. MR-2 public **read** URLs published (replica + sequencer-tip). Write hostname unpublished. MR-3/4/5 stay parked until an SOS trigger fires.

---

## Functional requirements

- **FR-1:** Remain OP Stack / EVM.
- **FR-2:** Versioned `deployments/rail-interface.json` with chain IDs, RPCs, bridge proxies, fee token, reset policy, replica notes, availability (nightly sleep/wake window).
- **FR-3:** SOS deploys existing contracts via CREATE — no ForteL2 Solidity required for MR-1.
- **FR-4:** Sepolia deployment stays **pinned through Phase 6**; SOS warned that redeploy gate (Phase 7 / mainnet-pilot entry) wipes require redeploy.
- **FR-5:** Replica update checklist stays in README + `replica/README.md` + this PRD (never orphaned).

---

## User stories — ForteL2

### US-MR-001: Publish rail interface ✅
**Acceptance Criteria:**
- [x] `deployments/rail-interface.json` committed with local (901) + Sepolia (852) entries
- [x] Documents OptimismPortal / L1StandardBridge proxies for Sepolia from `deployments/sepolia/deployments.json`
- [x] Reset policy: Phase 1 may reset freely; Sepolia pinned until the redeploy gate (Phase 7 / mainnet-pilot entry); that gate = coordinated wipe including replica
- [x] Links to SOS integration PRD + coordination doc
- [x] `cast` health examples in README or rail-interface comments/README section

### US-MR-002: SOS onboard checklist (operator)
**Acceptance Criteria:**
- [x] README “SettlementOS” subsection: start Sepolia stack, fund deployer via bridge/deposit, point SOS at `L2_RPC_URL`, deploy
- [x] Explicit: SOS writes → sequencer RPC; SOS/explorer reads → replica when available
- [x] Replica update triggers listed (redeploy gate (Phase 7 / mainnet-pilot entry) only for genesis republish)

### US-MR-003: Replica consumer note
**Acceptance Criteria:**
- [x] `replica/README.md` lists consumers: fortel2-replica operators, SOS reads, settlementos-explorer
- [x] Reminder: pack/publish only after redeploy; sync-check after SOS-heavy demos if tips look wrong

---

## Out of scope (SOS owns)

Payment APIs, compliance, `PaymentSettlement` features, `TokenizedMMF` rules, FX, reconciliation UI — see SOS PRD §§16–24 / Phase 8.

---

## Success metrics

- SOS settles one ACME→Tokyo-style payment on chain 852 with audit hashes — **met** 2026-08-13 (`pay_4bf481cdc9ea`, D-0036)
- Rail interface readable without a meeting
- Redeploy-gate (Phase 7 / mainnet-pilot entry) reset runbook still mentions replica **before** anyone wipes Mac-only
- Zero duplicate escrow/MMF implementations

## Open questions

- ~~Expose a stable tunnel/URL for SOS writes off-box, or keep SOS colocated with Mac sequencer for now?~~ — **resolved 2026-08-12/13 (D-0030, D-0035, D-0036)**: authenticated Cloudflare Access write path is live (`https://fortel2-write.ente.ltd` → `:9555`). Hostname stays **unpublished** in `rail-interface.json` (other clients lack Access headers). First settlement proven on 852.
- ~~Public vs private Render replica RPC for explorer~~ — **resolved 2026-08-18 (D-0045)**: diskless public gateways are live. `replica.readRpcUrl` = `https://fortel2-replica-rpc.onrender.com` (L1-derived). `sequencerReads.readRpcUrl` = `https://fortel2-sequencer-rpc.onrender.com` (sequencer tip; down in the nightly window). The verifier Private Service stays private. SOS in-Render still uses `http://fortel2-replica:10000` (D-0032). Write hostname stays unpublished.
- ~~Network registry id string: `fortel2-sepolia` vs `forte-l2`~~ — **resolved 2026-08-11 (D-0028)**: `fortel2-sepolia`, already live on the SOS side and fixed across re-genesis. Not a choice that was ever open to us.

### Trigger-gated later work (do not start)

| Phase | Trigger | Owner |
|---|---|---|
| **MR-3** paymaster / fee abstraction | SOS asks | ForteL2 spike only after the ask |
| **MR-4** canonical USDC | SOS needs Circle bridged-USDC | ForteL2 + SOS |
| **MR-5** AuditAnchor | SOS stable on 852 *and* asks | ForteL2 |
