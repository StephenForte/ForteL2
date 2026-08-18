// Command bad-proposal creates one DisputeGameFactory game with a deliberately
// corrupted output root, waits for the create tx to mine, self-checks the
// on-chain rootClaim, then exits (US-074).
//
//	go run ./cmd/bad-proposal \
//	  -l1 "$L1_RPC_URL" -rollup "$L2_NODE_RPC_URL" \
//	  -factory 0x... -game-type 1 \
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
	gameType := flag.Uint("game-type", envOrUint("PROPOSER_GAME_TYPE", 1), "dispute game type")
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
	gt := uint32(*gameType)

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
	txHash, err := sendCreate(ctx, l1, priv, from, factoryAddr, calldata, bond)
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
func sendCreate(ctx context.Context, l1 *ethclient.Client, priv *ecdsa.PrivateKey, from, factory common.Address, data []byte, value *big.Int) (common.Hash, error) {
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
	chainID, err := l1.ChainID(ctx)
	if err != nil {
		return common.Hash{}, err
	}
	tx := types.NewTransaction(nonce, factory, value, gas, gasPrice, data)
	signed, err := types.SignTx(tx, types.LatestSignerForChainID(chainID), priv)
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

func envOrUint(key string, def uint) uint {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.ParseUint(v, 10, 32)
	if err != nil {
		return def
	}
	return uint(n)
}
