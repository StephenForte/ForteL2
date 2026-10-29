// Command bad-proposal creates one DisputeGameFactory game with a deliberately
// corrupted output root, waits for the create tx to mine, self-checks the
// on-chain rootClaim, then exits (US-074).
//
//	go run ./cmd/bad-proposal \
//	  -l1 "$L1_RPC_URL" -rollup "$L2_NODE_RPC_URL" \
//	  -factory 0x... -game-type "$PROPOSER_GAME_TYPE" \
//	  -i-understand-this-posts-a-false-claim=true
//
// Signs with PROPOSER_PRIVATE_KEY (or -private-key) — the factory proposer
// role. Never CHALLENGER_PRIVATE_KEY: challenger cannot create() on this
// PermissionedDisputeGame deployment.
//
// Never commit private keys. Prefer env PROPOSER_PRIVATE_KEY over -private-key.
// One-shot only: no poll loop, no -interval. Stop stock op-proposer first so
// the shared proposer nonce cannot race.
package main

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/StephenForte/ForteL2/proposer"
	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

const confirmEnvName = "I_UNDERSTAND_THIS_POSTS_A_FALSE_CLAIM"

func main() {
	l1RPC := flag.String("l1", envOr("L1_RPC_URL", ""), "L1 HTTP RPC")
	rollupRPC := flag.String("rollup", envOr("L2_NODE_RPC_URL", ""), "op-node HTTP RPC")
	factoryFlag := flag.String("factory", "", "DisputeGameFactoryProxy")
	deployments := flag.String("deployments", "", "optional deployments.json")
	keyFlag := flag.String("private-key", "", "proposer EOA key (prefer PROPOSER_PRIVATE_KEY env; never CHALLENGER_PRIVATE_KEY)")
	gameTypeFlag := flag.String("game-type", "", "dispute game type (required; or PROPOSER_GAME_TYPE — no silent default)")
	blockFlag := flag.Uint64("block", 0, "L2 block to claim (0 = current safe head)")
	confirmFlag := flag.Bool("i-understand-this-posts-a-false-claim", false, "required to broadcast; without it, print the plan and exit 1")
	receiptTimeout := flag.Duration("receipt-timeout", 3*time.Minute, "wait for the create tx to be mined")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "usage: bad-proposal -l1 … -rollup … [-factory … | -deployments …]\n")
		fmt.Fprintf(os.Stderr, "one-shot US-074 tool: create() with a corrupted output root, wait for the receipt, self-check, exit.\n")
		fmt.Fprintf(os.Stderr, "signs with PROPOSER_PRIVATE_KEY or -private-key (factory proposer role — never CHALLENGER_PRIVATE_KEY).\n")
		fmt.Fprintf(os.Stderr, "refuses to broadcast unless -i-understand-this-posts-a-false-claim=true (or %s=true).\n\n", confirmEnvName)
		flag.PrintDefaults()
	}
	flag.Parse()

	keyHex := strings.TrimSpace(*keyFlag)
	if keyHex == "" {
		keyHex = strings.TrimSpace(os.Getenv("PROPOSER_PRIVATE_KEY"))
	}
	if *l1RPC == "" || *rollupRPC == "" || keyHex == "" {
		flag.Usage()
		fmt.Fprintln(os.Stderr, "requires PROPOSER_PRIVATE_KEY or -private-key")
		os.Exit(2)
	}
	gt, err := resolveGameType(*gameTypeFlag, os.Getenv("PROPOSER_GAME_TYPE"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(2)
	}
	factoryAddr, err := resolveFactory(*factoryFlag, *deployments)
	if err != nil {
		fmt.Fprintf(os.Stderr, "factory: %v\n", err)
		os.Exit(1)
	}
	priv, err := parseKey(keyHex)
	if err != nil {
		fmt.Fprintf(os.Stderr, "key: %v\n", err)
		os.Exit(1)
	}
	from := crypto.PubkeyToAddress(priv.PublicKey)

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	l1, err := ethclient.DialContext(ctx, *l1RPC)
	if err != nil {
		fmt.Fprintf(os.Stderr, "l1 dial: %v\n", proposer.RedactErr(*l1RPC, "", err))
		os.Exit(1)
	}
	defer l1.Close()

	blockNum := *blockFlag
	if blockNum == 0 {
		heads, err := proposer.FetchSyncHeads(ctx, *rollupRPC)
		if err != nil {
			fmt.Fprintf(os.Stderr, "syncStatus: %v\n", err)
			os.Exit(1)
		}
		blockNum = heads.SafeL2
	}
	if blockNum == 0 {
		fmt.Fprintln(os.Stderr, "skip genesis / empty safe head")
		os.Exit(1)
	}

	out, err := proposer.FetchOutputAtBlock(ctx, *rollupRPC, blockNum)
	if err != nil {
		fmt.Fprintf(os.Stderr, "outputAtBlock(%d): %v\n", blockNum, err)
		os.Exit(1)
	}
	if out.BlockNumber != blockNum {
		fmt.Fprintf(os.Stderr, "output block mismatch: got %d want %d\n", out.BlockNumber, blockNum)
		os.Exit(1)
	}

	realRoot := out.OutputRoot
	if gt == proposer.GameTypeSuperCannonKona {
		if err := runSuperRootBadProposal(ctx, l1, *l1RPC, *rollupRPC, priv, from, factoryAddr, gt, blockNum, realRoot, *confirmFlag, *receiptTimeout); err != nil {
			fmt.Fprintf(os.Stderr, "%v\n", err)
			os.Exit(1)
		}
		return
	}
	badRoot := corruptRoot(realRoot)
	if badRoot == realRoot {
		fmt.Fprintln(os.Stderr, "internal error: corruptRoot did not change the claim")
		os.Exit(1)
	}

	extra := proposer.PackExtraData(blockNum)
	bond, err := proposer.InitBond(ctx, l1, factoryAddr, gt)
	if err != nil {
		fmt.Fprintf(os.Stderr, "initBonds: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("from=%s (proposer role — not challenger)\n", from.Hex())
	fmt.Printf("factory=%s\n", factoryAddr.Hex())
	fmt.Printf("gameType=%d\n", gt)
	fmt.Printf("block=%d\n", blockNum)
	fmt.Printf("real_root=%s\n", realRoot.Hex())
	fmt.Printf("corrupted_root=%s (XOR last byte with 0xFF)\n", badRoot.Hex())
	fmt.Printf("bond=%s wei\n", bond.String())

	if !confirmRequested(*confirmFlag, os.Getenv(confirmEnvName)) {
		fmt.Fprintln(os.Stderr, "refusing to broadcast: pass -i-understand-this-posts-a-false-claim=true")
		os.Exit(1)
	}

	calldata, err := proposer.EncodeCreate(gt, badRoot, extra)
	if err != nil {
		fmt.Fprintf(os.Stderr, "encode create: %v\n", err)
		os.Exit(1)
	}

	beforeCount, err := proposer.GameCount(ctx, l1, factoryAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gameCount: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("broadcasting false claim from=%s factory=%s l2=%d\n", from.Hex(), factoryAddr.Hex(), blockNum)
	txHash, err := sendCreate(ctx, l1, *l1RPC, priv, from, factoryAddr, calldata, bond)
	if err != nil {
		fmt.Fprintf(os.Stderr, "send: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("broadcast l1_tx=%s\n", txHash.Hex())

	rcpt, err := waitMinedReceipt(ctx, l1, txHash, *receiptTimeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "receipt: %v\n", err)
		os.Exit(1)
	}
	if rcpt.Status != types.ReceiptStatusSuccessful {
		fmt.Fprintf(os.Stderr, "create tx reverted: tx=%s status=%d\n", txHash.Hex(), rcpt.Status)
		os.Exit(1)
	}
	fmt.Printf("mined status=%d block=%s\n", rcpt.Status, rcpt.BlockNumber.String())

	g, err := findNewGameWithRoot(ctx, l1, factoryAddr, beforeCount, badRoot, blockNum)
	if err != nil {
		fmt.Fprintf(os.Stderr, "self-check: %v (tx=%s)\n", err, txHash.Hex())
		os.Exit(1)
	}
	if g.RootClaim != badRoot {
		fmt.Fprintf(os.Stderr, "self-check failed: on-chain rootClaim=%s want corrupted=%s (index=%d tx=%s)\n",
			g.RootClaim.Hex(), badRoot.Hex(), g.Index, txHash.Hex())
		os.Exit(1)
	}

	fmt.Printf("index=%d\n", g.Index)
	fmt.Printf("proxy=%s\n", g.Proxy.Hex())
	fmt.Printf("tx=%s\n", txHash.Hex())
	fmt.Printf("rootClaim=%s (matches corrupted)\n", g.RootClaim.Hex())
	fmt.Println("done")
}

// corruptRoot returns a claim that is provably not the honest output root:
// XOR the last byte with 0xFF. Deterministic and obviously wrong — not a
// subtle bit-flip that a reviewer could miss.
func corruptRoot(real common.Hash) common.Hash {
	out := real
	out[common.HashLength-1] ^= 0xFF
	return out
}

// signTx is the only signer. Tests fail if this stops refusing Sepolia-on-loopback.
var signTx = proposer.SignLegacyTx

// buildType9FalseClaim corrupts the output root inside the super-root preimage
// and returns keccak(preimage) as the claim. initialize() requires that
// equality, so a flipped hash with an honest preimage would revert BadExtraData.
func buildType9FalseClaim(timestamp, chainID uint64, real common.Hash) (extra []byte, claim, badOutput common.Hash, err error) {
	badOutput = corruptRoot(real)
	if badOutput == real {
		return nil, common.Hash{}, common.Hash{}, errors.New("internal error: corruptRoot did not change the output root")
	}
	sr, err := proposer.EncodeSuperRoot(timestamp, []proposer.ChainOutput{{
		ChainID:    chainID,
		OutputRoot: badOutput,
	}})
	if err != nil {
		return nil, common.Hash{}, common.Hash{}, err
	}
	if sr.Hash == real {
		return nil, common.Hash{}, common.Hash{}, errors.New("internal error: super root hash collided with the honest output root")
	}
	if crypto.Keccak256Hash(sr.Preimage) != sr.Hash {
		return nil, common.Hash{}, common.Hash{}, errors.New("internal error: super root hash is not keccak(preimage)")
	}
	return append([]byte(nil), sr.Preimage...), sr.Hash, badOutput, nil
}

func runSuperRootBadProposal(ctx context.Context, l1 *ethclient.Client, l1RPC, rollupRPC string, priv *ecdsa.PrivateKey, from, factory common.Address, gt uint32, blockNum uint64, realRoot common.Hash, confirmFlag bool, receiptTimeout time.Duration) error {
	clock, err := proposer.FetchRollupClock(ctx, rollupRPC)
	if err != nil {
		return fmt.Errorf("rollup clock: %w", err)
	}
	ts, err := proposer.TimestampForL2Block(clock.GenesisTime, clock.BlockTime, blockNum)
	if err != nil {
		return err
	}
	impl, err := proposer.GameImpl(ctx, l1, factory, gt)
	if err != nil {
		return fmt.Errorf("gameImpls(%d): %w", gt, err)
	}
	if impl == (common.Address{}) {
		return fmt.Errorf("refusing game type %d: DisputeGameFactory.gameImpls(%d) is zero", gt, gt)
	}
	extra, claim, badOutput, err := buildType9FalseClaim(ts, clock.L2ChainID, realRoot)
	if err != nil {
		return err
	}
	bond, err := proposer.InitBond(ctx, l1, factory, gt)
	if err != nil {
		return fmt.Errorf("initBonds: %w", err)
	}

	fmt.Printf("from=%s (proposer role — not challenger)\n", from.Hex())
	fmt.Printf("factory=%s\n", factory.Hex())
	fmt.Printf("gameType=%d\n", gt)
	fmt.Printf("block=%d\n", blockNum)
	fmt.Printf("timestamp=%d\n", ts)
	fmt.Printf("chainId=%d\n", clock.L2ChainID)
	fmt.Printf("real_output_root=%s\n", realRoot.Hex())
	fmt.Printf("corrupted_output_root=%s (XOR last byte with 0xFF)\n", badOutput.Hex())
	fmt.Printf("superRoot=%s\n", claim.Hex())
	fmt.Printf("bond=%s wei\n", bond.String())

	if !confirmRequested(confirmFlag, os.Getenv(confirmEnvName)) {
		return errors.New("refusing to broadcast: pass -i-understand-this-posts-a-false-claim=true")
	}

	calldata, err := proposer.EncodeCreate(gt, claim, extra)
	if err != nil {
		return fmt.Errorf("encode create: %w", err)
	}
	beforeCount, err := proposer.GameCount(ctx, l1, factory)
	if err != nil {
		return fmt.Errorf("gameCount: %w", err)
	}
	fmt.Printf("broadcasting false claim from=%s factory=%s timestamp=%d\n", from.Hex(), factory.Hex(), ts)
	txHash, err := sendCreate(ctx, l1, l1RPC, priv, from, factory, calldata, bond)
	if err != nil {
		return fmt.Errorf("send: %w", err)
	}
	fmt.Printf("broadcast l1_tx=%s\n", txHash.Hex())
	rcpt, err := waitMinedReceipt(ctx, l1, txHash, receiptTimeout)
	if err != nil {
		return fmt.Errorf("receipt: %w", err)
	}
	if rcpt.Status != types.ReceiptStatusSuccessful {
		return fmt.Errorf("create tx reverted: tx=%s status=%d", txHash.Hex(), rcpt.Status)
	}
	fmt.Printf("mined status=%d block=%s\n", rcpt.Status, rcpt.BlockNumber.String())

	g, err := findNewGameWithRoot(ctx, l1, factory, beforeCount, claim, ts)
	if err != nil {
		return fmt.Errorf("self-check: %w (tx=%s)", err, txHash.Hex())
	}
	if g.RootClaim != claim {
		return fmt.Errorf("self-check failed: on-chain rootClaim=%s want %s", g.RootClaim.Hex(), claim.Hex())
	}
	if crypto.Keccak256Hash(g.ExtraData) != g.RootClaim {
		return fmt.Errorf("self-check failed: keccak(extraData) != rootClaim (tx=%s)", txHash.Hex())
	}
	byChain, err := proposer.RootClaimByChainID(ctx, l1, g.Proxy, clock.L2ChainID)
	if err != nil {
		return fmt.Errorf("rootClaimByChainId(%d): %w", clock.L2ChainID, err)
	}
	if byChain == realRoot {
		return fmt.Errorf("self-check failed: rootClaimByChainId(%d)=%s equals the real output root", clock.L2ChainID, byChain.Hex())
	}
	if byChain != badOutput {
		return fmt.Errorf("self-check failed: rootClaimByChainId(%d)=%s want corrupted output %s", clock.L2ChainID, byChain.Hex(), badOutput.Hex())
	}

	fmt.Printf("index=%d\n", g.Index)
	fmt.Printf("proxy=%s\n", g.Proxy.Hex())
	fmt.Printf("tx=%s\n", txHash.Hex())
	fmt.Printf("rootClaim=%s\n", g.RootClaim.Hex())
	fmt.Printf("rootClaimByChainId(%d)=%s (differs from real output root)\n", clock.L2ChainID, byChain.Hex())
	fmt.Printf("keccak(extraData)==rootClaim\n")
	fmt.Println("done")
	return nil
}

// confirmRequested is the broadcast gate. The flag or the exact env value
// "true" (trimmed) is required; "1" / "yes" do not count.
func confirmRequested(flagVal bool, env string) bool {
	if flagVal {
		return true
	}
	return strings.TrimSpace(env) == "true"
}

// sendCreate is copy-adapted from propose-loop (proven on Sepolia, D-0036):
// PendingNonceAt, SuggestGasPrice, EstimateGas + 20% headroom, legacy
// types.NewTransaction, SignTx with LatestSignerForChainID. Not factored
// into proposer/rpc.go — that file and propose-loop are reuse-only for US-074.
func sendCreate(ctx context.Context, l1 *ethclient.Client, l1RPC string, priv *ecdsa.PrivateKey, from, factory common.Address, data []byte, value *big.Int) (common.Hash, error) {
	chainID, err := l1.ChainID(ctx)
	if err != nil {
		return common.Hash{}, err
	}
	nonce, err := l1.PendingNonceAt(ctx, from)
	if err != nil {
		return common.Hash{}, err
	}
	gasPrice, err := l1.SuggestGasPrice(ctx)
	if err != nil {
		return common.Hash{}, err
	}
	msg := ethereum.CallMsg{From: from, To: &factory, Value: value, Data: data}
	gas, err := l1.EstimateGas(ctx, msg)
	if err != nil {
		return common.Hash{}, fmt.Errorf("estimate gas: %w", err)
	}
	gas = gas + gas/5 // headroom
	tx := types.NewTransaction(nonce, factory, value, gas, gasPrice, data)
	signed, err := signTx(l1RPC, chainID, tx, priv)
	if err != nil {
		return common.Hash{}, err
	}
	if err := l1.SendTransaction(ctx, signed); err != nil {
		return common.Hash{}, err
	}
	return signed.Hash(), nil
}

func waitMinedReceipt(ctx context.Context, client *ethclient.Client, hash common.Hash, timeout time.Duration) (*types.Receipt, error) {
	if timeout <= 0 {
		timeout = 3 * time.Minute
	}
	deadline := time.Now().Add(timeout)
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		rcpt, err := client.TransactionReceipt(ctx, hash)
		if err == nil && rcpt != nil {
			return rcpt, nil
		}
		if time.Now().After(deadline) {
			if err != nil && !errors.Is(err, ethereum.NotFound) {
				return nil, fmt.Errorf("timeout waiting for receipt %s: %w", hash.Hex(), err)
			}
			return nil, fmt.Errorf("timeout waiting for receipt %s", hash.Hex())
		}
		timer := time.NewTimer(2 * time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

// findNewGameWithRoot inspects games created after beforeCount and returns the
// one whose rootClaim matches want and whose L2 sequence matches blockNum.
func findNewGameWithRoot(ctx context.Context, client *ethclient.Client, factory common.Address, beforeCount *big.Int, want common.Hash, blockNum uint64) (proposer.InspectedGame, error) {
	afterCount, err := proposer.GameCount(ctx, client, factory)
	if err != nil {
		return proposer.InspectedGame{}, err
	}
	if afterCount.Cmp(beforeCount) <= 0 {
		return proposer.InspectedGame{}, fmt.Errorf("gameCount did not increase (before=%s after=%s)", beforeCount.String(), afterCount.String())
	}
	low := beforeCount.Uint64()
	high := afterCount.Uint64()
	var last proposer.InspectedGame
	for i := high; i > low; i-- {
		idx := i - 1
		meta, err := proposer.GameAtIndex(ctx, client, factory, new(big.Int).SetUint64(idx))
		if err != nil {
			return proposer.InspectedGame{}, fmt.Errorf("gameAtIndex(%d): %w", idx, err)
		}
		if meta.Proxy == (common.Address{}) {
			continue
		}
		g, err := proposer.InspectGame(ctx, client, factory, idx)
		if err != nil {
			return proposer.InspectedGame{}, fmt.Errorf("inspect index %d: %w", idx, err)
		}
		last = g
		if g.RootClaim == want && g.L2Sequence == blockNum {
			return g, nil
		}
	}
	return proposer.InspectedGame{}, fmt.Errorf("no new game with corrupted root %s at l2=%d (last index=%d root=%s)",
		want.Hex(), blockNum, last.Index, last.RootClaim.Hex())
}

func parseKey(hexKey string) (*ecdsa.PrivateKey, error) {
	hexKey = strings.TrimPrefix(strings.TrimSpace(hexKey), "0x")
	if hexKey == "" {
		return nil, errors.New("empty key")
	}
	return crypto.HexToECDSA(hexKey)
}

func resolveFactory(flagVal, deploymentsPath string) (common.Address, error) {
	if flagVal != "" {
		return proposer.HexOrAddress(flagVal)
	}
	if env := strings.TrimSpace(os.Getenv("DISPUTE_GAME_FACTORY")); env != "" {
		return proposer.HexOrAddress(env)
	}
	if deploymentsPath == "" {
		if root := os.Getenv("FORTEL2_ROOT"); root != "" {
			deploymentsPath = root + "/deployments/deployments.json"
		}
	}
	if deploymentsPath == "" {
		return common.Address{}, fmt.Errorf("need -factory, -deployments, or DISPUTE_GAME_FACTORY")
	}
	raw, err := os.ReadFile(deploymentsPath)
	if err != nil {
		return common.Address{}, err
	}
	return factoryFromJSON(raw, deploymentsPath)
}

func factoryFromJSON(raw []byte, path string) (common.Address, error) {
	var m map[string]string
	if err := json.Unmarshal(raw, &m); err != nil {
		var any map[string]interface{}
		if err2 := json.Unmarshal(raw, &any); err2 != nil {
			return common.Address{}, err
		}
		for _, key := range []string{"DisputeGameFactoryProxy", "disputeGameFactoryProxy"} {
			if v, ok := any[key].(string); ok && v != "" {
				return proposer.HexOrAddress(v)
			}
		}
		return common.Address{}, fmt.Errorf("DisputeGameFactoryProxy missing in %s", path)
	}
	for _, key := range []string{"DisputeGameFactoryProxy", "disputeGameFactoryProxy"} {
		if v := m[key]; v != "" {
			return proposer.HexOrAddress(v)
		}
	}
	return common.Address{}, fmt.Errorf("DisputeGameFactoryProxy missing in %s", path)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// resolveGameType requires an explicit -game-type or PROPOSER_GAME_TYPE.
// There is no silent default: a missing or unparseable value refuses, because
// posting a non-respected type is inert and unchallenged (D-0063 Finding 3c).
func resolveGameType(flagVal, env string) (uint32, error) {
	raw := strings.TrimSpace(flagVal)
	if raw == "" {
		raw = strings.TrimSpace(env)
	}
	if raw == "" {
		return 0, errors.New("game-type required: set -game-type or PROPOSER_GAME_TYPE (refusing a silent default)")
	}
	n, err := strconv.ParseUint(raw, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("game-type %q: %w", raw, err)
	}
	return uint32(n), nil
}
