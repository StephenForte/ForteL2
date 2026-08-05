package derivation

import (
	"encoding/json"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

func TestL2RefJSONRoundtrip(t *testing.T) {
	want := L2Ref{
		Hash:   common.HexToHash("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"),
		Number: 601_268,
	}
	raw, err := json.Marshal(want)
	if err != nil {
		t.Fatal(err)
	}
	if !jsonContainsField(t, raw, "number") {
		t.Fatalf("marshal dropped number field: %s", raw)
	}

	var got L2Ref
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if got.Hash != want.Hash {
		t.Fatalf("hash=%s want %s", got.Hash, want.Hash)
	}
	if got.Number != want.Number {
		t.Fatalf("number=%d want %d", got.Number, want.Number)
	}
}

func TestL2RefUnmarshalAbsentNumber(t *testing.T) {
	hash := common.HexToHash("0x1111111111111111111111111111111111111111111111111111111111111111")
	raw := []byte(`{"hash":"` + hash.Hex() + `"}`)
	var ref L2Ref
	if err := json.Unmarshal(raw, &ref); err != nil {
		t.Fatal(err)
	}
	if ref.Hash != hash {
		t.Fatalf("hash=%s", ref.Hash)
	}
	if ref.Number != 0 {
		t.Fatalf("absent number should decode as 0, got %d", ref.Number)
	}
}

func TestL2RefUnmarshalHexNumber(t *testing.T) {
	hash := common.HexToHash("0x2222222222222222222222222222222222222222222222222222222222222222")
	raw := []byte(`{"hash":"` + hash.Hex() + `","number":"0x92c94"}`)
	var ref L2Ref
	if err := json.Unmarshal(raw, &ref); err != nil {
		t.Fatal(err)
	}
	if ref.Number != 601_236 {
		t.Fatalf("number=%d want 601236", ref.Number)
	}
}

func jsonContainsField(t *testing.T, raw []byte, key string) bool {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	_, ok := m[key]
	return ok
}
