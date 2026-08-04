package derivation

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/ethereum/go-ethereum/common"
)

// L2Ref is a lightweight L2 block reference from optimism_syncStatus.
type L2Ref struct {
	Hash   common.Hash `json:"hash"`
	Number uint64      `json:"-"` // custom (un)marshal below: decimal out, hex/decimal/absent in
}

// MarshalJSON emits both fields — without this, JSON reports (e.g. the Sepolia
// golden fixture) silently lose the block number.
func (r L2Ref) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Hash   common.Hash `json:"hash"`
		Number uint64      `json:"number"`
	}{r.Hash, r.Number})
}

func (r *L2Ref) UnmarshalJSON(b []byte) error {
	var raw struct {
		Hash   common.Hash `json:"hash"`
		Number any         `json:"number"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	r.Hash = raw.Hash
	switch v := raw.Number.(type) {
	case float64:
		r.Number = uint64(v)
	case string:
		v = strings.TrimPrefix(v, "0x")
		n, err := strconv.ParseUint(v, 16, 64)
		if err != nil {
			n, err = strconv.ParseUint(v, 10, 64)
			if err != nil {
				return fmt.Errorf("parse l2 ref number: %w", err)
			}
		}
		r.Number = n
	case nil:
		// Absent number (fixtures captured before MarshalJSON emitted it).
		r.Number = 0
	default:
		return fmt.Errorf("unexpected number type %T", raw.Number)
	}
	return nil
}
