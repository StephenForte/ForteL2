package derivation

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/ethereum/go-ethereum/common"
)

const (
	// CompareReference is the legacy consistency oracle (reference EL block hashes).
	CompareReference = "reference"
	// CompareProposals audits derived output roots against DisputeGameFactory claims.
	CompareProposals = "proposals"
)

const (
	ProposalMatch    = "MATCH"
	ProposalMismatch = "MISMATCH"
	ProposalSkipped  = "SKIPPED"
)

// GameStatusName is IDisputeGame.status() as a label. Status is context, never a gate.
func GameStatusName(status uint8) string {
	switch status {
	case 0:
		return "IN_PROGRESS"
	case 1:
		return "CHALLENGER_WINS"
	case 2:
		return "DEFENDER_WINS"
	default:
		return fmt.Sprintf("UNKNOWN(%d)", status)
	}
}

// ProposalResult is one enumerated game's compare outcome.
type ProposalResult struct {
	Index       uint64         `json:"index"`
	Game        common.Address `json:"game"`
	CreatedAt   uint64         `json:"createdAt"`
	Status      uint8          `json:"status"`
	StatusName  string         `json:"statusName"`
	GameType    uint32         `json:"gameType"`
	L2Block     uint64         `json:"l2Block"`
	DerivedRoot common.Hash    `json:"derivedRoot,omitempty"`
	ClaimedRoot common.Hash    `json:"claimedRoot"`
	Result      string         `json:"result"`
	SkipReason  string         `json:"skipReason,omitempty"`
}

func inWindow(height, start, end uint64) bool {
	return height >= start && height <= end
}

// EvaluateProposal classifies one game against a derived window.
// compute is only invoked for in-window heights; a compute error is a hard error
// (proof failure), not SKIPPED.
func EvaluateProposal(p Proposal, windowStart, windowEnd uint64, compute func(height uint64) (common.Hash, error)) (ProposalResult, error) {
	r := ProposalResult{
		Index:       p.Index,
		Game:        p.Game,
		CreatedAt:   p.CreatedAt,
		Status:      p.Status,
		StatusName:  GameStatusName(p.Status),
		GameType:    p.GameType,
		L2Block:     p.L2Block,
		ClaimedRoot: p.RootClaim,
	}
	if !inWindow(p.L2Block, windowStart, windowEnd) {
		r.Result = ProposalSkipped
		r.SkipReason = fmt.Sprintf("height outside window %d–%d", windowStart, windowEnd)
		return r, nil
	}
	derived, err := compute(p.L2Block)
	if err != nil {
		return r, fmt.Errorf("proposal index=%d game=%s l2=%d: %w", p.Index, p.Game, p.L2Block, err)
	}
	r.DerivedRoot = derived
	if derived == p.RootClaim {
		r.Result = ProposalMatch
		return r, nil
	}
	r.Result = ProposalMismatch
	return r, nil
}

// FormatProposalLine is the human-readable per-game report line.
func FormatProposalLine(r ProposalResult) string {
	base := fmt.Sprintf("  proposal index=%d game=%s l2=%d created=%d status=%s type=%d",
		r.Index, r.Game, r.L2Block, r.CreatedAt, r.StatusName, r.GameType)
	switch r.Result {
	case ProposalSkipped:
		return fmt.Sprintf("%s %s (%s)", base, ProposalSkipped, r.SkipReason)
	default:
		return fmt.Sprintf("%s derived=%s claimed=%s %s", base, r.DerivedRoot, r.ClaimedRoot, r.Result)
	}
}

func derefInt(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}

func derefUint32(p *uint32) uint32 {
	if p == nil {
		return 0
	}
	return *p
}

func derefAddr(p *common.Address) common.Address {
	if p == nil {
		return common.Address{}
	}
	return *p
}

// ProposalMatchedCount is the MATCH count (0 if the field was not set).
func ProposalMatchedCount(r *VerifyReport) int {
	if r == nil {
		return 0
	}
	return derefInt(r.ProposalMatched)
}

