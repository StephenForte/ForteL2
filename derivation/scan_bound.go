package derivation

import (
	"context"
	"fmt"
	"os"

	"github.com/ethereum/go-ethereum/common"
)

// ResumeScanMargin is extra L1 blocks subtracted below origin(M) − channel_timeout.
//
// Spec (derivation ChannelBank timeouts): a channel is timed out iff
// current_l1 > open_l1 + CHANNEL_TIMEOUT, so a channel still open at origin(M)
// opened no earlier than origin(M) − CHANNEL_TIMEOUT. Margin 1 covers the
// inclusive/exclusive off-by-one on that inequality. Over-scanning is only
// cost; under-scanning misses a batch (loud: "missing derived block N in window").
const ResumeScanMargin uint64 = 1

// InboxScanStart is the first L1 block of a resumed self-anchor inbox scan:
// origin(M) − channelTimeout − margin, clamped at genesis.l1.
func InboxScanStart(originM, channelTimeout, margin, genesisL1 uint64) uint64 {
	var sub uint64
	if channelTimeout > ^uint64(0)-margin {
		sub = ^uint64(0)
	} else {
		sub = channelTimeout + margin
	}
	if originM < sub {
		return genesisL1
	}
	start := originM - sub
	if start < genesisL1 {
		return genesisL1
	}
	return start
}

type l1InfoTxSource interface {
	BlockFirstTx(ctx context.Context, num uint64) ([]byte, error)
}

// resolveResumeInboxScan derives -from-l1 from the sealing EL head's L1-info
// (the sealed head cannot lie about what has been derived). No checkpoint file.
func resolveResumeInboxScan(ctx context.Context, src l1InfoTxSource, cfg *RollupConfig, opts *VerifyOptions) error {
	if !opts.ResumeL1Bound {
		return nil
	}
	if opts.ChannelTx != (common.Hash{}) {
		return nil
	}
	if opts.FromL1Block != 0 || opts.StartL2 <= 1 {
		return nil
	}
	if cfg.ChannelTimeout == 0 {
		return fmt.Errorf("resume L1 scan bound: rollup config channel_timeout is 0 (read it from rollup.json; refusing to guess)")
	}
	prev := opts.StartL2 - 1
	rawTx, err := src.BlockFirstTx(ctx, prev)
	if err != nil {
		return fmt.Errorf("resume L1 scan bound: sealing EL block %d first tx: %w", prev, err)
	}
	info, err := ParseL1InfoDeposit(rawTx)
	if err != nil {
		return fmt.Errorf("resume L1 scan bound: sealing EL block %d L1-info: %w", prev, err)
	}
	opts.FromL1Block = InboxScanStart(info.L1OriginNumber, cfg.ChannelTimeout, ResumeScanMargin, cfg.Genesis.L1.Number)
	fmt.Fprintf(os.Stderr, "L1 inbox scan from block %d (bound: origin(M)=%d - channel_timeout=%d - margin=%d)\n",
		opts.FromL1Block, info.L1OriginNumber, cfg.ChannelTimeout, ResumeScanMargin)
	return nil
}
