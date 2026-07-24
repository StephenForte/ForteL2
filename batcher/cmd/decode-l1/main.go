// decode-l1 fetches an L1 transaction and prints OP Stack batcher frame metadata.
//
//	go run ./cmd/decode-l1 -rpc "$L1_RPC_URL" -tx 0x...
//
// Optional: -inbox 0x... to assert tx.to matches Batch Inbox.
package main

import (
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/StephenForte/ForteL2/batcher"
)

func main() {
	rpc := flag.String("rpc", "", "L1 HTTP RPC URL")
	txHash := flag.String("tx", "", "L1 batcher transaction hash (0x...)")
	inbox := flag.String("inbox", "", "optional Batch Inbox address; if set, require tx.to match")
	flag.Parse()
	if *rpc == "" || *txHash == "" {
		fmt.Fprintln(os.Stderr, "usage: decode-l1 -rpc <L1_RPC> -tx <hash> [-inbox <addr>]")
		os.Exit(2)
	}

	ctx := context.Background()
	to, from, input, err := ethGetTransaction(ctx, *rpc, *txHash)
	if err != nil {
		fmt.Fprintf(os.Stderr, "rpc: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("tx=%s\nfrom=%s\nto=%s\ninput_bytes=%d\n", *txHash, from, to, len(input))
	if *inbox != "" && !strings.EqualFold(to, *inbox) {
		fmt.Fprintf(os.Stderr, "error: tx.to %s != inbox %s\n", to, *inbox)
		os.Exit(1)
	}

	ver, frames, err := batcher.ParseBatcherTxPayload(input)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse: %v\ninput_prefix=%s\n", err, hex.EncodeToString(prefix(input, 32)))
		os.Exit(1)
	}
	fmt.Printf("batcher_tx_version=%d\nframes=%d\n", ver, len(frames))
	for i, f := range frames {
		fmt.Printf("  [%d] channel=%s frame_number=%d data_len=%d is_last=%v\n",
			i, batcher.ChannelIDHex(f.ChannelID), f.FrameNumber, len(f.Data), f.IsLast)
	}
}

func prefix(b []byte, n int) []byte {
	if len(b) < n {
		return b
	}
	return b[:n]
}
