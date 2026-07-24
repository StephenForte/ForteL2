package batcher

import (
	"bytes"
	"fmt"
	"io"
	"math/big"

	"github.com/ethereum/go-ethereum/rlp"
)

const (
	// BatchTypeSingular is batch_version 0 (pre-Delta / still accepted alongside spans).
	BatchTypeSingular = 0x00
)

// SingularBatch is a version-0 sequencer batch for one L2 block.
// Spec: batch_version ++ rlp([parent_hash, epoch_number, epoch_hash, timestamp, transaction_list])
type SingularBatch struct {
	ParentHash     [32]byte
	EpochNumber    uint64
	EpochHash      [32]byte
	Timestamp      uint64
	Transactions   [][]byte // EIP-2718 encoded txs
}

type singularBatchRLP struct {
	ParentHash   [32]byte
	EpochNumber  *big.Int
	EpochHash    [32]byte
	Timestamp    *big.Int
	Transactions [][]byte
}

// EncodeSingularBatch returns type-byte ++ RLP(content) — the inner typed batch payload.
func EncodeSingularBatch(b SingularBatch) ([]byte, error) {
	payload, err := rlp.EncodeToBytes(&singularBatchRLP{
		ParentHash:   b.ParentHash,
		EpochNumber:  new(big.Int).SetUint64(b.EpochNumber),
		EpochHash:    b.EpochHash,
		Timestamp:    new(big.Int).SetUint64(b.Timestamp),
		Transactions: b.Transactions,
	})
	if err != nil {
		return nil, err
	}
	out := make([]byte, 1+len(payload))
	out[0] = BatchTypeSingular
	copy(out[1:], payload)
	return out, nil
}

// DecodeSingularBatch parses a typed singular batch payload (type ++ rlp).
func DecodeSingularBatch(data []byte) (SingularBatch, error) {
	if len(data) < 2 {
		return SingularBatch{}, fmt.Errorf("singular batch too short")
	}
	if data[0] != BatchTypeSingular {
		return SingularBatch{}, fmt.Errorf("not a singular batch (type %d)", data[0])
	}
	var raw singularBatchRLP
	if err := rlp.DecodeBytes(data[1:], &raw); err != nil {
		return SingularBatch{}, fmt.Errorf("rlp decode singular: %w", err)
	}
	if raw.EpochNumber == nil || raw.Timestamp == nil {
		return SingularBatch{}, fmt.Errorf("missing epoch/timestamp")
	}
	if !raw.EpochNumber.IsUint64() || !raw.Timestamp.IsUint64() {
		return SingularBatch{}, fmt.Errorf("epoch/timestamp overflow")
	}
	return SingularBatch{
		ParentHash:   raw.ParentHash,
		EpochNumber:  raw.EpochNumber.Uint64(),
		EpochHash:    raw.EpochHash,
		Timestamp:    raw.Timestamp.Uint64(),
		Transactions: raw.Transactions,
	}, nil
}

// EncodeBatchForChannel RLP-encodes the typed batch as a byte string for the channel stream.
// Channel body = zlib( concat( rlp(typedBatchBytes)... ) ).
func EncodeBatchForChannel(typedBatch []byte) ([]byte, error) {
	return rlp.EncodeToBytes(typedBatch)
}

// ReadChannelBatches decodes all RLP byte-string batches from a decompressed channel body.
func ReadChannelBatches(body []byte) ([][]byte, error) {
	r := bytes.NewReader(body)
	var batches [][]byte
	for {
		var raw []byte
		err := rlp.Decode(r, &raw)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("channel batch rlp at index %d: %w", len(batches), err)
		}
		batches = append(batches, raw)
	}
	if len(batches) == 0 {
		return nil, fmt.Errorf("no batches in channel body")
	}
	return batches, nil
}
