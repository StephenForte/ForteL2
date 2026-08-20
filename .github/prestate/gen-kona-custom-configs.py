#!/usr/bin/env python3
"""Generate Kona custom-config JSON from an op-node rollup.json (F7-7 / Route A).

Kona's registry crate does not ingest op-node's rollup.json. It merges two
superchain-registry files from KONA_CUSTOM_CONFIGS_DIR at build time:

  chainList.json  — extra Chain entries (JSON array)
  configs.json    — Superchains with matching ChainConfig + RollupConfig

See rust/kona/crates/protocol/registry/build.rs and the crate README
§ "Custom chain configurations". This script is the conversion; it does
not need state.json (Route B).

Chain 852 is not in kona_registry::ROLLUP_CONFIGS. Baking these files into
the prestate is how the program commits to ForteL2's config (D-0061).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# Placeholder endpoints only — they exist so the registry types have a
# String to deserialize. They are not RPCs, and they must not be the
# Access write hostname or any live operator URL.
PLACEHOLDER_RPC = "https://fortel2.invalid"
PLACEHOLDER_EXPLORER = "https://explorer.fortel2.invalid"

REQUIRED_L2_CHAIN_ID = 852

FORK_FIELDS = (
    "regolith_time",
    "canyon_time",
    "delta_time",
    "ecotone_time",
    "fjord_time",
    "granite_time",
    "holocene_time",
    "pectra_blob_schedule_time",
    "isthmus_time",
    "jovian_time",
    "karst_time",
    "lagoon_time",
)


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def require(obj: dict[str, Any], key: str, ctx: str) -> Any:
    if key not in obj:
        die(f"{ctx} is missing required field {key!r}")
    return obj[key]


def hardforks_from_rollup(rollup: dict[str, Any]) -> dict[str, int]:
    """HardForkConfig is deny_unknown_fields — emit only scheduled times."""
    out: dict[str, int] = {}
    for field in FORK_FIELDS:
        if field in rollup and rollup[field] is not None:
            out[field] = int(rollup[field])
    return out


def system_config_from_rollup(syscfg: dict[str, Any]) -> dict[str, Any]:
    """Map genesis.system_config without packing zeros into real Option values.

    rollup.json carries eip1559Params / operatorFeeParams as 0x00.. packed
    fields. Kona's SystemConfig deserializer treats a present packed field
    as Some(decoded), so all-zero packing would bake elasticity=0 rather
    than "unset". The real EIP-1559 knobs live on chain_op_config / optimism.
    """
    out: dict[str, Any] = {
        "batcherAddr": require(syscfg, "batcherAddr", "genesis.system_config"),
        "overhead": require(syscfg, "overhead", "genesis.system_config"),
        "scalar": require(syscfg, "scalar", "genesis.system_config"),
        "gasLimit": require(syscfg, "gasLimit", "genesis.system_config"),
        "baseFeeScalar": None,
        "blobBaseFeeScalar": None,
        "eip1559Denominator": None,
        "eip1559Elasticity": None,
        "operatorFeeScalar": None,
        "operatorFeeConstant": None,
        "minBaseFee": syscfg.get("minBaseFee"),
        "daFootprintGasScalar": syscfg.get("daFootprintGasScalar"),
    }
    return out


def chain_list_entry(rollup: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": "ForteL2",
        "identifier": "sepolia/fortel2",
        "chainId": REQUIRED_L2_CHAIN_ID,
        "rpc": [PLACEHOLDER_RPC],
        "explorers": [PLACEHOLDER_EXPLORER],
        "superchainLevel": 0,
        "governedByOptimism": False,
        "dataAvailabilityType": "eth-da",
        "parent": {"type": "L2", "chain": "sepolia"},
        "faultProofs": {"status": "none"},
    }


def chain_config(rollup: dict[str, Any]) -> dict[str, Any]:
    genesis = require(rollup, "genesis", "rollup.json")
    syscfg = require(genesis, "system_config", "genesis")
    l1 = require(genesis, "l1", "genesis")
    l2 = require(genesis, "l2", "genesis")
    op = require(rollup, "chain_op_config", "rollup.json")
    portal = require(rollup, "deposit_contract_address", "rollup.json")
    system_config_addr = require(rollup, "l1_system_config_address", "rollup.json")

    return {
        "Name": "ForteL2",
        "PublicRPC": PLACEHOLDER_RPC,
        "SequencerRPC": PLACEHOLDER_RPC,
        "Explorer": PLACEHOLDER_EXPLORER,
        "SuperchainLevel": 0,
        "GovernedByOptimism": False,
        "SuperchainTime": None,
        "DataAvailabilityType": "eth-da",
        "l2_chain_id": REQUIRED_L2_CHAIN_ID,
        "batch_inbox_address": require(rollup, "batch_inbox_address", "rollup.json"),
        "block_time": require(rollup, "block_time", "rollup.json"),
        "seq_window_size": require(rollup, "seq_window_size", "rollup.json"),
        "max_sequencer_drift": require(rollup, "max_sequencer_drift", "rollup.json"),
        "GasPayingToken": None,
        "hardfork_configuration": hardforks_from_rollup(rollup),
        "optimism": {
            "eip1559Elasticity": require(op, "eip1559Elasticity", "chain_op_config"),
            "eip1559Denominator": require(op, "eip1559Denominator", "chain_op_config"),
            "eip1559DenominatorCanyon": require(
                op, "eip1559DenominatorCanyon", "chain_op_config"
            ),
        },
        "alt_da": None,
        "genesis": {
            "l1": {
                "number": require(l1, "number", "genesis.l1"),
                "hash": require(l1, "hash", "genesis.l1"),
            },
            "l2": {
                "number": require(l2, "number", "genesis.l2"),
                "hash": require(l2, "hash", "genesis.l2"),
            },
            "l2_time": require(genesis, "l2_time", "genesis"),
            "system_config": system_config_from_rollup(syscfg),
        },
        "Roles": {
            "SystemConfigOwner": None,
            "ProxyAdminOwner": None,
            "Guardian": None,
            "Challenger": None,
            "Proposer": None,
            "UnsafeBlockSigner": None,
            "BatchSubmitter": None,
        },
        # as_rollup_config() takes deposit_contract_address and
        # l1_system_config_address from these two Addresses fields. Leaving
        # them null would bake Address::ZERO into the program image.
        "Addresses": {
            "AddressManager": None,
            "L1CrossDomainMessengerProxy": None,
            "L1Erc721BridgeProxy": None,
            "L1StandardBridgeProxy": None,
            "L2OutputOracleProxy": None,
            "OptimismMintableErc20FactoryProxy": None,
            "OptimismPortalProxy": portal,
            "SystemConfigProxy": system_config_addr,
            "ProxyAdmin": None,
            "SuperchainConfig": None,
            "AnchorStateRegistryProxy": None,
            "DelayedWethProxy": None,
            "DisputeGameFactoryProxy": None,
            "FaultDisputeGame": None,
            "Mips": None,
            "PermissionedDisputeGame": None,
            "PreimageOracle": None,
            "DataAvailabilityChallenge": None,
        },
    }


def configs_json(rollup: dict[str, Any]) -> dict[str, Any]:
    # Own superchain name, not "sepolia": merging into the existing Sepolia
    # entry would inherit OP's SuperchainConfig address rather than ours.
    # l1.chain_id still has to be 11155111 so as_rollup_config gets the
    # right L1 id (copied from SuperchainConfig, not from rollup.json).
    return {
        "superchains": [
            {
                "name": "fortel2-sepolia",
                "config": {
                    "name": "ForteL2 Sepolia",
                    "l1": {
                        "chain_id": require(rollup, "l1_chain_id", "rollup.json"),
                        "public_rpc": "https://ethereum-sepolia-rpc.publicnode.com",
                        "explorer": "https://eth-sepolia.blockscout.com",
                    },
                    "hardforks": hardforks_from_rollup(rollup),
                    "superchain_config_addr": None,
                    "op_contracts_manager_proxy_addr": None,
                },
                "chains": [chain_config(rollup)],
            }
        ]
    }


def generate(rollup: dict[str, Any]) -> tuple[list[Any], dict[str, Any]]:
    chain_id = require(rollup, "l2_chain_id", "rollup.json")
    if chain_id != REQUIRED_L2_CHAIN_ID:
        die(
            f"rollup.json l2_chain_id is {chain_id}, expected {REQUIRED_L2_CHAIN_ID} "
            "(this workflow bakes ForteL2, not an arbitrary OP chain)"
        )
    l1_id = require(rollup, "l1_chain_id", "rollup.json")
    if l1_id != 11155111:
        die(f"rollup.json l1_chain_id is {l1_id}, expected 11155111 (Sepolia)")
    return [chain_list_entry(rollup)], configs_json(rollup)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--rollup",
        required=True,
        type=Path,
        help="op-node rollup.json (tracked at deployments/sepolia/rollup.json)",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="directory to write chainList.json and configs.json",
    )
    args = parser.parse_args()

    if not args.rollup.is_file():
        die(
            f"missing {args.rollup} — commit the post-wipe rollup.json first"
        )

    try:
        rollup = json.loads(args.rollup.read_text())
    except json.JSONDecodeError as e:
        die(f"failed to parse {args.rollup}: {e}")

    chain_list, configs = generate(rollup)

    args.out.mkdir(parents=True, exist_ok=True)
    chain_path = args.out / "chainList.json"
    configs_path = args.out / "configs.json"
    chain_path.write_text(json.dumps(chain_list, indent=2) + "\n")
    configs_path.write_text(json.dumps(configs, indent=2) + "\n")
    print(f"wrote {chain_path}")
    print(f"wrote {configs_path}")
    genesis_hash = rollup["genesis"]["l2"]["hash"]
    print(f"l2_genesis_hash {genesis_hash}")
    print(f"l2_chain_id {REQUIRED_L2_CHAIN_ID}")


if __name__ == "__main__":
    main()
