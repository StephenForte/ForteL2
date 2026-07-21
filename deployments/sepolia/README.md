# Sepolia deploy artifacts (Phase 2)

Separate from Phase 1 `deployments/.deployer/` and `deployments/deployments.json`.

| Path | Role |
|---|---|
| `.deployer/` | Local `op-deployer` workdir (gitignored) — intent, state, genesis, rollup |
| `deployments.json` | Checked-in L1 proxy addresses after a successful Phase 2b apply (added in 2b) |

Use with `FORTEL2_ENV=.env.sepolia` so `DEPLOY_DIR` points here. Do not copy Phase 1 Anvil artifacts into this tree.
