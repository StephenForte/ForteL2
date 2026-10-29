package proposer

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"
	"net/url"
	"strings"

	"github.com/ethereum/go-ethereum/core/types"
)

// SepoliaL1ChainID is Ethereum Sepolia. A signature under this chain id is
// valid on the live L1. The OPU fork uses 900852 so its signatures are not.
const SepoliaL1ChainID int64 = 11155111

// IsLoopbackRPC reports whether rawURL's host is loopback. Same hosts as
// scripts/lib.sh assert_loopback_url: 127.0.0.1, localhost, ::1.
func IsLoopbackRPC(rawURL string) bool {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || u.Host == "" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	switch host {
	case "127.0.0.1", "localhost", "::1":
		return true
	default:
		return false
	}
}

// RefuseSepoliaOnLoopback refuses to sign when a loopback L1 reports chain id
// 11155111. A port-forward or local proxy to Sepolia must not produce a
// Sepolia-valid transaction. Chain id 900852 on loopback is the fork and is
// allowed. A remote Sepolia URL is not this guard.
func RefuseSepoliaOnLoopback(rawURL string, chainID *big.Int) error {
	if chainID == nil {
		return fmt.Errorf("refusing to sign: missing chain id")
	}
	if !IsLoopbackRPC(rawURL) {
		return nil
	}
	if chainID.Cmp(big.NewInt(SepoliaL1ChainID)) == 0 {
		return fmt.Errorf("refusing to sign: loopback L1 reports chain id %s (Sepolia)", chainID)
	}
	return nil
}

// SignLegacyTx signs a legacy transaction after RefuseSepoliaOnLoopback.
// Signing tools call this instead of types.SignTx.
func SignLegacyTx(l1URL string, chainID *big.Int, tx *types.Transaction, key *ecdsa.PrivateKey) (*types.Transaction, error) {
	if err := RefuseSepoliaOnLoopback(l1URL, chainID); err != nil {
		return nil, err
	}
	if chainID == nil || chainID.Sign() <= 0 {
		return nil, fmt.Errorf("refusing to sign: missing chain id")
	}
	if key == nil {
		return nil, fmt.Errorf("refusing to sign: missing key")
	}
	return types.SignTx(tx, types.LatestSignerForChainID(chainID), key)
}
