// Command sequencer-stub is the US-062 minimal block-building sequencer stub.
// It seals empty L2 blocks on an isolated op-geth via the Engine API and
// follow-validates them with US-061 attribute derivation (D-T6-2).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/StephenForte/ForteL2/derivation"
)

func main() {
	rollup := flag.String("rollup", "", "path to rollup.json")
	l1 := flag.String("l1", "http://127.0.0.1:8545", "L1 RPC URL (read-only)")
	sealAuth := flag.String("seal-auth", "http://127.0.0.1:19751", "isolated EL Engine API URL")
	sealHTTP := flag.String("seal-http", "http://127.0.0.1:19745", "isolated EL HTTP RPC")
	jwt := flag.String("jwt", "", "JWT secret file for isolated EL")
	blocks := flag.Uint64("blocks", 10, "number of consecutive empty L2 blocks to build")
	l1Origin := flag.Uint64("l1-origin", 0, "L1 origin block number (0 = auto from genesis.l1 or head L1-info; validated)")
	jsonOut := flag.Bool("json", false, "emit JSON report on stdout")
	flag.Parse()

	if *rollup == "" {
		fmt.Fprintln(os.Stderr, "usage: sequencer-stub -rollup $DEPLOY_DIR/rollup.json -jwt JWT [flags]")
		os.Exit(2)
	}
	if *jwt == "" {
		fmt.Fprintln(os.Stderr, "error: -jwt required (isolated sealing EL)")
		os.Exit(2)
	}
	if *blocks < 1 {
		fmt.Fprintln(os.Stderr, "error: -blocks must be >= 1")
		os.Exit(2)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	sealer, err := derivation.StartSealingEL(ctx, *sealAuth, *jwt, *sealHTTP)
	if err != nil {
		fatal(err)
	}
	defer sealer.Close()

	report, err := derivation.RunSequencerStub(ctx, derivation.StubOptions{
		RollupPath:  *rollup,
		L1RPC:       *l1,
		Blocks:      *blocks,
		L1OriginNum: *l1Origin,
	}, sealer)

	human := os.Stdout
	if *jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(report)
		human = os.Stderr
	}

	if report != nil {
		fmt.Fprintf(human, "engine API: %s\n", report.EngineAPI)
		fmt.Fprintf(human, "start head: num=%d hash=%s\n", report.StartParentNum, report.StartParentHash)
		fmt.Fprintf(human, "l1 origin:  num=%d hash=%s\n", report.L1OriginNumber, report.L1OriginHash)
		for _, b := range report.Built {
			fmt.Fprintf(human, "  built block %d hash=%s parent=%s txs=%d seq=%d\n",
				b.Number, b.Hash, b.ParentHash, b.TxCount, b.SeqNumber)
		}
		for _, n := range report.FollowNotes {
			fmt.Fprintf(human, "follow: %s\n", n)
		}
		if report.FollowOK {
			fmt.Fprintf(human, "FOLLOW-VALIDATE: PASS (%d blocks)\n", len(report.Built))
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(human, "sequencer-stub: PASS — built %d consecutive blocks\n", *blocks)
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "error: %v\n", err)
	os.Exit(1)
}
