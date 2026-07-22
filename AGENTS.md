# AGENTS.md — ForteL2

Guidance for coding agents working in this repository.

## What this is

Personal **OP Stack L2 learning rollup** on a single Apple Silicon Mac. Phase 1 runs **native binaries only** (no Docker, OrbStack, or Kurtosis on this host). Throwaway Anvil keys only for local chain **901** — never real funds. Phase **2a** scaffolds Sepolia (L2 chain **852**) without broadcasting; funded Sepolia keys stay operator-local in `.env.sepolia`.

Canonical product/roadmap context: `tasks/prd-l2-learning-chain.md` and `README.md`.

## Non-negotiables

- **No containers** on this workstation for Phase 1 (see Phase 0 verdict in `tasks/spike-notes.md`).
- **Never commit** `.env`, `.env.sepolia`, private keys, JWT secrets, or live datadir contents.
- **Never ask the operator to paste private keys** into chat; never write keys into committed files.
- **Loopback only** for L2 RPCs, the guestbook HTTP server, and the pipeline viewer (`127.0.0.1` / `localhost`). Sepolia **L1** may be remote HTTPS (`assert_sepolia_rpc_urls`).
- Prefer **small, reversible diffs**. Phase **3** (Render replica) is done; do not expand into Phase **3a** (native Mac L1, after 4–6), **3b**, or **4+** unless asked.
- Keep `L1_BLOCK_TIME >= L2_BLOCK_TIME` on the **local Anvil** stack (both `2` today) or the sequencer hits Fjord drift / `NoTxPool` — `assert_block_times` enforces this on start. Sepolia L1 is ~12s; local L2 may stay 2s.
- **`scripts/lib.sh` `start_bg` / `stop_bg` are privileged.** Any edit needs human review (see `.github/CODEOWNERS`), even when the rest of a change is AI-authored. (`serve_static_loopback` is not privileged process control.)

## Layout

