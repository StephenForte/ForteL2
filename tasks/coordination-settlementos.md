# ForteL2 ↔ SettlementOS coordination

**Status:** living (updated 2026-08-18 — public read URLs published, D-0045; Phase 7 operator sequence in `tasks/prd-phase-7-fault-proofs.md`)  
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
**Writes:** D1 allowlist on mini `:9555`, Cloudflare Access hostname `https://fortel2-write.ente.ltd` (D-0034/D-0035). Operator `L2_RPC_URL` stays loopback `:9545`. **Reads:** public replica `https://fortel2-replica-rpc.onrender.com`; public sequencer tip `https://fortel2-sequencer-rpc.onrender.com` (D-0045). SettlementOS on Render still uses private `http://fortel2-replica:10000` (D-0032). `rail-interface.json` write URL remains unpublished.


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
1. ForteL2 publishes rail-interface.json          ← MR-0 done
2. SOS adds fortel2-sepolia (852) + deploy        ← SOS F1–F2 done
3. SOS single-chain settle + MMF on 852           ← SOS F3–F4 / D-0036 done
4. Reads via replica; explorer address book       ← MR-2 done (D-0045 public reads)
5. Phase 4–6 learning rebuilds (no redeploy)      ← done
6. Phase 7 wipe → replica pack + SOS redeploy + rail-interface v7
                                          ← next coordinated event; order in
                                            tasks/prd-phase-7-fault-proofs.md
                                            § Operator sequence (v6 stays until
                                            new proxies exist). Not authorized
                                            by docs-only PRs.
7. MR-3/4/5 (paymaster / USDC / AuditAnchor)      ← parked until SOS asks
```
## Status 2026-08-12 — replica reads live; authenticated writes proven (D-0035)

**Reads (done).** Public replica `https://fortel2-replica-rpc.onrender.com` (L1-derived, ~3 min lag). Public sequencer tip `https://fortel2-sequencer-rpc.onrender.com` (tip-follow; 502/403 during 23:45–03:00). Both reject `eth_sendRawTransaction` (`-32601`). SettlementOS on Render still sets `FORTEL2_SEPOLIA_READ_RPC_URL=http://fortel2-replica:10000` (D-0032). `rail-interface.json` `replica.readRpcUrl` / `sequencerReads.readRpcUrl` are those public URLs (D-0045). Do **not** convert the Private Service to Web.

**Writes (RPC path done; product overlay parked).** US-012 **GO** (D-0030). D1 filter live on mini `:9555`. Dashboard-managed tunnel `SuperForteL2_mini` (`64c3a080-44fa-4af6-9591-aba07d849757`) origin `:9555` only. Hostname `https://fortel2-write.ente.ltd`, Access app `fortel2-write`, policy `settlementos`. Unauthenticated → 403; token (mini + Render Shell) → `0x354`. SOS PR 65 (`785a9ae`) sends Access headers only on `fortel2-sepolia` writes. Render `FORTEL2_SEPOLIA_RPC_URL=https://fortel2-write.ente.ltd`. Do **not** point the read URL at `ente.ltd`. Do **not** publish the write hostname in `rail-interface.json`. Do **not** bootstrap `com.steve.fortel2-cloudflared` while the dashboard connector is Healthy.

**Settled end to end 2026-08-13 (D-0036).** Both parked items above are closed. Secret Files `deployments.fortel2-sepolia.json` and `deployments.base-sepolia.json` are on Render, and `pay_4bf481cdc9ea` settled on `fortel2-sepolia` — escrow `0x48797d94…c3942b` (block 979,593) and settlement `0x876325b2…8045c7` (block 979,595), both `status=0x1`, both **finalized on L1**. ~17 s from payment creation to escrow mined, so neither Access nor the method filter adds meaningful latency. Access token still lives with Steve (Cloudflare + Render Dashboard), not git.

### What failure looks like on this path

`cloudflared` runs as a **system LaunchDaemon** (`/Library/LaunchDaemons/com.cloudflare.cloudflared.plist`), so it starts at boot with no login. The ForteL2 stack runs as **user LaunchAgents**, which need a logged-in session (D7). The tunnel is therefore more available than the thing behind it, and that changes the failure signature:

| What SOS sees | What it usually means |
|---|---|
| **403** + Access HTML | Missing/invalid `CF-Access-Client-Id` / `-Secret`, or the policy changed. Never a ForteL2 problem. |
| **502 / 530** from Cloudflare | Tunnel is healthy, **origin is not** — `:9555` filter or the sequencer is down. This is the reboot-without-login case, and it is the one that looks like "ForteL2 is up but broken." |
| Connection refused / DNS failure | The tunnel itself is down, or the mini is off/asleep. |
| Success but stale reads | Reading the replica, which trails ~3 min by design (D-0032). Not an outage. |
| `filter not found` on `eth_getFilterChanges` | Filter IDs are per-node in-memory and die on every sequencer restart — expected nightly. Re-create, do not alert. |

**The 502 case is the trap**: the obvious first guess is "the tunnel is down," and it will be wrong every time. Check `:9555` on the mini before touching Cloudflare. Expected daily during **23:45–03:00** `America/Los_Angeles`; unexpected at any other hour means the stack did not come back after a reboot.

End-of-day recap with every live value: [`tasks/status-2026-08-12-write-path.md`](status-2026-08-12-write-path.md).

**Explorer.** Same Render private network (`settlementos-explorer-ihgo`). Set **non-VITE** `FORTEL2_SEPOLIA_READ_RPC_URL=http://fortel2-replica:10000` for Node/MCP. Do not put that hostname in `VITE_*` (browser bundle; visitors cannot resolve private DNS).

**Availability unchanged:** sequencer (and therefore writes) down **23:45–03:00** `America/Los_Angeles`. Replica may keep serving a stale tip until new L1 batches land.

**Do not:** convert the replica Private Service to Web; apply `fortel2-replica` `render.yaml` as a new Blueprint (20 GB empty disk vs live 50 GB); put the Access write hostname in `rail-interface.json`.