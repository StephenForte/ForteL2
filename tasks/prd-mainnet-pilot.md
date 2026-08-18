# PRD — Mainnet pilot — Phase 9 track; entered via the redeploy gate

**Status:** P7-0 leftovers expanded (2026-08-18) · **Owner:** VP Eng · **Charter:** D-0018  
**Learning sibling:** Phase 7 fault proofs (`tasks/prd-phase-7-fault-proofs.md`) share the redeploy **event**, not this product program.

> P7-1 through P7-5 remain wave-level scopes without full FRDs. Do not treat this file as authorization to spend mainnet ETH or to run `FORCE_SEPOLIA_REDEPLOY`.

---

## 1. Mission

A production OP Stack L2 ("real chain, still a bit of learning") ready to run SettlementOS
for a pilot institutional customer — target scenario: operator acquires a bank in SEA and
the bank settles stablecoin transfers on this rail (or builds its own SOS-like app on it).

**In scope:** stablecoin transfers between institutions · lightweight defi · future-phase RWA transfers.
**Out of scope:** everything else (general-purpose public chain ambitions, NFT/consumer, full defi).

---

## 2. Pinned decisions (from D-0018 — do not re-litigate)

| # | Decision | Later note |
|---|---|---|
| 1 | **Stock OP Stack releases** for sequencer/batcher/proposer. Custom `batcher/`/`proposer/` modules stay frozen: learning artifacts + emergency backup only. | Unchanged |
| 2 | DA = **blobs** (EIP-4844); span batches; relaxed channel + proposal cadence. | **Superseded for now by D-0037.** Production DA on 852 is **calldata + span batches**. Blobs prune after ~18 days and break the `derivation/` “audit your rail from L1” story. Revisit only if a cost case reappears **and** the archive question is solved. |
| 3 | `derivation/` verifier is the **counterparty audit tool**. | Still the goal. Today it proves consistency vs the operator node — see US-P7-005. |
| 4 | L1 access: **self-hosted primary + paid fallback**, router pattern. QuickNode demoted to fallback. | Unchanged; P7-1 |
| 5 | Sepolia 852 remains **staging**; mainnet deploy goes through the **redeploy gate**. | Unchanged |
| 6 | Key custody is **gating**: HSM/MPC for hot keys, multisig admin + timelock, external audit before pilot funds. | US-P7-001 |
| 7 | Public-DA transparency is **disclosed to the pilot up front**; mitigation is app-layer. | Unchanged |

---

## 3. Phase blocks

P7 block IDs are stable identifiers, not a phase number.

### P7-0 — Decision spikes (before infra spend)

| Item | Status |
|---|---|
| T5 write-path revival | **Done** — US-012 GO (D-0030); Access proven (D-0035); first 852 settlement (D-0036) |
| Cost model | **Done** — span batches 11.82× cheaper (D-0037); fee scalars no-action (D-0038); tip attribution corrected (D-0039). Blobs not pursued. Cadence parked. |
| Custody design | **Specified** — US-P7-001 (not executed) |
| Deployment-permission policy | **Specified** — US-P7-002 |
| Sequencer HA stance | **Specified** — US-P7-003 |
| RaaS re-check | **Specified** — US-P7-004 |
| Independent derivation gap | **Specified** — US-P7-005 |

### P7-1 — L1 + chain infrastructure (later wave)

- [ ] Self-hosted L1 full node + consensus client (calldata archive; blob sidecar only if DA revisits blobs)
- [ ] Mainnet deploy: fresh contract set + genesis (redeploy gate); stock op-node/op-geth/op-batcher/op-proposer at pinned release tags
- [ ] Fee config measured against the D-0037/D-0038 baseline (operator ~0.014 ETH/day at current span+calldata cadence on idle 852 — re-measure at plan start)
- [ ] Monitoring/alerting to replace dev-sleep-era habits (the chain no longer sleeps at 23:00)

### P7-2 — Replicas + audit distribution (later wave)

- [ ] Operator standby verifier (second provider/region; Render replica pattern)
- [ ] Counterparty replica pack + Docker runbook + verifier handoff — blocked on US-P7-005
- [ ] Replica sync-check path that works for private deployments (extend D-0016 or publish a deliberate public read URL)

### P7-3 — Money-rail triggers fire (later; SOS-gated)

- [ ] **MR-4** canonical USDC — parked until SOS asks (D-0005)
- [ ] **MR-3** paymaster — parked until SOS asks
- [ ] **MR-5** AuditAnchor — parked until SOS is stable on 852 *and* asks

### P7-4 — SettlementOS deployment (later wave)

- [x] SOS contracts on 852 staging + settle demo — **met** (D-0036)
- [ ] SOS on mainnet chain after P7-1 / triggered P7-3 items land
- [ ] Pilot-bank integration: their replica, their keys, their SOS instance

### P7-5 — Security, compliance, go-live (later wave)

