package batcher

import (
	"fmt"
)

// BuildSingularBatch builds a version-0 singular batch from L2 block fields.
// l1InfoDepositInput is the calldata of the first (L1-info) deposit tx.
// userTxs are EIP-2718 encodings of non-deposit transactions (deposits stripped).
func BuildSingularBatch(parentHash [32]byte, timestamp uint64, l1InfoDepositInput []byte, userTxs [][]byte) (SingularBatch, error) {
	if len(l1InfoDepositInput) == 0 {
		return SingularBatch{}, fmt.Errorf("missing l1 info deposit input")
	}
	epoch, err := ParseL1InfoEpoch(l1InfoDepositInput)
	if err != nil {
		return SingularBatch{}, fmt.Errorf("parse l1 info: %w", err)
	}
	txs := userTxs
	if txs == nil {
		txs = [][]byte{}
	}
	return SingularBatch{
		ParentHash:   parentHash,
		EpochNumber:  epoch.Number,
		EpochHash:    epoch.Hash,
		Timestamp:    timestamp,
		Transactions: txs,
	}, nil
}

// SplitDepositAndUserTxs partitions opaque EIP-2718 txs: first deposit provides
// L1-info input (caller still needs deposit calldata — use RPC tx.input), and
// non-deposit raw txs become the batch transaction list.
//
// Prefer BuildSingularBatch with explicit l1-info input from eth_getTransactionByHash.
func IsDepositTx(opaque []byte) bool {
	return len(opaque) > 0 && opaque[0] == DepositTxType
}
