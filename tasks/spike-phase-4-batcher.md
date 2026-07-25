# Phase 4 spike notes — custom batcher

**Date:** 2026-07-24  
**PRD:** `tasks/prd-phase-4-batcher.md`  
**Code:** `batcher/`

## Specs consulted

- https://specs.optimism.io/protocol/batcher.html — minimal submit loop
- https://specs.optimism.io/protocol/derivation.html — batcher tx / frame / channel / batch encodings

## Wire format (calldata path)

```text
L1 tx.to = BatchInbox
L1 tx.from = SystemConfig batcher EOA
input = version_byte (0) ++ frame+

frame = channel_id(16) || frame_number(u16 BE) || frame_data_length(u32 BE) || frame_data || is_last(0|1)
channel bytes = zlib( rlp( concatenated singular-or-span batch encodings ) )   # pre-Fjord channel
```

Fjord adds a versioned channel encoding (possible brotli). Confirm against live `rollup.json` / fork schedule before US-041 compression work.

## Decisions (US-040)

| Question | Decision |
|---|---|
| Language | **Go** — matches OP Stack tooling; native on Apple Silicon |
| Repo layout | `batcher/` in ForteL2 (not a separate repo) |
| DA | **Calldata only** for v1 (matches `BATCHER_DA_TYPE=calldata`) |
| First batch type | **Singular batches** (version 0); span batches only if local submit fails fork checks |
| Sepolia | Decode against Sepolia history when `.env.sepolia` available; **submit** only after local US-042 |

## Done in this spike slice

- [x] Frame encode/decode + version-0 payload parse (`batcher/frame.go`)
- [x] Unit tests (`go test ./...`)
- [x] Read-only CLI `batcher/cmd/decode-l1` for one L1 tx
- [x] Operator: decode ≥1 real ForteL2 batcher tx (local Anvil L1 900) — frame summary below

## Operator follow-up (real decode) — ✅ 2026-07-24

Local Anvil stack. `cast tx` confirmed batcher → Batch Inbox; payload decoded (version 0, one frame).

```text
tx=0x97de57afb4a9c0528e3ea4002ac972468fa82a8cdd0d81a4af042e035bef01b3
from=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
to=0x00289C189bEE4E70334629f04Cd5eD602B6600eB
l1_chain_id=900
batcher_tx_version=0
frames=1
channel_ids=0x6184cc6618ec85c54b8b50ddc6d427dc
frame_number=0
data_len=294
is_last=true
notes=Decoded from cast tx input (supermini live stack). batcher/ CLI not yet on /Users/steveforte/ForteL2 until Phase 4 scaffold is committed/pushed and pulled.
```

## US-041 notes (done)

- Channel body on local ForteL2: **raw zlib** (header `78da`), not Fjord `version++compress`.
- Channel stream: `zlib( concat( rlp(typedBatchBytes)… ) )` where typedBatch = `0x00 ++ rlp(singular fields)`.
- Live fixture decompresses to **6** batches; first is singular (empty txs OK).
- Span batch encode **deferred** until US-042 proves singular-only is rejected.

## US-042 notes (done 2026-07-24)

- `cmd/submit-loop` polls `optimism_syncStatus`, builds singular zlib channels, posts version-0 calldata to Batch Inbox.
- Duplicate safeguard: in-memory `lastSubmitted`; init from `safe` on start.
- Live local Anvil: stock batcher stopped; custom `-once` posted L2 17..22; **safe 16→22** within wait window; stock `05-start-batcher.sh` resumes afterward.
- Side fix: local `02-deploy-contracts.sh` now sets `faultGameClockExtension` (same constraint as Sepolia) so fresh `reset`/`start-all` works with current op-deployer.

## US-043 / US-044 (done)

- Local: `USE_CUSTOM_BATCHER=1 ./scripts/05-start-batcher.sh` builds `$BIN_DIR/fortel2-batcher` and starts it under pid name `op-batcher` (stop-all compatible). Default path unchanged.
- Sepolia: same flag **plus** `CONFIRM_CUSTOM_BATCHER_SEPOLIA=1`; poll defaults to credit-budget **12s**. Documented max ~15 min + revert to stock.
- No `lib.sh` `start_bg`/`stop_bg` changes.

## US-045 — What a batch is (operator write-up)

### Anatomy (calldata path we rebuilt)

1. **L2 block** (sequencer) includes an L1-info deposit plus optional user txs.
2. **Singular batch** = type `0x00` + RLP(`[parent_hash, epoch_number, epoch_hash, timestamp, user_txs]`). Deposit txs are stripped; epoch comes from the L1-info deposit.
3. **Channel** = zlib over a concatenation of RLP(typed-batch-bytes). Local ForteL2 uses **raw zlib** (no Fjord channel-version prefix).
4. **Frames** slice the channel (`channel_id`, frame number, data, `is_last`).
5. **Batcher tx** = version byte `0` + frames, sent to the **Batch Inbox** from the SystemConfig batcher EOA.

Span batches (type `1`) appear on the wire from stock; our learning builder submits **singular only**, which op-node accepted on local 901.

### Why safe lags unsafe

- **Unsafe** = tip the sequencer has built (local EL).
- **Safe** = tip that can be **derived from L1** batch data.
- Until a channel covering those L2 blocks is posted and included on L1, and op-node derives it, safe stays behind. That lag is normal; a healthy batcher keeps it bounded.

### What breaks if the batcher stops

- Sequencer keeps producing **unsafe** blocks.
- **Safe** freezes → withdrawals that need a safe/finalized view stall; replicas that only follow L1 also stop advancing.
- Restarting a correct batcher (stock or custom) posts the gap; derivation catches up. Bad channels are dropped by derivation rules — prefer abort + stock over forcing through.

### Lessons from Phase 4

- Spec-first decode (US-040) beat guessing wire format.
- Matching live compression (raw zlib) mattered more than implementing every fork day one.
- Duplicate submission is mostly “remember last submitted / start from safe.”
- Script integration is an env flag; Sepolia stays confirm-gated because L1 gas + QuickNode credits are real.

## Phase 4 complete

US-040 → US-045 accepted for the learning rebuild. Stock remains default; custom is opt-in.
