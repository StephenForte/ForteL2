package derivation

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common"
)

const fjordMaxSequencerDrift = 1800

// ValidateL2OriginTimestamp checks the sequencing-window timestamp rule:
// l2_ts >= l1_origin_ts and l2_ts <= l1_origin_ts + max_sequencer_drift.
// Spec: https://specs.optimism.io/protocol/derivation.html#sequencing-window
func ValidateL2OriginTimestamp(l2Ts, l1OriginTs, maxDrift uint64) error {
	if l2Ts < l1OriginTs {
		return fmt.Errorf("l2 timestamp %d before l1 origin timestamp %d", l2Ts, l1OriginTs)
	}
	if l2Ts > l1OriginTs+maxDrift {
		return fmt.Errorf("l2 timestamp %d exceeds l1 origin timestamp %d + max drift %d", l2Ts, l1OriginTs, maxDrift)
	}
	return nil
}

// EffectiveMaxSequencerDrift returns the drift cap for an L2 block timestamp.
// With Fjord active from genesis, op-node uses a constant 1800s (see README).
func (c *RollupConfig) EffectiveMaxSequencerDrift(l2Timestamp uint64) uint64 {
	if c.IsFjord(l2Timestamp) {
		return fjordMaxSequencerDrift
	}
	if c.MaxSequencerDrift != 0 {
		return c.MaxSequencerDrift
	}
	return 600
}

// OriginForL2Timestamp returns the L1 origin block valid for building an L2 block at l2Ts,
// advancing the L1 origin by at most one block per call when drift would be exceeded.
func (c *RollupConfig) OriginForL2Timestamp(ctx context.Context, l1 *L1Client, startOriginNum, l2Ts uint64) (*L1BlockHeader, error) {
	maxDrift := c.EffectiveMaxSequencerDrift(l2Ts)
	originNum := startOriginNum
	const maxAdvance = 10_000
	for i := 0; i < maxAdvance; i++ {
		hdr, err := l1.BlockHeader(ctx, originNum)
		if err != nil {
			return nil, fmt.Errorf("l1 origin %d: %w", originNum, err)
		}
		if err := ValidateL2OriginTimestamp(l2Ts, hdr.Time, maxDrift); err == nil {
			return hdr, nil
		} else if l2Ts < hdr.Time {
			return nil, fmt.Errorf("no valid l1 origin: l2 timestamp %d before origin %d timestamp %d", l2Ts, originNum, hdr.Time)
		}
		originNum++
	}
	return nil, fmt.Errorf("no valid l1 origin within %d advances of block %d for l2 timestamp %d", maxAdvance, startOriginNum, l2Ts)
}

// ResolveStubL1Origin picks the default L1 origin for stub block building, or validates -l1-origin.
func ResolveStubL1Origin(ctx context.Context, cfg *RollupConfig, l1 *L1Client, sealer *SealingEL, overrideNum, firstL2Ts uint64) (*L1BlockHeader, error) {
	if overrideNum != 0 {
		hdr, err := l1.BlockHeader(ctx, overrideNum)
		if err != nil {
			return nil, fmt.Errorf("l1 origin %d: %w", overrideNum, err)
		}
		maxDrift := cfg.EffectiveMaxSequencerDrift(firstL2Ts)
		if err := ValidateL2OriginTimestamp(firstL2Ts, hdr.Time, maxDrift); err != nil {
			return nil, fmt.Errorf("invalid -l1-origin %d for first l2 timestamp %d: %w", overrideNum, firstL2Ts, err)
		}
		return hdr, nil
	}

	_, parentNum, _, err := sealer.LoadLatestHead(ctx)
	if err != nil {
		return nil, fmt.Errorf("sealing EL head: %w", err)
	}

	startOriginNum := cfg.Genesis.L1.Number
	if startOriginNum == 0 && cfg.Genesis.L1.Hash != (common.Hash{}) {
		hdr, err := l1.BlockHeaderByHash(ctx, cfg.Genesis.L1.Hash)
		if err != nil {
			return nil, fmt.Errorf("genesis.l1 hash: %w", err)
		}
		startOriginNum = hdr.Number
	}
	if parentNum > 0 {
		rawTx, err := sealer.BlockFirstTx(ctx, parentNum)
		if err != nil {
			return nil, fmt.Errorf("head block %d L1-info tx: %w", parentNum, err)
		}
		info, err := ParseL1InfoDeposit(rawTx)
		if err != nil {
			return nil, fmt.Errorf("head block %d L1-info: %w", parentNum, err)
		}
		startOriginNum = info.L1OriginNumber
	}

	return cfg.OriginForL2Timestamp(ctx, l1, startOriginNum, firstL2Ts)
}

// ParentL1InfoFromBlock reads and parses the L1-info deposit from a sealed block.
func ParentL1InfoFromBlock(ctx context.Context, sealer *SealingEL, blockNum uint64) (L1InfoFromDeposit, error) {
	rawTx, err := sealer.BlockFirstTx(ctx, blockNum)
	if err != nil {
		return L1InfoFromDeposit{}, err
	}
	return ParseL1InfoDeposit(rawTx)
}

// StubStartOriginNum returns the L1 origin number to advance from when planning stub blocks.
// Fresh genesis uses rollup genesis.l1; continuation uses the head block's L1-info deposit.
func StubStartOriginNum(ctx context.Context, cfg *RollupConfig, l1 *L1Client, sealer *SealingEL, parentNum uint64) (uint64, error) {
	startOriginNum := cfg.Genesis.L1.Number
	if startOriginNum == 0 && cfg.Genesis.L1.Hash != (common.Hash{}) {
		hdr, err := l1.BlockHeaderByHash(ctx, cfg.Genesis.L1.Hash)
		if err != nil {
			return 0, fmt.Errorf("genesis.l1 hash: %w", err)
		}
		startOriginNum = hdr.Number
	}
	if parentNum > 0 {
		info, err := ParentL1InfoFromBlock(ctx, sealer, parentNum)
		if err != nil {
			return 0, fmt.Errorf("head block %d L1-info: %w", parentNum, err)
		}
		startOriginNum = info.L1OriginNumber
	}
	return startOriginNum, nil
}

// SeedStubDerivationState initializes derivation state for stub block building.
// Fresh genesis (parentNum==0): L1OriginNum stays 0 so the first block is treated as
// an origin change (seq=0). Continuation seeds L1 origin + seq from the parent block's
// L1-info deposit per https://specs.optimism.io/protocol/derivation.html#l2-block-seal
// (same origin as parent → next seq is parentSeq+1; origin advance → seq=0).
func SeedStubDerivationState(ctx context.Context, sealer *SealingEL, parentNum uint64, parentHash common.Hash, parentTime uint64, cfg *RollupConfig) (DerivationState, error) {
	st := NewDerivationState(cfg)
	st.ParentHash = parentHash
	st.ParentTime = parentTime
	if parentNum == 0 {
		return st, nil
	}
	info, err := ParentL1InfoFromBlock(ctx, sealer, parentNum)
	if err != nil {
		return st, fmt.Errorf("parent block %d L1-info: %w", parentNum, err)
	}
	st.L1OriginNum = info.L1OriginNumber
	st.L1OriginHash = info.L1OriginHash
	st.SeqNumber = info.SeqNumber
	return st, nil
}