| Path | Role |
|---|---|
| `scripts/` | Start/stop/deploy helpers; shared logic in `scripts/lib.sh` |
| `contracts/` | Foundry project (`Guestbook` demo) |
| `dapp/` | Static guestbook UI (`index.html`, `styles.css`, `app.js`, `config.js`) |
| `viewer/` | Phase 1c pipeline viewer (sequencer / batcher / proposer / aggregate) |
| `deployments/` | Phase 1 checked-in addresses + local `.deployer` artifacts |
| `deployments/sepolia/` | Phase 2 deploy tree (separate; `.deployer/` gitignored) |
| `replica/` | Phase 3 pack output + pointer to [fortel2-replica](https://github.com/StephenForte/fortel2-replica) (Docker lives there) |
| `config/` | L1 chain config fragments |
| `bin/` | Symlinks to built OP Stack binaries (gitignored) |
| `.env.sepolia.example` | Phase 2a Sepolia template (no keys); load via `FORTEL2_ENV=.env.sepolia` |

Runtime data defaults to `DATA_DIR` outside Dropbox (`~/src/fortel2/data`). Sepolia uses a separate `DATA_DIR` (see `.env.sepolia.example`).

## Everyday commands

```bash
cp .env.example .env          # once
./scripts/start-all.sh
./scripts/status.sh
./scripts/smoke-transfer.sh
./scripts/deposit-eth.sh      # Phase 1b L1→L2 (ADMIN)
./scripts/withdraw-initiate.sh && ./scripts/withdraw-prove.sh && ./scripts/withdraw-finalize.sh
./scripts/deploy-guestbook.sh # after Guestbook ABI changes
./scripts/serve-dapp.sh       # http://127.0.0.1:8080
./scripts/serve-viewer.sh     # http://127.0.0.1:8081 pipeline viewer
FORTEL2_ENV=.env.sepolia ./scripts/serve-viewer.sh  # same UI against Sepolia L1 + local L2 852
./scripts/demo-checklist.sh   # auto smokes + Phase 1→1c verification checklist
FORTEL2_ENV=.env.sepolia ./scripts/sepolia-fund-check.sh
FORTEL2_ENV=.env.sepolia ./scripts/02-deploy-contracts-sepolia.sh  # Phase 2b after ADMIN funded
FORTEL2_ENV=.env.sepolia ./scripts/start-all-sepolia.sh            # Phase 2c (no Anvil)
FORTEL2_ENV=.env.sepolia ./scripts/deposit-eth-sepolia.sh
FORTEL2_ENV=.env.sepolia ./scripts/sepolia-rpc-check.sh          # Phase 2d QuickNode/public L1 check
FORTEL2_ENV=.env.sepolia ./scripts/stop-all-sepolia.sh
FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh      # Phase 3: genesis/rollup → replica/config/ (publish to fortel2-replica)
# FORTEL2_ENV=.env.sepolia REPLICA_L2_RPC_URL=… ./scripts/replica-sync-check.sh
./scripts/stop-all.sh
./scripts/reset.sh            # wipe datadir + redeploy next start (needed after portal delay overrides)
```

## Tests (run before claiming done)

```bash
# Solidity
export PATH="$HOME/.foundry/bin:$PATH"
cd contracts && forge test

# Script helpers (no chain required)
./scripts/test-helpers.sh

# Pipeline viewer + dApp pure helpers
node --test viewer/lib.test.js dapp/lib.test.js

# Bridge helpers (viem deps)
(cd scripts/bridge && npm ci && node --test lib.test.js)
```

CI runs the same suite on every PR (`.github/workflows/ci.yml`).

Install Solidity deps once: `cd contracts && forge install foundry-rs/forge-std --no-git --shallow`.

## dApp / viewer conventions

- Static ESM only — no bundler. Guestbook config from `deploy-guestbook.sh`; viewer config from `gen-viewer-config.sh`.
- Render user content with `textContent` (never `innerHTML` for on-chain strings).
- Validate `GUESTBOOK_ADDRESS` with `isAddress` before contract calls.
- Pin wallet fee floors for quiet local base fees (see `dapp/app.js`).
- Message length is **UTF-8 bytes** (contract `MAX_TEXT_BYTES=280`), not HTML `maxlength` characters.
- After contract changes: redeploy, then MetaMask **Delete activity and nonce data** if txs stick post-reset.
- Pipeline viewer: four panels (Aggregate includes mempool pending/queued); `connect-src` comes from the HTTP `Content-Security-Policy` header (`viewer/.csp-header` via `serve-viewer.sh`), not a hard-coded Sepolia host in `index.html`. `viewer/config.js` is gitignored.

## Security expectations (learning stack)

- Keys in `.env.example` are **public Foundry test keys** — fine for local Anvil chain **901**; never fund them on public nets. Broadcast scripts refuse those keys when `L2_CHAIN_ID != 901` (including Sepolia L2 **852**).
- Sepolia keys live only in local `.env.sepolia` (gitignored). Agents must not request, log, or commit them.
- Treat guestbook storage as unbounded demo state (DoS/growth is acceptable locally; do not ship as production).
- Do not expose Anvil / op-geth / dApp / viewer beyond loopback without an explicit hardening task (Phase 1b US-012).
- `ethers` is **vendored** under `dapp/vendor/` and copied into `viewer/vendor/` (CSP `script-src 'self'`). Do not use a symlink for the viewer copy — static serve roots at `viewer/` and symlink-as-text checkouts break the import. Bump both files via `dapp/vendor/README.md` — do not reintroduce CDN script tags.

## When editing scripts

- Source `scripts/lib.sh`; use `require_bin`, `redact_rpc_url`, `wait_for_rpc` (logs redacted URLs), `start_bg` / `stop_bg`, `serve_static_loopback`, `assert_loopback_url` / `assert_local_rpc_urls` / `assert_sepolia_rpc_urls` / `assert_l2_loopback_urls`, `assert_block_times`, `refuse_foundry_defaults_unless_local_l2`.
- Phase 2 scripts (when added) must set/require `FORTEL2_ENV=.env.sepolia` and call `assert_sepolia_rpc_urls` — never `assert_local_rpc_urls` against a remote L1.
- Validate addresses with `is_eth_address` / `require_eth_address`.
- Keep `set -euo pipefail` and avoid printing private keys.

## Docs to update with behavior changes

- Operator-facing behavior → `README.md`
- Roadmap / acceptance criteria → `tasks/prd-l2-learning-chain.md`
- Agent workflow / guardrails → this file

## Cursor Cloud specific instructions

This repo was authored for macOS/`darwin-arm64`, but the Cursor Cloud VM is **Linux `x86_64`**. The toolchain and built OP Stack binaries are installed into the VM snapshot during environment setup, so a fresh session already has them — the startup update script does not rebuild anything.

- **Do NOT `cp .env.example .env` here.** `.env.example` hard-codes `/Users/steveforte/...` paths that fail on Linux (`mkdir: cannot create directory '/Users'`). A Linux `.env` already exists (gitignored) pointing at `FORTEL2_ROOT=/workspace`, `BIN_DIR=/workspace/bin`, `DATA_DIR=/home/ubuntu/src/fortel2/data`, `DEPLOY_DIR=/workspace/deployments/.deployer`. If it is ever missing, recreate it from `.env.example` with those four path overrides (keys are the public Foundry test keys).
- **Toolchain locations** (all on PATH via `~/.bashrc`): Foundry `~/.foundry/bin`, Go 1.26.5 `~/go1.26/bin`, `just` + mikefarah `yq` `~/.local/bin`. Note `/usr/bin/yq` is the unrelated Python `yq`; the mikefarah `yq` (needed by `just build-superchain-go`) must precede it on PATH.
- **OP Stack binaries** are built from source under `~/src/fortel2/{optimism,op-geth}` and symlinked into `/workspace/bin` (`op-geth`, `op-node`, `op-batcher`, `op-proposer`, plus the `op-deployer` release binary). `scripts/lib.sh` prepends `$BIN_DIR` and `$HOME/.foundry/bin` to PATH, so the scripts find them. To rebuild after a version bump: `just build-superchain-go && just op-node op-batcher op-proposer` in the optimism tree, `make geth` in op-geth.
- **Running the stack:** `./scripts/start-all.sh` (see README/AGENTS everyday commands). Processes are daemonized via a Python double-fork in `start_bg`, so they survive shell/agent teardown; check `./scripts/status.sh` and `data/logs/*.log`. `./scripts/stop-all.sh` / `./scripts/reset.sh` to stop / wipe.
- **dApp reads without a wallet:** `dapp/app.js` calls `refresh()` on load through a read-only `JsonRpcProvider`, so `./scripts/serve-dapp.sh` (http://127.0.0.1:8080) shows on-chain guestbook entries even with no MetaMask. Ethers is vendored under `dapp/vendor/` (CSP `script-src 'self'`).
- **Pipeline viewer:** `./scripts/serve-viewer.sh` (http://127.0.0.1:8081) polls L1/L2/op-node; run after deploy so `gen-viewer-config.sh` can read `rollup.json`.
- **Tests / lint:** Solidity `cd contracts && forge test`; shell helpers `./scripts/test-helpers.sh`; viewer + dApp `node --test viewer/lib.test.js dapp/lib.test.js`; bridge `(cd scripts/bridge && npm ci && node --test lib.test.js)`; L2 end-to-end `./scripts/smoke-transfer.sh`. There is no dedicated linter wired up (`forge fmt --check` is the closest option).
