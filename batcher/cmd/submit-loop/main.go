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
	"errors"
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
	confirmations := flag.Uint64("confirmations", 1, "L1 confirmations required before advancing lastSubmitted (matches stock num-confirmations)")
	receiptTimeoutFlag := flag.Duration("receipt-timeout", 0, "per-wait timeout for receipt+confirmations (0=auto: 90s, or 10m when confirmations>1)")
	flag.Parse()
	if *confirmations == 0 {
		*confirmations = 1
	}
	receiptTimeout := *receiptTimeoutFlag
	if receiptTimeout <= 0 {
		receiptTimeout = 90 * time.Second
		if *confirmations > 1 {
			// Sepolia inclusion + confirmations often exceed Anvil waits.
			receiptTimeout = 10 * time.Minute
		}
	}

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

	fmt.Printf("custom batcher starting from=%s inbox=%s max_blocks=%d confirmations=%d receipt_timeout=%s once=%v\n",
		from.Hex(), inbox.Hex(), *maxBlocks, *confirmations, receiptTimeout, *once)
	fmt.Println("duplicate safeguard: track lastSubmitted; never re-submit <= that L2 number; on restart begin at safe+1")
	fmt.Println("pending safeguard: after broadcast, keep waiting the same L1 tx — never resubmit while it is pending or mined")

	var lastSubmitted uint64
	var initialized bool
	// After SendTransaction succeeds, track the in-flight L1 tx until confirmations.
	// Soft receipt timeouts / temporary reorg receipt loss must NOT rebuild the same
	// L2 range under a new nonce (duplicate calldata on Sepolia).
	var pendingHash common.Hash
	var pendingTo uint64
	var havePending bool

	for {
		if err := ctx.Err(); err != nil {
			fmt.Println("stopped")
			return
		}

		// Resume waiting on an in-flight submission before considering new work.
		if havePending {
			fmt.Printf("awaiting pending l1_tx=%s (L2 ..%d)\n", pendingHash.Hex(), pendingTo)
			if err := waitReceiptConfirmed(ctx, l1, pendingHash, *confirmations, receiptTimeout); err != nil {
				clear, reason := shouldClearPending(ctx, l1, pendingHash, err)
				if clear {
					fmt.Fprintf(os.Stderr, "pending tx cleared (%s): %v — will rebuild range\n", reason, err)
					havePending = false
					pendingHash = common.Hash{}
					pendingTo = 0
				} else {
					fmt.Fprintf(os.Stderr, "receipt/confirmations still pending (%s): %v — not resubmitting\n", reason, err)
				}
				if sleepCtx(ctx, *poll) != nil {
					return
				}
				continue
			}
			lastSubmitted = pendingTo
			havePending = false
			pendingHash = common.Hash{}
			pendingTo = 0
			fmt.Printf("submitted ok lastSubmitted=%d confirmations=%d\n", lastSubmitted, *confirmations)
			if *waitSafe > 0 {
				if err := waitSafeHead(ctx, *rollupRPC, lastSubmitted, *waitSafe, *poll); err != nil {
					return
				}
			}
			if *once {
				return
			}
			continue
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
		// Record pending before waiting so a timeout cannot cause a duplicate submit.
		pendingHash = txHash
		pendingTo = toBlock
		havePending = true
		// Do not advance lastSubmitted until the receipt is deep enough — a single
		// inclusion can reorg away on Sepolia; stock op-batcher uses num-confirmations.
		if err := waitReceiptConfirmed(ctx, l1, txHash, *confirmations, receiptTimeout); err != nil {
			clear, reason := shouldClearPending(ctx, l1, pendingHash, err)
			if clear {
				fmt.Fprintf(os.Stderr, "tx cleared (%s): %v — clearing pending; will rebuild range\n", reason, err)
				havePending = false
				pendingHash = common.Hash{}
				pendingTo = 0
			} else {
				fmt.Fprintf(os.Stderr, "receipt/confirmations: %v (%s) — keeping pending tx, not resubmitting\n", err, reason)
			}
			if sleepCtx(ctx, *poll) != nil {
				return
			}
			continue
		}
		lastSubmitted = toBlock
		havePending = false
		pendingHash = common.Hash{}
		pendingTo = 0
		fmt.Printf("submitted ok lastSubmitted=%d confirmations=%d\n", lastSubmitted, *confirmations)

		if *waitSafe > 0 {
			if err := waitSafeHead(ctx, *rollupRPC, toBlock, *waitSafe, *poll); err != nil {
				return
			}
		}

		if *once {
			return
		}
	}
}

// isHardTxFailure is true when the L1 tx reverted on-chain. Soft timeouts and
// temporary reorg receipt loss keep pending so we do not burn a new nonce.
func isHardTxFailure(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "tx failed status=")
}

