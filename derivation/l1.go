package derivation

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strings"

	"github.com/StephenForte/ForteL2/batcher"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/core/types"
)

// L1BlockHeader is a minimal L1 block header for derivation.
type L1BlockHeader struct {
	Number     uint64
	Hash       common.Hash
	ParentHash common.Hash
	Time       uint64
	BaseFee    *big.Int
	MixDigest  common.Hash
}

// L1Client reads L1 data for batch inbox scanning and deposit derivation.
type L1Client struct {
	rpc *RPCClient
}

func NewL1Client(rpc *RPCClient) *L1Client {
	return &L1Client{rpc: rpc}
}

type l1HeaderJSON struct {
	Number        string         `json:"number"`
	Hash          common.Hash    `json:"hash"`
	ParentHash    common.Hash    `json:"parentHash"`
	Timestamp     hexutil.Uint64 `json:"timestamp"`
	BaseFeePerGas *hexutil.Big   `json:"baseFeePerGas"`
	MixHash       common.Hash    `json:"mixHash"`
}

type l1BlockJSON struct {
	Number        string         `json:"number"`
	Hash          common.Hash    `json:"hash"`
	ParentHash    common.Hash    `json:"parentHash"`
	Timestamp     hexutil.Uint64 `json:"timestamp"`
	BaseFeePerGas *hexutil.Big   `json:"baseFeePerGas"`
	MixHash       common.Hash    `json:"mixHash"`
	Transactions  []txJSON       `json:"transactions"`
}

type txJSON struct {
	Hash  common.Hash `json:"hash"`
	From  common.Address `json:"from"`
	To    *common.Address `json:"to"`
	Input hexutil.Bytes `json:"input"`
	BlockNumber string `json:"blockNumber"`
}

func (c *L1Client) BlockHeader(ctx context.Context, num uint64) (*L1BlockHeader, error) {
	var blk l1HeaderJSON
	tag := fmt.Sprintf("0x%x", num)
	if err := c.rpc.Call(ctx, "eth_getBlockByNumber", []any{tag, false}, &blk); err != nil {
		return nil, err
	}
	return headerFromJSON(blk)
}

func (c *L1Client) BlockHeaderByHash(ctx context.Context, hash common.Hash) (*L1BlockHeader, error) {
	var blk l1HeaderJSON
	if err := c.rpc.Call(ctx, "eth_getBlockByHash", []any{hash, false}, &blk); err != nil {
		return nil, err
	}
	return headerFromJSON(blk)
}

func headerFromJSON(blk l1HeaderJSON) (*L1BlockHeader, error) {
	n, err := hexutil.DecodeUint64(blk.Number)
	if err != nil {
		return nil, err
	}
	var baseFee *big.Int
	if blk.BaseFeePerGas != nil {
		baseFee = (*big.Int)(blk.BaseFeePerGas)
	}
	return &L1BlockHeader{
		Number:     n,
		Hash:       blk.Hash,
		ParentHash: blk.ParentHash,
		Time:       uint64(blk.Timestamp),
		BaseFee:    baseFee,
		MixDigest:  blk.MixHash,
	}, nil
}

func (c *L1Client) BlockReceipts(ctx context.Context, hash common.Hash) (types.Receipts, error) {
	var raw []json.RawMessage
	if err := c.rpc.Call(ctx, "eth_getBlockReceipts", []any{hash}, &raw); err != nil {
		return nil, err
	}
	receipts := make(types.Receipts, len(raw))
	for i, r := range raw {
		var rec types.Receipt
		if err := json.Unmarshal(r, &rec); err != nil {
			return nil, fmt.Errorf("receipt %d: %w", i, err)
		}
		receipts[i] = &rec
	}
	return receipts, nil
}

// BatcherTx is an L1 batcher transaction to the batch inbox.
type BatcherTx struct {
	Hash        common.Hash
	BlockNumber uint64
	Input       []byte
}

