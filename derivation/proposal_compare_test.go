package derivation

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

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
}
