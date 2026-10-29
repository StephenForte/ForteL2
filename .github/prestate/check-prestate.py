#!/usr/bin/env python3
"""Fail-closed prestate gates, shared by CI and local artifact verification."""
import argparse
import json
import re

U20_STOCK = "0x031ac6f15c19010da258f5cb633ef6ca9318c2d0f244bea6b2045ce6b790e1df"


def commitment(proof):
    value = proof.get("pre")
    if not isinstance(value, str) or not re.fullmatch(r"0x[0-9a-f]{64}", value):
        raise ValueError(".pre must be a 32-byte lowercase hex commitment")
    return value


def check_witness(proof, witness):
    pre = commitment(proof)
    if witness.get("witnessHash") != pre:
        raise ValueError("witnessHash != .pre")
    if type(witness.get("stateVersion")) is not int or witness["stateVersion"] != 8:
        raise ValueError("stateVersion must explicitly equal 8")


def check_stock(proof):
    if commitment(proof) != U20_STOCK:
        raise ValueError(f"stock .pre != published U20 {U20_STOCK}")


def check_distinct(proof, stock):
    if commitment(proof) == commitment(stock):
        raise ValueError("custom .pre == stock .pre; custom configuration did not land")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("gate", choices=("witness", "stock", "distinct"))
    parser.add_argument("--proof", required=True, type=argparse.FileType())
    parser.add_argument("--witness", type=argparse.FileType())
    parser.add_argument("--stock", type=argparse.FileType())
    args = parser.parse_args()
    proof = json.load(args.proof)
    try:
        if args.gate == "witness":
            if args.witness is None:
                parser.error("witness gate requires --witness")
            check_witness(proof, json.load(args.witness))
        elif args.gate == "stock":
            check_stock(proof)
        else:
            if args.stock is None:
                parser.error("distinct gate requires --stock")
            check_distinct(proof, json.load(args.stock))
    except ValueError as error:
        parser.exit(1, f"{args.gate} FAIL: {error}\n")
    print(f"{args.gate} PASS: {commitment(proof)}")


if __name__ == "__main__":
    main()
