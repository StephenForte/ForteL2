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
	L1OriginNum uint64 // 0 = auto-select valid origin; non-zero must pass timestamp validation
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

// PlanStubBlockInputs plans N empty stub blocks, resolving the L1 origin per block via
// OriginForL2Timestamp so origin advance (seq reset) is correct when drift is exceeded.
func PlanStubBlockInputs(ctx context.Context, cfg *RollupConfig, l1 *L1Client, parentNum, parentTime, startOriginNum, n uint64) ([]BlockInput, error) {
	bt := cfg.BlockTime
	if bt == 0 {
		bt = 2
	}
	out := make([]BlockInput, 0, n)
	ts := parentTime
	originNum := startOriginNum
	for i := uint64(0); i < n; i++ {
		ts += bt
		hdr, err := cfg.OriginForL2Timestamp(ctx, l1, originNum, ts)
		if err != nil {
			return nil, fmt.Errorf("block %d origin: %w", parentNum+1+i, err)
		}
		var epochHash [32]byte
		copy(epochHash[:], hdr.Hash[:])
		out = append(out, BlockInput{
			Number:       parentNum + 1 + i,
			EpochNumber:  hdr.Number,
			EpochHash:    epochHash,
			Timestamp:    ts,
			Transactions: nil,
			Source:       "stub",
		})
		originNum = hdr.Number
	}
	return out, nil
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

	parentHash, parentNum, parentTime, err := sealer.LoadLatestHead(ctx)
	if err != nil {
		return nil, fmt.Errorf("load sealing EL head: %w", err)
	}
	sealer.SetHead(parentHash)

	bt := cfg.BlockTime
	if bt == 0 {
		bt = 2
	}
	firstL2Ts := parentTime + bt

	l1Origin, err := ResolveStubL1Origin(ctx, cfg, l1, sealer, opts.L1OriginNum, firstL2Ts)
	if err != nil {
		return nil, err
	}

	st, err := SeedStubDerivationState(ctx, sealer, parentNum, parentHash, parentTime, cfg)
	if err != nil {
		return nil, err
	}

	startOriginNum, err := StubStartOriginNum(ctx, cfg, l1, sealer, parentNum)
	if err != nil {
		return nil, err
	}
	inputs, err := PlanStubBlockInputs(ctx, cfg, l1, parentNum, parentTime, startOriginNum, opts.Blocks)
	if err != nil {
		return nil, err
	}

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
			EpochNum:   in.EpochNumber,
			SeqNumber:  st.SeqNumber,
		})
		prevHash = hash
		st.ParentHash = hash
		st.ParentTime = in.Timestamp
	}

	notes, err := FollowValidateStub(ctx, cfg, l1, sealer, report)
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
// Expected seq/epoch are seeded only from the start-parent L1-info re-parse (D-H3a-1),
// not from the builder's in-memory state, so builder-state bugs are detectable.
func FollowValidateStub(ctx context.Context, cfg *RollupConfig, l1 *L1Client, sealer *SealingEL, report *StubReport) ([]string, error) {
	if report == nil || len(report.Built) == 0 {
		return nil, fmt.Errorf("no built blocks to follow-validate")
	}
	notes := []string{"mechanism=rebuild BuildPayloadAttributes + compare first tx (L1-info) + parent links + origin timestamp invariant (spec: sequencing window); independent seed from parent L1-info re-parse (D-H3a-1)"}

	st, err := SeedStubDerivationState(ctx, sealer, report.StartParentNum, report.StartParentHash, 0, cfg)
	if err != nil {
		return notes, err
	}
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
		l1Origin, err := l1.BlockHeader(ctx, b.EpochNum)
		if err != nil {
			return notes, fmt.Errorf("follow l1 origin %d block %d: %w", b.EpochNum, b.Number, err)
		}
		maxDrift := cfg.EffectiveMaxSequencerDrift(b.Timestamp)
		if err := ValidateL2OriginTimestamp(b.Timestamp, l1Origin.Time, maxDrift); err != nil {
			return notes, fmt.Errorf("origin timestamp invariant block %d (spec sequencing window): %w", b.Number, err)
		}

		in := BlockInput{
			Number:      b.Number,
			EpochNumber: b.EpochNum,
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
		notes = append(notes, fmt.Sprintf("block %d parent-link OK; L1-info match; txs=%d seq=%d", b.Number, txCount, st.SeqNumber))
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
