package derivation

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/StephenForte/ForteL2/batcher"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

// 12 L2 blocks (1–12), two L1 origins (6 blocks each). A window that only
// needs one origin must not fetch the other; repeated epochs must not refetch.
const (
	stormSpanBlocks     = 12
	stormBlocksPerEpoch = 6
	stormOriginA        = uint64(100)
	stormOriginB        = uint64(101)
)

func epochHashFor(n uint64) common.Hash {
	var h common.Hash
	h[0] = 0xee
	binary.BigEndian.PutUint64(h[24:], n)
	return h
}

func stormSpanChannel(t *testing.T) []byte {
	t.Helper()
	cfg := testRollupConfig()
	originBits := big.NewInt(0)
	originBits.SetBit(originBits, stormBlocksPerEpoch, 1) // block index 6 starts origin B
	txCounts := make([]uint64, stormSpanBlocks)
	span := encodeTestSpanBatch(testSpanBatchParams{
		relTimestamp:  cfg.BlockTime, // L2 block 1
		l1OriginNum:   stormOriginB,
		parentCheck:   first20([]byte("parent-check")),
		l1OriginCheck: first20([]byte("origin-check")),
		blockCount:    stormSpanBlocks,
		originBits:    originBits,
		blockTxCounts: txCounts,
	})
	channel, err := batcher.BuildChannelZlib([][]byte{span})
	if err != nil {
		t.Fatalf("BuildChannelZlib: %v", err)
	}
	var id [16]byte
	copy(id[:], []byte("epoch-hash-test!"))
	frames, err := batcher.SplitChannelFrames(id, channel, 100_000)
	if err != nil {
		t.Fatalf("SplitChannelFrames: %v", err)
	}
	payload, err := batcher.EncodeBatcherTxPayload(frames)
	if err != nil {
		t.Fatalf("EncodeBatcherTxPayload: %v", err)
	}
	return payload
}

type headerFetchServer struct {
	payload     []byte
	txHash      common.Hash
	headerCalls atomic.Int64
	failNum     map[uint64]bool
}

