# Phase 3 replica — operator bridge only

Runtime (Dockerfile, compose, Render Blueprint, baked genesis/rollup) lives in a **separate repo**:

**https://github.com/StephenForte/fortel2-replica**

This directory is a thin staging area for the Mac operator — not a second node package.

| Audience | What to use |
|---|---|
| Friends / Render | Clone `fortel2-replica` — root `Dockerfile`, `docker compose`, no keys |
| Operator (this repo) | `./scripts/pack-replica-artifacts.sh` → publish `replica/config/{genesis,rollup}.json` into fortel2-replica after a Sepolia redeploy |
| Sync check | `./scripts/replica-sync-check.sh` (needs reachable replica RPC) |

## Consumers (do not forget)

| Consumer | Role | Needs genesis republish? |
|---|---|---|
| Render / friend verifiers | Derive L2 from Sepolia L1 | **Yes** on every Sepolia redeploy (Phase 7+) |
| SettlementOS | Optional **read** RPC (writes stay on Mac sequencer) | Only if redeploy changed genesis |
| settlementos-explorer | Optional indexed reads | Same as SOS |

Replica is **Phase 3 done**. Money-rail / SOS work does **not** require rebuilding it. It **does** require running the pack/publish/wipe checklist whenever L1 contracts are redeployed.

See `tasks/prd-money-rail.md` § “Replica — do we need to update it?” and README **Network reset procedure**.

## Pack (operator)

```bash
FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh
# → replica/config/genesis.json + rollup.json (gitignored)
# Copy those into fortel2-replica/config/ and push.
```

**While the 2026-07-22 Sepolia deploy is pinned through Phase 6:** do not pack/publish unless you actually redeployed. Packing without redeploy only copies the current (unchanged) artifacts.

Do **not** put `.env.sepolia`, role keys, or JWTs here. fortel2-replica generates its own JWT on disk / via `JWT_SECRET`.
