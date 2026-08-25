# derivation — Phase 6 derivation verifier (US-061) + sequencer stub (US-062)

Minimal OP Stack derivation **verifier**: reads L1 batch inbox txs and Portal deposits, derives L2 payload attributes for a bounded window, seals block hashes via a **separate** loopback `op-geth` (Engine API), and diffs against the reference stack. Optional **sequencer stub** builds empty L2 blocks on a second isolated EL.

**Spec:** [Derivation pipeline](https://specs.optimism.io/protocol/derivation.html) · **PRD:** `tasks/prd-phase-6-derivation.md` · **Spike:** `tasks/spike-phase-6-derivation.md`

## What this implements

| Stage | Package files | Notes |
|---|---|---|
| L1 batch inbox scan | `l1.go` | Filter txs to inbox from authorized batcher |
| Frames → channel → batches | `l1.go` | Imports `batcher` decode helpers (`ParseBatcherTxPayload`, zlib, singular `0x00`) |
| Span batches (`0x01`) | `span.go`, `span_bits.go`, `span_txs.go` | Required decoder; local history is singular-only |
| Portal deposits | `deposit.go`, `deposit_tx.go` | User deposit inclusion on L1-origin change |
| L1-info deposit | `l1info.go` | Bedrock → Jovian calldata variants; blob base fee from `eth_feeHistory` (D-R3-1) |
| Payload attributes | `attrs.go`, `rollup.go` | Fork-aware attrs from rollup config |
| Engine API sealing | `engine.go` | Separate EL only — never the reference stack |
| Hash diff | `verify.go`, `cmd/verify/` | `derivedHash == eth_getBlockByNumber(n).hash` (D-T2-3) |

## Runbook

Reference stack must be running (`./scripts/start-all.sh` or Sepolia equivalent).

```bash
./scripts/derivation-check.sh                    # local 901, blocks 1–20 (genesis replay)
./scripts/derivation-check.sh --start-l2 1 --end-l2 20
./scripts/derivation-check.sh --channel-tx 0x…   # single L1 batcher tx window

# Mid-chain window (R2 anchor flow)
./scripts/stop-all.sh
./scripts/derivation-check.sh --make-anchor
./scripts/start-all.sh
./scripts/derivation-check.sh --start-l2 60 --end-l2 80

FORTEL2_ENV=.env.sepolia ./scripts/derivation-check.sh --sepolia  # needs prior: --sepolia --make-anchor (stack stopped)

# Self-anchor (Path A): keep the derivation EL datadir; resume from last self-sealed block.
# Mutually exclusive with --make-anchor / --anchor-datadir. Does not copy or stop the reference.
./scripts/derivation-check.sh --self-anchor --start-l2 1 --end-l2 20
./scripts/derivation-check.sh --self-anchor --start-l2 21 --end-l2 40
FORTEL2_ENV=.env.sepolia ./scripts/derivation-check.sh --sepolia --self-anchor --start-l2 1 --end-l2 20
FORTEL2_ENV=.env.sepolia ./scripts/derivation-check.sh --sepolia --self-anchor --start-l2 21 --end-l2 40
```

**Pass:** every block in the window prints `OK`; exit 0; summary `derivation-check: PASS`.

**Fail:** first hash mismatch or RPC/derivation error; exit 1; stderr shows expected vs derived hash.

**Kill switch:** do not run `derivation-check.sh` — stock `op-node` derivation is unchanged.

### Separate sealing EL (D-R1-1)

The runbook starts its own `op-geth` under `$DATA_DIR/l2/derivation-op-geth` (genesis replay) or reuses `$DATA_DIR/l2/derivation-anchor-op-geth` (mid-chain copy) with dedicated ports (`DERIV_EL_HTTP_PORT=19645`, `DERIV_EL_AUTH_PORT=19651`, P2P `--port=30323`) and JWT (`$DATA_DIR/jwt/derivation-jwt.txt`). The reference `op-geth` / `op-node` are **read-only** oracles (`eth_getBlockByNumber`, `optimism_syncStatus`). `debug_setHead` is confined to the anchor copy only.

## CLI

```bash
cd derivation
go run ./cmd/verify \
  -rollup "$DEPLOY_DIR/rollup.json" \
  -l1 "$L1_RPC_URL" \
  -ref-l2 "$L2_RPC_URL" \
  -ref-node "$L2_NODE_RPC_URL" \
  -seal-auth http://127.0.0.1:19651 \
  -seal-http http://127.0.0.1:19645 \
  -jwt "$DATA_DIR/jwt/derivation-jwt.txt" \
  -start-l2 1 -end-l2 20
```

## Limitations — independent verification

`cmd/verify` always needs `-ref-l2` and `-ref-node` — the operator's own L2 / op-node — as the comparison oracle. Mid-chain windows also need an **anchor datadir** copied from that same operator node while it is stopped (D-R2-2).

A third party running this today is checking the operator's chain against the operator's own answers, which proves consistency, not honesty.

Independent verification would need either a self-derived state root from genesis, or an anchor taken from the counterparty's own replica — not a copy of the operator's datadir.

## Tests

```bash
cd derivation && go test ./...
```

Fixtures: `testdata/local901/batcher_tx.hex` (15 singular batches from local 901). Sepolia golden slot: `testdata/sepolia/window.json` — when present, unmarshaled as `VerifyReport` and integrity-checked (contiguous numbers, every `Match`, derived==expected); skipped with notice when absent.

## Sequencer stub (US-062)

```bash
./scripts/sequencer-stub-demo.sh --blocks 10
```

| Item | Detail |
|---|---|
| Binary | `derivation/cmd/sequencer-stub` (separate from `cmd/verify`) |
| Engine API | `forkchoiceUpdatedV3` + `getPayloadV4`/`V3` + `newPayloadV4`/`V3` (`--l2.enginekind=geth`) |
| Isolated EL | `$DATA_DIR/l2/sequencer-stub-op-geth` · `:19745`/`:19751` · P2P `:30324` |
| Follow-validate | Rebuild `BuildPayloadAttributes`; match L1-info bytes + parent links (D-T6-2); independent seed from parent L1-info re-parse (D-H3a-1) |
| L1 origin default | `genesis.l1` from `rollup.json` (or head L1-info when continuing); validated against [sequencing window](https://specs.optimism.io/protocol/derivation.html#sequencing-window) timestamp rules (D-R3-2) |
| Continuation | Non-genesis head: seq + origin hash recovered from parent L1-info; same origin → `parentSeq+1`, origin advance → `seq=0` (spec: L2 block seal) |
| Kill switch | EXIT trap stops stub EL; `rm -rf` stub datadir; reference op-node untouched |

## Module wiring

```go
require github.com/StephenForte/ForteL2/batcher v0.0.0
replace github.com/StephenForte/ForteL2/batcher => ../batcher
```

Do **not** edit `batcher/*.go`; import decode helpers only.
