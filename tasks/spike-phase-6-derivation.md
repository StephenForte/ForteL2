# Phase 6 spike notes — derivation (US-060)

**Date:** 2026-08-04  
**PRD (output):** `tasks/prd-phase-6-derivation.md`  
**Code (read-only reuse):** `batcher/` · **Spike tool:** `batcher/cmd/decode-full/` (throwaway; do not extend `batcher/*.go`)

## Specs consulted

| Topic | URL |
|---|---|
| Derivation pipeline overview | https://specs.optimism.io/protocol/derivation.html |
| Batcher tx / frames / channels | https://specs.optimism.io/protocol/derivation.html#batcher-transaction-format |
| Channel bank / inbox rules | https://specs.optimism.io/protocol/derivation.html#channels |
| Singular batches | https://specs.optimism.io/protocol/derivation.html#singular-batch-format |
| Span batches | https://specs.optimism.io/protocol/derivation.html#span-batch-format |
| Deposit tx / L1-info | https://specs.optimism.io/protocol/deposits.html |
| Batch inbox address convention | https://specs.optimism.io/protocol/configurability.html#batch-inbox-address |
| Batcher submitter (context) | https://specs.optimism.io/protocol/batcher.html |

## Wire format recap (calldata path — matches Phase 4)

```text
L1 tx.to   = batch_inbox_address  (0x00 || keccak256(bytes32(chainId))[:19])
L1 tx.from = SystemConfig batcher EOA (batcherHash on L1)
input      = version_byte (0x00) ++ frame+

frame      = channel_id(16) || frame_number(u16 BE) || frame_data_length(u32 BE) || frame_data || is_last(0|1)
channel    = zlib( concat( rlp(typedBatchBytes)… ) )   # raw zlib on ForteL2; no Fjord channel-version prefix observed
typedBatch = batch_type(0x00 singular | 0x01 span) ++ rlp(fields…)
```

Fjord **brotli** channel encoding and **channel-version** prefix were **not** observed on either chain in this spike. Re-check `rollup.json` fork schedule before US-061 ships.

## What was decoded

### Local Anvil L1 (chain **900**) → L2 **901**

| Field | Value |
|---|---|
| L1 RPC | `http://127.0.0.1:8545` (persisted Anvil state in VM) |
| Batch inbox | `0x00289c189bee4e70334629f04cd5ed602b6600eb` |
| Batcher EOA | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| Example tx | `0x5548fd9463208e10a1bbcc0f544f78cc789d02b8461fb8f5b6da8c2629e90495` (L1 block 25) |
| Channel id | `0x5b379c8de994b73c05e53065ad5acdf9` |
| Frames | 1 (is_last=true, zlib header `0x78da`) |
| Batches | **15** × type `0x00` singular |
| Span batches | **0** in sampled local txs |

**Relate to reference L2 blocks (stock op-batcher log + batch parent hashes):**

| Batch index | Singular `parent_hash` (→ L2 block *N* hash) | L2 block *N+1* (from op-batcher log) | Match |
|---|---|---|---|
| 0 | `0x0dc87d02…` (genesis) | `:1` `0x030b09a2…` | parent of block 1 ✓ |
| 1 | `0x030b09a2…` | `:2` `0x48302da2…` | ✓ |
| … | … | … | ✓ |
| 14 | `0x24eae2e3…` | `:15` `0x42f38279…` | ✓ |

op-batcher log for this channel: `oldest_l2=…:1` `latest_l2=…:15` — consistent with decoded batch count.

Additional local txs decoded (all singular): `0x8fa53873…` (6 batches), `0x5937b59a…` (6 batches).

Phase 4 captured fixture (`0x97de57af…`, 6 batches, epoch=26223) still decodes via unit test when input hex is supplied; that tx is **not** in the current Anvil snapshot.

### Sepolia L1 (chain **11155111**) → L2 **852**

