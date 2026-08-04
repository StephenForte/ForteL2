package derivation

import (
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

func testRollupConfig() *RollupConfig {
	zero := uint64(0)
	cfg := &RollupConfig{
		BlockTime: 2,
		L2ChainID: 901,
	}
	cfg.Genesis.L2Time = 1_700_000_000
	cfg.Genesis.SystemConfig = SystemConfig{
		BatcherAddr: common.HexToAddress("0x70997970C51812dc3A010C7d01b50e0d17dc79C8"),
		GasLimit:    30_000_000,
	}
	// Ecotone+ active from genesis so L1-info uses post-Bedrock encoding paths.
	cfg.RegolithTime = &zero
	cfg.CanyonTime = &zero
	cfg.EcotoneTime = &zero
	cfg.HoloceneTime = &zero
	cfg.IsthmusTime = &zero
	cfg.DepositContractAddress = common.HexToAddress("0x0000000000000000000000000000000000000001")
	return cfg
}

func TestPlanEmptyBlockInputs(t *testing.T) {
	cfg := testRollupConfig()
	origin := &L1BlockHeader{
		Number:    42,
		Hash:      common.HexToHash("0xabc1"),
		Time:      1_700_000_100,
		MixDigest: common.HexToHash("0xdead"),
		BaseFee:   big.NewInt(7),
	}
	inputs := PlanEmptyBlockInputs(cfg, 0, cfg.Genesis.L2Time, origin, 10)
	if len(inputs) != 10 {
		t.Fatalf("got %d inputs, want 10", len(inputs))
	}
	for i, in := range inputs {
		wantNum := uint64(i + 1)
		wantTS := cfg.Genesis.L2Time + cfg.BlockTime*uint64(i+1)
		if in.Number != wantNum {
			t.Errorf("input[%d].Number=%d want %d", i, in.Number, wantNum)
		}
		if in.Timestamp != wantTS {
			t.Errorf("input[%d].Timestamp=%d want %d", i, in.Timestamp, wantTS)
		}
		if in.EpochNumber != 42 {
			t.Errorf("input[%d].EpochNumber=%d", i, in.EpochNumber)
		}
		if in.EpochHash != origin.Hash {
			t.Errorf("input[%d].EpochHash mismatch", i)
		}
		if len(in.Transactions) != 0 {
			t.Errorf("input[%d] should have empty user txs", i)
		}
		if in.Source != "stub" {
			t.Errorf("input[%d].Source=%q", i, in.Source)
		}
	}
	// Contiguous parent-link numbering.
	for i := 1; i < len(inputs); i++ {
		if inputs[i].Number != inputs[i-1].Number+1 {
			t.Fatalf("non-contiguous at %d", i)
		}
	}
}

func TestL1InfoDepositBytesForStubAttrs(t *testing.T) {
	cfg := testRollupConfig()
	origin := &L1BlockHeader{
		Number:    7,
		Hash:      common.HexToHash("0x1111"),
		Time:      1_700_000_050,
		MixDigest: common.HexToHash("0x2222"),
		BaseFee:   big.NewInt(1),
	}
	ts := cfg.Genesis.L2Time + cfg.BlockTime
	raw, err := L1InfoDepositBytes(cfg, cfg.Genesis.SystemConfig, 0, origin, ts)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) < 2 || raw[0] != 0x7e {
		t.Fatalf("expected deposit tx type prefix 0x7e, got len=%d first=%x", len(raw), raw)
	}

	// Same inputs must be deterministic (follow-validate depends on this).
	raw2, err := L1InfoDepositBytes(cfg, cfg.Genesis.SystemConfig, 0, origin, ts)
	if err != nil {
		t.Fatal(err)
	}
	if !bytesEqual(raw, raw2) {
		t.Fatal("L1InfoDepositBytes not deterministic")
	}

	// Seq number change must alter the deposit.
	rawSeq1, err := L1InfoDepositBytes(cfg, cfg.Genesis.SystemConfig, 1, origin, ts+2)
	if err != nil {
		t.Fatal(err)
	}
	if bytesEqual(raw, rawSeq1) {
		t.Fatal("expected different L1-info for seq=1")
	}
}

func TestBuildPayloadAttributesEmptyStubPath(t *testing.T) {
	cfg := testRollupConfig()
	originHash := common.HexToHash("0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
	originNum := uint64(9)
	mix := common.HexToHash("0x99")
	baseFee := hexutil.Big(*big.NewInt(8))

	var calls atomic.Uint64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
			ID     uint64            `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode: %v", err)
			return
		}
		var result any
		switch req.Method {
		case "eth_getBlockByHash", "eth_getBlockByNumber":
			result = map[string]any{
				"number":           hexutil.EncodeUint64(originNum),
				"hash":             originHash,
				"parentHash":       common.Hash{},
				"timestamp":        hexutil.Uint64(1_700_000_040),
				"baseFeePerGas":    &baseFee,
				"mixHash":          mix,
				"transactions":     []any{},
			}
		case "eth_getBlockReceipts":
			result = []any{}
		case "eth_feeHistory":
			// Behave like a pre-Cancun node: JSON-RPC method-not-found is the
			// one error the blob-fee fetch may treat as "fall back to 1".
			_ = json.NewEncoder(w).Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      req.ID,
				"error":   map[string]any{"code": -32601, "message": "the method eth_feeHistory does not exist/is not available"},
			})
			return
		default:
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"result":  result,
		})
	}))
	defer srv.Close()

	l1 := NewL1Client(NewRPCClient(srv.URL))
	st := NewDerivationState(cfg)
	inputs := PlanEmptyBlockInputs(cfg, 0, cfg.Genesis.L2Time, &L1BlockHeader{
		Number: originNum,
		Hash:   originHash,
		Time:   1_700_000_040,
		BaseFee: big.NewInt(8),
		MixDigest: mix,
	}, 3)

	var prevAttrsTx0 []byte
	for i, in := range inputs {
		attrs, err := BuildPayloadAttributes(t.Context(), cfg, l1, &st, in)
		if err != nil {
			t.Fatalf("block %d: %v", in.Number, err)
		}
		if attrs.NoTxPool != true {
			t.Fatalf("block %d: NoTxPool want true", in.Number)
		}
		if uint64(attrs.Timestamp) != in.Timestamp {
			t.Fatalf("block %d: timestamp", in.Number)
		}
		if len(attrs.Transactions) < 1 {
			t.Fatalf("block %d: missing L1-info deposit", in.Number)
		}
		if attrs.PrevRandao != mix {
			t.Fatalf("block %d: PrevRandao", in.Number)
		}
		if i == 0 {
			prevAttrsTx0 = attrs.Transactions[0]
			if st.SeqNumber != 0 {
				t.Fatalf("first block seq=%d want 0", st.SeqNumber)
			}
		} else {
			if st.SeqNumber != uint64(i) {
				t.Fatalf("block %d seq=%d want %d", in.Number, st.SeqNumber, i)
			}
			if bytesEqual(prevAttrsTx0, attrs.Transactions[0]) {
				t.Fatalf("block %d L1-info should differ by seq", in.Number)
			}
			prevAttrsTx0 = attrs.Transactions[0]
		}
	}
	if calls.Load() == 0 {
		t.Fatal("expected mock L1 RPC calls")
	}
}

func TestEngineAPIVersionsConstant(t *testing.T) {
	if EngineAPIVersions == "" {
		t.Fatal("empty EngineAPIVersions")
	}
}
