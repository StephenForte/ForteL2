# Bridge helpers (Phase 1b)

Node ESM helpers for OP Stack **prove** / **finalize** using `viem` op-stack actions. Bash wrappers:

- `../withdraw-initiate.sh` — L2 `L2ToL1MessagePasser.initiateWithdrawal`
- `../withdraw-prove.sh` → `prove.mjs`
- `../withdraw-finalize.sh` → `finalize.mjs` (resolve game + Anvil time-warp + finalize)

```bash
cd scripts/bridge && npm ci
```

`node_modules/` is gitignored; lockfile is committed.
