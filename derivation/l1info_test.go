package derivation

import (
	"bytes"
	"math/big"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func ecotoneRollupConfig() *RollupConfig {
	zero := uint64(0)
	cfg := testRollupConfig()
	cfg.EcotoneTime = &zero
	cfg.FjordTime = &zero
	cfg.HoloceneTime = &zero
	cfg.IsthmusTime = &zero
	return cfg
}

func TestMarshalL1InfoBlobBaseFeeNonOne(t *testing.T) {
	cfg := ecotoneRollupConfig()
	l1 := &L1BlockHeader{
		Number:      10,
		Hash:        common.HexToHash("0x1111"),
		Time:        1_700_000_100,
		BaseFee:     big.NewInt(5),
		BlobBaseFee: big.NewInt(7),
		MixDigest:   common.HexToHash("0x2222"),
	}
	ts := cfg.Genesis.L2Time + cfg.BlockTime

	withSeven, err := marshalL1Info(cfg, cfg.Genesis.SystemConfig, 0, l1, ts)
	if err != nil {
		t.Fatal(err)
	}

	l1One := *l1
	l1One.BlobBaseFee = big.NewInt(1)
	withOne, err := marshalL1Info(cfg, cfg.Genesis.SystemConfig, 0, &l1One, ts)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(withSeven, withOne) {
		t.Fatal("expected Ecotone marshal bytes to differ when blobBaseFee changes from 1 to 7")
	}

	// Nil BlobBaseFee falls back to pre-Cancun default (1) for equivalence on idle Anvil.
	l1Nil := *l1
	l1Nil.BlobBaseFee = nil
	withNil, err := marshalL1Info(cfg, cfg.Genesis.SystemConfig, 0, &l1Nil, ts)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(withOne, withNil) {
		t.Fatal("nil BlobBaseFee should marshal same as explicit 1 (legacy Anvil default)")
	}

	// blobBaseFee sits after baseFee in marshalEcotoneBody.
	bodySeven := withSeven[4:]
	off := 8 + 8 + 8 + 8 + 32 // scalars + seq + l1Time + l1Number + baseFee
	got := new(big.Int).SetBytes(bytesTrimLeftZero(bodySeven[off : off+32]))
	if got.Cmp(big.NewInt(7)) != 0 {
		t.Fatalf("blobBaseFee field = %s want 7", got)
	}
}

func bytesTrimLeftZero(b []byte) []byte {
	i := 0
	for i < len(b) && b[i] == 0 {
		i++
	}
	return b[i:]
}

func TestL1InfoDepositBytesBlobBaseFeeAffectsOutput(t *testing.T) {
	cfg := ecotoneRollupConfig()
	l1 := &L1BlockHeader{
		Number:      3,
		Hash:        common.HexToHash("0xabcd"),
		Time:        1_700_000_050,
		BaseFee:     big.NewInt(1),
		BlobBaseFee: big.NewInt(42),
	}
	ts := cfg.Genesis.L2Time + cfg.BlockTime
	raw, err := L1InfoDepositBytes(cfg, cfg.Genesis.SystemConfig, 0, l1, ts)
	if err != nil {
		t.Fatal(err)
	}
	l1.BlobBaseFee = big.NewInt(1)
	rawOne, err := L1InfoDepositBytes(cfg, cfg.Genesis.SystemConfig, 0, l1, ts)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(raw, rawOne) {
		t.Fatal("deposit tx bytes should change with non-1 blob base fee")
	}
}
