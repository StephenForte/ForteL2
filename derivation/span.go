package derivation

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/big"
)

const (
	// BatchTypeSpan is batch_version 1 (Delta+ span batches).
	BatchTypeSpan = 0x01

	maxSpanBatchElementCount = 10_000_000
)

var (
	errTooBigSpanBatchSize = errors.New("span batch size limit reached")
	errEmptySpanBatch      = errors.New("span batch must not be empty")
)

// SpanBlockElement is one L2 block derived from a span batch payload.
// ParentHash is populated only for the first block (first 20 bytes from parent_check; caller resolves full hash).
// EpochHash is left zero; the caller resolves it from L1 origin data.
type SpanBlockElement struct {
	ParentHash   [32]byte
	EpochNumber  uint64
	EpochHash    [32]byte
	Timestamp    uint64
	Transactions [][]byte
}

type spanBatchPrefix struct {
	relTimestamp  uint64
	l1OriginNum   uint64
	parentCheck   [20]byte
	l1OriginCheck [20]byte
}

type spanBatchPayload struct {
	blockCount    uint64
	originBits    *big.Int
	blockTxCounts []uint64
	txs           *spanBatchTxs
}

type rawSpanBatch struct {
	spanBatchPrefix
	spanBatchPayload
}

// DecodeSpanBatch parses a typed span batch (type ++ prefix ++ payload) and returns per-block elements.
func DecodeSpanBatch(data []byte, genesisTimestamp, blockTime uint64, chainID *big.Int) ([]SpanBlockElement, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("span batch too short")
	}
	if data[0] != BatchTypeSpan {
		return nil, fmt.Errorf("not a span batch (type %d)", data[0])
	}
	var raw rawSpanBatch
	r := bytes.NewReader(data[1:])
	if err := raw.decode(r); err != nil {
		return nil, err
	}
	return raw.derive(genesisTimestamp, blockTime, chainID)
}

func (bp *spanBatchPrefix) decodePrefix(r *bytes.Reader) error {
	relTimestamp, err := binary.ReadUvarint(r)
	if err != nil {
		return fmt.Errorf("read rel timestamp: %w", err)
	}
	bp.relTimestamp = relTimestamp

	l1OriginNum, err := binary.ReadUvarint(r)
	if err != nil {
		return fmt.Errorf("read l1 origin num: %w", err)
	}
	bp.l1OriginNum = l1OriginNum

	if _, err := io.ReadFull(r, bp.parentCheck[:]); err != nil {
		return fmt.Errorf("read parent check: %w", err)
	}
	if _, err := io.ReadFull(r, bp.l1OriginCheck[:]); err != nil {
		return fmt.Errorf("read l1 origin check: %w", err)
	}
	return nil
}

func (bp *spanBatchPayload) decodeOriginBits(r *bytes.Reader) error {
	if bp.blockCount > maxSpanBatchElementCount {
		return errTooBigSpanBatchSize
	}
	bits, err := decodeSpanBatchBits(r, bp.blockCount)
	if err != nil {
		return fmt.Errorf("decode origin bits: %w", err)
	}
	bp.originBits = bits
	return nil
}

func (bp *spanBatchPayload) decodeBlockCount(r *bytes.Reader) error {
	blockCount, err := binary.ReadUvarint(r)
	if err != nil {
		return fmt.Errorf("read block count: %w", err)
	}
	if blockCount > maxSpanBatchElementCount {
		return errTooBigSpanBatchSize
	}
	if blockCount == 0 {
		return errEmptySpanBatch
	}
	bp.blockCount = blockCount
	return nil
}

func (bp *spanBatchPayload) decodeBlockTxCounts(r *bytes.Reader) error {
	var blockTxCounts []uint64
	for i := 0; i < int(bp.blockCount); i++ {
		blockTxCount, err := binary.ReadUvarint(r)
		if err != nil {
			return fmt.Errorf("read block tx count: %w", err)
		}
		if blockTxCount > maxSpanBatchElementCount {
			return errTooBigSpanBatchSize
		}
		blockTxCounts = append(blockTxCounts, blockTxCount)
	}
	bp.blockTxCounts = blockTxCounts
	return nil
}

func (bp *spanBatchPayload) decodeTxs(r *bytes.Reader) error {
	if bp.txs == nil {
		bp.txs = &spanBatchTxs{}
	}
	if bp.blockTxCounts == nil {
		return errors.New("block tx counts not set")
	}
	var totalBlockTxCount uint64
	for _, count := range bp.blockTxCounts {
		next, overflow := bitsAdd(totalBlockTxCount, count)
		if overflow {
			return errTooBigSpanBatchSize
		}
		totalBlockTxCount = next
	}
	if totalBlockTxCount > maxSpanBatchElementCount {
		return errTooBigSpanBatchSize
	}
	bp.txs.totalBlockTxCount = totalBlockTxCount
	if err := bp.txs.decode(r); err != nil {
		return err
	}
	return nil
}

func (bp *spanBatchPayload) decodePayload(r *bytes.Reader) error {
	if err := bp.decodeBlockCount(r); err != nil {
		return err
	}
	if err := bp.decodeOriginBits(r); err != nil {
		return err
	}
	if err := bp.decodeBlockTxCounts(r); err != nil {
		return err
	}
	if err := bp.decodeTxs(r); err != nil {
		return err
	}
	return nil
}

func (b *rawSpanBatch) decode(r *bytes.Reader) error {
	if err := b.decodePrefix(r); err != nil {
		return fmt.Errorf("decode span batch prefix: %w", err)
	}
	if err := b.decodePayload(r); err != nil {
		return fmt.Errorf("decode span batch payload: %w", err)
	}
	return nil
}

func (b *rawSpanBatch) derive(genesisTimestamp, blockTime uint64, chainID *big.Int) ([]SpanBlockElement, error) {
	if b.blockCount == 0 {
		return nil, errEmptySpanBatch
	}

	blockOriginNums := make([]uint64, b.blockCount)
	l1OriginBlockNumber := b.l1OriginNum
	for i := int(b.blockCount) - 1; i >= 0; i-- {
		blockOriginNums[i] = l1OriginBlockNumber
		if b.originBits.Bit(i) == 1 && i > 0 {
			l1OriginBlockNumber--
		}
	}

	if err := b.txs.recoverV(chainID); err != nil {
		return nil, err
	}
	fullTxs, err := b.txs.fullTxs(chainID)
	if err != nil {
		return nil, err
	}

	elements := make([]SpanBlockElement, 0, b.blockCount)
	txIdx := 0
	for i := 0; i < int(b.blockCount); i++ {
		elem := SpanBlockElement{
			EpochNumber: blockOriginNums[i],
			Timestamp:   genesisTimestamp + b.relTimestamp + blockTime*uint64(i),
		}
		if i == 0 {
			copy(elem.ParentHash[:20], b.parentCheck[:])
		}
		for j := 0; j < int(b.blockTxCounts[i]); j++ {
			elem.Transactions = append(elem.Transactions, fullTxs[txIdx])
			txIdx++
		}
		elements = append(elements, elem)
	}
	return elements, nil
}

func bitsAdd(a, b uint64) (uint64, bool) {
	sum := a + b
	return sum, sum < a
}
