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
**Availability:** sequencer RPC is down **23:00–04:00** local (`America/Los_Angeles`) every night — SOS retry/backoff must assume that window. No uptime commitment (personal Mac mini L2).  
**Writes:** Mac sequencer L2 RPC, **loopback only** today; no off-box write path is approved — operator US-012 go/no-go is outstanding (options in `tasks/spike-t5-write-path.md`, D-0019). Per D-0016 there is no Mac-reachable replica read URL; interim reads use the same sequencer endpoint.

Full table: `tasks/prd-money-rail.md` § “When SettlementOS may come on the L2”.

## Replica — never forget

| When | Action |
|---|---|
| SOS/explorer reads | Prefer Render replica RPC if reachable |
| Phase 7 redeploy | **Mandatory** pack → publish fortel2-replica → wipe Mac + Render together |
| Before Phase 7 | Do not republish genesis “for fun” — deployment is pinned |

Details: `replica/README.md`, README “Network reset procedure”, money-rail PRD.

## Ownership matrix (no duplicates)

| Capability | Owner |
|---|---|
| Payment lifecycle, quotes, FX, compliance, audit DB | **SOS** |
| `PaymentSettlement`, `MockERC20`, `TokenizedMMF` | **SOS** (deploy on ForteL2) |
| Network registry entry for ForteL2 | **SOS** |
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
