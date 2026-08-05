package derivation

import (
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func testRollup901() *RollupConfig {
	return &RollupConfig{
		Genesis: struct {
			L1 struct {
				Hash   common.Hash `json:"hash"`
				Number uint64      `json:"number"`
			} `json:"l1"`
			L2Time       uint64       `json:"l2_time"`
			SystemConfig SystemConfig `json:"system_config"`
		}{L2Time: 1_700_000_000},
		BlockTime: 2,
	}
}

func TestBlockNumberFromTimestamp(t *testing.T) {
	cfg := testRollup901()

	cases := []struct {
		ts      uint64
		want    uint64
		wantErr bool
	}{
		{1_700_000_002, 1, false},
		{1_700_000_040, 20, false},
		{1_700_000_120, 60, false},
		{1_700_000_000, 0, true}, // genesis time maps to block 0
		{1_699_999_999, 0, true}, // before genesis
		{1_700_000_003, 0, true}, // drift
	}
	for _, tc := range cases {
		got, err := blockNumberFromTimestamp(cfg, tc.ts)
		if tc.wantErr {
			if err == nil {
				t.Fatalf("ts %d: expected error", tc.ts)
			}
			continue
		}
		if err != nil {
			t.Fatalf("ts %d: %v", tc.ts, err)
		}
		if got != tc.want {
			t.Fatalf("ts %d: got block %d want %d", tc.ts, got, tc.want)
		}
	}
}

func TestBlockNumberFromTimestampDefaultBlockTime(t *testing.T) {
	cfg := testRollup901()
	cfg.BlockTime = 0
	got, err := blockNumberFromTimestamp(cfg, 1_700_000_004)
	if err != nil {
		t.Fatal(err)
	}
	if got != 2 {
		t.Fatalf("got %d want 2 with default block_time", got)
	}
}

func TestBlockNumberFromTimestampBlockOneBoundary(t *testing.T) {
	cfg := testRollup901()
	// First post-genesis block: exactly genesis.l2_time + block_time.
	got, err := blockNumberFromTimestamp(cfg, cfg.Genesis.L2Time+cfg.BlockTime)
	if err != nil {
		t.Fatal(err)
	}
	if got != 1 {
		t.Fatalf("got block %d want 1", got)
	}
}

func TestDuplicateBatchLastWriteWins(t *testing.T) {
	prev := BlockInput{Number: 10, Timestamp: 100, L1SourceTx: [32]byte{1}}
	next := BlockInput{Number: 10, Timestamp: 100, L1SourceTx: [32]byte{2}}
	// logDuplicateBlock must not panic
	logDuplicateBlock(10, prev, next)
}
