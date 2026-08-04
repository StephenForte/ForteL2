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
			from = 1
		}
		batcherTxs, err = l1.ScanBatcherTxs(ctx, cfg.BatchInboxAddress, batcherAddr, from, toBlock)
		if err != nil {
			return nil, err
		}
	}

	var inputs []BlockInput
	blockNum := uint64(1)
	var lastSealed common.Hash

	for _, btx := range batcherTxs {
		rawBatches, err := DecodeBatcherChannel(btx.Input)
		if err != nil {
			return nil, fmt.Errorf("tx %s: %w", btx.Hash, err)
		}
		for _, raw := range rawBatches {
			var parent [32]byte
			if lastSealed != (common.Hash{}) {
				parent = lastSealed
			}
			elems, err := DecodeTypedBatch(raw, cfg, chainID, parent)
			if err != nil {
				return nil, err
			}
			for i, e := range elems {
				if e.EpochHash == (common.Hash{}) {
					hdr, err := l1.BlockHeader(ctx, e.EpochNumber)
					if err != nil {
						return nil, err
					}
					e.EpochHash = hdr.Hash
				}
				if i == 0 && e.ParentHash == (common.Hash{}) && lastSealed != (common.Hash{}) {
					e.ParentHash = lastSealed
				}
				e.Number = blockNum
				e.L1SourceTx = btx.Hash
				inputs = append(inputs, e)
				blockNum++
			}
		}
	}
	return inputs, nil
}