- [ ] External security audit (contracts config + infra + key ceremony)
- [ ] Incident response runbook + drill
- [ ] SEA regulatory review with counsel (out of engineering scope; gates go-live)
- [ ] Pilot success metrics: settle E2E on mainnet, cost-per-transfer ≤ target, time-to-safe ≤ target, counterparty independently verifies a window

---

## 4. User stories — P7-0 leftovers

These close the skeleton’s “no acceptance criteria” gap for the four open decision spikes. None of them spend mainnet ETH.

### US-P7-001: Custody design (start first — longest lead)

**Description:** As the operator, I want a written custody design so batcher/proposer/admin keys are not a Mac-mini file when pilot funds exist.

**Acceptance Criteria:**

- [ ] Vendor shortlist (at least one HSM and one MPC) with a recorded pick or a dated deferral
- [ ] Quorum: admin multisig size + timelock duration written down
- [ ] Key ceremony runbook (generate, backup, rotate, revoke) — never asks anyone to paste a key into chat
- [ ] Hot-key set named: batcher, proposer, challenger (if any). Sequencer key stays out of the “can drain L1” set
- [ ] External audit of the ceremony is a P7-5 gate, not this story

**TBD-plan (not a debate):** pick the vendor when this story starts; do not re-open “self-host vs RaaS” here (that is US-P7-004).

### US-P7-002: Deployment-permission policy

**Description:** As the operator, I want a rule for who may deploy contracts on the pilot chain so it is a settlement rail, not an anonymous contract host.

**Acceptance Criteria:**

- [ ] Policy one-pager: allowlist mechanism (EOA list vs factory vs SOS-only deployer)
- [ ] Staging (852) vs mainnet: 852 may stay more open for learning; mainnet is allowlisted
- [ ] Enforcement named (off-chain process is acceptable for v1; on-chain allowlist is optional)
- [ ] Disclosed to the pilot up front (pairs with D-0018 #7 transparency)

### US-P7-003: Sequencer HA stance

**Description:** As the operator, I want a written failover posture so a Mac-mini reboot is not an unspoken single point of failure.

**Acceptance Criteria:**

- [ ] Stance recorded: **single sequencer + documented failover** (default) **or** active standby
- [ ] Failover runbook: who promotes, how `op-node` sequencer flags move, how the write filter / Access tunnel retargets
- [ ] Nightly 23:45–03:00 sleep is **retired** before any pilot SLA (or the SLA names the window)
- [ ] Explicit non-goal: Phase 8 leader election

### US-P7-004: RaaS re-check

**Description:** As the operator, I want a one-page re-validation that self-host still beats Conduit/Caldera/etc. given custody (D-0018 already leans self-host).

**Acceptance Criteria:**

- [ ] One-page note comparing self-host vs at least two RaaS options on: key custody, DA policy (calldata permanence), cost, who can halt the sequencer
- [ ] Decision recorded in `tasks/decisions.md` (keep or switch). Default remains self-host unless the note says otherwise

### US-P7-005: Independent derivation (blocks promising the verifier to a pilot)

**Description:** As the operator, I want the `derivation/` limitation closed so a counterparty is not “auditing” my node against itself.

**Acceptance Criteria:**

- [ ] Spec chooses **one**: self-derived state from genesis, **or** an anchor taken from the **counterparty’s** replica (not a copy of the operator datadir)
- [ ] `derivation/README.md` § Limitations updated when the chosen path lands
- [ ] Until then, counterparty docs must not claim independent honesty — only consistency

See current gap: [`derivation/README.md` § Limitations — independent verification](../derivation/README.md#limitations--independent-verification).

---

## 5. Feasibility baseline (updated 2026-08-18)

| Question | Answer |
|---|---|
| Gas / batcher burn | Span + calldata on idle 852 ≈ **0.014 ETH/day** (D-0037), down from ~0.16. Blobs not required for that saving. Re-measure before mainnet. |
| User fees | Settlement flow ≈ **$0.00076** (D-0038). Dominant tip term is the sequencer GPO suggestion (D-0039), not SOS config. |
| TPS | ~200–300 ERC-20 ceiling; pilot needs <1. Optimize cost + time-to-safe. |
| Without QuickNode | Self-host L1 (2–4TB NVMe, 32–64GB RAM, ~$100–200/mo) + paid fallback. |
| Replicas to start | 2 operator-run + 1 per counterparty. Friend path: `replica/FRIENDS.md`. |
| SOS on 852 | Done (D-0036). Next SOS work is their product; ForteL2 waits on MR-3/4/5 triggers. |

---

## 6. Known gaps this expansion still does not resolve

- P7-1..P7-5 have no full FRDs yet (later waves).
- Privacy posture beyond disclosure (netting/omnibus) unexplored.
- Custody vendor and audit firm unselected (US-P7-001 / P7-5).
- Mainnet economics must be re-modeled at P7-1 start; 2026 blob-market assumptions in the 2026-08-05 skeleton are stale given D-0037.
