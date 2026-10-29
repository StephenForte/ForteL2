package proposer

import (
	"bytes"
	"encoding/hex"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Recorded from the live op-node at 127.0.0.1:9547 on 2026-10-29.
// finalized L2 block 2936314, timestamp 1793305916, chain 852.
const liveSuperRootPreimageHex = "01000000006ae3ad3c0000000000000000000000000000000000000000000000000000000000000354fccdd69abef076b8544147eeaabdb05a5fd3dc17ef9199e4e5990cb136d8da0d"

func TestEncodeSuperRootFixture(t *testing.T) {
	ts := uint64(1793305916)
	output := common.HexToHash("0xfccdd69abef076b8544147eeaabdb05a5fd3dc17ef9199e4e5990cb136d8da0d")
	wantPre, err := hex.DecodeString(liveSuperRootPreimageHex)
	if err != nil {
		t.Fatal(err)
	}
	if len(wantPre) != SuperRootOneChainLen {
		t.Fatalf("fixture len %d", len(wantPre))
	}
	got, err := EncodeSuperRoot(ts, []ChainOutput{{ChainID: 852, OutputRoot: output}})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Preimage, wantPre) {
		t.Fatalf("preimage %x want %x", got.Preimage, wantPre)
	}
	wantHash := crypto.Keccak256Hash(wantPre)
	if got.Hash != wantHash {
		t.Fatalf("hash %s want %s", got.Hash.Hex(), wantHash.Hex())
	}
	if got.Hash.Hex() != "0x4dc0ed872ff0767543e5144eedce459e4950cedcb9846e89903c250c208669be" {
		t.Fatalf("live super root %s", got.Hash.Hex())
	}
	back, err := DecodeSuperRoot(got.Preimage)
	if err != nil {
		t.Fatal(err)
	}
	if back.Timestamp != ts || len(back.Chains) != 1 || back.Chains[0].ChainID != 852 || back.Chains[0].OutputRoot != output || back.Hash != got.Hash {
		t.Fatalf("round trip %+v", back)
	}
}

func TestEncodeSuperRootSortsChains(t *testing.T) {
	a := common.HexToHash("0x11")
	b := common.HexToHash("0x22")
	got, err := EncodeSuperRoot(10, []ChainOutput{
		{ChainID: 900, OutputRoot: a},
		{ChainID: 852, OutputRoot: b},
	})
	if err != nil {
		t.Fatal(err)
	}
	if got.Chains[0].ChainID != 852 || got.Chains[1].ChainID != 900 {
		t.Fatalf("order %+v", got.Chains)
	}
	if len(got.Preimage) != 9+64*2 {
		t.Fatalf("len %d", len(got.Preimage))
	}
}

func TestDecodeSuperRootRejectsOutputRootLength(t *testing.T) {
	if _, err := DecodeSuperRoot(make([]byte, 32)); err == nil {
		t.Fatal("32-byte extraData must not decode as a super root")
	}
	if _, err := DecodeSuperRoot(nil); err == nil {
		t.Fatal("empty")
	}
}

func TestL2BlockForTimestamp(t *testing.T) {
	const genesis, blockTime = uint64(1787433288), uint64(2)
	block, err := L2BlockForTimestamp(genesis, blockTime, 1793305916)
	if err != nil {
		t.Fatal(err)
	}
	if block != 2936314 {
		t.Fatalf("block %d", block)
	}
	if _, err := L2BlockForTimestamp(genesis, blockTime, 1793305917); err == nil {
		t.Fatal("non-boundary timestamp must error, not round")
	}
	if _, err := L2BlockForTimestamp(genesis, blockTime, genesis-1); err == nil {
		t.Fatal("before genesis")
	}
	if _, err := L2BlockForTimestamp(genesis, 0, genesis); err == nil {
		t.Fatal("zero block time")
	}
	ts, err := TimestampForL2Block(genesis, blockTime, block)
	if err != nil || ts != 1793305916 {
		t.Fatalf("timestamp %d err %v", ts, err)
	}
}

func TestSuperRootForBlockRefusesFuture(t *testing.T) {
	clock := RollupClock{GenesisTime: 1000, BlockTime: 2, L2ChainID: 852}
	_, err := SuperRootForBlock(t.Context(), "http://127.0.0.1:1", clock, 50, 10)
	if err == nil || !bytes.Contains([]byte(err.Error()), []byte("ahead")) {
		t.Fatalf("future timestamp must error, got %v", err)
	}
}
