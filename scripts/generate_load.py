#!/usr/bin/env python3
"""
Generate synthetic transaction load on a local Polygon POS devnet.
Used during autoresearch experiments to stress-test the node.

Usage:
    python3 generate_load.py [--rpc URL] [--duration SECONDS] [--tps TARGET_TPS]
"""

import argparse
import json
import time
import urllib.request


def rpc_call(url: str, method: str, params: list = None, id: int = 1) -> dict:
    """Make a JSON-RPC call to the node."""
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params or [],
        "id": id,
    }
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e)}


def get_accounts(url: str) -> list[str]:
    """Get available accounts from the node."""
    result = rpc_call(url, "eth_accounts")
    return result.get("result", [])


def get_block_number(url: str) -> int:
    """Get current block number."""
    result = rpc_call(url, "eth_blockNumber")
    hex_val = result.get("result", "0x0")
    return int(hex_val, 16)


def send_transaction(url: str, from_addr: str, to_addr: str, value: str = "0x1") -> str:
    """Send a simple value transfer transaction."""
    tx = {
        "from": from_addr,
        "to": to_addr,
        "value": value,
        "gas": "0x5208",  # 21000
        "gasPrice": "0x3B9ACA00",  # 1 gwei
    }
    result = rpc_call(url, "eth_sendTransaction", [tx])
    return result.get("result", result.get("error", "unknown"))


def deploy_storage_contract(url: str, from_addr: str) -> str:
    """Deploy a simple storage contract for write-heavy testing."""
    # Simple contract: stores a uint256 and has a set function
    # contract Storage { uint256 public value; function set(uint256 v) { value = v; } }
    bytecode = (
        "0x6080604052348015600f57600080fd5b5060"
        "ac8061001e6000396000f3fe6080604052348015600f"
        "57600080fd5b506004361060325760003560e01c8063"
        "3fa4f24514603757806360fe47b114604f575b600080"
        "fd5b603d6061565b604051908152602001604051"
        "80910390f35b605f600a6067565b005b60005481565b"
        "600055565b00fea264697066735822122000000000"
        "00000000000000000000000000000000000000000000"
        "0000000000064736f6c63430008000033"
    )
    tx = {
        "from": from_addr,
        "data": bytecode,
        "gas": "0x100000",
        "gasPrice": "0x3B9ACA00",
    }
    result = rpc_call(url, "eth_sendTransaction", [tx])
    return result.get("result", "")


def main():
    parser = argparse.ArgumentParser(description="Generate load on POS devnet")
    parser.add_argument("--rpc", default="http://127.0.0.1:8545", help="RPC endpoint")
    parser.add_argument("--duration", type=int, default=240, help="Duration in seconds")
    parser.add_argument("--tps", type=int, default=10, help="Target transactions per second")
    parser.add_argument("--mode", choices=["transfer", "storage", "mixed"], default="mixed",
                        help="Load type")
    args = parser.parse_args()

    print(f"Generating load: mode={args.mode}, tps={args.tps}, duration={args.duration}s")
    print(f"RPC: {args.rpc}")

    # Get accounts
    accounts = get_accounts(args.rpc)
    if not accounts:
        print("WARNING: No accounts available. Using dev account.")
        accounts = ["0x71562b71999873DB5b286dF957af199Ec94617F7"]

    from_addr = accounts[0]
    to_addr = accounts[1] if len(accounts) > 1 else accounts[0]

    start_block = get_block_number(args.rpc)
    print(f"Starting block: {start_block}")
    print(f"From: {from_addr}")

    # Deploy storage contract if needed
    contract_addr = None
    if args.mode in ("storage", "mixed"):
        print("Deploying storage contract...")
        tx_hash = deploy_storage_contract(args.rpc, from_addr)
        if tx_hash and not isinstance(tx_hash, dict):
            print(f"  Deploy tx: {tx_hash}")
            time.sleep(3)
            # Get contract address from receipt
            receipt = rpc_call(args.rpc, "eth_getTransactionReceipt", [tx_hash])
            contract_addr = receipt.get("result", {}).get("contractAddress")
            print(f"  Contract deployed at: {contract_addr}")

    # Generate load
    tx_count = 0
    error_count = 0
    start_time = time.time()
    interval = 1.0 / args.tps

    print(f"\nSending transactions (Ctrl+C to stop)...")

    try:
        while time.time() - start_time < args.duration:
            loop_start = time.time()

            if args.mode == "transfer" or (args.mode == "mixed" and tx_count % 3 != 0):
                # Simple transfer
                result = send_transaction(args.rpc, from_addr, to_addr, "0x1")
            else:
                # Storage write
                if contract_addr:
                    # Call set(value)
                    data = f"0x60fe47b1{tx_count:064x}"
                    tx = {
                        "from": from_addr,
                        "to": contract_addr,
                        "data": data,
                        "gas": "0x10000",
                        "gasPrice": "0x3B9ACA00",
                    }
                    result = rpc_call(args.rpc, "eth_sendTransaction", [tx])
                    result = result.get("result", result.get("error", "unknown"))
                else:
                    result = send_transaction(args.rpc, from_addr, to_addr, "0x1")

            if "error" in str(result).lower() or result == "unknown":
                error_count += 1
            else:
                tx_count += 1

            # Print progress every 50 txs
            if tx_count % 50 == 0 and tx_count > 0:
                elapsed = time.time() - start_time
                actual_tps = tx_count / elapsed
                current_block = get_block_number(args.rpc)
                print(f"  Sent {tx_count} txs | {actual_tps:.1f} tps | "
                      f"Block: {current_block} | Errors: {error_count}")

            # Rate limiting
            elapsed_loop = time.time() - loop_start
            if elapsed_loop < interval:
                time.sleep(interval - elapsed_loop)

    except KeyboardInterrupt:
        print("\nInterrupted.")

    # Summary
    end_time = time.time()
    end_block = get_block_number(args.rpc)
    total_time = end_time - start_time
    blocks_produced = end_block - start_block

    print(f"\n{'='*50}")
    print(f" Load Generation Summary")
    print(f"{'='*50}")
    print(f"  Duration: {total_time:.1f}s")
    print(f"  Transactions sent: {tx_count}")
    print(f"  Errors: {error_count}")
    print(f"  Actual TPS: {tx_count/max(total_time,1):.1f}")
    print(f"  Blocks produced: {blocks_produced}")
    print(f"  Blocks/sec: {blocks_produced/max(total_time,1):.2f}")
    print(f"{'='*50}")

    # Save summary
    summary = {
        "duration_sec": round(total_time, 1),
        "tx_count": tx_count,
        "errors": error_count,
        "actual_tps": round(tx_count / max(total_time, 1), 1),
        "start_block": start_block,
        "end_block": end_block,
        "blocks_produced": blocks_produced,
    }
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
