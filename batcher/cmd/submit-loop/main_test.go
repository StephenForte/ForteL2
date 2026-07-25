package main

import (
	"errors"
	"testing"
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
		{name: "reorg", err: errors.New("receipt for 0xabc disappeared after reorg"), want: true},
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
