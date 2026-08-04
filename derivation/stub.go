package derivation

import (
	"context"
	"fmt"

	"github.com/ethereum/go-ethereum/common"
)

// EngineAPIVersions documents the Engine API methods the sequencer stub targets.
// Equivalent to driving op-geth with --l2.enginekind=geth (op-node naming).
const EngineAPIVersions = "forkchoiceUpdatedV3 + getPayloadV4(fallback V3) + newPayloadV4(fallback V3)"

// StubOptions configures a US-062 sequencer-stub run on an isolated sealing EL.
type StubOptions struct {
	RollupPath  string
	L1RPC       string
	Blocks      uint64 // N consecutive empty blocks to build (must be >= 1)
	L1OriginNum uint64 // 0 = use latest L1 tip at start
}

// BuiltBlock is one L2 block produced by the sequencer stub.
type BuiltBlock struct {
	Number     uint64      `json:"number"`
	Hash       common.Hash `json:"hash"`
	ParentHash common.Hash `json:"parentHash"`
	Timestamp  uint64      `json:"timestamp"`
	TxCount    int         `json:"txCount"`
	EpochNum   uint64      `json:"l1Origin"`
	SeqNumber  uint64      `json:"seqNumber"`
}

// StubReport summarizes a sequencer-stub run and follow-validation.
type StubReport struct {
	Built           []BuiltBlock `json:"built"`
	EngineAPI       string       `json:"engineAPI"`
	FollowOK        bool         `json:"followOK"`
	FollowNotes     []string     `json:"followNotes,omitempty"`
	StartParentHash common.Hash  `json:"startParentHash"`
	StartParentNum  uint64       `json:"startParentNum"`
	L1OriginNumber  uint64       `json:"l1OriginNumber"`
	L1OriginHash    common.Hash  `json:"l1OriginHash"`
}

// PlanEmptyBlockInputs plans N empty (no user-tx) L2 blocks continuing after parentNum,
// advancing timestamps by cfg.BlockTime and holding a fixed L1 origin.
func PlanEmptyBlockInputs(cfg *RollupConfig, parentNum, parentTime uint64, l1Origin *L1BlockHeader, n uint64) []BlockInput {
	bt := cfg.BlockTime
	if bt == 0 {
		bt = 2
	}
	out := make([]BlockInput, 0, n)
	ts := parentTime
	for i := uint64(0); i < n; i++ {
		ts += bt
		var epochHash [32]byte
		copy(epochHash[:], l1Origin.Hash[:])
		out = append(out, BlockInput{
			Number:       parentNum + 1 + i,
			EpochNumber:  l1Origin.Number,
			EpochHash:    epochHash,
			Timestamp:    ts,
			Transactions: nil,
			Source:       "stub",
		})
	}
	return out
}

// RunSequencerStub builds N consecutive empty L2 blocks on the isolated sealing EL
// via the Engine API, starting from the sealer's current head.
func RunSequencerStub(ctx context.Context, opts StubOptions, sealer *SealingEL) (*StubReport, error) {
	if opts.Blocks == 0 {
		return nil, fmt.Errorf("blocks must be >= 1")
	}
	cfg, err := LoadRollupConfig(opts.RollupPath)
	if err != nil {
		return nil, err
	}
	l1 := NewL1Client(NewRPCClient(opts.L1RPC))

	originNum := opts.L1OriginNum
	if originNum == 0 {
		originNum, err = l1.LatestBlockNumber(ctx)
		if err != nil {
			return nil, fmt.Errorf("l1 tip: %w", err)
		}
	}
	l1Origin, err := l1.BlockHeader(ctx, originNum)
	if err != nil {
		return nil, fmt.Errorf("l1 origin %d: %w", originNum, err)
	}

	parentHash, parentNum, parentTime, err := sealer.LoadLatestHead(ctx)
	if err != nil {
		return nil, fmt.Errorf("load sealing EL head: %w", err)
	}
	sealer.SetHead(parentHash)

	st := NewDerivationState(cfg)
	st.ParentHash = parentHash
	st.ParentTime = parentTime
	// L1OriginNum stays 0 so the first stub block is treated as an origin change
	// (seq=0, optional user deposits from that L1 block). Subsequent blocks on the
	// same origin increment SeqNumber via BuildPayloadAttributes.

	inputs := PlanEmptyBlockInputs(cfg, parentNum, parentTime, l1Origin, opts.Blocks)
	report := &StubReport{
		EngineAPI:       EngineAPIVersions,
		StartParentHash: parentHash,
		StartParentNum:  parentNum,
		L1OriginNumber:  l1Origin.Number,
		L1OriginHash:    l1Origin.Hash,
	}

	prevHash := parentHash
	for _, in := range inputs {
		attrs, err := BuildPayloadAttributes(ctx, cfg, l1, &st, in)
		if err != nil {
			return report, fmt.Errorf("block %d attrs: %w", in.Number, err)
		}
		hash, err := sealer.SealBlock(ctx, attrs)
		if err != nil {
			return report, fmt.Errorf("block %d seal: %w", in.Number, err)
		}
		gotHash, gotParent, gotTime, txCount, err := sealer.BlockMeta(ctx, in.Number)
		if err != nil {
			return report, fmt.Errorf("block %d readback: %w", in.Number, err)
		}
		if gotHash != hash {
			return report, fmt.Errorf("block %d hash mismatch seal=%s read=%s", in.Number, hash, gotHash)
		}
		if gotParent != prevHash {
			return report, fmt.Errorf("block %d parent-link broken: got %s want %s", in.Number, gotParent, prevHash)
		}
		report.Built = append(report.Built, BuiltBlock{
			Number:     in.Number,
			Hash:       hash,
			ParentHash: gotParent,
			Timestamp:  gotTime,
			TxCount:    txCount,
			EpochNum:   l1Origin.Number,
			SeqNumber:  st.SeqNumber,
		})
		prevHash = hash
		st.ParentHash = hash
		st.ParentTime = in.Timestamp
	}

	notes, err := FollowValidateStub(ctx, cfg, l1, sealer, report, l1Origin)
	report.FollowNotes = notes
	if err != nil {
		report.FollowOK = false
		return report, err
	}
	report.FollowOK = true
	return report, nil
}