// ProposalSkippedCount is the SKIPPED count (0 if the field was not set).
func ProposalSkippedCount(r *VerifyReport) int {
	if r == nil {
		return 0
	}
	return derefInt(r.ProposalSkipped)
}

// ProposalMismatchedCount is the MISMATCH count (0 if the field was not set).
func ProposalMismatchedCount(r *VerifyReport) int {
	if r == nil {
		return 0
	}
	return derefInt(r.ProposalMismatched)
}

// ProposalRespectedType is the respected/override game type (0 if unset).
func ProposalRespectedType(r *VerifyReport) uint32 {
	if r == nil {
		return 0
	}
	return derefUint32(r.RespectedGameType)
}

// WriteProposalReport prints the proposal-mode header and per-game lines.
func WriteProposalReport(w io.Writer, report *VerifyReport) {
	if report == nil {
		return
	}
	src := "on-chain"
	if report.GameTypeOverridden {
		src = "override"
	}
	fmt.Fprintf(w, "respected_game_type=%d (%s)\n", derefUint32(report.RespectedGameType), src)
	fmt.Fprintf(w, "factory=%s asr=%s\n", derefAddr(report.Factory), derefAddr(report.ASR))
	fmt.Fprintf(w, "window=%d–%d MATCH=%d SKIPPED=%d MISMATCH=%d enumerated=%d\n",
		report.WindowStart, report.WindowEnd,
		derefInt(report.ProposalMatched), derefInt(report.ProposalSkipped), derefInt(report.ProposalMismatched),
		len(report.Proposals))
	for _, p := range report.Proposals {
		fmt.Fprintln(w, FormatProposalLine(p))
	}
}

func verifyAgainstProposals(ctx context.Context, opts VerifyOptions, sealer *SealingEL) (*VerifyReport, error) {
	if opts.Factory == (common.Address{}) || opts.ASR == (common.Address{}) {
		return nil, fmt.Errorf("proposal mode: factory and ASR addresses are required")
	}
	cfg, err := LoadRollupConfig(opts.RollupPath)
	if err != nil {
		return nil, err
	}
	l1RPC := NewRPCClient(opts.L1RPC)
	l1 := NewL1Client(l1RPC)

	gameType := uint32(0)
	overridden := false
	if opts.GameTypeOverride != nil {
		gameType = *opts.GameTypeOverride
		overridden = true
	} else {
		gameType, err = RespectedGameType(ctx, l1RPC, opts.ASR)
		if err != nil {
			return nil, err
		}
	}

	matched, mismatched, skipped := 0, 0, 0
	gt := gameType
	fac, asr := opts.Factory, opts.ASR
	report := &VerifyReport{
		WindowStart:        opts.StartL2,
		WindowEnd:          opts.EndL2,
		Compare:            CompareProposals,
		RespectedGameType:  &gt,
		GameTypeOverridden: overridden,
		Factory:            &fac,
		ASR:                &asr,
		ProposalMatched:    &matched,
		ProposalMismatched: &mismatched,
		ProposalSkipped:    &skipped,
	}

	if opts.ResumeL1Bound {
		if err := resolveResumeInboxScan(ctx, sealer, cfg, &opts); err != nil {
			return report, err
		}
	} else if err := resolveFromL1BlockSeal(ctx, sealer, &opts); err != nil {
		return report, err
	}

	blocks, err := deriveBlockInputs(ctx, cfg, l1, opts)
	if err != nil {
		return report, err
	}

	st, err := initDerivationStateFromSeal(ctx, cfg, sealer, opts.StartL2)
	if err != nil {
		return report, fmt.Errorf("derivation state from sealing EL: %w", err)
	}
	if opts.AnchoredHead {
		if err := sealer.SyncHeadFromLatest(ctx); err != nil {
			return report, fmt.Errorf("sealing EL head sync: %w", err)
		}
	}

	byNumber := map[uint64]BlockInput{}
	for _, b := range blocks {
		byNumber[b.Number] = b
	}

	for n := opts.StartL2; n <= opts.EndL2; n++ {
		in, ok := byNumber[n]
		if !ok {
			return report, fmt.Errorf("missing derived block %d in window (have %d batches)", n, len(blocks))
		}
		attrs, err := BuildPayloadAttributes(ctx, cfg, l1, &st, in)
		if err != nil {
			return report, fmt.Errorf("block %d attrs: %w", n, err)
		}
		derived, err := sealer.SealBlock(ctx, attrs)
		if err != nil {
			return report, fmt.Errorf("block %d seal: %w", n, err)
		}
		st.ParentHash = derived
		st.ParentTime = in.Timestamp
	}

	proposals, err := EnumerateProposals(ctx, l1RPC, opts.Factory, gameType)
	if err != nil {
		return report, err
	}

	compute := func(height uint64) (common.Hash, error) {
		return sealer.OutputRootV0At(ctx, height)
	}

	var mismatch error
	for _, p := range proposals {
		pr, err := EvaluateProposal(p, opts.StartL2, opts.EndL2, compute)
		if err != nil {
			return report, err
		}
		report.Proposals = append(report.Proposals, pr)
		switch pr.Result {
		case ProposalMatch:
			*report.ProposalMatched++
		case ProposalSkipped:
			*report.ProposalSkipped++
		case ProposalMismatch:
			*report.ProposalMismatched++
			if mismatch == nil {
				mismatch = fmt.Errorf("output-root mismatch at game %s index=%d l2=%d: derived %s claimed %s",
					pr.Game, pr.Index, pr.L2Block, pr.DerivedRoot, pr.ClaimedRoot)
			}
		}
	}
	return report, mismatch
}