func (c *L1Client) ScanBatcherTxs(ctx context.Context, inbox, batcher common.Address, fromBlock, toBlock uint64) ([]BatcherTx, error) {
	var out []BatcherTx
	for n := fromBlock; n <= toBlock; n++ {
		if n == fromBlock || n%100 == 0 || n == toBlock {
			fmt.Fprintf(os.Stderr, "L1 inbox scan: block %d / %d (%d batcher txs so far)\n", n, toBlock, len(out))
		}
		var blk l1BlockJSON
		tag := fmt.Sprintf("0x%x", n)
		if err := c.rpc.Call(ctx, "eth_getBlockByNumber", []any{tag, true}, &blk); err != nil {
			return nil, err
		}
		bn, _ := hexutil.DecodeUint64(blk.Number)
		for _, tx := range blk.Transactions {
			if tx.To == nil {
				continue
			}
			if !strings.EqualFold(tx.To.Hex(), inbox.Hex()) {
				continue
			}
			if !strings.EqualFold(tx.From.Hex(), batcher.Hex()) {
				continue
			}
			out = append(out, BatcherTx{
				Hash:        tx.Hash,
				BlockNumber: bn,
				Input:       tx.Input,
			})
		}
	}
	return out, nil
}

func (c *L1Client) TxInput(ctx context.Context, hash common.Hash) ([]byte, error) {
	var tx txJSON
	if err := c.rpc.Call(ctx, "eth_getTransactionByHash", []any{hash}, &tx); err != nil {
		return nil, err
	}
	return tx.Input, nil
}

func (c *L1Client) LatestBlockNumber(ctx context.Context) (uint64, error) {
	var tag string
	if err := c.rpc.Call(ctx, "eth_blockNumber", []any{}, &tag); err != nil {
		return 0, err
	}
	return hexutil.DecodeUint64(tag)
}

// DecodeBatcherChannel decodes one batcher tx through frames → channel → typed batches.
func DecodeBatcherChannel(input []byte) ([][]byte, error) {
	_, frames, err := batcher.ParseBatcherTxPayload(input)
	if err != nil {
		return nil, err
	}
	joined, err := batcher.JoinFrameData(frames)
	if err != nil {
		return nil, err
	}
	body, err := batcher.DecompressChannelZlib(joined)
	if err != nil {
		return nil, err
	}
	return batcher.ReadChannelBatches(body)
}

// DecodeTypedBatch decodes a typed batch into block elements.
func DecodeTypedBatch(raw []byte, cfg *RollupConfig, chainID *big.Int, parentHash [32]byte) ([]BlockInput, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("empty batch")
	}
	switch raw[0] {
	case batcher.BatchTypeSingular:
		sb, err := batcher.DecodeSingularBatch(raw)
		if err != nil {
			return nil, err
		}
		return []BlockInput{{
			ParentHash:   sb.ParentHash,
			EpochNumber:  sb.EpochNumber,
			EpochHash:    sb.EpochHash,
			Timestamp:    sb.Timestamp,
			Transactions: sb.Transactions,
			Source:       "batch",
		}}, nil
	case BatchTypeSpan:
		elems, err := DecodeSpanBatch(raw, cfg.Genesis.L2Time, cfg.BlockTime, chainID)
		if err != nil {
			return nil, err
		}
		out := make([]BlockInput, len(elems))
		for i, e := range elems {
			ph := parentHash
			if i == 0 {
				copy(ph[:20], e.ParentHash[:20])
			}
			out[i] = BlockInput{
				ParentHash:   ph,
				EpochNumber:  e.EpochNumber,
				EpochHash:    e.EpochHash,
				Timestamp:    e.Timestamp,
				Transactions: e.Transactions,
				Source:       "batch",
			}
		}
		return out, nil
	default:
		return nil, fmt.Errorf("unknown batch type %d", raw[0])
	}
}

// BlockInput is one derived L2 block before payload attributes / sealing.
type BlockInput struct {
	Number       uint64
	ParentHash   [32]byte
	EpochNumber  uint64
	EpochHash    [32]byte
	Timestamp    uint64
	Transactions [][]byte
	Source       string // "batch" | "deposit"
	L1SourceTx   common.Hash
}
