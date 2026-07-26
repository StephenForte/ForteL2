// Command propose-loop creates DisputeGameFactory games from rollup output roots (US-052).
//
//	go run ./cmd/propose-loop \
//	  -l1 "$L1_RPC_URL" -rollup "$L2_NODE_RPC_URL" \
//	  -factory 0x... -game-type 1 \
//	  -once
//
// Never commit private keys. Prefer env PROPOSER_PRIVATE_KEY over -private-key.
package main

import (
	"context"
	"crypto/ecdsa"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"os/signal"
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

func main() {
	l1RPC := flag.String("l1", envOr("L1_RPC_URL", ""), "L1 HTTP RPC")
	rollupRPC := flag.String("rollup", envOr("L2_NODE_RPC_URL", ""), "op-node HTTP RPC")
	factoryFlag := flag.String("factory", "", "DisputeGameFactoryProxy")
	deployments := flag.String("deployments", "", "optional deployments.json")
	keyFlag := flag.String("private-key", "", "proposer EOA key (prefer PROPOSER_PRIVATE_KEY env)")
	gameType := flag.Uint("game-type", envOrUint("PROPOSER_GAME_TYPE", 1), "dispute game type")
	poll := flag.Duration("poll", 2*time.Second, "sync poll interval")
	interval := flag.Duration("proposal-interval", envOrDuration("PROPOSER_INTERVAL", 12*time.Second), "min time between proposals")
	allowNonFinalized := flag.Bool("allow-non-finalized", true, "propose against safe head (Anvil never finalizes like mainnet)")
	once := flag.Bool("once", false, "create one game (if work) then exit")
	confirmations := flag.Uint64("confirmations", 1, "L1 confirmations before counting success")
	receiptTimeout := flag.Duration("receipt-timeout", 90*time.Second, "wait for receipt+confirmations")
	flag.Parse()

	keyHex := strings.TrimSpace(*keyFlag)
	if keyHex == "" {
		keyHex = strings.TrimSpace(os.Getenv("PROPOSER_PRIVATE_KEY"))
	}
	if *l1RPC == "" || *rollupRPC == "" || keyHex == "" {
		fmt.Fprintln(os.Stderr, "usage: propose-loop -l1 … -rollup … -factory … [-once]")
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
		fmt.Fprintf(os.Stderr, "l1 dial: %v\n", err)
		os.Exit(1)
	}
	defer l1.Close()

	fmt.Printf("custom proposer starting from=%s factory=%s gameType=%d interval=%s allowNonFinalized=%v once=%v\n",
		from.Hex(), factoryAddr.Hex(), gt, *interval, *allowNonFinalized, *once)
	fmt.Println("duplicate safeguard: track lastProposedL2 + lastProposalTime; init from latest factory game of this type")
	fmt.Println("output root: fetched via optimism_outputAtBlock (not recomputed locally)")

	var (
		lastProposedL2   uint64
		lastProposalTime time.Time
		initialized      bool
		pendingHash      common.Hash
		havePending      bool
	)

	for {
		if err := ctx.Err(); err != nil {
			fmt.Println("stopped")
			return
		}

		if havePending {
			fmt.Printf("awaiting pending l1_tx=%s\n", pendingHash.Hex())
			if err := waitReceiptConfirmed(ctx, l1, pendingHash, *confirmations, *receiptTimeout); err != nil {
				fmt.Fprintf(os.Stderr, "receipt wait: %v\n", err)
				if sleepCtx(ctx, *poll) != nil {
					return
				}
				continue
			}
			havePending = false
			pendingHash = common.Hash{}
			fmt.Printf("proposed ok lastProposedL2=%d\n", lastProposedL2)
			if *once {
				return
			}
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}

		if !initialized {
			if g, ok, err := proposer.LatestGameOfType(ctx, l1, factoryAddr, gt); err != nil {
				fmt.Fprintf(os.Stderr, "init from factory: %v\n", err)
			} else if ok {
				lastProposedL2 = g.L2Sequence
				lastProposalTime = time.Unix(int64(g.CreatedAt), 0)
				fmt.Printf("initialized from factory index=%d l2=%d createdAt=%s root=%s\n",
					g.Index, g.L2Sequence, lastProposalTime.UTC().Format(time.RFC3339), g.RootClaim.Hex())
			} else {
				fmt.Println("initialized: no prior games of this type")
			}
			initialized = true
		}

		if !lastProposalTime.IsZero() && time.Since(lastProposalTime) < *interval {
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}

		heads, err := proposer.FetchSyncHeads(ctx, *rollupRPC)
		if err != nil {
			fmt.Fprintf(os.Stderr, "syncStatus: %v\n", err)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		blockNum := heads.FinalizedL2
		if *allowNonFinalized {
			blockNum = heads.SafeL2
		}
		if blockNum == 0 {
			fmt.Println("skip genesis / empty safe head")
			if *once {
				return
			}
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		if blockNum <= lastProposedL2 {
			fmt.Printf("no new safe head (safe=%d lastProposed=%d)\n", blockNum, lastProposedL2)
			if *once {
				return
			}
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}

		out, err := proposer.FetchOutputAtBlock(ctx, *rollupRPC, blockNum)
		if err != nil {
			fmt.Fprintf(os.Stderr, "outputAtBlock(%d): %v\n", blockNum, err)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		if out.BlockNumber != blockNum {
			fmt.Fprintf(os.Stderr, "output block mismatch: got %d want %d\n", out.BlockNumber, blockNum)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}

		extra := proposer.PackExtraData(blockNum)
		bond, err := proposer.InitBond(ctx, l1, factoryAddr, gt)
		if err != nil {
			fmt.Fprintf(os.Stderr, "initBonds: %v\n", err)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		calldata, err := proposer.EncodeCreate(gt, out.OutputRoot, extra)
		if err != nil {
			fmt.Fprintf(os.Stderr, "encode create: %v\n", err)
			os.Exit(1)
		}

		fmt.Printf("proposing l2=%d root=%s bond=%s wei\n", blockNum, out.OutputRoot.Hex(), bond.String())
		txHash, err := sendCreate(ctx, l1, priv, from, factoryAddr, calldata, bond)
		if err != nil {
			fmt.Fprintf(os.Stderr, "send: %v\n", err)
			if *once {
				// Permanent estimate/revert failures should not spin forever in -once mode.
				os.Exit(1)
			}
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		fmt.Printf("broadcast l1_tx=%s\n", txHash.Hex())
		lastProposedL2 = blockNum
		lastProposalTime = time.Now()
		pendingHash = txHash
		havePending = true
	}
}

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

func waitReceiptConfirmed(ctx context.Context, l1 *ethclient.Client, hash common.Hash, confirmations uint64, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timeout waiting for %s", hash.Hex())
		}
		receipt, err := l1.TransactionReceipt(ctx, hash)
		if err != nil {
			if sleepCtx(ctx, time.Second) != nil {
				return ctx.Err()
			}
			continue
		}
		if receipt.Status != types.ReceiptStatusSuccessful {
			return fmt.Errorf("tx %s reverted", hash.Hex())
		}
		head, err := l1.BlockNumber(ctx)
		if err != nil {
			return err
		}
		if head >= receipt.BlockNumber.Uint64()+confirmations-1 {
			return nil
		}
		if sleepCtx(ctx, time.Second) != nil {
			return ctx.Err()
		}
	}
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
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
	// Reuse inspect-game style parse via a tiny local unmarshal.
	return factoryFromJSON(raw, deploymentsPath)
}

func factoryFromJSON(raw []byte, path string) (common.Address, error) {
	var any map[string]interface{}
	if err := jsonUnmarshal(raw, &any); err != nil {
		return common.Address{}, err
	}
	for _, key := range []string{"DisputeGameFactoryProxy", "disputeGameFactoryProxy"} {
		if v, ok := any[key].(string); ok && v != "" {
			return proposer.HexOrAddress(v)
		}
	}
	return common.Address{}, fmt.Errorf("DisputeGameFactoryProxy missing in %s", path)
}
