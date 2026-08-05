// Command inspect-game prints DisputeGameFactory + latest game metadata (US-050).
//
//	go run ./cmd/inspect-game \
//	  -l1 "$L1_RPC_URL" \
//	  -factory 0x... \
//	  [-index N] [-game-type 1]
//
// Read-only — never requires a private key.
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/StephenForte/ForteL2/proposer"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/ethclient"
)

func main() {
	l1RPC := flag.String("l1", envOr("L1_RPC_URL", ""), "L1 HTTP RPC")
	factoryFlag := flag.String("factory", "", "DisputeGameFactoryProxy address")
	deployments := flag.String("deployments", "", "optional deployments.json (reads DisputeGameFactoryProxy)")
	indexFlag := flag.Int64("index", -1, "game index (-1 = latest matching game-type)")
	gameType := flag.Uint("game-type", envOrUint("PROPOSER_GAME_TYPE", 1), "game type filter for latest")
	flag.Parse()

	if *l1RPC == "" {
		fmt.Fprintln(os.Stderr, "usage: inspect-game -l1 … -factory 0x… [-index N]")
		os.Exit(2)
	}
	factoryAddr, err := resolveFactory(*factoryFlag, *deployments)
	if err != nil {
		fmt.Fprintf(os.Stderr, "factory: %v\n", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	client, err := ethclient.DialContext(ctx, *l1RPC)
	if err != nil {
		fmt.Fprintf(os.Stderr, "l1 dial: %v\n", proposer.RedactErr(*l1RPC, "", err))
		os.Exit(1)
	}
	defer client.Close()

	count, err := proposer.GameCount(ctx, client, factoryAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gameCount: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("factory=%s\n", factoryAddr.Hex())
	fmt.Printf("gameCount=%s\n", count.String())

	bond, err := proposer.InitBond(ctx, client, factoryAddr, uint32(*gameType))
	if err != nil {
		fmt.Fprintf(os.Stderr, "initBonds: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("initBonds(gameType=%d)=%s wei\n", *gameType, bond.String())

	if count.Sign() == 0 {
		fmt.Println("no games yet")
		return
	}

	var g proposer.InspectedGame
	if *indexFlag >= 0 {
		g, err = proposer.InspectGame(ctx, client, factoryAddr, uint64(*indexFlag))
	} else {
		var ok bool
		g, ok, err = proposer.LatestGameOfType(ctx, client, factoryAddr, uint32(*gameType))
		if err == nil && !ok {
			fmt.Printf("no games of type %d\n", *gameType)
			return
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "inspect: %v\n", err)
		os.Exit(1)
	}

	seqFromExtra, extraErr := proposer.UnpackExtraData(g.ExtraData)
	fmt.Printf("index=%d\n", g.Index)
	fmt.Printf("proxy=%s\n", g.Proxy.Hex())
	fmt.Printf("factory_gameType=%d factory_timestamp=%d (%s)\n",
		g.FactoryGameType, g.FactoryTime, time.Unix(int64(g.FactoryTime), 0).UTC().Format(time.RFC3339))
	fmt.Printf("rootClaim=%s\n", g.RootClaim.Hex())
	fmt.Printf("extraData=0x%s\n", hex.EncodeToString(g.ExtraData))
	fmt.Printf("l2SequenceNumber=%d\n", g.L2Sequence)
	if extraErr == nil {
		fmt.Printf("extraData_sequence=%d\n", seqFromExtra)
	} else {
		fmt.Printf("extraData_sequence=<unpack error: %v>\n", extraErr)
	}
	fmt.Printf("gameType=%d status=%d createdAt=%d creator=%s\n",
		g.GameType, g.Status, g.CreatedAt, g.Creator.Hex())
}

func resolveFactory(flagVal, deploymentsPath string) (common.Address, error) {
	if flagVal != "" {
		return proposer.HexOrAddress(flagVal)
	}
	if deploymentsPath == "" {
		return common.Address{}, fmt.Errorf("need -factory or -deployments")
	}
	raw, err := os.ReadFile(deploymentsPath)
	if err != nil {
		return common.Address{}, err
	}
	var m map[string]string
	if err := json.Unmarshal(raw, &m); err != nil {
		// deployments.json has mixed types; fall back to generic map.
		var any map[string]interface{}
		if err2 := json.Unmarshal(raw, &any); err2 != nil {
			return common.Address{}, err
		}
		for _, key := range []string{"DisputeGameFactoryProxy", "disputeGameFactoryProxy"} {
			if v, ok := any[key].(string); ok && v != "" {
				return proposer.HexOrAddress(v)
			}
		}
		return common.Address{}, fmt.Errorf("DisputeGameFactoryProxy missing in %s", deploymentsPath)
	}
	for _, key := range []string{"DisputeGameFactoryProxy", "disputeGameFactoryProxy"} {
		if v := m[key]; v != "" {
			return proposer.HexOrAddress(v)
		}
	}
	return common.Address{}, fmt.Errorf("DisputeGameFactoryProxy missing in %s", deploymentsPath)
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
