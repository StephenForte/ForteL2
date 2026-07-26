package proposer

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestPackUnpackExtraData(t *testing.T) {
	cases := []uint64{0, 1, 22, 901, 1<<32 - 1, 1 << 40}
	for _, n := range cases {
		packed := PackExtraData(n)
		if len(packed) != ExtraDataSize {
			t.Fatalf("len=%d want %d", len(packed), ExtraDataSize)
		}
		// Leading 24 bytes must be zero.
		if !bytes.Equal(packed[:24], make([]byte, 24)) {
			t.Fatalf("leading bytes not zero: %x", packed[:24])
		}
		got, err := UnpackExtraData(packed)
		if err != nil {
			t.Fatalf("unpack %d: %v", n, err)
		}
		if got != n {
			t.Fatalf("round-trip: got %d want %d", got, n)
		}
	}
}

func TestUnpackExtraDataRejectsBadLength(t *testing.T) {
	if _, err := UnpackExtraData([]byte{1, 2, 3}); err == nil {
		t.Fatal("expected error for short extraData")
	}
}

func TestPackExtraDataFixture(t *testing.T) {
	// Matches stock op-proposer ExtraData() for SequenceNum=22.
	want, _ := hex.DecodeString("0000000000000000000000000000000000000000000000000000000000000016")
	got := PackExtraData(22)
	if !bytes.Equal(got, want) {
		t.Fatalf("got %x want %x", got, want)
	}
}
