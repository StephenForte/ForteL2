package derivation

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// VerifyOptions configures a derivation verification run.
type VerifyOptions struct {
	RollupPath      string
	L1RPC           string
	RefL2RPC        string
	RefNodeRPC      string
	SealingAuth     string
	SealingHTTP     string
	StartL2         uint64
	EndL2           uint64
	ChannelTx       common.Hash
	FromL1Block     uint64
	ScanFromGenesis bool
	AnchoredHead    bool // sealing EL was reset to StartL2-1 via debug_setHead
	L1Lookback      uint64 // inbox scan lookback from anchor/safe L1 origin (default 300)
	// Proposal mode (US-P7-005). Zero values keep legacy consistency mode unchanged.
	Compare          string
	Factory          common.Address
	ASR              common.Address
	GameTypeOverride *uint32 // nil = AnchorStateRegistry.respectedGameType(); never a silent default
}

// Verify runs the derivation pipeline and compares sealed hashes to reference EL.
func Verify(ctx context.Context, opts VerifyOptions, sealer *SealingEL) (*VerifyReport, error) {
	switch opts.Compare {
	case "", CompareReference:
		// legacy consistency path below
	case CompareProposals:
		return verifyAgainstProposals(ctx, opts, sealer)
	default:
		return nil, fmt.Errorf("unknown -compare %q (want %q or %q)", opts.Compare, CompareReference, CompareProposals)
	}
	cfg, err := LoadRollupConfig(opts.RollupPath)
	if err != nil {
		return nil, err
	}
	l1 := NewL1Client(NewRPCClient(opts.L1RPC))
	ref := NewReferenceClient(opts.RefL2RPC, opts.RefNodeRPC)

	sync, _ := ref.SyncStatus(ctx)
	report := &VerifyReport{WindowStart: opts.StartL2, WindowEnd: opts.EndL2}
	if sync != nil {
		report.ReferenceSafeL2 = sync.SafeL2
		report.ReferenceUnsafeL2 = sync.UnsafeL2
	}

	if err := resolveFromL1Block(ctx, ref, &opts); err != nil {
		return nil, err
	}

	blocks, err := deriveBlockInputs(ctx, cfg, l1, opts)
	if err != nil {
		return nil, err
	}

	st, err := initDerivationState(ctx, cfg, ref, opts.StartL2)
	if err != nil {
		return nil, fmt.Errorf("derivation state anchor: %w", err)
	}
	if opts.AnchoredHead {
		if err := sealer.SyncHeadFromLatest(ctx); err != nil {
			return nil, fmt.Errorf("sealing EL head sync: %w", err)
		}
	}

	byNumber := map[uint64]BlockInput{}
	for _, b := range blocks {
		byNumber[b.Number] = b
	}

	for n := opts.StartL2; n <= opts.EndL2; n++ {
		in, ok := byNumber[n]
		if !ok {
			return nil, fmt.Errorf("missing derived block %d in window (have %d batches)", n, len(blocks))
		}
		attrs, err := BuildPayloadAttributes(ctx, cfg, l1, &st, in)
		if err != nil {
			return nil, fmt.Errorf("block %d attrs: %w", n, err)
		}
		derived, err := sealer.SealBlock(ctx, attrs)
		if err != nil {
			return nil, fmt.Errorf("block %d seal: %w", n, err)
		}
		expected, err := ref.BlockHash(ctx, n)
		if err != nil {
			return nil, err
		}
		match := derived == expected
		br := BlockResult{
			Number:       n,
			DerivedHash:  derived,
			ExpectedHash: expected,
			TxCount:      len(attrs.Transactions),
			Source:       in.Source,
			Match:        match,
		}
		report.Blocks = append(report.Blocks, br)
		if match {
			report.Matched++
		} else {
			report.Mismatched++
			return report, fmt.Errorf("hash mismatch at block %d: derived %s expected %s", n, derived, expected)
		}
		st.ParentHash = derived
		st.ParentTime = in.Timestamp
	}
	return report, nil
}

func initDerivationState(ctx context.Context, cfg *RollupConfig, ref *ReferenceClient, startL2 uint64) (DerivationState, error) {
	st := NewDerivationState(cfg)
	if startL2 <= 1 {
		genesisHash, err := ref.BlockHash(ctx, 0)
		if err != nil {
			return st, err
		}
		st.ParentHash = genesisHash
		return st, nil
	}

	prev := startL2 - 1
	parentHash, parentTime, err := ref.BlockMeta(ctx, prev)
	if err != nil {
		return st, fmt.Errorf("reference block %d meta: %w", prev, err)
	}
	rawTx, err := ref.BlockFirstTx(ctx, prev)
	if err != nil {
		return st, fmt.Errorf("reference block %d first tx: %w", prev, err)
	}
	info, err := ParseL1InfoDeposit(rawTx)
	if err != nil {
		return st, fmt.Errorf("reference block %d L1-info: %w", prev, err)
	}

	st.ParentHash = parentHash
	st.ParentTime = parentTime
	st.L1OriginNum = info.L1OriginNumber
	st.L1OriginHash = info.L1OriginHash
	st.SeqNumber = info.SeqNumber
	return st, nil
}

func resolveFromL1Block(ctx context.Context, ref *ReferenceClient, opts *VerifyOptions) error {
	if opts.FromL1Block != 0 || opts.StartL2 <= 1 {
		return nil
	}
	lookback := opts.L1Lookback
	if lookback == 0 {
		lookback = 300
	}
	prev := opts.StartL2 - 1
	rawTx, err := ref.BlockFirstTx(ctx, prev)
	if err != nil {
		return fmt.Errorf("anchor scan bound: block %d first tx: %w", prev, err)
	}
	info, err := ParseL1InfoDeposit(rawTx)
	if err != nil {
		return fmt.Errorf("anchor scan bound: block %d L1-info: %w", prev, err)
	}
	from := int64(info.L1OriginNumber) - int64(lookback)
	if from < 1 {
		from = 1
	}
	opts.FromL1Block = uint64(from)
	fmt.Fprintf(os.Stderr, "L1 inbox scan from block %d (anchor l1origin=%d lookback=%d)\n",
		opts.FromL1Block, info.L1OriginNumber, lookback)
	return nil
}

func runCmd(name string, bin string, args ...string) error {
	cmd := exec.Command(bin, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func startCmd(bin string, args ...string) (*os.Process, error) {
	cmd := exec.Command(bin, args...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return cmd.Process, nil
}

func WaitForRPC(ctx context.Context, url string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	c := NewRPCClient(url)
	for time.Now().Before(deadline) {
		var n string
		if err := c.Call(ctx, "eth_blockNumber", []any{}, &n); err == nil {
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("rpc %s not ready after %s", url, timeout)
}