// l1TxTracker is the receipt/tx lookup surface used while deciding whether a
// soft wait failure may clear pending state (dropped) or must keep waiting.
type l1TxTracker interface {
	TransactionReceipt(ctx context.Context, txHash common.Hash) (*types.Receipt, error)
	TransactionByHash(ctx context.Context, hash common.Hash) (*types.Transaction, bool, error)
}

// shouldClearPending decides whether to abandon an in-flight L1 hash after a
// wait error. Only a reverted receipt or a fully dropped/unknown tx clears
// pending; timeouts and reorg receipt flicker keep waiting the same hash.
func shouldClearPending(ctx context.Context, l1 l1TxTracker, hash common.Hash, waitErr error) (clear bool, reason string) {
	if isHardTxFailure(waitErr) {
		return true, "reverted"
	}
	known, pending, err := txStillTracked(ctx, l1, hash)
	if err != nil {
		// RPC blip: keep pending rather than risk a duplicate submit.
		return false, "rpc-error-keep-pending"
	}
	if known {
		if pending {
			return false, "still-pending"
		}
		return false, "still-known"
	}
	return true, "dropped-or-unknown"
}

// txStillTracked reports whether the L1 node still knows about hash (mempool
// pending and/or a receipt). Unknown means safe to rebuild the L2 range.
func txStillTracked(ctx context.Context, l1 l1TxTracker, hash common.Hash) (known bool, pending bool, err error) {
	tx, isPending, err := l1.TransactionByHash(ctx, hash)
	if err == nil && tx != nil {
		return true, isPending, nil
	}
	if err != nil && !errors.Is(err, ethereum.NotFound) {
		return false, false, err
	}
	rcpt, rerr := l1.TransactionReceipt(ctx, hash)
	if rerr == nil && rcpt != nil {
		return true, false, nil
	}
	if rerr != nil && !errors.Is(rerr, ethereum.NotFound) {
		return false, false, rerr
	}
	return false, false, nil
}

func waitSafeHead(ctx context.Context, rollupRPC string, target uint64, wait, poll time.Duration) error {
	deadline := time.Now().Add(wait)
	advanced := false
	for time.Now().Before(deadline) {
		s, _, err := syncHeads(ctx, rollupRPC)
		if err == nil && s >= target {
			fmt.Printf("safe head advanced to %d\n", s)
			advanced = true
			break
		}
		if sleepCtx(ctx, poll) != nil {
			return ctx.Err()
		}
	}
	if !advanced {
		s, u, _ := syncHeads(ctx, rollupRPC)
		fmt.Printf("safe head not yet at target after wait: safe=%d unsafe=%d target=%d\n", s, u, target)
	}
	return nil
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

// receiptConfirmed reports whether an L1 head gives `confirmations` depth to a
// receipt mined at receiptBlock (confirmations=1 ⇒ receipt alone is enough).
func receiptConfirmed(head, receiptBlock, confirmations uint64) bool {
	if confirmations == 0 {
		confirmations = 1
	}
	return head+1 >= receiptBlock+confirmations
}

func waitReceiptConfirmed(ctx context.Context, l1 *ethclient.Client, hash common.Hash, confirmations uint64, timeout time.Duration) error {
	if confirmations == 0 {
		confirmations = 1
	}
	deadline := time.Now().Add(timeout)
	var receiptBlock uint64
	haveReceipt := false
	for time.Now().Before(deadline) {
		rcpt, err := l1.TransactionReceipt(ctx, hash)
		if err != nil || rcpt == nil {
			if haveReceipt {
				return fmt.Errorf("receipt for %s disappeared after reorg", hash.Hex())
			}
			if sleepCtx(ctx, 500*time.Millisecond) != nil {
				return ctx.Err()
			}
			continue
		}
		if rcpt.Status != types.ReceiptStatusSuccessful {
			return fmt.Errorf("tx failed status=%d", rcpt.Status)
		}
		receiptBlock = rcpt.BlockNumber.Uint64()
		haveReceipt = true
		head, err := l1.HeaderByNumber(ctx, nil)
		if err != nil {
			if sleepCtx(ctx, 500*time.Millisecond) != nil {
				return ctx.Err()
			}
			continue
		}
		if receiptConfirmed(head.Number.Uint64(), receiptBlock, confirmations) {
			return nil
		}
		if sleepCtx(ctx, 500*time.Millisecond) != nil {
			return ctx.Err()
		}
	}
	if !haveReceipt {
		return fmt.Errorf("timeout waiting for receipt %s", hash.Hex())
	}
	return fmt.Errorf("timeout waiting for %d confirmations of %s (receipt block %d)", confirmations, hash.Hex(), receiptBlock)
}
