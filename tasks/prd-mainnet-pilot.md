# PRD — Mainnet pilot — Phase 9 track; entered via the redeploy gate — SKELETON

**Status:** skeleton (2026-08-05) · **Owner:** VP Eng · **Charter:** D-0018
**Expand via:** the next parallel plan turns each `P7-x` block into full spec + FRDs + user stories (US-P7-xxx) using the D-0001..D-0017 program's contract template (`tasks/plan-parallel-integration.md` §5).

> This file deliberately contains structure and pinned decisions, not acceptance criteria.
> Anything marked **TBD-plan** is the next plan's first work item, not an open debate here.

---

## 1. Mission

A production OP Stack L2 ("real chain, still a bit of learning") ready to run SettlementOS
for a pilot institutional customer — target scenario: operator acquires a bank in SEA and
the bank settles stablecoin transfers on this rail (or builds its own SOS-like app on it).

**In scope:** stablecoin transfers between institutions · lightweight defi · future-phase RWA transfers.
**Out of scope:** everything else (general-purpose public chain ambitions, NFT/consumer, full defi).

## 2. Pinned decisions (from D-0018 — do not re-litigate in the plan)

| # | Decision |
|---|---|
| 1 | **Stock OP Stack releases** for sequencer/batcher/proposer. Custom `batcher/`/`proposer/` modules stay frozen: learning artifacts + emergency backup only. |
| 2 | DA = **blobs** (EIP-4844); span batches; relaxed channel + proposal cadence (cost over latency — time-to-safe target set in P7-0). |
| 3 | `derivation/` verifier is the **counterparty audit tool** — every institutional counterparty gets replica pack + verifier. |
| 4 | L1 access: **self-hosted primary + paid fallback**, router pattern generalized from the L1 RPC router in the `fortel2-replica` repo (`l1_rpc_router.py`, not in this tree). QuickNode demoted to fallback. |
| 5 | Sepolia 852 remains **staging**; mainnet deploy goes through the **redeploy gate** (fresh genesis, replica republish, pack/publish/wipe checklist). |
| 6 | Key custody is **gating**: HSM/MPC for hot keys, multisig admin + timelock, external security audit before pilot funds. |
| 7 | Public-DA transparency is **disclosed to the pilot up front**; any mitigation (netting, omnibus structuring) is app-layer, not chain-layer. |

## 3. Phase blocks (each becomes a wave in the next plan)

P7 block IDs below are stable identifiers, not a phase number.

### P7-0 — Decision spikes (sequential, before infra spend)
- [ ] **T5 revival:** stable off-box write URL for SOS (the deliberately-parked money-rail open question). Deliverable: go/no-go + rail-interface v2 draft.
- [ ] Cost model: blob-market assumptions, channel duration, proposal cadence → **cost-per-transfer and time-to-safe targets** (TBD-plan).
- [ ] Custody design: HSM/MPC vendor choice, multisig quorum, timelock params, key ceremony runbook (TBD-plan; longest lead time — start first).
- [ ] Deployment-permission policy: who may deploy contracts on the pilot chain (allowlist mechanism + governance).
- [ ] Sequencer HA stance for pilot (single sequencer + documented failover vs active standby).
- [ ] RaaS re-check: one-page re-validation that self-host still beats Conduit/Caldera/etc. given custody requirements (decision already leans self-host per D-0018).

### P7-1 — L1 + chain infrastructure
- [ ] Self-hosted L1 full node + consensus client (blob sidecar retention); paid fallback; primary/fallback router.
- [ ] Mainnet deploy: fresh contract set + genesis (redeploy gate); stock op-node/op-geth/op-batcher (blobs)/op-proposer at pinned release tags.
- [ ] Fee config: L2 basefee floor, L1-fee scalars, per-transfer cost measured against P7-0 target.
- [ ] Monitoring/alerting to replace dev-sleep-era habits (the chain no longer sleeps at 23:00).

### P7-2 — Replicas + audit distribution
- [ ] Operator standby verifier (second provider/region; Render replica pattern).
- [ ] Counterparty replica pack: genesis/rollup publish + Docker runbook + derivation-verifier handoff doc ("audit your rail" as product surface).
  - Gap today: `derivation/` proves consistency against the operator's own node, not independent honesty — see [`derivation/README.md` § Limitations — independent verification](../derivation/README.md#limitations--independent-verification). Next plan must scope self-derived roots or counterparty-owned anchors before promising this to a pilot.
- [ ] Replica sync-check path that works for private deployments (extend D-0016 pattern or make the pilot replica reachable).

### P7-3 — Money-rail triggers fire
- [ ] **MR-4:** canonical USDC via Circle bridged-USDC standard (the single most important integration for institutional stablecoin transfers).
- [ ] **MR-3:** paymaster / fee abstraction so pilot users never touch gas.
- [ ] **MR-5:** AuditAnchor once SOS runs stable on the pilot chain.

### P7-4 — SettlementOS deployment
- [ ] SOS contracts on 852 staging per `rail-interface.json` + T5 outcome; settle demo end-to-end; MR-1 acceptance.
- [ ] SOS on mainnet chain after P7-1/P7-3 land.
- [ ] Pilot-bank integration: their replica, their keys, their SOS instance (or their app on our rail).

### P7-5 — Security, compliance, go-live
- [ ] External security audit (contracts config + infra + key ceremony).
- [ ] Incident response runbook (sequencer halt, key compromise, L1 reorg handling) + drill (cold-start discipline from H4 carries over).
- [ ] SEA regulatory review with counsel (bank acquisition context; out of engineering scope but gates go-live).
- [ ] Pilot success metrics: settle demo E2E on mainnet, cost-per-transfer ≤ target, time-to-safe ≤ target, counterparty independently verifies a window with `derivation/`.

## 4. Feasibility baseline (2026-08-05 answers backing this skeleton)

| Question | Answer |
|---|---|
| Gas / batcher burn | Current burn = calldata + aggressive cadence (learning tuning). Blobs + span batches + relaxed cadence → single-digit $/day at pilot volume. |
| TPS | ~200–300 TPS ceiling for ERC-20 transfers; pilot needs <1. Non-issue — optimize cost + time-to-safe instead. |
| Without QuickNode | Self-host L1 (2–4TB NVMe, 32–64GB RAM, ~$100–200/mo bare metal) + paid fallback via router pattern. |
| Replicas to start | 2 operator-run (reads + standby) + 1 per counterparty; counterparty replica is part of the product. |
| Scope fit | General-purpose EVM shaped by policy: permissioned deployment, canonical USDC, paymaster. RWA later is mostly legal, not chain. Transparency disclosed. |
| SOS next step | T5 write-tunnel decision → SOS on 852 → settle demo → MR-1 → mainnet. |

## 5. Known gaps this skeleton does not resolve

- No acceptance criteria anywhere yet (deliberate — next plan's job).
- Privacy posture beyond disclosure (netting/omnibus design) unexplored.
- Custody vendor and audit firm unselected.
- Mainnet economics assume 2026 blob-market conditions; re-model at plan start.
