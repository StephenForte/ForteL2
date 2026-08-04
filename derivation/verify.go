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
	RollupPath  string
	L1RPC       string
	RefL2RPC    string
	RefNodeRPC  string
	SealingAuth string
	SealingHTTP string
	StartL2     uint64
	EndL2       uint64
	ChannelTx   common.Hash
	FromL1Block uint64
}

// Verify runs the derivation pipeline and compares sealed hashes to reference EL.
func Verify(ctx context.Context, opts VerifyOptions, sealer *SealingEL) (*VerifyReport, error) {
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

	blocks, err := deriveBlockInputs(ctx, cfg, l1, opts)
	if err != nil {
		return nil, err
	}

	st := NewDerivationState(cfg)
	genesisHash, err := ref.BlockHash(ctx, 0)
	if err != nil {
		return nil, err
	}
	st.ParentHash = genesisHash

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
