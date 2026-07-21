# Phase 3 — ForteL2 replica (Render / verifier)

Stock **op-geth + op-node** in **verifier** mode. Derives L2 chain **852** from Ethereum Sepolia L1 using the Phase 2b `genesis.json` / `rollup.json`.

## Sync model (MVP)

| Path | What it follows | Needs Mac mini open? |
|---|---|---|
| **L1 derivation (default)** | Safe / finalized (and unsafe once batches are on L1) | **No** |
| Sequencer P2P (US-032 stretch) | Faster unsafe head | Tunnel only (Tailscale/cloudflared) |

Containers are for **Render** (or any remote host). The Mac mini Phase 1/2c stack stays **native binaries** — do not require Docker on that workstation to close US-031.

## Image pins

Match Phase 1 toolchain where possible:

| Component | Image |
|---|---|
| op-node | `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-node:v1.19.2` |
| op-geth | `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-geth:v1.101702.2` |

## Pack artifacts (Mac mini)

```bash
FORTEL2_ENV=.env.sepolia ./scripts/pack-replica-artifacts.sh
# writes replica/config/{genesis.json,rollup.json} (gitignored)
```

## Local compose smoke (optional host with Docker)

```bash
cp replica/.env.example replica/.env
# set L1_RPC_URL to QuickNode Sepolia HTTPS (never commit)
cd replica && docker compose up -d
# EL :9545  op-node RPC :9547
```

## Render

1. Create a **Docker** web/private service from this repo (`replica/Dockerfile` context = `replica/`).
2. Set secrets: `L1_RPC_URL` (QuickNode), optional `JWT_SECRET` (32+ hex; auto-generated if empty).
3. Mount or bake `config/genesis.json` + `config/rollup.json` (from pack step — commit a **release copy** only if you accept public genesis; prefer Render secret files / build arg from CI).
4. Expose HTTP carefully — default is a Render **private service** (`pserv` in `render.yaml`). Do not publish an open eth_sendRawTransaction surface without a fresh policy review.
5. Disk: attach a persistent disk at `/data` for op-geth.
6. Secret files (required): mount packed `genesis.json` and `rollup.json` at `/config/genesis.json` and `/config/rollup.json`.

`render.yaml` is a starting Blueprint; adjust plan/disk size for your account.

## Sync check (from Mac mini)

With the Sepolia sequencer running locally and the replica reachable from this machine:

```bash
FORTEL2_ENV=.env.sepolia \
  REPLICA_L2_RPC_URL=https://… \
  REPLICA_NODE_RPC_URL=https://… \
  ./scripts/replica-sync-check.sh
```

Compares replica heads to local `L2_RPC_URL` / `L2_NODE_RPC_URL`. Does not print private keys or full RPC URLs with embedded tokens (uses `redact_rpc_url` helpers).

**Reachability note:** `render.yaml` defaults to a **private service** (`pserv`). The Mac mini cannot hit that URL over the public internet. For US-031 verification pick one:

1. Temporary **web** service (restrict at the edge / tear down after check), or
2. Tailscale / cloudflared tunnel to the private service (also the US-032 path), or
3. Run `docker compose` smoke on any Docker-capable host you can reach, then promote the same image to Render.

Do not leave an unauthenticated public `eth_sendRawTransaction` surface up.

## Tear-down

- Render: delete the service / Blueprint — does **not** touch Mac mini `DATA_DIR` / `data-sepolia`.
- Local compose: `docker compose -f replica/docker-compose.yml down` (add `-v` only if you intend to wipe replica datadir).
