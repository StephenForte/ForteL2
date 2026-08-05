package derivation

import (
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// TestBuildPayloadAttributesPropagatesParentBeaconBlockRoot guards D-0013:
// a zero parentBeaconBlockRoot on Ecotone+ L1s changes the state root via
// EIP-4788 even with identical transactions — invisible on beacon-less Anvil.
func TestBuildPayloadAttributesPropagatesParentBeaconBlockRoot(t *testing.T) {
	cfg := testRollupConfig()
	beaconRoot := common.HexToHash("0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	originHash := common.HexToHash("0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
	originNum := uint64(100)
	mix := common.HexToHash("0x99")
	baseFee := hexutil.Big(*big.NewInt(8))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
			ID     uint64 `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode: %v", err)
			return
		}
		var result any
		switch req.Method {
		case "eth_getBlockByHash", "eth_getBlockByNumber":
			result = map[string]any{
				"number":                hexutil.EncodeUint64(originNum),
				"hash":                  originHash,
				"parentHash":            common.Hash{},
				"timestamp":             hexutil.Uint64(1_700_000_040),
				"baseFeePerGas":         &baseFee,
				"mixHash":               mix,
				"parentBeaconBlockRoot": beaconRoot,
				"transactions":          []any{},
			}
		case "eth_getBlockReceipts":
			result = []any{}
		case "eth_feeHistory":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      req.ID,
				"error":   map[string]any{"code": -32601, "message": "method not found"},
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
	ts := cfg.Genesis.L2Time + cfg.BlockTime*5 // Ecotone active, not activation block
	in := BlockInput{
		Number:      5,
		Timestamp:   ts,
		EpochNumber: originNum,
		EpochHash:   originHash,
	}

	attrs, err := BuildPayloadAttributes(t.Context(), cfg, l1, &st, in)
	if err != nil {
		t.Fatal(err)
	}
	if attrs.ParentBeaconBlockRoot == nil {
		t.Fatal("ParentBeaconBlockRoot nil on Ecotone+ block")
	}
	if *attrs.ParentBeaconBlockRoot != beaconRoot {
		t.Fatalf("ParentBeaconBlockRoot=%s want %s", attrs.ParentBeaconBlockRoot, beaconRoot)
	}
}

// TestBuildPayloadAttributesSeqNumberWithinEpoch covers seq>0 within the same
// L1 origin (Sepolia mid-window path): deposits are skipped and SeqNumber increments.
func TestBuildPayloadAttributesSeqNumberWithinEpoch(t *testing.T) {
	cfg := testRollupConfig()
	originHash := common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111")
	originNum := uint64(42)
	mix := common.HexToHash("0x2222")
	baseFee := hexutil.Big(*big.NewInt(1))

	var receiptCalls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
			ID     uint64 `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode: %v", err)
			return
		}
		var result any
		switch req.Method {
		case "eth_getBlockByHash", "eth_getBlockByNumber":
			result = map[string]any{
				"number":        hexutil.EncodeUint64(originNum),
				"hash":          originHash,
				"timestamp":     hexutil.Uint64(1_700_000_100),
				"baseFeePerGas": &baseFee,
				"mixHash":       mix,
				"transactions":  []any{},
			}
		case "eth_getBlockReceipts":
			receiptCalls++
			result = []any{}
		case "eth_feeHistory":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      req.ID,
				"error":   map[string]any{"code": -32601, "message": "method not found"},
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

	var prevL1Info []byte
	for seq := uint64(0); seq < 4; seq++ {
		ts := cfg.Genesis.L2Time + cfg.BlockTime*uint64(seq+1)
		in := BlockInput{
			Number:      seq + 1,
			Timestamp:   ts,
			EpochNumber: originNum,
			EpochHash:   originHash,
		}
		attrs, err := BuildPayloadAttributes(t.Context(), cfg, l1, &st, in)
		if err != nil {
			t.Fatalf("seq %d: %v", seq, err)
		}
		if st.SeqNumber != seq {
			t.Fatalf("after block %d st.SeqNumber=%d want %d", in.Number, st.SeqNumber, seq)
		}
		if len(attrs.Transactions) < 1 {
			t.Fatalf("seq %d: missing L1-info deposit", seq)
		}
		if seq == 0 {
			prevL1Info = attrs.Transactions[0]
			continue
		}
		if bytesEqual(prevL1Info, attrs.Transactions[0]) {
			t.Fatalf("seq %d: L1-info bytes unchanged within epoch", seq)
		}
		prevL1Info = attrs.Transactions[0]
	}
	if receiptCalls != 1 {
		t.Fatalf("eth_getBlockReceipts calls=%d want 1 (deposits only on first block of epoch)", receiptCalls)
	}
}

// TestBuildPayloadAttributesSeqNumberResetsOnNewEpoch verifies SeqNumber returns
// to 0 when the L1 origin advances.
func TestBuildPayloadAttributesSeqNumberResetsOnNewEpoch(t *testing.T) {
	cfg := testRollupConfig()
	epoch1 := uint64(10)
	epoch2 := uint64(11)
	hash1 := common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	hash2 := common.HexToHash("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	mix := common.HexToHash("0xcccc")
	baseFee := hexutil.Big(*big.NewInt(1))

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
			ID     uint64            `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode: %v", err)
			return
		}
		var hash common.Hash
		if len(req.Params) > 0 {
			_ = json.Unmarshal(req.Params[0], &hash)
		}
		num := epoch1
		h := hash1
		if hash == hash2 || hash == (common.Hash{}) && len(req.Params) > 0 {
			var tag string
			_ = json.Unmarshal(req.Params[0], &tag)
			if tag == "0xb" || tag == "0x0b" {
				num = epoch2
				h = hash2
			}
		}
		var result any
		switch req.Method {
		case "eth_getBlockByHash", "eth_getBlockByNumber":
			result = map[string]any{
				"number":        hexutil.EncodeUint64(num),
				"hash":          h,
				"timestamp":     hexutil.Uint64(1_700_000_200),
				"baseFeePerGas": &baseFee,
				"mixHash":       mix,
				"transactions":  []any{},
			}
		case "eth_getBlockReceipts":
			result = []any{}
		case "eth_feeHistory":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      req.ID,
				"error":   map[string]any{"code": -32601, "message": "method not found"},
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

	ts1 := cfg.Genesis.L2Time + cfg.BlockTime
	_, err := BuildPayloadAttributes(t.Context(), cfg, l1, &st, BlockInput{
		Number: 1, Timestamp: ts1, EpochNumber: epoch1, EpochHash: hash1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.SeqNumber != 0 {
		t.Fatalf("epoch1 block1 seq=%d want 0", st.SeqNumber)
	}

	ts2 := ts1 + cfg.BlockTime
	_, err = BuildPayloadAttributes(t.Context(), cfg, l1, &st, BlockInput{
		Number: 2, Timestamp: ts2, EpochNumber: epoch1, EpochHash: hash1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.SeqNumber != 1 {
		t.Fatalf("epoch1 block2 seq=%d want 1", st.SeqNumber)
	}

	ts3 := ts2 + cfg.BlockTime
	_, err = BuildPayloadAttributes(t.Context(), cfg, l1, &st, BlockInput{
		Number: 3, Timestamp: ts3, EpochNumber: epoch2, EpochHash: hash2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.SeqNumber != 0 {
		t.Fatalf("epoch2 block1 seq=%d want 0 after origin advance", st.SeqNumber)
	}
	if st.L1OriginNum != epoch2 {
		t.Fatalf("L1OriginNum=%d want %d", st.L1OriginNum, epoch2)
	}
}
