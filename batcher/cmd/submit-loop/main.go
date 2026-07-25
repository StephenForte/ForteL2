// Command submit-loop posts singular-batch channels to the local L1 Batch Inbox (US-042).
//
//	go run ./cmd/submit-loop \
//	  -l1 "$L1_RPC_URL" -l2 "$L2_RPC_URL" -rollup "$L2_NODE_RPC_URL" \
//	  -rollup-json "$DEPLOY_DIR/rollup.json" \
//	  -once
//
// Never commit private keys. Prefer env BATCHER_PRIVATE_KEY over -private-key.
package main

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/StephenForte/ForteL2/batcher"
	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

func main() {
	l1RPC := flag.String("l1", envOr("L1_RPC_URL", ""), "L1 HTTP RPC")
	l2RPC := flag.String("l2", envOr("L2_RPC_URL", ""), "L2 EL HTTP RPC")
	rollupRPC := flag.String("rollup", envOr("L2_NODE_RPC_URL", ""), "op-node HTTP RPC (optimism_syncStatus)")
	rollupJSON := flag.String("rollup-json", "", "path to rollup.json (batch_inbox_address)")
	inboxFlag := flag.String("inbox", "", "Batch Inbox override (else rollup.json)")
	keyFlag := flag.String("private-key", "", "batcher EOA key (prefer BATCHER_PRIVATE_KEY env)")
	poll := flag.Duration("poll", 2*time.Second, "sync poll interval")
	maxBlocks := flag.Int("max-blocks", 6, "max L2 blocks per channel")
	once := flag.Bool("once", false, "submit one channel (if work) then exit")
	waitSafe := flag.Duration("wait-safe", 60*time.Second, "after submit, wait this long for safe head to advance (0=skip)")
	flag.Parse()

	keyHex := strings.TrimSpace(*keyFlag)
	if keyHex == "" {
		keyHex = strings.TrimSpace(os.Getenv("BATCHER_PRIVATE_KEY"))
	}
	if *l1RPC == "" || *l2RPC == "" || *rollupRPC == "" || keyHex == "" {
		fmt.Fprintln(os.Stderr, "usage: submit-loop -l1 … -l2 … -rollup … -rollup-json … [-once]")
		fmt.Fprintln(os.Stderr, "requires BATCHER_PRIVATE_KEY or -private-key")
		os.Exit(2)
	}

	inbox, err := resolveInbox(*inboxFlag, *rollupJSON)
	if err != nil {
		fmt.Fprintf(os.Stderr, "inbox: %v\n", err)
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
		fmt.Fprintf(os.Stderr, "l1 dial: %v\n", err)
		os.Exit(1)
	}
	defer l1.Close()

	fmt.Printf("custom batcher starting from=%s inbox=%s max_blocks=%d once=%v\n",
		from.Hex(), inbox.Hex(), *maxBlocks, *once)
	fmt.Println("duplicate safeguard: track lastSubmitted; never re-submit <= that L2 number; on restart begin at safe+1")

	var lastSubmitted uint64
	var initialized bool

	for {
		if err := ctx.Err(); err != nil {
			fmt.Println("stopped")
			return
		}
		safeN, unsafeN, err := syncHeads(ctx, *rollupRPC)
		if err != nil {
			fmt.Fprintf(os.Stderr, "syncStatus: %v\n", err)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		if !initialized {
			lastSubmitted = safeN
			initialized = true
			fmt.Printf("init lastSubmitted=%d (safe) unsafe=%d\n", lastSubmitted, unsafeN)
		}
		if unsafeN <= lastSubmitted {
			if *once {
				fmt.Printf("nothing to submit (safe=%d unsafe=%d last=%d)\n", safeN, unsafeN, lastSubmitted)
				return
			}
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}

		fromBlock := lastSubmitted + 1
		toBlock := unsafeN
		if int(toBlock-fromBlock)+1 > *maxBlocks {
			toBlock = fromBlock + uint64(*maxBlocks) - 1
		}

		batches, err := loadSingularBatches(ctx, *l2RPC, fromBlock, toBlock)
		if err != nil {
			fmt.Fprintf(os.Stderr, "load blocks %d..%d: %v\n", fromBlock, toBlock, err)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		payload, frames, err := batcher.BuildBatcherTxFromSingularBatches(batches, batcher.ChannelOptions{})
		if err != nil {
			fmt.Fprintf(os.Stderr, "build channel: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("submitting L2 %d..%d batches=%d frames=%d payload=%d bytes\n",
			fromBlock, toBlock, len(batches), len(frames), len(payload))

		txHash, err := sendBatcherTx(ctx, l1, priv, from, inbox, payload)
		if err != nil {
			fmt.Fprintf(os.Stderr, "send: %v\n", err)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		fmt.Printf("l1_tx=%s\n", txHash.Hex())
		if err := waitReceipt(ctx, l1, txHash, 30*time.Second); err != nil {
			fmt.Fprintf(os.Stderr, "receipt: %v\n", err)
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		lastSubmitted = toBlock
		fmt.Printf("submitted ok lastSubmitted=%d\n", lastSubmitted)

		if *waitSafe > 0 {
			deadline := time.Now().Add(*waitSafe)
			advanced := false
			for time.Now().Before(deadline) {
				s, _, err := syncHeads(ctx, *rollupRPC)
				if err == nil && s >= toBlock {
					fmt.Printf("safe head advanced to %d\n", s)
					advanced = true
					break
				}
				if sleepCtx(ctx, *poll) != nil {
					return
				}
			}
			if !advanced {
				s, u, _ := syncHeads(ctx, *rollupRPC)
				fmt.Printf("safe head not yet at target after wait: safe=%d unsafe=%d target=%d\n", s, u, toBlock)
			}
		}

		if *once {
			return
		}
	}
}

func envOr(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func parseKey(hexKey string) (*ecdsa.PrivateKey, error) {
	hexKey = strings.TrimPrefix(hexKey, "0x")
	return crypto.HexToECDSA(hexKey)
}

func resolveInbox(flagVal, rollupPath string) (common.Address, error) {
	if flagVal != "" {
		if !common.IsHexAddress(flagVal) {
			return common.Address{}, fmt.Errorf("invalid inbox %s", flagVal)
		}
		return common.HexToAddress(flagVal), nil
	}
	if rollupPath == "" {
		return common.Address{}, fmt.Errorf("need -inbox or -rollup-json")
	}
	raw, err := os.ReadFile(rollupPath)
	if err != nil {
		return common.Address{}, err
	}
	var cfg struct {
		BatchInboxAddress string `json:"batch_inbox_address"`
		BatchInbox        string `json:"batch_inbox"`
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return common.Address{}, err
	}
	addr := cfg.BatchInboxAddress
	if addr == "" {
		addr = cfg.BatchInbox
	}
	if !common.IsHexAddress(addr) {
		return common.Address{}, fmt.Errorf("no batch_inbox_address in %s", rollupPath)
	}
	return common.HexToAddress(addr), nil
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

func sendBatcherTx(ctx context.Context, l1 *ethclient.Client, key *ecdsa.PrivateKey, from, to common.Address, data []byte) (common.Hash, error) {
	chainID, err := l1.ChainID(ctx)
	if err != nil {
		return common.Hash{}, err
	}
	nonce, err := l1.PendingNonceAt(ctx, from)
	if err != nil {
		return common.Hash{}, err
	}
	tip, err := l1.SuggestGasTipCap(ctx)
	if err != nil || tip == nil {
		tip = big.NewInt(1_000_000_000)
	}
	header, err := l1.HeaderByNumber(ctx, nil)
	if err != nil {
		return common.Hash{}, err
	}
	base := header.BaseFee
	if base == nil {
		base = big.NewInt(0)
	}
	feeCap := new(big.Int).Add(new(big.Int).Mul(base, big.NewInt(2)), tip)
	msg := ethereum.CallMsg{From: from, To: &to, Data: data}
	gas, err := l1.EstimateGas(ctx, msg)
	if err != nil {
		gas = 500_000
	}
	tx := types.NewTx(&types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     nonce,
		GasTipCap: tip,
		GasFeeCap: feeCap,
		Gas:       gas,
		To:        &to,
		Value:     big.NewInt(0),
		Data:      data,
	})
	signer := types.LatestSignerForChainID(chainID)
	signed, err := types.SignTx(tx, signer, key)
	if err != nil {
		return common.Hash{}, err
	}
	if err := l1.SendTransaction(ctx, signed); err != nil {
		return common.Hash{}, err
	}
	return signed.Hash(), nil
}

func waitReceipt(ctx context.Context, l1 *ethclient.Client, hash common.Hash, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		rcpt, err := l1.TransactionReceipt(ctx, hash)
		if err == nil && rcpt != nil {
			if rcpt.Status != types.ReceiptStatusSuccessful {
				return fmt.Errorf("tx failed status=%d", rcpt.Status)
			}
			return nil
		}
		if sleepCtx(ctx, 500*time.Millisecond) != nil {
			return ctx.Err()
		}
	}
	return fmt.Errorf("timeout waiting for %s", hash.Hex())
}
