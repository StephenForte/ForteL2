package main

import (
	"context"
	"errors"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

func TestReceiptConfirmed(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name          string
		head          uint64
		receiptBlock  uint64
		confirmations uint64
		want          bool
	}{
		{name: "one conf at receipt block", head: 10, receiptBlock: 10, confirmations: 1, want: true},
		{name: "one conf before receipt", head: 9, receiptBlock: 10, confirmations: 1, want: false},
		{name: "two confs need one child", head: 10, receiptBlock: 10, confirmations: 2, want: false},
		{name: "two confs satisfied", head: 11, receiptBlock: 10, confirmations: 2, want: true},
		{name: "zero treated as one", head: 10, receiptBlock: 10, confirmations: 0, want: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := receiptConfirmed(tc.head, tc.receiptBlock, tc.confirmations)
			if got != tc.want {
				t.Fatalf("receiptConfirmed(%d,%d,%d)=%v want %v",
					tc.head, tc.receiptBlock, tc.confirmations, got, tc.want)
			}
		})
	}
}

func TestIsHardTxFailure(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{name: "nil", err: nil, want: false},
		{name: "receipt timeout", err: errors.New("timeout waiting for receipt 0xabc"), want: false},
		{name: "confirmations timeout", err: errors.New("timeout waiting for 2 confirmations of 0xabc (receipt block 1)"), want: false},
		{name: "reverted", err: errors.New("tx failed status=0"), want: true},
		{name: "reorg", err: errors.New("receipt for 0xabc disappeared after reorg"), want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := isHardTxFailure(tc.err); got != tc.want {
				t.Fatalf("isHardTxFailure(%v)=%v want %v", tc.err, got, tc.want)
			}
		})
	}
}

type fakeL1TxTracker struct {
	byHashTx      *types.Transaction
	byHashPending bool
	byHashErr     error
	receipt       *types.Receipt
	receiptErr    error
}

func (f *fakeL1TxTracker) TransactionByHash(context.Context, common.Hash) (*types.Transaction, bool, error) {
	return f.byHashTx, f.byHashPending, f.byHashErr
}

func (f *fakeL1TxTracker) TransactionReceipt(context.Context, common.Hash) (*types.Receipt, error) {
	return f.receipt, f.receiptErr
}

func TestShouldClearPending(t *testing.T) {
	t.Parallel()
	hash := common.HexToHash("0xabc")
	ctx := context.Background()
	dummyTx := types.NewTx(&types.LegacyTx{Nonce: 1, GasPrice: big.NewInt(1), Gas: 21000})

	cases := []struct {
		name       string
		waitErr    error
		l1         *fakeL1TxTracker
		wantClear  bool
		wantReason string
	}{
		{
			name:       "reverted clears",
			waitErr:    errors.New("tx failed status=0"),
			l1:         &fakeL1TxTracker{},
			wantClear:  true,
			wantReason: "reverted",
		},
		{
			name:    "timeout still pending keeps",
			waitErr: errors.New("timeout waiting for receipt 0xabc"),
			l1: &fakeL1TxTracker{
				byHashTx:      dummyTx,
				byHashPending: true,
			},
			wantClear:  false,
			wantReason: "still-pending",
		},
		{
			name:    "timeout already mined keeps",
			waitErr: errors.New("timeout waiting for 2 confirmations of 0xabc (receipt block 1)"),
			l1: &fakeL1TxTracker{
				byHashTx:      dummyTx,
				byHashPending: false,
			},
			wantClear:  false,
			wantReason: "still-known",
		},
		{
			name:    "dropped allows retry",
			waitErr: errors.New("timeout waiting for receipt 0xabc"),
			l1: &fakeL1TxTracker{
				byHashErr:  ethereum.NotFound,
				receiptErr: ethereum.NotFound,
			},
			wantClear:  true,
			wantReason: "dropped-or-unknown",
		},
		{
			name:    "rpc error keeps pending",
			waitErr: errors.New("timeout waiting for receipt 0xabc"),
			l1: &fakeL1TxTracker{
				byHashErr: errors.New("429 too many requests"),
			},
			wantClear:  false,
			wantReason: "rpc-error-keep-pending",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			clear, reason := shouldClearPending(ctx, tc.l1, hash, tc.waitErr)
			if clear != tc.wantClear || reason != tc.wantReason {
				t.Fatalf("shouldClearPending → (%v, %q) want (%v, %q)",
					clear, reason, tc.wantClear, tc.wantReason)
			}
		})
	}
}

func TestTxStillTracked(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	hash := common.HexToHash("0xdef")
	dummyTx := types.NewTx(&types.LegacyTx{Nonce: 2, GasPrice: big.NewInt(1), Gas: 21000})

	known, pending, err := txStillTracked(ctx, &fakeL1TxTracker{
		byHashTx: dummyTx, byHashPending: true,
	}, hash)
	if err != nil || !known || !pending {
		t.Fatalf("pending tx: known=%v pending=%v err=%v", known, pending, err)
	}

	known, pending, err = txStillTracked(ctx, &fakeL1TxTracker{
		byHashErr: ethereum.NotFound,
		receipt:   &types.Receipt{BlockNumber: big.NewInt(1)},
	}, hash)
	if err != nil || !known || pending {
		t.Fatalf("receipt-only: known=%v pending=%v err=%v", known, pending, err)
	}

	known, pending, err = txStillTracked(ctx, &fakeL1TxTracker{
		byHashErr: ethereum.NotFound, receiptErr: ethereum.NotFound,
	}, hash)
	if err != nil || known || pending {
		t.Fatalf("dropped: known=%v pending=%v err=%v", known, pending, err)
	}
}