// FollowValidateStub re-runs US-061 attribute derivation against the stub-built
// blocks and checks L1-info deposit bytes + parent links (D-T6-2).
func FollowValidateStub(ctx context.Context, cfg *RollupConfig, l1 *L1Client, sealer *SealingEL, report *StubReport, l1Origin *L1BlockHeader) ([]string, error) {
	if report == nil || len(report.Built) == 0 {
		return nil, fmt.Errorf("no built blocks to follow-validate")
	}
	notes := []string{"mechanism=rebuild BuildPayloadAttributes + compare first tx (L1-info) + parent links"}

	st := NewDerivationState(cfg)
	st.ParentHash = report.StartParentHash
	if report.StartParentNum == 0 {
		st.ParentTime = cfg.Genesis.L2Time
	} else {
		_, _, pt, _, err := sealer.BlockMeta(ctx, report.StartParentNum)
		if err != nil {
			return notes, fmt.Errorf("parent meta: %w", err)
		}
		st.ParentTime = pt
	}

	prev := report.StartParentHash
	for _, b := range report.Built {
		in := BlockInput{
			Number:      b.Number,
			EpochNumber: l1Origin.Number,
			Timestamp:   b.Timestamp,
			Source:      "stub",
		}
		copy(in.EpochHash[:], l1Origin.Hash[:])

		attrs, err := BuildPayloadAttributes(ctx, cfg, l1, &st, in)
		if err != nil {
			return notes, fmt.Errorf("follow attrs block %d: %w", b.Number, err)
		}
		if len(attrs.Transactions) == 0 {
			return notes, fmt.Errorf("follow block %d: expected L1-info deposit", b.Number)
		}

		_, parent, _, txCount, err := sealer.BlockMeta(ctx, b.Number)
		if err != nil {
			return notes, err
		}
		if parent != prev {
			return notes, fmt.Errorf("follow parent-link block %d: got %s want %s", b.Number, parent, prev)
		}

		firstTx, err := sealer.BlockFirstTx(ctx, b.Number)
		if err != nil {
			return notes, fmt.Errorf("follow first tx block %d: %w", b.Number, err)
		}
		want := []byte(attrs.Transactions[0])
		if !bytesEqual(firstTx, want) {
			return notes, fmt.Errorf("follow L1-info mismatch at block %d: sealed %d bytes vs derived %d bytes", b.Number, len(firstTx), len(want))
		}
		notes = append(notes, fmt.Sprintf("block %d parent-link OK; L1-info match; txs=%d", b.Number, txCount))
		prev = b.Hash
		st.ParentHash = b.Hash
		st.ParentTime = b.Timestamp
	}
	notes = append(notes, fmt.Sprintf("follow-validate PASS for %d blocks", len(report.Built)))
	return notes, nil
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
