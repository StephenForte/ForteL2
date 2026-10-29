package proposer

import (
	"crypto/ecdsa"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

func TestRefuseSepoliaOnLoopback(t *testing.T) {
	sepolia := big.NewInt(SepoliaL1ChainID)
	fork := big.NewInt(900852)
	cases := []struct {
		name    string
		url     string
		chain   *big.Int
		refuses bool
	}{
		{"loopback sepolia", "http://127.0.0.1:8545", sepolia, true},
		{"localhost sepolia", "http://localhost:8545", sepolia, true},
		{"ipv6 loopback sepolia", "http://[::1]:8545", sepolia, true},
		{"loopback fork", "http://127.0.0.1:8545", fork, false},
		{"remote sepolia is not this guard", "https://ethereum-sepolia.example/rpc", sepolia, false},
		{"missing chain", "http://127.0.0.1:8545", nil, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := RefuseSepoliaOnLoopback(tc.url, tc.chain)
			if tc.refuses && err == nil {
				t.Fatal("expected refusal")
			}
			if !tc.refuses && err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSignLegacyTxRefusesLoopbackSepolia(t *testing.T) {
	key, err := crypto.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	tx := types.NewTransaction(0, common.Address{}, big.NewInt(0), 21000, big.NewInt(1), nil)
	_, err = SignLegacyTx("http://127.0.0.1:8545", big.NewInt(SepoliaL1ChainID), tx, key)
	if err == nil || !strings.Contains(err.Error(), "11155111") {
		t.Fatalf("loopback Sepolia must not be signed, got %v", err)
	}
	signed, err := SignLegacyTx("http://127.0.0.1:8545", big.NewInt(900852), tx, key)
	if err != nil {
		t.Fatal(err)
	}
	if signed == nil {
		t.Fatal("fork chain id must still sign")
	}
	remote, err := SignLegacyTx("https://ethereum-sepolia.example/rpc", big.NewInt(SepoliaL1ChainID), tx, key)
	if err != nil || remote == nil {
		t.Fatalf("remote URL is outside this guard: %v", err)
	}
}

func TestSignLegacyTxNeedsKey(t *testing.T) {
	tx := types.NewTransaction(0, common.Address{}, big.NewInt(0), 21000, big.NewInt(1), nil)
	var key *ecdsa.PrivateKey
	if _, err := SignLegacyTx("http://127.0.0.1:9", big.NewInt(900852), tx, key); err == nil {
		t.Fatal("nil key")
	}
}
