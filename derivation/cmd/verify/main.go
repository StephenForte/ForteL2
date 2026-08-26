// Command verify is the US-061 derivation verifier CLI.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/StephenForte/ForteL2/derivation"
	"github.com/ethereum/go-ethereum/common"
)

func main() {
	rollup := flag.String("rollup", "", "path to rollup.json")
	l1 := flag.String("l1", "http://127.0.0.1:8545", "L1 RPC URL")
	refL2 := flag.String("ref-l2", "http://127.0.0.1:9545", "reference L2 EL RPC (read-only)")
	refNode := flag.String("ref-node", "http://127.0.0.1:9547", "reference op-node RPC (read-only)")
	sealAuth := flag.String("seal-auth", "http://127.0.0.1:19651", "sealing EL Engine API URL")
	sealHTTP := flag.String("seal-http", "http://127.0.0.1:19645", "sealing EL HTTP RPC")
	jwt := flag.String("jwt", "", "JWT secret file for sealing EL")
	start := flag.Uint64("start-l2", 1, "first L2 block (inclusive)")
	end := flag.Uint64("end-l2", 20, "last L2 block (inclusive)")
	channelTx := flag.String("channel-tx", "", "derive single channel from L1 tx hash")
	fromL1 := flag.Uint64("from-l1", 0, "first L1 block for inbox scan (0 = auto; on large chains use explicit bound or -scan-from-genesis)")
	scanFromGenesis := flag.Bool("scan-from-genesis", false, "allow L1 inbox scan from block 1 when L1 tip exceeds 1M blocks")
	anchoredHead := flag.Bool("anchored-head", false, "sealing EL was reset to start-l2-1 via debug_setHead")
	resumeL1Bound := flag.Bool("resume-l1-bound", false, "derive L1 inbox scan start from the sealing EL head: origin(M) - channel_timeout - margin, clamped at genesis.l1")
	l1Lookback := flag.Uint64("l1-lookback", 300, "L1 inbox scan lookback from anchor/safe origin when -from-l1 0")
	jsonOut := flag.Bool("json", false, "emit JSON report")
	compare := flag.String("compare", derivation.CompareReference, "comparison oracle: reference (legacy, uses -ref-l2) or proposals (factory root claims; -ref-l2 is not an authority)")
	factory := flag.String("factory", "", "DisputeGameFactory address (overrides -deploy-state)")
	asr := flag.String("asr", "", "AnchorStateRegistry address (overrides -deploy-state)")
	deployState := flag.String("deploy-state", "", "op-deployer state.json or deployments.json with factory/ASR proxies")
	gameType := flag.String("game-type", "", "override respected game type; empty resolves AnchorStateRegistry.respectedGameType() (no default)")
	flag.Parse()

	if *rollup == "" {
		fmt.Fprintln(os.Stderr, "usage: verify -rollup $DEPLOY_DIR/rollup.json [flags]")
		os.Exit(2)
	}
	if *jwt == "" {
		fmt.Fprintln(os.Stderr, "error: -jwt required (separate sealing EL)")
		os.Exit(2)
	}

	opts := derivation.VerifyOptions{
		RollupPath:      *rollup,
		L1RPC:           *l1,
		RefL2RPC:        *refL2,
		RefNodeRPC:      *refNode,
		SealingAuth:     *sealAuth,
		SealingHTTP:     *sealHTTP,
		StartL2:         *start,
		EndL2:           *end,
		FromL1Block:     *fromL1,
		ScanFromGenesis: *scanFromGenesis,
		AnchoredHead:    *anchoredHead,
		ResumeL1Bound:   *resumeL1Bound,
		L1Lookback:      *l1Lookback,
		Compare:         *compare,
	}
	if *channelTx != "" {
		opts.ChannelTx = common.HexToHash(*channelTx)
	}
	if *compare == derivation.CompareProposals {
		// Proposal mode must run without -ref-l2 as an authority (D-0097).
		opts.RefL2RPC = ""
		opts.RefNodeRPC = ""
		fac, asrAddr, err := derivation.ResolveProposalContracts(*deployState, *factory, *asr)
		if err != nil {
			fatal(err)
		}
		opts.Factory = fac
		opts.ASR = asrAddr
		gt, err := derivation.ParseGameTypeFlag(*gameType)
		if err != nil {
			fatal(err)
		}
		opts.GameTypeOverride = gt
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	sealer, err := derivation.StartSealingEL(ctx, *sealAuth, *jwt, *sealHTTP)
	if err != nil {
		fatal(err)
	}
	defer sealer.Close()

	report, err := derivation.Verify(ctx, opts, sealer)
	// With -json, stdout carries ONLY the JSON report (fixture-capture safe);
	// human-readable lines move to stderr.
	human := os.Stdout
	if *jsonOut {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(report)
		human = os.Stderr
	}
	printHeader(human, report)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: %v\n", err)
		os.Exit(1)
	}
	if *compare == derivation.CompareProposals {
		fmt.Fprintf(human, "PASS: proposals MATCH=%d SKIPPED=%d MISMATCH=%d (respected type %d)\n",
			derivation.ProposalMatchedCount(report), derivation.ProposalSkippedCount(report),
			derivation.ProposalMismatchedCount(report), derivation.ProposalRespectedType(report))
		return
	}
	fmt.Fprintf(human, "PASS: blocks %d–%d all match reference EL\n", *start, *end)
}

func printHeader(w io.Writer, r *derivation.VerifyReport) {
	if r == nil {
		return
	}
	if r.Compare == derivation.CompareProposals {
		derivation.WriteProposalReport(w, r)
		return
	}
	fmt.Fprintf(w, "reference safe_l2=%d hash=%s\n", r.ReferenceSafeL2.Number, r.ReferenceSafeL2.Hash)
	fmt.Fprintf(w, "reference unsafe_l2=%d hash=%s\n", r.ReferenceUnsafeL2.Number, r.ReferenceUnsafeL2.Hash)
	for _, b := range r.Blocks {
		status := "OK"
		if !b.Match {
			status = "MISMATCH"
		}
		fmt.Fprintf(w, "  block %d derived=%s expected=%s txs=%d source=%s %s\n",
			b.Number, b.DerivedHash, b.ExpectedHash, b.TxCount, b.Source, status)
	}
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "error: %v\n", err)
	os.Exit(1)
}

// waitForSealingEL is used by tests / runbook helpers.
func waitForSealingEL(ctx context.Context, url string) error {
	return derivation.WaitForRPC(ctx, url, 30*time.Second)
}
