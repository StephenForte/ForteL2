package derivation

import (
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func TestParseBedrockL1InfoCalldata(t *testing.T) {
	var body []byte
	body = append(body, padU64(42)...)   // l1Number
	body = append(body, padU64(99)...)   // l1Time
	body = append(body, make([]byte, 32)...) // baseFee
	l1Hash := common.BytesToHash([]byte("l1-hash-for-bedrock-test!!"))
	body = append(body, l1Hash.Bytes()...)
	body = append(body, padU64(7)...) // seqNumber
	body = append(body, make([]byte, 32*3)...) // batcher + overhead + scalar

	data := append(append([]byte{}, l1InfoFuncBedrockBytes4...), body...)
	got, err := parseL1InfoCalldata(data)
	if err != nil {
		t.Fatal(err)
	}
	if got.L1OriginNumber != 42 || got.SeqNumber != 7 || got.L1OriginHash != l1Hash {
		t.Fatalf("got %+v", got)
	}
}

func TestParseEcotoneFamilyL1InfoCalldata(t *testing.T) {
	var body []byte
	body = append(body, 0, 0, 0, 1) // baseScalar
	body = append(body, 0, 0, 0, 2) // blobScalar
	var seq [8]byte
	putU64(seq[:], 11)
	body = append(body, seq[:]...)
	var l1Time [8]byte
	putU64(l1Time[:], 1234)
	body = append(body, l1Time[:]...)
	var l1Num [8]byte
	putU64(l1Num[:], 77)
	body = append(body, l1Num[:]...)
	body = append(body, make([]byte, 32)...) // baseFee
	body = append(body, make([]byte, 32)...) // blobBaseFee
	l1Hash := common.BytesToHash([]byte("l1-hash-for-ecotone-test!!"))
	body = append(body, l1Hash.Bytes()...)
	body = append(body, make([]byte, 32)...) // batcher padded

	for _, sel := range [][]byte{l1InfoFuncEcotoneBytes4, l1InfoFuncIsthmusBytes4, l1InfoFuncJovianBytes4} {
		data := append(append([]byte{}, sel...), body...)
		got, err := parseL1InfoCalldata(data)
		if err != nil {
			t.Fatalf("selector 0x%x: %v", sel, err)
		}
		if got.L1OriginNumber != 77 || got.SeqNumber != 11 || got.L1OriginHash != l1Hash {
			t.Fatalf("selector 0x%x: got %+v", sel, got)
		}
	}
}

func TestParseL1InfoDepositRoundTrip(t *testing.T) {
	cfg := testRollup901()
	l1 := &L1BlockHeader{
		Number: 55,
		Time:   999,
		Hash:   common.BytesToHash([]byte("roundtrip-l1-origin-hash!!")),
		BaseFee: nil,
	}
	raw, err := L1InfoDepositBytes(cfg, cfg.Genesis.SystemConfig, 3, l1, 1_700_000_010)
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParseL1InfoDeposit(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.L1OriginNumber != 55 || got.SeqNumber != 3 || got.L1OriginHash != l1.Hash {
		t.Fatalf("got %+v", got)
	}
}

func padU64(v uint64) []byte {
	var word [32]byte
	putU64(word[24:], v)
	return word[:]
}

func putU64(b []byte, v uint64) {
	for i := 7; i >= 0; i-- {
		b[i] = byte(v)
		v >>= 8
	}
}
