//go:build live

package proposer

import (
	"fmt"
	"os"
	"testing"
)

// Three distinct recent timestamps the live op-node must still serve.
// Re-run with: FORTEL2_LIVE_OPNODE=http://127.0.0.1:9547 go test -tags live -run TestLiveSuperRoot -count=1
func TestLiveSuperRoot(t *testing.T) {
	url := os.Getenv("FORTEL2_LIVE_OPNODE")
	if url == "" {
		t.Fatal("FORTEL2_LIVE_OPNODE is required")
	}
	ctx := t.Context()
	clock, err := FetchRollupClock(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	heads, err := FetchSyncHeads(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	fin, err := TimestampForL2Block(clock.GenesisTime, clock.BlockTime, heads.FinalizedL2)
	if err != nil {
		t.Fatal(err)
	}
	// Finalized, and two earlier days, each already on a block boundary.
	timestamps := []uint64{fin, fin - 86400, fin - 2*86400}
	for _, ts := range timestamps {
		block, err := L2BlockForTimestamp(clock.GenesisTime, clock.BlockTime, ts)
		if err != nil {
			t.Fatal(err)
		}
		sr, err := SuperRootForBlock(ctx, url, clock, block, heads.UnsafeL2)
		if err != nil {
			t.Fatal(err)
		}
		node, err := FetchSuperRootAtTimestamp(ctx, url, ts)
		if err != nil {
			t.Fatal(err)
		}
		if sr.Hash != node {
			t.Fatalf("timestamp %d ours %s op-node %s", ts, sr.Hash.Hex(), node.Hex())
		}
		fmt.Printf("LIVE timestamp=%d block=%d ours=%s op-node=%s\n", ts, block, sr.Hash.Hex(), node.Hex())
	}
}
