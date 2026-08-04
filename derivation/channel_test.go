package derivation

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/StephenForte/ForteL2/batcher"
	"github.com/ethereum/go-ethereum/common"
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
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skip("operator Sepolia golden fixture not present (testdata/sepolia/window.json); skip-with-notice")
	}

	var report VerifyReport
	if err := json.Unmarshal(raw, &report); err != nil {
		t.Fatalf("unmarshal VerifyReport: %v", err)
	}
	assertVerifyReportIntegrity(t, &report)
	t.Logf("sepolia golden replay: window %d–%d matched=%d mismatched=%d blocks=%d",
		report.WindowStart, report.WindowEnd, report.Matched, report.Mismatched, len(report.Blocks))
}

// assertVerifyReportIntegrity checks contiguous numbers, every block Match,
// and derived==expected (D-0009 fixture-replay upgrade).
func assertVerifyReportIntegrity(t *testing.T, report *VerifyReport) {
	t.Helper()
	if report.WindowEnd < report.WindowStart {
		t.Fatalf("invalid window %d–%d", report.WindowStart, report.WindowEnd)
	}
	wantLen := report.WindowEnd - report.WindowStart + 1
	if uint64(len(report.Blocks)) != wantLen {
		t.Fatalf("blocks len=%d want %d for window %d–%d", len(report.Blocks), wantLen, report.WindowStart, report.WindowEnd)
	}
	if report.Mismatched != 0 {
		t.Fatalf("mismatched=%d want 0", report.Mismatched)
	}
	if uint64(report.Matched) != wantLen {
		t.Fatalf("matched=%d want %d", report.Matched, wantLen)
	}
	for i, b := range report.Blocks {
		wantNum := report.WindowStart + uint64(i)
		if b.Number != wantNum {
			t.Fatalf("blocks[%d].Number=%d want %d (contiguous)", i, b.Number, wantNum)
		}
		if !b.Match {
			t.Fatalf("blocks[%d] number=%d Match=false", i, b.Number)
		}
		if b.DerivedHash != b.ExpectedHash {
			t.Fatalf("blocks[%d] number=%d derived=%s expected=%s", i, b.Number, b.DerivedHash, b.ExpectedHash)
		}
		if b.DerivedHash == (common.Hash{}) {
			t.Fatalf("blocks[%d] number=%d zero derived hash", i, b.Number)
		}
	}
}

func TestAssertVerifyReportIntegrityUnit(t *testing.T) {
	rep := &VerifyReport{
		Matched:     2,
		Mismatched:  0,
		WindowStart: 10,
		WindowEnd:   11,
		Blocks: []BlockResult{
			{Number: 10, DerivedHash: [32]byte{1}, ExpectedHash: [32]byte{1}, Match: true},
			{Number: 11, DerivedHash: [32]byte{2}, ExpectedHash: [32]byte{2}, Match: true},
		},
	}
	assertVerifyReportIntegrity(t, rep)
}