func (s *headerFetchServer) handler(t *testing.T) http.HandlerFunc {
	t.Helper()
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
			ID     uint64 `json:"id"`
			Params []any  `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode: %v", err)
			return
		}
		switch req.Method {
		case "eth_getTransactionByHash":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      req.ID,
				"result": map[string]any{
					"hash":  s.txHash,
					"input": hexutil.Bytes(s.payload),
				},
			})
		case "eth_getBlockByNumber":
			if len(req.Params) < 2 {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			full, _ := req.Params[1].(bool)
			if full {
				t.Errorf("decode path must request header-only (full=false)")
			}
			s.headerCalls.Add(1)
			tag, _ := req.Params[0].(string)
			num, err := hexutil.DecodeUint64(tag)
			if err != nil {
				t.Errorf("block tag %q: %v", tag, err)
				return
			}
			if s.failNum[num] {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"jsonrpc": "2.0",
					"id":      req.ID,
					"error":   map[string]any{"code": -32000, "message": fmt.Sprintf("missing header %d", num)},
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      req.ID,
				"result": map[string]any{
					"number":        hexutil.EncodeUint64(num),
					"hash":          epochHashFor(num),
					"parentHash":    common.Hash{},
					"timestamp":     hexutil.Uint64(1_700_000_040),
					"baseFeePerGas": (*hexutil.Big)(big.NewInt(1)),
					"mixHash":       common.Hash{},
				},
			})
		default:
			w.WriteHeader(http.StatusBadRequest)
		}
	}
}

func deriveStormWindow(t *testing.T, start, end uint64, fail map[uint64]bool) (inputs []BlockInput, headerFetches int64, err error) {
	t.Helper()
	payload := stormSpanChannel(t)
	txHash := common.HexToHash("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	srvState := &headerFetchServer{payload: payload, txHash: txHash, failNum: fail}
	httpSrv := httptest.NewServer(srvState.handler(t))
	t.Cleanup(httpSrv.Close)

	l1 := NewL1Client(tightRPCClient(httpSrv.URL))
	cfg := testRollupConfig()
	inputs, err = deriveBlockInputs(t.Context(), cfg, l1, VerifyOptions{
		ChannelTx: txHash,
		StartL2:   start,
		EndL2:     end,
	})
	return inputs, srvState.headerCalls.Load(), err
}

func TestDeriveBlockInputsEpochHashFetchBudget(t *testing.T) {
	// Property 3: a W-block window touching K distinct L1 origins performs
	// O(K) header fetches during decode, not one per decoded L2 block.
	cases := []struct {
		name    string
		start   uint64
		end     uint64
		wantN   int
		wantK   int64
		origins []uint64
	}{
		{name: "full span two origins", start: 1, end: 12, wantN: 12, wantK: 2, origins: []uint64{stormOriginA, stormOriginB}},
		{name: "window second origin only", start: 7, end: 12, wantN: 6, wantK: 1, origins: []uint64{stormOriginB}},
		{name: "window first origin only", start: 1, end: 6, wantN: 6, wantK: 1, origins: []uint64{stormOriginA}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			inputs, fetches, err := deriveStormWindow(t, tc.start, tc.end, nil)
			if err != nil {
				t.Fatalf("deriveBlockInputs: %v", err)
			}
			if len(inputs) != tc.wantN {
				t.Fatalf("got %d inputs, want %d", len(inputs), tc.wantN)
			}
			if fetches != tc.wantK {
				t.Fatalf("header fetches=%d want %d (K distinct origins); a per-block decode storm would be %d",
					fetches, tc.wantK, stormSpanBlocks)
			}
			seen := map[uint64]bool{}
			for i, in := range inputs {
				wantNum := tc.start + uint64(i)
				if in.Number != wantNum {
					t.Errorf("inputs[%d].Number=%d want %d", i, in.Number, wantNum)
				}
				if in.EpochHash != epochHashFor(in.EpochNumber) {
					t.Errorf("block %d EpochHash=%s want %s (origin %d)", in.Number, in.EpochHash, epochHashFor(in.EpochNumber), in.EpochNumber)
				}
				seen[in.EpochNumber] = true
			}
			if uint64(len(seen)) != uint64(tc.wantK) {
				t.Errorf("distinct origins in result=%d want %d (%v)", len(seen), tc.wantK, seen)
			}
			for _, o := range tc.origins {
				if !seen[o] {
					t.Errorf("missing origin %d in derived inputs", o)
				}
			}
		})
	}
}

func TestDeriveBlockInputsEpochHashOutOfWindowMissingIsOK(t *testing.T) {
	// Origin A is only used by L2 1–6. A 7–12 window must not fetch it,
	// so a missing/unfetchable A header is not an error.
	inputs, fetches, err := deriveStormWindow(t, 7, 12, map[uint64]bool{stormOriginA: true})
	if err != nil {
		t.Fatalf("out-of-window missing header must not fail: %v", err)
	}
	if len(inputs) != 6 {
		t.Fatalf("got %d inputs, want 6", len(inputs))
	}
	if fetches != 1 {
		t.Fatalf("header fetches=%d want 1 (in-window origin B only)", fetches)
	}
	for _, in := range inputs {
		if in.EpochNumber != stormOriginB || in.EpochHash != epochHashFor(stormOriginB) {
			t.Errorf("block %d epoch=%d hash=%s", in.Number, in.EpochNumber, in.EpochHash)
		}
	}
}

func TestDeriveBlockInputsEpochHashInWindowMissingIsError(t *testing.T) {
	_, fetches, err := deriveStormWindow(t, 7, 12, map[uint64]bool{stormOriginB: true})
	if err == nil {
		t.Fatal("missing in-window epoch header must be a hard error")
	}
	if fetches != 1 {
		t.Fatalf("header fetches=%d want 1 (failed in-window origin)", fetches)
	}
}

func TestBlockHeaderMemoizesByNumber(t *testing.T) {
	var calls atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
			ID     uint64 `json:"id"`
			Params []any  `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode: %v", err)
			return
		}
		if req.Method != "eth_getBlockByNumber" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		calls.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"result": map[string]any{
				"number":    hexutil.EncodeUint64(7),
				"hash":      epochHashFor(7),
				"timestamp": hexutil.Uint64(1),
			},
		})
	}))
	t.Cleanup(srv.Close)

	l1 := NewL1Client(tightRPCClient(srv.URL))
	h1, err := l1.BlockHeader(t.Context(), 7)
	if err != nil {
		t.Fatal(err)
	}
	h2, err := l1.BlockHeader(t.Context(), 7)
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("BlockHeader calls=%d want 1", calls.Load())
	}
	if h1.Hash != epochHashFor(7) || h2.Hash != h1.Hash {
		t.Fatalf("cached hash mismatch: %s vs %s", h1.Hash, h2.Hash)
	}
	h3, err := l1.BlockHeaderByHash(t.Context(), epochHashFor(7))
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatalf("BlockHeaderByHash must hit the number-populated cache; calls=%d want 1", calls.Load())
	}
	if h3.Number != 7 {
		t.Fatalf("cached-by-hash number=%d want 7", h3.Number)
	}
}
