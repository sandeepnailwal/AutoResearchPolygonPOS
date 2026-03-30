#!/bin/bash
set -euo pipefail

NODE_ID="${NODE_ID:-0}"
NODE_LOCATION="${NODE_LOCATION:-local}"
LATENCY_MS="${LATENCY_MS:-0}"
DATA_DIR="/data/node${NODE_ID}"
CONFIG_FILE="/configs/experiment.toml"
BOOTNODE_ENODE=""

echo "=== Bor Node ${NODE_ID} (${NODE_LOCATION}) ==="
echo "Simulated latency: ${LATENCY_MS}ms"

# --- Apply network latency simulation ---
if [ "$LATENCY_MS" -gt 0 ]; then
    echo "Applying ${LATENCY_MS}ms latency via tc netem..."
    # Add latency with 10% jitter for realism
    JITTER_MS=$((LATENCY_MS / 10))
    tc qdisc add dev eth0 root netem delay ${LATENCY_MS}ms ${JITTER_MS}ms distribution normal || \
        echo "WARNING: Could not apply tc netem (may need NET_ADMIN capability)"
fi

# --- Initialize node data directory ---
mkdir -p "$DATA_DIR"

if [ ! -d "$DATA_DIR/bor" ]; then
    echo "Initializing Bor datadir..."
    bor init --datadir "$DATA_DIR" /genesis.json
fi

# --- Build static-nodes from other containers ---
# In the Docker network, nodes are at 172.25.0.10-17
STATIC_NODES="["
for i in $(seq 0 7); do
    if [ "$i" -ne "$NODE_ID" ]; then
        # We'll use a deterministic node key derived from node ID
        # In practice, we generate keys at first boot and share enodes
        IP="172.25.0.$((10 + i))"
        PORT="30303"
        if [ -n "$STATIC_NODES" ] && [ "$STATIC_NODES" != "[" ]; then
            STATIC_NODES="${STATIC_NODES},"
        fi
        # Placeholder — real enodes get populated by setup_network.sh
    fi
done

# --- Determine P2P port ---
P2P_PORT=30303

# --- Start Bor ---
echo "Starting Bor node ${NODE_ID}..."
exec bor server \
    --datadir "$DATA_DIR" \
    --dev \
    --dev.period 2 \
    --port "$P2P_PORT" \
    --http \
    --http.addr "0.0.0.0" \
    --http.port 8545 \
    --http.api "eth,net,web3,txpool,debug,bor,admin" \
    --http.vhosts "*" \
    --http.corsdomain "*" \
    --metrics \
    --pprof \
    --pprof.addr "0.0.0.0" \
    --pprof.port 7071 \
    --maxpeers 50 \
    --verbosity 3 \
    --nat "extip:172.25.0.$((10 + NODE_ID))" \
    --nodiscover \
    --config "$CONFIG_FILE" \
    2>&1 | tee "/data/node${NODE_ID}.log"
