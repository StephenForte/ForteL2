// decode-full walks an L1 batcher tx through frames → channel → batches.
//
//	go run ./cmd/decode-full -rpc "$L1_RPC_URL" -tx 0x...
//	go run ./cmd/decode-full -input 0x...   # raw batcher tx calldata (version byte + frames)
//
// Read-only spike tool for Phase 6 (US-060). Does not modify batcher library code.
package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/StephenForte/ForteL2/batcher"
)

func main() {
	rpc := flag.String("rpc", "", "L1 HTTP RPC URL (with -tx)")
	txHash := flag.String("tx", "", "L1 batcher transaction hash")
	inputHex := flag.String("input", "", "raw batcher tx calldata hex (alternative to -rpc/-tx)")
	inbox := flag.String("inbox", "", "optional Batch Inbox address; require tx.to match")
	flag.Parse()

	var input []byte
	var meta string
	switch {
	case *inputHex != "":
		var err error
		input, err = decodeHex(*inputHex)
		if err != nil {
			fatal("input hex: %v", err)
		}
		meta = "source=input_hex"
	case *rpc != "" && *txHash != "":
		to, from, raw, err := ethGetTransaction(*rpc, *txHash)
		if err != nil {
			fatal("rpc: %v", err)
		}
		if *inbox != "" && !strings.EqualFold(to, *inbox) {
			fatal("tx.to %s != inbox %s", to, *inbox)
		}
		input = raw
		meta = fmt.Sprintf("tx=%s from=%s to=%s input_bytes=%d", *txHash, from, to, len(input))
	default:
		fmt.Fprintln(os.Stderr, "usage: decode-full (-rpc <L1> -tx <hash> [-inbox <addr>]) | (-input <hex>)")
		os.Exit(2)
	}

	fmt.Println(meta)
	ver, frames, err := batcher.ParseBatcherTxPayload(input)
	if err != nil {
		fatal("parse batcher payload: %v", err)
	}
	fmt.Printf("batcher_tx_version=%d\nframes=%d\n", ver, len(frames))
	for i, f := range frames {
		fmt.Printf("  frame[%d] channel=%s number=%d data_len=%d is_last=%v\n",
			i, batcher.ChannelIDHex(f.ChannelID), f.FrameNumber, len(f.Data), f.IsLast)
	}

	joined, err := batcher.JoinFrameData(frames)
	if err != nil {
		fatal("join frames: %v", err)
	}
	fmt.Printf("channel_bytes=%d zlib_header=0x%02x%02x\n", len(joined), joined[0], joined[1])

	body, err := batcher.DecompressChannelZlib(joined)
	if err != nil {
		fatal("decompress channel: %v (Fjord brotli / channel-version prefix not implemented in spike tool)", err)
	}
	fmt.Printf("decompressed_channel_bytes=%d\n", len(body))

	rawBatches, err := batcher.ReadChannelBatches(body)
	if err != nil {
		fatal("read channel batches: %v", err)
	}
	fmt.Printf("batches_in_channel=%d\n", len(rawBatches))

	var singularCount, spanCount, otherCount int
	for i, raw := range rawBatches {
		if len(raw) == 0 {
			fmt.Printf("  batch[%d] type=? len=0\n", i)
			otherCount++
			continue
		}
		switch raw[0] {
		case batcher.BatchTypeSingular:
			sb, err := batcher.DecodeSingularBatch(raw)
			if err != nil {
				fmt.Printf("  batch[%d] type=singular decode_error=%v\n", i, err)
				otherCount++
				continue
			}
			singularCount++
			fmt.Printf("  batch[%d] type=singular epoch=%d epoch_hash=%s parent=%s timestamp=%d user_txs=%d\n",
				i, sb.EpochNumber, shortHex(sb.EpochHash[:]), shortHex(sb.ParentHash[:]), sb.Timestamp, len(sb.Transactions))
		case 1:
			spanCount++
			fmt.Printf("  batch[%d] type=span len=%d (decode not implemented — US-061 scope)\n", i, len(raw))
		default:
			otherCount++
			fmt.Printf("  batch[%d] type=%d len=%d (unknown)\n", i, raw[0], len(raw))
		}
	}
	fmt.Printf("summary singular=%d span=%d other=%d\n", singularCount, spanCount, otherCount)
}

func shortHex(b []byte) string {
	if len(b) < 4 {
		return "0x" + hex.EncodeToString(b)
	}
	return "0x" + hex.EncodeToString(b[:4]) + "…"
}

func decodeHex(s string) ([]byte, error) {
	s = strings.TrimPrefix(strings.ToLower(s), "0x")
	return hex.DecodeString(s)
}

func fatal(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}
