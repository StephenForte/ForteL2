# Phase 3 replica — operator bridge only

Runtime (Dockerfile, compose, Render Blueprint, baked genesis/rollup) lives in a **separate repo**:

**https://github.com/StephenForte/fortel2-replica**

This directory is a thin staging area for the Mac operator — not a second node package.

| Audience | What to use |
|---|---|
| Friends / Render | Clone `fortel2-replica` — root `Dockerfile`, `docker compose`, no keys |
| Operator (this repo) | `./scripts/pack-replica-artifacts.sh` → publish `replica/config/{genesis,rollup}.json` into fortel2-replica after a Sepolia redeploy |
| Sync check | `./scripts/replica-sync-check.sh` (needs reachable replica RPC). The Render deploy is a **private service** with no Mac-reachable URL and no SSH tunneling — use the dashboard **Web Shell** on the running instance instead: python3/urllib JSON-RPC against `localhost:10000` (EL) / `:9545` (op-node); no curl in the image. See `tasks/decisions.md` D-0016. |

## Consumers (do not forget)

| Consumer | Role | Needs genesis republish? |
|---|---|---|
| Render / friend verifiers | Derive L2 from Sepolia L1 | **Yes** on every Sepolia redeploy (Phase 7+) |
| SettlementOS | **Read** RPC over Render private network (`http://fortel2-replica:10000`). **Writes** use Cloudflare Access `https://fortel2-write.ente.ltd` (D-0035), not the replica. | Only if redeploy changed genesis |
| settlementos-explorer | Optional indexed reads | Same as SOS |

Replica is **Phase 3 done**. Money-rail / SOS work does **not** require rebuilding it. It **does** require running the pack/publish/wipe checklist whenever L1 contracts are redeployed.

After SOS-heavy demos, if Mac and replica tips diverge, run `FORTEL2_ENV=.env.sepolia REPLICA_L2_RPC_URL=… ./scripts/replica-sync-check.sh` (set `REPLICA_L2_RPC_URL` to a reachable replica endpoint). For the current private-service Render deploy there is no such endpoint — compare heads via the Web Shell per D-0016 instead.

See `tasks/prd-money-rail.md` § “Replica — do we need to update it?” and README **Network reset procedure**.

## Pack (operator)

```bash
FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh
# → replica/config/genesis.json + rollup.json (gitignored)
# Copy those into fortel2-replica/config/ and push.
```

**While the 2026-07-22 Sepolia deploy is pinned through Phase 6:** do not pack/publish unless you actually redeployed. Packing without redeploy only copies the current (unchanged) artifacts.

Do **not** put `.env.sepolia`, role keys, or JWTs here. fortel2-replica generates its own JWT on disk / via `JWT_SECRET`.

## Patch staging (fortel2-replica)

Operator-only: apply pending Docker healthcheck fix in the sibling repo:

```bash
cd ../fortel2-replica   # or your clone path
git checkout -B cursor/healthcheck-long-geth-recovery-f3d9
bash ../ForteL2/replica/patches/apply-healthcheck-fix.sh
# expects 18 unit tests, then commits + pushes
```

Or: `git apply ../ForteL2/replica/patches/healthcheck-long-geth-recovery.patch`

