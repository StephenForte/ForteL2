package derivation

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
)

func TestParseGameTypeFlagNoDefault(t *testing.T) {
	got, err := ParseGameTypeFlag("")
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Fatalf("empty flag must mean on-chain resolve, got %v", *got)
	}
	got, err = ParseGameTypeFlag("  ")
	if err != nil || got != nil {
		t.Fatalf("whitespace must be empty: %v %v", got, err)
	}
	got, err = ParseGameTypeFlag("8")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || *got != 8 {
		t.Fatalf("explicit 8: %v", got)
	}
	got, err = ParseGameTypeFlag("0")
	if err != nil || got == nil || *got != 0 {
		t.Fatalf("explicit 0 is an override, not a missing default: %v %v", got, err)
	}
	if _, err := ParseGameTypeFlag("nope"); err == nil {
		t.Fatal("non-numeric must error (no silent default)")
	}
}

func TestResolveProposalContractsNeither(t *testing.T) {
	_, _, err := ResolveProposalContracts("", "", "")
	if err == nil || !strings.Contains(err.Error(), "neither") {
		t.Fatalf("want neither-error, got %v", err)
	}
}

func TestResolveProposalContractsFromFlatJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "deployments.json")
	factory := common.HexToAddress("0x67f9e427c716586ecc0dc0b62baa8cd05e43262f")
	asr := common.HexToAddress("0x8f98eb7f5ebb9a0de0acf8fa7916b67b9295f480")
	if err := os.WriteFile(path, []byte(fmt.Sprintf(
		`{"DisputeGameFactoryProxy":"%s","AnchorStateRegistryProxy":"%s"}`, factory, asr,
	)), 0o644); err != nil {
		t.Fatal(err)
	}
	gotF, gotA, err := ResolveProposalContracts(path, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if gotF != factory || gotA != asr {
		t.Fatalf("got factory=%s asr=%s", gotF, gotA)
	}
}

func TestResolveProposalContractsFromNestedStateJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	factory := common.HexToAddress("0x1111111111111111111111111111111111111111")
	asr := common.HexToAddress("0x2222222222222222222222222222222222222222")
	body := fmt.Sprintf(`{"opChainDeployments":[{"DisputeGameFactoryProxy":"%s","AnchorStateRegistryProxy":"%s"}]}`, factory, asr)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	gotF, gotA, err := ResolveProposalContracts(path, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if gotF != factory || gotA != asr {
		t.Fatalf("got factory=%s asr=%s", gotF, gotA)
	}
}

func TestResolveProposalContractsFlagOverride(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "deployments.json")
	if err := os.WriteFile(path, []byte(`{
		"DisputeGameFactoryProxy":"0x1111111111111111111111111111111111111111",
		"AnchorStateRegistryProxy":"0x2222222222222222222222222222222222222222"
	}`), 0o644); err != nil {
		t.Fatal(err)
	}
	override := "0x3333333333333333333333333333333333333333"
	gotF, gotA, err := ResolveProposalContracts(path, override, "")
	if err != nil {
		t.Fatal(err)
	}
	if gotF != common.HexToAddress(override) {
		t.Fatalf("factory override not applied: %s", gotF)
	}
	if gotA != common.HexToAddress("0x2222222222222222222222222222222222222222") {
		t.Fatalf("asr should stay from file: %s", gotA)
	}
}

func TestDecodeL2BlockNumber(t *testing.T) {
	extra := PackExtraDataUint256(20)
	n, err := DecodeL2BlockNumber(extra)
	if err != nil {
		t.Fatal(err)
	}
	if n != 20 {
		t.Fatalf("got %d", n)
	}
}

func TestDecodeL2BlockNumberMalformed(t *testing.T) {
	if _, err := DecodeL2BlockNumber(nil); err == nil {
		t.Fatal("empty extraData must error, not skip")
	}
	if _, err := DecodeL2BlockNumber([]byte{1, 2, 3}); err == nil {
		t.Fatal("short extraData must error")
	}
	tooBig := make([]byte, 32)
	tooBig[0] = 1
	if _, err := DecodeL2BlockNumber(tooBig); err == nil {
		t.Fatal("uint256 that does not fit uint64 must error")
	}
}

func TestRespectedGameTypeFromMockRPC(t *testing.T) {
	asr := common.HexToAddress("0x8f98eb7f5ebb9a0de0acf8fa7916b67b9295f480")
	client := mockRPC(t, func(method string, params []any) (any, error) {
		if method != "eth_call" {
			return nil, fmt.Errorf("unexpected method %s", method)
		}
		return encodeABIUint32(8), nil
	})
	got, err := RespectedGameType(context.Background(), client, asr)
	if err != nil {
		t.Fatal(err)
	}
	if got != 8 {
		t.Fatalf("respectedGameType=%d want 8", got)
	}
}

