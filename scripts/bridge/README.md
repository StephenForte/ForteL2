# Bridge helpers (Phase 1b)

Node ESM helpers for OP Stack **prove** / **finalize** using `viem` op-stack actions.

**Always invoke `node` from this directory** (`cd scripts/bridge && node …`). `viem` resolves from this package’s `package.json` (`"type": "module"`, viem 2.51.0). Running `node scripts/bridge/finalize.mjs` from the repo root fails with `ERR_MODULE_NOT_FOUND: viem`.

viem 2.51.0 is the lowest release whose `getGames` / `buildProveWithdrawal` source treats game types 4, 5, 7 and 9 as super-root games: `l2SequenceNumber` is kept as a timestamp (`usesSuperRoots`) and the output-root proof is built at the L2 block for that timestamp. 2.50.4 reads `l2SequenceNumber` but still proves at that value as a block number.

## Local Anvil (L2 901)

- `../withdraw-initiate.sh` — L2 `L2ToL1MessagePasser.initiateWithdrawal`
- `../withdraw-prove.sh` → `prove.mjs` (`assert_local_rpc_urls`; loopback L1)
- `../withdraw-finalize.sh` → `finalize.mjs` (resolve game + Anvil time-warp + finalize)

## Sepolia (L2 852, L1 11155111)

Remote L1 is required. The Anvil wrappers refuse it (`assert_local_rpc_urls`). Use:

- `../withdraw-initiate-sepolia.sh` → L2 `initiateWithdrawal` (loopback L2, remote Sepolia L1, no Foundry default keys)
- `../withdraw-prove-sepolia.sh` → `prove.mjs` (`assert_sepolia_rpc_urls`)
- `../withdraw-finalize-sepolia.sh` → `finalize.mjs` real-clock mode

A type-9 game is selected by L2 timestamp (`l2SequenceNumber`), and the proof is built at `(timestamp − genesis.l2_time) / block_time` from `rollup.json`. Type 8 still uses the L2 block number. `FORTEL2_ALLOW_FORK_PROVE=1` accepts an artifact stamped `l1ChainId=11155111` only when the env L1 is `900852` and `L1_RPC_URL` is loopback. A non-loopback L1 whose chain id is not 11155111 is refused.

Both wrappers:

- make the artifact path **absolute** so a `cd` cannot lose it
- run `node` in a subshell from `scripts/bridge` so viem resolves from any caller cwd
- accept `--dry-run` (on-chain reads + portal `eth_call`; **sends nothing**)

```bash
FORTEL2_ENV=.env.sepolia ./scripts/withdraw-prove-sepolia.sh --dry-run
FORTEL2_ENV=.env.sepolia ./scripts/withdraw-finalize-sepolia.sh --dry-run
```

`--dry-run` prints `readiness: <verdict>`:

| Verdict | Meaning | prove exit | finalize exit |
|---|---|---|---|
| `not-proven` | expected next prove step | 0 | nonzero |
| `proven-waiting-until-<ts>` | proven; L1 head not yet `resolvedAt + disputeGameFinalityDelaySeconds` | nonzero | nonzero |
| `finalizable` | expected next finalize step | nonzero | 0 |
| `already-finalized` | portal `finalizedWithdrawals` is true | nonzero | nonzero |

### Real-clock finalize (no Anvil warp)

When `L1_CHAIN_ID=11155111`, `finalize.mjs` **never** calls `evm_increaseTime` or `evm_mine` (`lib.mjs` `refuseAnvilWarp` / `mineBlocks` throw). It polls the L1 head timestamp until the dispute game is `DEFENDER_WINS` (2) **and** `resolvedAt + disputeGameFinalityDelaySeconds` (both read on-chain) have passed. It does not submit `resolve` / `resolveClaim` — hourly `resolve-games-sepolia.sh` owns that.

Max wait: `FINALIZE_REAL_CLOCK_MAX_WAIT_MS` (default **7200000** = 2h). Poll interval: `FINALIZE_REAL_CLOCK_POLL_MS` (default 12000). Exceeding the cap exits nonzero; raise the env var and re-run.

Readiness uses the **later** of `resolvedAt + disputeGameFinalityDelaySeconds` and `proofTimestamp + proofMaturityDelaySeconds` (both on-chain). Proving against an already-resolved game starts the proof-maturity clock after `resolvedAt`.

`withdraw-prove-sepolia.sh` defaults `PROVE_WAIT_MS` to **3900000** (65 min) because the Sepolia proposer posts about once an hour. The Anvil wrapper keeps the 180s default. Override with `PROVE_WAIT_MS`.

Artifacts may carry `l1ChainId` / `l2ChainId`. A 901 artifact on 852 (and vice versa) is refused. Legacy artifacts without those fields are allowed; prove/finalize stamp them on write.

```bash
cd scripts/bridge && npm ci
```

`node_modules/` is gitignored; lockfile is committed.
