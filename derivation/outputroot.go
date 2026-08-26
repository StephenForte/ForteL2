package derivation

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/crypto"
)

// L2ToL1MessagePasser is the OP Stack predeploy whose storage root is in the
// version-0 output-root preimage (specs: L2 output root).
var L2ToL1MessagePasser = common.HexToAddress("0x4200000000000000000000000000000000000016")

// emptyCodeHash is keccak256("") — eth_getProof returns this for a non-existent account.
var emptyCodeHash = common.HexToHash("0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

// OutputRootV0 is keccak256(version ‖ stateRoot ‖ messagePasserStorageRoot ‖ blockHash)
// with version = 32 zero bytes (OP Stack output version 0).
func OutputRootV0(stateRoot, messagePasserStorageRoot, blockHash common.Hash) common.Hash {
	var preimage [128]byte
	copy(preimage[32:64], stateRoot[:])
	copy(preimage[64:96], messagePasserStorageRoot[:])
	copy(preimage[96:128], blockHash[:])
	return crypto.Keccak256Hash(preimage[:])
}

type accountProofJSON struct {
	Address      common.Address `json:"address"`
	AccountProof []string       `json:"accountProof"`
	Balance      *hexutil.Big   `json:"balance"`
	CodeHash     common.Hash    `json:"codeHash"`
	Nonce        hexutil.Uint64 `json:"nonce"`
	StorageHash  common.Hash    `json:"storageHash"`
}

// requireExistingAccount rejects eth_getProof results for a missing account.
// A non-existent account still returns a storageHash (empty trie) that would
// produce a plausible-looking wrong output root — a false MISMATCH.
func requireExistingAccount(want common.Address, proof accountProofJSON) error {
	if proof.Address != (common.Address{}) && proof.Address != want {
		return fmt.Errorf("eth_getProof address %s does not match %s", proof.Address, want)
	}
	if len(proof.AccountProof) == 0 {
		return fmt.Errorf("eth_getProof: empty accountProof for %s", want)
	}
	if proof.CodeHash == (common.Hash{}) || proof.CodeHash == emptyCodeHash {
		return fmt.Errorf("eth_getProof: account %s does not exist at this height (empty codeHash); refusing storage root to avoid a false MISMATCH", want)
	}
	if proof.StorageHash == (common.Hash{}) {
		return fmt.Errorf("eth_getProof: missing storageHash for %s", want)
	}
	return nil
}

type sealedBlockJSON struct {
	Hash      common.Hash `json:"hash"`
	StateRoot common.Hash `json:"stateRoot"`
	Number    string      `json:"number"`
}

// OutputRootV0At computes the version-0 output root at height from the seal EL.
func (el *SealingEL) OutputRootV0At(ctx context.Context, height uint64) (common.Hash, error) {
	hash, stateRoot, err := el.sealedHeaderAt(ctx, height)
	if err != nil {
		return common.Hash{}, err
	}
	storageRoot, err := el.messagePasserStorageRoot(ctx, height, stateRoot)
	if err != nil {
		return common.Hash{}, err
	}
	return OutputRootV0(stateRoot, storageRoot, hash), nil
}

func (el *SealingEL) sealedHeaderAt(ctx context.Context, height uint64) (hash, stateRoot common.Hash, err error) {
	raw, err := el.httpRPC.CallRaw(ctx, "eth_getBlockByNumber", []any{fmt.Sprintf("0x%x", height), false})
	if err != nil {
		return common.Hash{}, common.Hash{}, fmt.Errorf("seal EL block %d: %w", height, err)
	}
	if string(raw) == "null" {
		return common.Hash{}, common.Hash{}, fmt.Errorf("seal EL block %d: not present (null header)", height)
	}
	var blk sealedBlockJSON
	if err := json.Unmarshal(raw, &blk); err != nil {
		return common.Hash{}, common.Hash{}, fmt.Errorf("seal EL block %d: decode header: %w", height, err)
	}
	if blk.Hash == (common.Hash{}) || blk.StateRoot == (common.Hash{}) {
		return common.Hash{}, common.Hash{}, fmt.Errorf("seal EL block %d: missing hash or stateRoot", height)
	}
	return blk.Hash, blk.StateRoot, nil
}

func (el *SealingEL) messagePasserStorageRoot(ctx context.Context, height uint64, stateRoot common.Hash) (common.Hash, error) {
	raw, err := el.httpRPC.CallRaw(ctx, "eth_getProof", []any{
		L2ToL1MessagePasser.Hex(),
		[]string{},
		fmt.Sprintf("0x%x", height),
	})
	if err != nil {
		return common.Hash{}, fmt.Errorf("eth_getProof at L2 block %d: %w", height, err)
	}
	if string(raw) == "null" {
		return common.Hash{}, fmt.Errorf("eth_getProof at L2 block %d: null result", height)
	}
	var proof accountProofJSON
	if err := json.Unmarshal(raw, &proof); err != nil {
		return common.Hash{}, fmt.Errorf("eth_getProof at L2 block %d: decode: %w", height, err)
	}
	if err := requireExistingAccount(L2ToL1MessagePasser, proof); err != nil {
		return common.Hash{}, fmt.Errorf("eth_getProof at L2 block %d (stateRoot=%s): %w", height, stateRoot, err)
	}
	return proof.StorageHash, nil
}
