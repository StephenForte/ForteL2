# Phase 3 replica — moved

The verifier package (Dockerfile, compose, Render Blueprint, baked genesis/rollup) lives in a **separate repo** so friends and Render only clone what they need:

**https://github.com/StephenForte/fortel2-replica**

| Audience | What to use |
|---|---|
| Friends / Render | Clone `fortel2-replica` — root `Dockerfile`, `docker compose`, no keys |
| Operator (this repo) | `./scripts/pack-replica-artifacts.sh` then publish `replica/config/{genesis,rollup}.json` into that repo when Sepolia genesis changes |
| Sync check | `./scripts/replica-sync-check.sh` (still here; needs reachable replica RPC) |

## Pack (operator)

```bash
FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh
# → replica/config/genesis.json + rollup.json (gitignored)
# Copy those into fortel2-replica/config/ and push a release there.
```

Do **not** put `.env.sepolia` or role keys in `fortel2-replica`.