func TestEnumerateProposalsSynthetic(t *testing.T) {
	factory := common.HexToAddress("0x67f9e427c716586ecc0dc0b62baa8cd05e43262f")
	gameMatch := common.HexToAddress("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	gameSkipType := common.HexToAddress("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	claim := common.HexToHash("0x" + strings.Repeat("11", 32))

	client := mockRPC(t, func(method string, params []any) (any, error) {
		if method != "eth_call" {
			return nil, fmt.Errorf("unexpected %s", method)
		}
		obj := params[0].(map[string]any)
		to := strings.ToLower(obj["to"].(string))
		data := obj["data"].(string)
		switch {
		case to == strings.ToLower(factory.Hex()) && strings.HasPrefix(data, selector("gameCount")):
			return encodeABIUint256(2), nil
		case to == strings.ToLower(factory.Hex()) && strings.HasPrefix(data, selector("gameAtIndex")):
			idx := indexFromCalldata(t, data)
			if idx == 0 {
				return encodeGameAtIndex(8, 111, gameMatch), nil
			}
			return encodeGameAtIndex(1, 222, gameSkipType), nil
		case to == strings.ToLower(gameMatch.Hex()) && strings.HasPrefix(data, selector("rootClaim")):
			return hexutil.Encode(claim[:]), nil
		case to == strings.ToLower(gameMatch.Hex()) && strings.HasPrefix(data, selector("extraData")):
			return encodeABIBytes(PackExtraDataUint256(20)), nil
		case to == strings.ToLower(gameMatch.Hex()) && strings.HasPrefix(data, selector("status")):
			return encodeABIUint8(0), nil
		default:
			return nil, fmt.Errorf("unexpected call to=%s data=%s", to, data)
		}
	})

	got, err := EnumerateProposals(context.Background(), client, factory, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("enumerated %d want 1 (type-1 game filtered)", len(got))
	}
	if got[0].Game != gameMatch || got[0].L2Block != 20 || got[0].RootClaim != claim || got[0].Status != 0 {
		t.Fatalf("unexpected proposal: %+v", got[0])
	}
}

func TestEnumerateProposalsMalformedExtraData(t *testing.T) {
	factory := common.HexToAddress("0x67f9e427c716586ecc0dc0b62baa8cd05e43262f")
	game := common.HexToAddress("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	client := mockRPC(t, func(method string, params []any) (any, error) {
		obj := params[0].(map[string]any)
		to := strings.ToLower(obj["to"].(string))
		data := obj["data"].(string)
		switch {
		case strings.HasPrefix(data, selector("gameCount")):
			return encodeABIUint256(1), nil
		case strings.HasPrefix(data, selector("gameAtIndex")):
			return encodeGameAtIndex(8, 1, game), nil
		case to == strings.ToLower(game.Hex()) && strings.HasPrefix(data, selector("rootClaim")):
			return hexutil.Encode(make([]byte, 32)), nil
		case to == strings.ToLower(game.Hex()) && strings.HasPrefix(data, selector("extraData")):
			return encodeABIBytes([]byte{1, 2, 3}), nil
		case to == strings.ToLower(game.Hex()) && strings.HasPrefix(data, selector("status")):
			return encodeABIUint8(0), nil
		default:
			return nil, fmt.Errorf("unexpected call")
		}
	})
	_, err := EnumerateProposals(context.Background(), client, factory, 8)
	if err == nil || !strings.Contains(err.Error(), "extraData") {
		t.Fatalf("malformed extraData must error, not skip: %v", err)
	}
}

func selector(name string) string {
	switch name {
	case "gameCount":
		return hexutil.Encode(mustPack(proposalFactoryABI.Pack("gameCount")))[:10]
	case "gameAtIndex":
		return hexutil.Encode(mustPack(proposalFactoryABI.Pack("gameAtIndex", big.NewInt(0))))[:10]
	case "rootClaim":
		return hexutil.Encode(mustPack(proposalGameABI.Pack("rootClaim")))[:10]
	case "extraData":
		return hexutil.Encode(mustPack(proposalGameABI.Pack("extraData")))[:10]
	case "status":
		return hexutil.Encode(mustPack(proposalGameABI.Pack("status")))[:10]
	default:
		panic(name)
	}
}

func mustPack(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func indexFromCalldata(t *testing.T, data string) uint64 {
	t.Helper()
	raw, err := hexutil.Decode(data)
	if err != nil || len(raw) < 36 {
		t.Fatalf("calldata %s", data)
	}
	return new(big.Int).SetBytes(raw[4:]).Uint64()
}

func encodeABIUint32(n uint32) string {
	out, err := proposalASRABI.Methods["respectedGameType"].Outputs.Pack(n)
	if err != nil {
		panic(err)
	}
	return hexutil.Encode(out)
}

func encodeABIUint256(n uint64) string {
	out, err := proposalFactoryABI.Methods["gameCount"].Outputs.Pack(new(big.Int).SetUint64(n))
	if err != nil {
		panic(err)
	}
	return hexutil.Encode(out)
}

func encodeABIUint8(n uint8) string {
	out, err := proposalGameABI.Methods["status"].Outputs.Pack(n)
	if err != nil {
		panic(err)
	}
	return hexutil.Encode(out)
}

func encodeABIBytes(b []byte) string {
	out, err := proposalGameABI.Methods["extraData"].Outputs.Pack(b)
	if err != nil {
		panic(err)
	}
	return hexutil.Encode(out)
}

func encodeGameAtIndex(gameType uint32, ts uint64, proxy common.Address) string {
	out, err := proposalFactoryABI.Methods["gameAtIndex"].Outputs.Pack(gameType, ts, proxy)
	if err != nil {
		panic(err)
	}
	return hexutil.Encode(out)
}

func mockRPC(t *testing.T, handle func(method string, params []any) (any, error)) *RPCClient {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
			Params []any  `json:"params"`
			ID     any    `json:"id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		res, err := handle(req.Method, req.Params)
		enc := json.NewEncoder(w)
		if err != nil {
			_ = enc.Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      req.ID,
				"error":   map[string]any{"code": -32000, "message": err.Error()},
			})
			return
		}
		raw, _ := json.Marshal(res)
		_ = enc.Encode(map[string]any{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"result":  json.RawMessage(raw),
		})
	}))
	t.Cleanup(srv.Close)
	return NewRPCClient(srv.URL)
}
