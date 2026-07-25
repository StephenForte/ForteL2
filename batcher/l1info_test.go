package batcher

import (
	"encoding/binary"
	"encoding/hex"
	"testing"
)

func TestParseL1InfoEpochEcotone(t *testing.T) {
	// Synthetic Ecotone layout with number=42, hash=0x22…
	data := make([]byte, 4+4+4+8+8+8+32+32+32+32)
	copy(data[0:4], l1InfoEcotoneSel[:])
	numOff := 4 + 4 + 4 + 8 + 8
	binary.BigEndian.PutUint64(data[numOff:numOff+8], 42)
	hashOff := numOff + 8 + 32 + 32
	for i := 0; i < 32; i++ {
		data[hashOff+i] = 0x22
	}
	got, err := ParseL1InfoEpoch(data)
	if err != nil {
		t.Fatal(err)
	}
	if got.Number != 42 {
		t.Fatalf("number %d", got.Number)
	}
	for i := 0; i < 32; i++ {
		if got.Hash[i] != 0x22 {
			t.Fatalf("hash %x", got.Hash)
		}
	}
}

func TestParseL1InfoEpochBedrock(t *testing.T) {
	data := make([]byte, 4+32*8)
	copy(data[0:4], l1InfoBedrockSel[:])
	data[4+31] = 7
	hashOff := 4 + 32*3
	for i := 0; i < 32; i++ {
		data[hashOff+i] = 0xab
	}
	got, err := ParseL1InfoEpoch(data)
	if err != nil {
		t.Fatal(err)
	}
	if got.Number != 7 {
		t.Fatalf("number %d", got.Number)
	}
	if got.Hash[0] != 0xab {
		t.Fatalf("hash %x", got.Hash)
	}
}

func TestBuildSingularBatch(t *testing.T) {
	data := make([]byte, 4+32*8)
	copy(data[0:4], l1InfoBedrockSel[:])
	data[4+31] = 9
	var parent [32]byte
	for i := range parent {
		parent[i] = 0x11
	}
	b, err := BuildSingularBatch(parent, 12345, data, [][]byte{{0x02, 0x01}})
	if err != nil {
		t.Fatal(err)
	}
	if b.EpochNumber != 9 || b.Timestamp != 12345 || b.ParentHash != parent {
		t.Fatalf("%+v", b)
	}
	enc, err := EncodeSingularBatch(b)
	if err != nil {
		t.Fatal(err)
	}
	if enc[0] != BatchTypeSingular {
		t.Fatal(hex.EncodeToString(enc[:4]))
	}
}
