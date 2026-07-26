# Phase 5 — custom proposer (learning)

Minimal OP Stack proposer rebuild targeting the DisputeGameFactory (not L2OutputOracle). Specs:

- [Dispute game interface](https://specs.optimism.io/fault-proof/stage-one/dispute-game-interface.html)
- Stock reference: `op-proposer` → `DisputeGameFactory.create(gameType, rootClaim, extraData)`

**PRD:** [`tasks/prd-phase-5-proposer.md`](../tasks/prd-phase-5-proposer.md)

## Status

| Story | Status |
|---|---|
| US-050 inspect spike + CLI | Done |
| US-051 ABI helpers (extraData / create / initBonds) | Done |
| US-052 local propose loop | Done (prove with stock proposer stopped) |
| US-053 `USE_CUSTOM_PROPOSER=1` local start | Done |
| US-054 Sepolia demo window (optional) | Documented (confirm gate; stock remains default) |
| US-055 learning write-up | Done — see spike notes |

**Output root note:** v1 **fetches** `optimism_outputAtBlock` from op-node. Recomputing the hash locally is a documented follow-up, not required for Phase 5 acceptance.

Stock `op-proposer` remains the **default** via `scripts/06-start-proposer*.sh`.

## Layout

```text
proposer/
  extradata.go / abi.go / rpc.go
  cmd/inspect-game/   # read-only factory + game metadata
  cmd/propose-loop/   # poll syncStatus → outputAtBlock → create
```

## Tests

```bash
cd proposer && go test ./...
```

## Inspect a real dispute game

```bash
cd proposer
go run ./cmd/inspect-game \
  -l1 "$L1_RPC_URL" \
  -deployments "$FORTEL2_ROOT/deployments/deployments.json"
```

Never paste private keys into this tool — it is read-only.

## US-053: local switch + kill switch

Default (unchanged):

```bash
./scripts/06-start-proposer.sh
```

Custom (learning demo):

```bash
USE_CUSTOM_PROPOSER=1 ./scripts/06-start-proposer.sh
```

Builds `$BIN_DIR/fortel2-proposer` from `cmd/propose-loop` and starts it under the same `op-proposer` pid name so `./scripts/stop-all.sh` still works. No `lib.sh` `start_bg`/`stop_bg` edits. If an `op-proposer` pid is already alive, the script stops it first, then launches the custom binary.

Kill switch back to stock:

```bash
kill "$(cat "$DATA_DIR/pids/op-proposer.pid")" && rm -f "$DATA_DIR/pids/op-proposer.pid"
./scripts/06-start-proposer.sh   # USE_CUSTOM_PROPOSER unset/0
```

## US-052: one-shot propose (manual)

1. Start local Anvil stack (`./scripts/start-all.sh`), confirm chain **901**.
2. Stop stock proposer only:

```bash
kill "$(cat "$DATA_DIR/pids/op-proposer.pid")" && rm -f "$DATA_DIR/pids/op-proposer.pid"
```

3. One game (after safe head has advanced past the last proposal):

```bash
set -a && source .env && set +a
FACTORY=$(jq -r .DisputeGameFactoryProxy deployments/deployments.json)
cd proposer
go run ./cmd/propose-loop \
  -l1 "$L1_RPC_URL" -rollup "$L2_NODE_RPC_URL" \
  -factory "$FACTORY" -game-type "${PROPOSER_GAME_TYPE:-1}" \
  -proposal-interval 0s \
  -once
```

**Duplicate safeguards:** in-memory `lastProposedL2` + `lastProposalTime`; never re-propose `<= lastProposedL2`; on restart initialize from latest factory game of the configured type; respect `-proposal-interval` (stock uses time-since-last-game).

**Recovery:** restart stock with `./scripts/06-start-proposer.sh`.

## US-054: Sepolia demo window (optional)

After local US-052 is green:

```bash
FORTEL2_ENV=.env.sepolia USE_CUSTOM_PROPOSER=1 CONFIRM_CUSTOM_PROPOSER_SEPOLIA=1 \
  ./scripts/06-start-proposer-sepolia.sh
```

- Honors credit-budget poll defaults (`SEPOLIA_PROPOSER_POLL_INTERVAL`, default 12s).
- Max ~15 minutes; then stop the pid and revert to stock `06-start-proposer-sepolia.sh`.
- If games look wrong: abort immediately; leave stock as the Sepolia default until fixed.
- No genesis pack / redeploy.

## What an output root is (US-055 summary)

See [`tasks/spike-phase-5-proposer.md`](../tasks/spike-phase-5-proposer.md).
