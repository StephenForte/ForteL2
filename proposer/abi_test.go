package proposer

import (
	"bytes"
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func TestEncodeCreateSelector(t *testing.T) {
	root := common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	extra := PackExtraData(22)
	data, err := EncodeCreate(1, root, extra)
	if err != nil {
		t.Fatal(err)
	}
	// create(uint32,bytes32,bytes) selector = first 4 bytes of keccak.
	if len(data) < 4 {
		t.Fatalf("calldata too short: %d", len(data))
	}
	// Re-encode and ensure stable.
	data2, err := EncodeCreate(1, root, extra)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, data2) {
		t.Fatal("EncodeCreate not stable")
	}
	// Method id should be non-zero and match a second pack.
	if bytes.Equal(data[:4], []byte{0, 0, 0, 0}) {
		t.Fatal("zero selector")
	}
}

func TestEncodeDecodeGameCount(t *testing.T) {
	calldata, err := EncodeGameCount()
	if err != nil {
		t.Fatal(err)
	}
	if len(calldata) != 4 {
		t.Fatalf("gameCount calldata len=%d want 4", len(calldata))
	}
	// Simulate ABI-encoded uint256 = 7
	raw, _ := hex.DecodeString("0000000000000000000000000000000000000000000000000000000000000007")
	n, err := DecodeGameCount(raw)
	if err != nil {
		t.Fatal(err)
	}
	if n.Cmp(big.NewInt(7)) != 0 {
		t.Fatalf("got %s want 7", n)
	}
}

func TestEncodeDecodeGameAtIndex(t *testing.T) {
	calldata, err := EncodeGameAtIndex(big.NewInt(3))
	if err != nil {
		t.Fatal(err)
	}
	if len(calldata) != 4+32 {
		t.Fatalf("gameAtIndex calldata len=%d", len(calldata))
	}
	// gameType=1, timestamp=1700000000, proxy=0x1111…1111
	raw, _ := hex.DecodeString(
		"0000000000000000000000000000000000000000000000000000000000000001" +
			"00000000000000000000000000000000000000000000000000000000654c1e00" +
			"0000000000000000000000001111111111111111111111111111111111111111",
	)
	got, err := DecodeGameAtIndex(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.GameType != 1 {
		t.Fatalf("gameType=%d", got.GameType)
	}
	if got.Timestamp != 0x654c1e00 {
		t.Fatalf("timestamp=%d", got.Timestamp)
	}
	if got.Proxy != common.HexToAddress("0x1111111111111111111111111111111111111111") {
		t.Fatalf("proxy=%s", got.Proxy.Hex())
	}
}

func TestEncodeDecodeInitBonds(t *testing.T) {
	calldata, err := EncodeInitBonds(1)
	if err != nil {
		t.Fatal(err)
	}
	if len(calldata) != 4+32 {
		t.Fatalf("initBonds calldata len=%d", len(calldata))
	}
	raw, _ := hex.DecodeString("0000000000000000000000000000000000000000000000000000000000000000")
	bond, err := DecodeInitBonds(raw)
	if err != nil {
		t.Fatal(err)
	}
	if bond.Sign() != 0 {
		t.Fatalf("bond=%s want 0", bond)
	}
}
