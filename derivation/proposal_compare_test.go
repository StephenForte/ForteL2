package derivation

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/StephenForte/ForteL2/proposer"
	"github.com/ethereum/go-ethereum/common"
)

func TestEvaluateProposalSkippedOutsideWindow(t *testing.T) {
	p := Proposal{
		Index:     3,
		Game:      common.HexToAddress("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
		CreatedAt: 99,
		GameType:  8,
		L2Block:   500,
		RootClaim: common.HexToHash("0x" + strings.Repeat("11", 32)),
		Status:    0,
	}
	called := false
	r, err := EvaluateProposal(p, 1, 20, func(uint64) (common.Hash, error) {
		called = true
		return common.Hash{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatal("SKIPPED height must not invoke eth_getProof / compute")
	}
	if r.Result != ProposalSkipped {
		t.Fatalf("result=%s", r.Result)
	}
	line := FormatProposalLine(r)
	if !strings.Contains(line, "SKIPPED") || !strings.Contains(line, p.Game.Hex()) {
		t.Fatalf("line=%s", line)
	}
}

func TestEvaluateProposalMatchAndMismatch(t *testing.T) {
	claim := common.HexToHash("0x" + strings.Repeat("ab", 32))
	p := Proposal{
		Index:     1,
		Game:      common.HexToAddress("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
		CreatedAt: 1,
		GameType:  8,
		L2Block:   10,
		RootClaim: claim,
		Status:    0, // IN_PROGRESS — status is not a gate
	}
	r, err := EvaluateProposal(p, 1, 20, func(h uint64) (common.Hash, error) {
		if h != 10 {
			t.Fatalf("height=%d", h)
		}
		return claim, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.Result != ProposalMatch {
		t.Fatalf("unresolved matching claim must be MATCH, got %s", r.Result)
	}

	other := common.HexToHash("0x" + strings.Repeat("cd", 32))
	r, err = EvaluateProposal(p, 1, 20, func(uint64) (common.Hash, error) { return other, nil })
	if err != nil {
		t.Fatal(err)
	}
	if r.Result != ProposalMismatch {
		t.Fatalf("got %s", r.Result)
	}
}

func TestEvaluateProposalProofErrorIsHard(t *testing.T) {
	p := Proposal{
		Index:     1,
		Game:      common.HexToAddress("0xcccccccccccccccccccccccccccccccccccccccc"),
		GameType:  8,
		L2Block:   10,
		RootClaim: common.Hash{1},
	}
	_, err := EvaluateProposal(p, 1, 20, func(uint64) (common.Hash, error) {
		return common.Hash{}, fmt.Errorf("eth_getProof: missing trie node")
	})
	if err == nil || !strings.Contains(err.Error(), "eth_getProof") {
		t.Fatalf("in-window proof error must be hard, got %v", err)
	}
}

func TestProposalMismatchIsError(t *testing.T) {
	claim := common.HexToHash("0x" + strings.Repeat("11", 32))
	derived := common.HexToHash("0x" + strings.Repeat("22", 32))
	p := Proposal{Index: 7, Game: common.HexToAddress("0xdddddddddddddddddddddddddddddddddddddddd"), GameType: 8, L2Block: 5, RootClaim: claim}
	r, err := EvaluateProposal(p, 1, 20, func(uint64) (common.Hash, error) { return derived, nil })
	if err != nil {
		t.Fatal(err)
	}
	if r.Result != ProposalMismatch {
		t.Fatal(r.Result)
	}
	agg := fmt.Errorf("output-root mismatch at game %s index=%d l2=%d: derived %s claimed %s",
		r.Game, r.Index, r.L2Block, r.DerivedRoot, r.ClaimedRoot)
	if !strings.Contains(agg.Error(), r.Game.Hex()) {
		t.Fatal(agg)
	}
}

func TestUnknownCompareMode(t *testing.T) {
	_, err := Verify(t.Context(), VerifyOptions{Compare: "nope", RollupPath: "missing.json"}, nil)
	if err == nil || !strings.Contains(err.Error(), "unknown -compare") {
		t.Fatalf("got %v", err)
	}
}

func TestGameStatusName(t *testing.T) {
	if GameStatusName(0) != "IN_PROGRESS" || GameStatusName(1) != "CHALLENGER_WINS" || GameStatusName(2) != "DEFENDER_WINS" {
		t.Fatal("status labels")
	}
}

func TestProposalReportJSONIncludesZeroGameType(t *testing.T) {
	gt := uint32(0)
	matched, skipped, mismatched := 0, 2, 0
	report := &VerifyReport{
		Compare:            CompareProposals,
		RespectedGameType:  &gt,
		ProposalMatched:    &matched,
		ProposalSkipped:    &skipped,
		ProposalMismatched: &mismatched,
	}
	raw, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if string(m["respectedGameType"]) != "0" {
		t.Fatalf("respectedGameType omitted or wrong: %s", raw)
	}
	if string(m["proposalMatched"]) != "0" {
		t.Fatalf("proposalMatched omitted or wrong: %s", raw)
	}
	if string(m["proposalMismatched"]) != "0" {
		t.Fatalf("proposalMismatched omitted or wrong: %s", raw)
	}
	if string(m["proposalSkipped"]) != "2" {
		t.Fatalf("proposalSkipped=%s", m["proposalSkipped"])
	}

	legacy := &VerifyReport{WindowStart: 1, WindowEnd: 20, Matched: 20}
	lraw, err := json.Marshal(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(lraw), "respectedGameType") || strings.Contains(string(lraw), "proposalMatched") {
		t.Fatalf("legacy JSON must omit proposal fields: %s", lraw)
	}
	if strings.Contains(string(lraw), `"factory"`) || strings.Contains(string(lraw), `"asr"`) {
		t.Fatalf("legacy JSON must omit zero factory/asr (common.Address is not omitempty-empty): %s", lraw)
	}
}

func TestSuperRootWindowUsesBlockNotTimestamp(t *testing.T) {
	const genesis, blockTime = uint64(1000), uint64(2)
	const ts = uint64(1020) // block 10, not 1020
	output := common.HexToHash("0x" + strings.Repeat("ab", 32))
	sr, err := proposer.EncodeSuperRoot(ts, []proposer.ChainOutput{{ChainID: 852, OutputRoot: output}})
	if err != nil {
		t.Fatal(err)
	}
	p := Proposal{
		Index:       4,
		Game:        common.HexToAddress("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
		GameType:    proposer.GameTypeSuperCannonKona,
		L2Block:     ts,
		L2Timestamp: ts,
		ExtraData:   sr.Preimage,
		RootClaim:   sr.Hash,
		Status:      0,
	}
	var saw uint64
	r, err := EvaluateSuperRootProposal(p, 1, 20, genesis, blockTime, 852, func(h uint64) (common.Hash, error) {
		saw = h
		if h == ts {
			t.Fatalf("compute was called with the timestamp %d", h)
		}
		return output, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if saw != 10 {
		t.Fatalf("compute height %d want block 10", saw)
	}
	if r.Result != ProposalMatch || r.L2Block != 10 {
		t.Fatalf("result %+v", r)
	}
	line := FormatProposalLine(r)
	if !strings.Contains(line, "l2=10") || !strings.Contains(line, "timestamp=1020") || !strings.Contains(line, "MATCH") {
		t.Fatalf("line=%s", line)
	}
}

func TestMixedProposalList(t *testing.T) {
	const genesis, blockTime = uint64(1000), uint64(2)
	output10 := common.HexToHash("0x" + strings.Repeat("11", 32))
	output12 := common.HexToHash("0x" + strings.Repeat("22", 32))
	honest, err := proposer.EncodeSuperRoot(1024, []proposer.ChainOutput{{ChainID: 852, OutputRoot: output12}})
	if err != nil {
		t.Fatal(err)
	}
	badClaim := honest.Hash
	badClaim[0] ^= 0xff
	outside, err := proposer.EncodeSuperRoot(1100, []proposer.ChainOutput{{ChainID: 852, OutputRoot: output12}})
	if err != nil {
		t.Fatal(err)
	}
	proposals := []Proposal{
		{Index: 1, Game: common.HexToAddress("0x1111111111111111111111111111111111111111"), GameType: 8, L2Block: 10, RootClaim: output10, Status: 0},
		{Index: 2, Game: common.HexToAddress("0x2222222222222222222222222222222222222222"), GameType: proposer.GameTypeSuperCannonKona, L2Timestamp: 1024, ExtraData: honest.Preimage, RootClaim: badClaim, Status: 0},
		{Index: 3, Game: common.HexToAddress("0x3333333333333333333333333333333333333333"), GameType: 8, L2Block: 100, RootClaim: output10, Status: 0},
		{Index: 4, Game: common.HexToAddress("0x4444444444444444444444444444444444444444"), GameType: proposer.GameTypeSuperCannonKona, L2Timestamp: 1100, ExtraData: outside.Preimage, RootClaim: outside.Hash, Status: 0},
	}
	got, err := ClassifyProposals(proposals, 1, 20, genesis, blockTime, 852, func(h uint64) (common.Hash, error) {
		switch h {
		case 10:
			return output10, nil
		case 12:
			return output12, nil
		default:
			t.Fatalf("unexpected height %d", h)
			return common.Hash{}, nil
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{ProposalMatch, ProposalMismatch, ProposalSkipped, ProposalSkipped}
	if len(got) != len(want) {
		t.Fatalf("len %d", len(got))
	}
	for i, w := range want {
		if got[i].Result != w {
			t.Fatalf("game %d result %s want %s", got[i].Index, got[i].Result, w)
		}
	}
	if got[1].L2Block != 12 {
		t.Fatalf("type 9 window block %d want 12", got[1].L2Block)
	}
}

func TestProposalGameTypesIncludesSibling(t *testing.T) {
	if fmt.Sprint(ProposalGameTypes(8)) != "[8 9]" {
		t.Fatalf("type 8: %v", ProposalGameTypes(8))
	}
	if fmt.Sprint(ProposalGameTypes(9)) != "[9 8]" {
		t.Fatalf("type 9: %v", ProposalGameTypes(9))
	}
	if fmt.Sprint(ProposalGameTypes(1)) != "[1]" {
		t.Fatalf("type 1 must stay single-type: %v", ProposalGameTypes(1))
	}
}

func TestType9ExtraDataRejectedOnOutputRootCompare(t *testing.T) {
	p := Proposal{GameType: proposer.GameTypeSuperCannonKona, L2Timestamp: 1020, L2Block: 10}
	_, err := EvaluateProposal(p, 1, 20, func(uint64) (common.Hash, error) {
		t.Fatal("type 9 must not be compared as an output root")
		return common.Hash{}, nil
	})
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestForeignChainIDIsNotAMatch(t *testing.T) {
	const genesis, blockTime = uint64(1000), uint64(2)
	const ts = uint64(1020)
	output := common.HexToHash("0x" + strings.Repeat("ab", 32))
	foreign, err := proposer.EncodeSuperRoot(ts, []proposer.ChainOutput{{ChainID: 999, OutputRoot: output}})
	if err != nil {
		t.Fatal(err)
	}
	p := Proposal{
		Index:       7,
		Game:        common.HexToAddress("0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
		GameType:    proposer.GameTypeSuperCannonKona,
		L2Timestamp: ts,
		ExtraData:   foreign.Preimage,
		RootClaim:   foreign.Hash,
	}
	r, err := EvaluateSuperRootProposal(p, 1, 20, genesis, blockTime, 852, func(h uint64) (common.Hash, error) {
		if h != 10 {
			t.Fatalf("compute height %d", h)
		}
		return output, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.Result != ProposalMismatch {
		t.Fatalf("a preimage that names chain 999 must not MATCH this rollup, got %s", r.Result)
	}
}
