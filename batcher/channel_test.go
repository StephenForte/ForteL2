package batcher

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestSingularRoundTrip(t *testing.T) {
	var parent, epoch [32]byte
	copy(parent[:], bytes.Repeat([]byte{0x11}, 32))
	copy(epoch[:], bytes.Repeat([]byte{0x22}, 32))
	b := SingularBatch{
		ParentHash:   parent,
		EpochNumber:  42,
		EpochHash:    epoch,
		Timestamp:    1_700_000_000,
		Transactions: [][]byte{[]byte{0x02, 0xf8, 0x01, 0x00}}, // opaque fixture bytes
	}
	enc, err := EncodeSingularBatch(b)
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeSingularBatch(enc)
	if err != nil {
		t.Fatal(err)
	}
	if got.EpochNumber != b.EpochNumber || got.Timestamp != b.Timestamp {
		t.Fatalf("fields: %+v", got)
	}
	if got.ParentHash != b.ParentHash || got.EpochHash != b.EpochHash {
		t.Fatal("hashes mismatch")
	}
	if !bytes.Equal(got.Transactions[0], b.Transactions[0]) {
		t.Fatal("tx mismatch")
	}
}

func TestChannelBuildRoundTrip(t *testing.T) {
	var parent, epoch [32]byte
	copy(parent[:], bytes.Repeat([]byte{0xaa}, 32))
	copy(epoch[:], bytes.Repeat([]byte{0xbb}, 32))
	batches := []SingularBatch{{
		ParentHash:   parent,
		EpochNumber:  9,
		EpochHash:    epoch,
		Timestamp:    12345,
		Transactions: nil,
	}}
	var chID [16]byte
	copy(chID[:], []byte("0123456789abcdef"))
	payload, frames, err := BuildBatcherTxFromSingularBatches(batches, ChannelOptions{
		MaxFrameData: 16, // force multi-frame on tiny channel
		ChannelID:    chID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) < 2 {
		t.Fatalf("expected multiple frames, got %d (channel may be tiny)", len(frames))
	}
	ver, parsed, err := ParseBatcherTxPayload(payload)
	if err != nil {
		t.Fatal(err)
	}
	if ver != BatcherTxVersionCalldata {
		t.Fatalf("version %d", ver)
	}
	joined, err := JoinFrameData(parsed)
	if err != nil {
		t.Fatal(err)
	}
	body, err := DecompressChannelZlib(joined)
	if err != nil {
		t.Fatal(err)
	}
	rawBatches, err := ReadChannelBatches(body)
	if err != nil {
		t.Fatal(err)
	}
	if len(rawBatches) != 1 {
		t.Fatalf("batches %d", len(rawBatches))
	}
	got, err := DecodeSingularBatch(rawBatches[0])
	if err != nil {
		t.Fatal(err)
	}
	if got.EpochNumber != 9 || got.Timestamp != 12345 {
		t.Fatalf("decoded %+v", got)
	}
}

func TestDecompressLiveLocalChannelFrame(t *testing.T) {
	// Captured from local Anvil batcher tx 0x97de57af… (see spike-phase-4-batcher.md).
	// Full batcher tx input; we parse frames then inflate.
	input, err := hex.DecodeString("006184cc6618ec85c54b8b50ddc6d427dc00000000012678dadae1c7f0c37b81f9bd89f93ee597bdfce3eb7bf28b34d74d1348cc08fe6f707e7de266fe92132efc4d69f90bea1f38f169666cbc6df5f3eecdd3179b8eec99d395f5e9485e52f497cce2b0ad3b96b464c572691c809877329ed3fae9375f95dd7e9fae6f76332ed7bcafaaace7b7f4a6b184f7c635134b6e106b9e16d43ce1909c639ca60b55ef5bb58965d737a49c746a3f117876b17d8990e7db848ed3c9c49aa70335af99d19daf6d937cbae53c7da9dc567eb9f32f538f6c513f3ac776cfb1b7571282f589354f0f6a5ec6d9f5276e26f525e5e627bc65600b7af0660ed7d2bd2ad1cc6cd70fafeeff55bf8c58f30ca0e67db96329522c6874bc6b72d273868fc7d7b845fdfc241aa2527079fdcf8ec677bf5e106b9ed10140000000ffff069afa0501")
	if err != nil {
		t.Fatal(err)
	}
	_, frames, err := ParseBatcherTxPayload(input)
	if err != nil {
		t.Fatal(err)
	}
	joined, err := JoinFrameData(frames)
	if err != nil {
		t.Fatal(err)
	}
	if joined[0] != 0x78 { // zlib header
		t.Fatalf("expected raw zlib channel (no Fjord prefix), got 0x%x", joined[0])
	}
	body, err := DecompressChannelZlib(joined)
	if err != nil {
		t.Fatal(err)
	}
	rawBatches, err := ReadChannelBatches(body)
	if err != nil {
		t.Fatal(err)
	}
	if len(rawBatches) == 0 {
		t.Fatal("expected >=1 batch")
	}
	// Local stock batcher may emit singular and/or span; accept either for this fixture.
	switch rawBatches[0][0] {
	case BatchTypeSingular:
		sb, err := DecodeSingularBatch(rawBatches[0])
		if err != nil {
			t.Fatal(err)
		}
		if sb.EpochNumber == 0 && sb.Timestamp == 0 {
			t.Fatal("empty singular batch unexpected")
		}
		t.Logf("live fixture: %d singular/span-typed batches; first singular epoch=%d ts=%d txs=%d",
			len(rawBatches), sb.EpochNumber, sb.Timestamp, len(sb.Transactions))
	case 1: // span batch type
		t.Logf("live fixture: first batch is span (type 1), len=%d; singular encode path still unit-tested", len(rawBatches[0]))
	default:
		t.Fatalf("unknown batch type %d", rawBatches[0][0])
	}
}