| Field | Value |
|---|---|
| L1 RPC | `https://ethereum-sepolia-rpc.publicnode.com` (single-tx fetch OK; bulk block scan **403** from worker VM) |
| Batch inbox | `0x007238ac625e3e5369739fa5b9cdbf61320b237c` (convention for chain id 852) |
| Batcher EOA | `0x3d54fd6353cd66d143fb94d178c9eeb1ae98a31d` (from `SystemConfig.batcherHash()`) |
| Example tx | `0xd76f10dab27dde896ea49614d12308598a5587e02fb8f983c693aabb84e1f8a6` (nonce 4081, L1 block 11417779) |
| Channel id | `0x52fa13df050955fa70e4082ca2fd24dd` |
| Frames | 1, zlib `0x78da` |
| Batches | **150** × type `0x00` singular |
| Span batches | **0** in 3 recent txs sampled (nonces 4081, 4080, 4079 area) |

**L2 block relation (Sepolia):** without a live reference `op-node` in the worker VM, mapping uses the derivation convention: singular batch *i* in a channel describes **L2 block number = prior derived tip + 1**, and `parent_hash` must equal the reference L2 block hash at that parent height. First batch in the example channel has `parent=0x126d7a64…`, `timestamp=1785851544`, `epoch=11417748` (L1 origin block number). **Operator verification:** with Sepolia stack up, `cast rpc optimism_syncStatus` at the batch’s first inclusion L1 block and compare `safe_l2` / per-block `eth_getBlockByNumber` headers to decoded parent/timestamp fields.

Additional Sepolia txs (Blockscout inbox listing + publicnode single fetch): `0x16f05cec…` (162 singular), `0x23a90da7…` (156 singular).

## Gaps hit (US-061 scope, not spike)

| Gap | Notes |
|---|---|
| **Span batch decode** | Type byte `0x01` not seen on recent ForteL2 Sepolia history; still required for spec completeness — import/decode from optimism monorepo or spec, do not guess |
| **Fjord brotli channels** | Not observed; spike tool errors if zlib inflate fails |
| **Multi-frame channels** | Local + Sepolia samples used single-frame channels; reassembly logic exists in `batcher.JoinFrameData` |
| **Deposit derivation** | User-deposit txs via Portal + L1-info deposit tx reconstruction not implemented |
| **Payload attributes → block hash** | Singular batch fields decode; full L2 block hash needs Engine API or EL execution (US-061) |
| **Bulk L1 history scan** | Worker VM public RPC returns 403 on heavy `eth_getBlockBy*` loops; operator/Mac QuickNode fine for US-061 |

## Decisions (recorded in `tasks/decisions.md`)

| ID | Decision |
|---|---|
| **D-T2-1** | **Verifier-only first** — US-061 builds an offline/L1-driven derivation verifier; US-062 sequencer stub stays gated |
| **D-T2-2** | **`derivation/` Go module** — imports `batcher` decode helpers; does not extend `batcher/*.go` |
| **D-T2-3** | **Comparison window** — see PRD US-061; primary match on `safe_l2` block number + hash for a documented inclusive range |

## Spike tooling

```bash
cd batcher
go run ./cmd/decode-full \
  -rpc "$L1_RPC_URL" \
  -tx 0x5548fd9463208e10a1bbcc0f544f78cc789d02b8461fb8f5b6da8c2629e90495 \
  -inbox 0x00289c189bee4e70334629f04cd5ed602b6600eb

# Sepolia (operator / QuickNode)
go run ./cmd/decode-full \
  -rpc "$L1_RPC_URL" \
  -tx 0xd76f10dab27dde896ea49614d12308598a5587e02fb8f983c693aabb84e1f8a6 \
  -inbox 0x007238ac625e3e5369739fa5b9cdbf61320b237c
```

## Operator follow-up

- [ ] Re-run `decode-full` against operator QuickNode L1 RPC and confirm Sepolia parent hashes vs live `op-geth` headers for one channel (852).
- [ ] Capture one **span-batch** tx hash if stock op-batcher ever emits type `0x01` on 852 (none in Aug 2026 sample).
- [ ] With `start-all-sepolia.sh` up: record `optimism_syncStatus` + L2 header for the window covered by a chosen batch tx (golden fixture for US-061 tests).

## Non-goals (confirmed for spike)

Production performance, P2P, full EVM reimplementation, Sepolia redeploy/spend, modifying stock `op-node` in place.
