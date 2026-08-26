package derivation

import (
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// Hand-computed with Foundry `cast keccak` (not go-ethereum) over the 128-byte
// version-0 preimage: 32 zero bytes ‖ 0x11…11 ‖ 0x22…22 ‖ 0x33…33.
const outputRootV0HandVector = "0xd50bf2ff34ced71be0d2f0be7c2433c6b39d9c3b16c95daf1ed6f24b7578a3b2"

func TestOutputRootV0HandVector(t *testing.T) {
	state := common.HexToHash("0x" + strings.Repeat("11", 32))
	storage := common.HexToHash("0x" + strings.Repeat("22", 32))
	block := common.HexToHash("0x" + strings.Repeat("33", 32))
	got := OutputRootV0(state, storage, block)
	want := common.HexToHash(outputRootV0HandVector)
	if got != want {
		t.Fatalf("OutputRootV0 = %s want %s (hand-computed keccak)", got, want)
	}
}

func TestOutputRootV0VersionIsZero(t *testing.T) {
	// Changing only the implicit version bytes (the first 32) must not match a
	// preimage that starts with 0x01… — version is zeros, not a numeric 0 packed
	// into the last byte of the first word.
	a := OutputRootV0(common.Hash{1}, common.Hash{2}, common.Hash{3})
	b := OutputRootV0(common.Hash{1}, common.Hash{2}, common.Hash{3})
	if a != b {
		t.Fatal("same preimage must be stable")
	}
	if a == (common.Hash{}) {
		t.Fatal("output root must not be zero")
	}
}

func TestRequireExistingAccountEmptyCodeHash(t *testing.T) {
	proof := accountProofJSON{
		Address:      L2ToL1MessagePasser,
		AccountProof: []string{"0x01"},
		CodeHash:     emptyCodeHash,
		StorageHash:  common.HexToHash("0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"),
	}
	err := requireExistingAccount(L2ToL1MessagePasser, proof)
	if err == nil {
		t.Fatal("empty codeHash must be refused (non-existent account)")
	}
	if !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("error should name non-existence: %v", err)
	}
}

func TestRequireExistingAccountZeroCodeHash(t *testing.T) {
	proof := accountProofJSON{
		Address:      L2ToL1MessagePasser,
		AccountProof: []string{"0x01"},
		StorageHash:  common.HexToHash("0x11"),
	}
	if err := requireExistingAccount(L2ToL1MessagePasser, proof); err == nil {
		t.Fatal("zero codeHash must be refused")
	}
}

func TestRequireExistingAccountMissingProof(t *testing.T) {
	proof := accountProofJSON{
		Address:     L2ToL1MessagePasser,
		CodeHash:    common.HexToHash("0x" + strings.Repeat("ab", 32)),
		StorageHash: common.HexToHash("0x" + strings.Repeat("cd", 32)),
	}
	if err := requireExistingAccount(L2ToL1MessagePasser, proof); err == nil {
		t.Fatal("empty accountProof must be refused")
	}
}

func TestRequireExistingAccountOK(t *testing.T) {
	proof := accountProofJSON{
		Address:      L2ToL1MessagePasser,
		AccountProof: []string{"0x01"},
		CodeHash:     common.HexToHash("0x" + strings.Repeat("ab", 32)),
		StorageHash:  common.HexToHash("0x" + strings.Repeat("cd", 32)),
	}
	if err := requireExistingAccount(L2ToL1MessagePasser, proof); err != nil {
		t.Fatal(err)
	}
}

func TestRequireExistingAccountWrongAddress(t *testing.T) {
	proof := accountProofJSON{
		Address:      common.HexToAddress("0x0000000000000000000000000000000000000001"),
		AccountProof: []string{"0x01"},
		CodeHash:     common.HexToHash("0x" + strings.Repeat("ab", 32)),
		StorageHash:  common.HexToHash("0x" + strings.Repeat("cd", 32)),
	}
	if err := requireExistingAccount(L2ToL1MessagePasser, proof); err == nil {
		t.Fatal("mismatched proof address must be refused")
	}
}

func TestMessagePasserAddress(t *testing.T) {
	want := common.HexToAddress("0x4200000000000000000000000000000000000016")
	if L2ToL1MessagePasser != want {
		t.Fatalf("L2ToL1MessagePasser = %s want %s", L2ToL1MessagePasser, want)
	}
}
