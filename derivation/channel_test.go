package derivation

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/StephenForte/ForteL2/batcher"
)

func TestDecodeLocal901BatcherTx(t *testing.T) {
	path := filepath.Join("testdata", "local901", "batcher_tx.hex")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skip("fixture missing:", err)
	}
	input, err := decodeHexString(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	batches, err := DecodeBatcherChannel(input)
	if err != nil {
		t.Fatal(err)
	}
	if len(batches) != 15 {
		t.Fatalf("expected 15 batches, got %d", len(batches))
	}
	sb, err := batcher.DecodeSingularBatch(batches[0])
	if err != nil {
		t.Fatal(err)
	}
	if sb.EpochNumber == 0 || sb.Timestamp == 0 {
		t.Fatalf("unexpected first batch: %+v", sb)
	}
	t.Logf("local901 fixture: %d batches; first epoch=%d ts=%d", len(batches), sb.EpochNumber, sb.Timestamp)
}

func TestDecodeSyntheticChannel(t *testing.T) {
	var parent, epoch [32]byte
	copy(parent[:], []byte("parent-hash-for-test!!"))
	copy(epoch[:], []byte("epoch-hash-for-test!!!"))
	batches := []batcher.SingularBatch{{
		ParentHash:   parent,
		EpochNumber:  42,
		EpochHash:    epoch,
		Timestamp:    1_700_000_000,
		Transactions: nil,
	}}
	payload, _, err := batcher.BuildBatcherTxFromSingularBatches(batches, batcher.ChannelOptions{
		MaxFrameData: 100_000,
	})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := DecodeBatcherChannel(payload)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 1 {
		t.Fatalf("batches %d", len(raw))
	}
	got, err := batcher.DecodeSingularBatch(raw[0])
	if err != nil {
		t.Fatal(err)
	}
	if got.EpochNumber != 42 || got.Timestamp != 1_700_000_000 {
		t.Fatalf("decoded %+v", got)
	}
}

func TestSepoliaGoldenSkipped(t *testing.T) {
	path := filepath.Join("testdata", "sepolia", "window.json")
	if _, err := os.Stat(path); err != nil {
		t.Skip("operator Sepolia golden fixture not present (expected until T2 handoff capture)")
	}
}
