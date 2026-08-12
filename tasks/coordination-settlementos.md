# ForteL2 ↔ SettlementOS coordination

**Status:** living (updated 2026-08-04 for MR-0 closeout; Phase 0–3 complete)  
**Sources:** SettlementOS PRD/README; ForteL2 learning-chain PRD; money-rail PRD

## Product split

```text
SettlementOS  = payments product (orchestration, compliance, liquidity, audit, API/UI)
ForteL2       = settlement infrastructure (OP Stack L2)
Stablecoins   = settlement assets (USDC later; mocks now)
Light DeFi    = SOS TokenizedMMF (JLTXX-inspired) — not an L2 DeFi suite
RWA           = SOS later — L2 only hosts contracts
```

## SOS onboarding gate (summary)

**SettlementOS may start now on Sepolia ForteL2 (chain 852).**  
Do not wait for Phase 3b/4–6/paymaster/USDC.  
**Availability:** sequencer RPC is down **23:45–03:00** local (`America/Los_Angeles`) every night — SOS retry/backoff must assume that window. No uptime commitment (personal Mac mini L2).  
**Writes:** still Mac sequencer loopback (`L2_RPC_URL` / `:9545`) plus D1 allowlist on `:9555`. US-012 is GO (D-0030); Cloudflare tunnel to `:9555` is not up yet. **Reads:** SettlementOS uses Render private `http://fortel2-replica:10000` (D-0032); `rail-interface.json` `replica.readRpcUrl` remains null (D-0031).


Full table: `tasks/prd-money-rail.md` § “When SettlementOS may come on the L2”.

## Replica — never forget

| When | Action |
|---|---|
| SOS/explorer reads | Prefer Render replica RPC if reachable |
| Phase 7 redeploy | **Mandatory** pack → publish fortel2-replica → wipe Mac + Render together |
| Phase 7 redeploy | **Notify SOS ≥1 day ahead**, and send new contract addresses once they exist — re-genesis expires every ForteL2 address they hold and breaks their live explorer address book (D-0028) |
| Before Phase 7 | Do not republish genesis “for fun” — deployment is pinned |

Details: `replica/README.md`, README “Network reset procedure”, money-rail PRD.

## Ownership matrix (no duplicates)

| Capability | Owner |
|---|---|
| Payment lifecycle, quotes, FX, compliance, audit DB | **SOS** |
| `PaymentSettlement`, `MockERC20`, `TokenizedMMF` | **SOS** (deploy on ForteL2) |
| Network registry entry for ForteL2 | **SOS** — id settled: `fortel2-sepolia` / `fortel2-local`, fixed across re-genesis (D-0028) |
| Sequencer / batcher / proposer / L1 contracts | **ForteL2** |
| Render replica + artifact pack on redeploy | **ForteL2** |
| `rail-interface.json` | **ForteL2** |
| Rebuild escrow/MMF as rollup features | **Forbidden** |

## PRD handoff

| Audience | Doc |
|---|---|
| SettlementOS | `~/settlementos/tasks/prd-fortel2-integration.md` |
| ForteL2 | `tasks/prd-money-rail.md` |
| Shared | this file |

## Integration order

```text
1. ForteL2 publishes rail-interface.json          ← MR-0 (now)
2. SOS adds fortel2-sepolia (852) + deploy        ← SOS F1–F2
3. SOS single-chain settle + MMF on 852           ← SOS F3–F4
4. Reads via replica; explorer address book       ← MR-2 / SOS explorer
5. Phase 4–6 learning rebuilds (no redeploy)      ← parallel
6. Phase 7 wipe → replica pack + SOS redeploy     ← coordinated
```
## Status 2026-08-12 — replica reads live; writes still loopback pending tunnel

**Reads (done).** Render Private Service `fortel2-replica:10000` (Oregon, env `evm-d9h424715fvs73cq2gl0`) serves the MR-2 method filter (geth/op-node loopback). SettlementOS sets `FORTEL2_SEPOLIA_READ_RPC_URL=http://fortel2-replica:10000`. Operator Shell from `settlementos` → replica `eth_chainId` = `0x354` (852). Replica is read-only (`eth_sendRawTransaction` → `-32601`). Lag ~3 minutes (L1 batches); `confirm()` and writes stay on the sequencer. `rail-interface.json` `replica.readRpcUrl` stays **null** (D-0031) — the private hostname is not a published rail URL (D-0032).

**Writes (not done).** US-012 is **GO** (D-0030). D1 filter is live on mini `:9555`. Cloudflare tunnel to `:9555` (never `:9545`) is the next ForteL2 ops task (D-0034). Until that lands, SOS writes remain Mac loopback / colocate. Do not point `FORTEL2_SEPOLIA_RPC_URL` at the replica.

**Explorer.** Same Render private network (`settlementos-explorer-ihgo`). Set **non-VITE** `FORTEL2_SEPOLIA_READ_RPC_URL=http://fortel2-replica:10000` for Node/MCP. Do not put that hostname in `VITE_*` (browser bundle; visitors cannot resolve private DNS).

**Availability unchanged:** sequencer (and therefore writes) down **23:45–03:00** `America/Los_Angeles`. Replica may keep serving a stale tip until new L1 batches land.

**Do not:** convert the replica Private Service to Web; apply `fortel2-replica` `render.yaml` as a new Blueprint (20 GB empty disk vs live 50 GB); publish a public replica URL until a diskless reverse-proxy exists (D-0031).