func initDerivationStateFromSeal(ctx context.Context, cfg *RollupConfig, sealer *SealingEL, startL2 uint64) (DerivationState, error) {
	st := NewDerivationState(cfg)
	if startL2 <= 1 {
		hash, _, _, _, err := sealer.BlockMeta(ctx, 0)
		if err != nil {
			return st, fmt.Errorf("sealing EL genesis: %w", err)
		}
		if hash == (common.Hash{}) {
			return st, fmt.Errorf("sealing EL genesis hash is zero")
		}
		st.ParentHash = hash
		return st, nil
	}

	prev := startL2 - 1
	parentHash, _, parentTime, _, err := sealer.BlockMeta(ctx, prev)
	if err != nil {
		return st, fmt.Errorf("sealing EL block %d meta: %w", prev, err)
	}
	rawTx, err := sealer.BlockFirstTx(ctx, prev)
	if err != nil {
		return st, fmt.Errorf("sealing EL block %d first tx: %w", prev, err)
	}
	info, err := ParseL1InfoDeposit(rawTx)
	if err != nil {
		return st, fmt.Errorf("sealing EL block %d L1-info: %w", prev, err)
	}

	st.ParentHash = parentHash
	st.ParentTime = parentTime
	st.L1OriginNum = info.L1OriginNumber
	st.L1OriginHash = info.L1OriginHash
	st.SeqNumber = info.SeqNumber
	return st, nil
}

func resolveFromL1BlockSeal(ctx context.Context, sealer *SealingEL, opts *VerifyOptions) error {
	if opts.FromL1Block != 0 || opts.StartL2 <= 1 {
		return nil
	}
	lookback := opts.L1Lookback
	if lookback == 0 {
		lookback = 300
	}
	prev := opts.StartL2 - 1
	rawTx, err := sealer.BlockFirstTx(ctx, prev)
	if err != nil {
		return fmt.Errorf("anchor scan bound: sealing EL block %d first tx: %w", prev, err)
	}
	info, err := ParseL1InfoDeposit(rawTx)
	if err != nil {
		return fmt.Errorf("anchor scan bound: sealing EL block %d L1-info: %w", prev, err)
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
