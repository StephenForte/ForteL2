package derivation

import (
	"context"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

func deriveBlockInputs(ctx context.Context, cfg *RollupConfig, l1 *L1Client, opts VerifyOptions) ([]BlockInput, error) {
	chainID := big.NewInt(int64(cfg.L2ChainID))
	batcherAddr := cfg.Genesis.SystemConfig.BatcherAddr

	var batcherTxs []BatcherTx
	if opts.ChannelTx != (common.Hash{}) {
		input, err := l1.TxInput(ctx, opts.ChannelTx)
		if err != nil {
			return nil, err
		}
		batcherTxs = []BatcherTx{{Hash: opts.ChannelTx, Input: input}}
	} else {
		toBlock, err := l1.LatestBlockNumber(ctx)
		if err != nil {
			return nil, err
		}
		from := opts.FromL1Block
		if from == 0 {
			if !opts.ScanFromGenesis && toBlock > 1_000_000 {
				return nil, fmt.Errorf("refusing unbounded L1 inbox scan from genesis (tip=%d): pass -from-l1 or -scan-from-genesis", toBlock)
			}
			from = 1
		}
		batcherTxs, err = l1.ScanBatcherTxs(ctx, cfg.BatchInboxAddress, batcherAddr, from, toBlock)
		if err != nil {
			return nil, err
		}
	}

	byNumber := map[uint64]BlockInput{}

	for _, btx := range batcherTxs {
		rawBatches, err := DecodeBatcherChannel(btx.Input)
		if err != nil {
			return nil, fmt.Errorf("tx %s: %w", btx.Hash, err)
		}
		for _, raw := range rawBatches {
			elems, err := DecodeTypedBatch(raw, cfg, chainID, [32]byte{})
			if err != nil {
				return nil, err
			}
			for _, e := range elems {
				if e.EpochHash == (common.Hash{}) {
					hdr, err := l1.BlockHeader(ctx, e.EpochNumber)
					if err != nil {
						return nil, err
					}
					e.EpochHash = hdr.Hash
				}

				num, err := blockNumberFromTimestamp(cfg, e.Timestamp)
				if err != nil {
					return nil, fmt.Errorf("tx %s: %w", btx.Hash, err)
				}
				if num < opts.StartL2 || num > opts.EndL2 {
					continue
				}
				e.Number = num
				e.L1SourceTx = btx.Hash

				if prev, dup := byNumber[num]; dup {
					logDuplicateBlock(num, prev, e)
				}
				byNumber[num] = e
			}
		}
	}

	var inputs []BlockInput
	for n := opts.StartL2; n <= opts.EndL2; n++ {
		if in, ok := byNumber[n]; ok {
			inputs = append(inputs, in)
		}
	}
	return inputs, nil
}
