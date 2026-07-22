# Phase 3 replica — operator bridge only

Runtime (Dockerfile, compose, Render Blueprint, baked genesis/rollup) lives in a **separate repo**:

**https://github.com/StephenForte/fortel2-replica**

This directory is a thin staging area for the Mac operator — not a second node package.

| Audience | What to use |
|---|---|
| Friends / Render | Clone `fortel2-replica` — root `Dockerfile`, `docker compose`, no keys |
| Operator (this repo) | `./scripts/pack-replica-artifacts.sh` → publish `replica/config/{genesis,rollup}.json` into fortel2-replica after a Sepolia redeploy |
| Sync check | `./scripts/replica-sync-check.sh` (needs reachable replica RPC) |

## Pack (operator)

```bash
FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh
# → replica/config/genesis.json + rollup.json (gitignored)
# Copy those into fortel2-replica/config/ and push.
```

Do **not** put `.env.sepolia`, role keys, or JWTs here. fortel2-replica generates its own JWT on disk / via `JWT_SECRET`.
