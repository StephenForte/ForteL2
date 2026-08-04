package derivation

import (
	"context"
	"fmt"
	"math/big"
	"sync"

	"github.com/ethereum/go-ethereum/common/hexutil"
)

var blobBaseFeePreCancun = big.NewInt(1)

// blobFeeCache stores eth_feeHistory results keyed by L1 block number.
type blobFeeCache struct {
	mu    sync.Mutex
	byNum map[uint64]*big.Int
}

func newBlobFeeCache() *blobFeeCache {
	return &blobFeeCache{byNum: make(map[uint64]*big.Int)}
}

type feeHistoryJSON struct {
	OldestBlock       string          `json:"oldestBlock"`
	BaseFeePerBlobGas []*hexutil.Big  `json:"baseFeePerBlobGas"`
}

// EnrichBlobBaseFee sets h.BlobBaseFee from eth_feeHistory when missing.
// Results are cached per L1 block number to avoid one RPC per derived block.
func (c *L1Client) EnrichBlobBaseFee(ctx context.Context, h *L1BlockHeader) error {
	if h == nil {
		return fmt.Errorf("nil L1 header")
	}
	if h.BlobBaseFee != nil {
		return nil
	}
	fee, err := c.blobBaseFeeAt(ctx, h.Number)
	if err != nil {
		return err
	}
	h.BlobBaseFee = fee
	return nil
}

func (c *L1Client) blobBaseFeeAt(ctx context.Context, blockNum uint64) (*big.Int, error) {
	if c.blobFees != nil {
		c.blobFees.mu.Lock()
		if fee, ok := c.blobFees.byNum[blockNum]; ok {
			c.blobFees.mu.Unlock()
			return fee, nil
		}
		c.blobFees.mu.Unlock()
	}

	fee, err := c.fetchBlobBaseFeeHistory(ctx, blockNum)
	if err != nil {
		return nil, err
	}

	if c.blobFees != nil {
		c.blobFees.mu.Lock()
		c.blobFees.byNum[blockNum] = fee
		c.blobFees.mu.Unlock()
	}
	return fee, nil
}

func (c *L1Client) fetchBlobBaseFeeHistory(ctx context.Context, blockNum uint64) (*big.Int, error) {
	tag := fmt.Sprintf("0x%x", blockNum)
	var hist feeHistoryJSON
	if err := c.rpc.Call(ctx, "eth_feeHistory", []any{1, tag, []float64{}}, &hist); err != nil {
		// Pre-Cancun L1 or RPC without blob fee support — match legacy hard-code.
		return new(big.Int).Set(blobBaseFeePreCancun), nil
	}
	if len(hist.BaseFeePerBlobGas) == 0 || hist.BaseFeePerBlobGas[0] == nil {
		return new(big.Int).Set(blobBaseFeePreCancun), nil
	}
	return (*big.Int)(hist.BaseFeePerBlobGas[0]), nil
}

// PrefetchBlobBaseFees warms the cache for a contiguous L1 block range (inclusive).
func (c *L1Client) PrefetchBlobBaseFees(ctx context.Context, from, to uint64) error {
	if from > to {
		return nil
	}
	count := to - from + 1
	if count > 128 {
		// eth_feeHistory blockCount is capped on many nodes; chunk large ranges.
		for start := from; start <= to; start += 128 {
			end := start + 127
			if end > to {
				end = to
			}
			if err := c.prefetchBlobBaseFeeChunk(ctx, start, end); err != nil {
				return err
			}
		}
		return nil
	}
	return c.prefetchBlobBaseFeeChunk(ctx, from, to)
}

func (c *L1Client) prefetchBlobBaseFeeChunk(ctx context.Context, from, to uint64) error {
	count := to - from + 1
	tag := fmt.Sprintf("0x%x", to)
	var hist feeHistoryJSON
	if err := c.rpc.Call(ctx, "eth_feeHistory", []any{count, tag, []float64{}}, &hist); err != nil {
		return nil // treat as pre-Cancun; per-block fetch falls back to 1
	}
	if len(hist.BaseFeePerBlobGas) == 0 {
		return nil
	}
	oldest, err := hexutil.DecodeUint64(hist.OldestBlock)
	if err != nil {
		return nil
	}
	if c.blobFees == nil {
		c.blobFees = newBlobFeeCache()
	}
	c.blobFees.mu.Lock()
	defer c.blobFees.mu.Unlock()
	for i, fee := range hist.BaseFeePerBlobGas {
		num := oldest + uint64(i)
		if num < from || num > to {
			continue
		}
		if fee == nil {
			c.blobFees.byNum[num] = new(big.Int).Set(blobBaseFeePreCancun)
		} else {
			c.blobFees.byNum[num] = (*big.Int)(fee)
		}
	}
	return nil
}
