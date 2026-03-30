#!/bin/bash
# Connect all Bor nodes into a peer network using admin_addPeer
# Run this AFTER docker compose up
# This replaces static-nodes by dynamically peering all containers

set -euo pipefail

echo "=== Setting up peer network ==="

BASE_PORT=8545
NODES=8

# Collect enodes from all nodes
declare -a ENODES

for i in $(seq 0 $((NODES - 1))); do
    PORT=$((BASE_PORT + i))
    echo "Getting enode for node-$i (port $PORT)..."

    ENODE=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
        "http://127.0.0.1:$PORT" 2>/dev/null | \
        jq -r '.result.enode // empty' 2>/dev/null)

    if [ -n "$ENODE" ]; then
        # Replace the IP in enode with the container IP
        CONTAINER_IP="172.25.0.$((10 + i))"
        ENODE=$(echo "$ENODE" | sed "s/@[^:]*:/@${CONTAINER_IP}:/")
        ENODES[$i]="$ENODE"
        echo "  Node $i: $ENODE"
    else
        echo "  WARNING: Could not get enode for node-$i (node may not be ready)"
        ENODES[$i]=""
    fi
done

# Cross-peer all nodes
echo ""
echo "=== Connecting peers ==="
CONNECTED=0

for i in $(seq 0 $((NODES - 1))); do
    for j in $(seq 0 $((NODES - 1))); do
        if [ "$i" -ne "$j" ] && [ -n "${ENODES[$j]}" ]; then
            PORT=$((BASE_PORT + i))
            RESULT=$(curl -s -X POST -H "Content-Type: application/json" \
                --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"${ENODES[$j]}\"],\"id\":1}" \
                "http://127.0.0.1:$PORT" 2>/dev/null | jq -r '.result // false')

            if [ "$RESULT" = "true" ]; then
                CONNECTED=$((CONNECTED + 1))
            fi
        fi
    done
done

echo ""
echo "Established $CONNECTED peer connections."
echo ""

# Verify peer counts
echo "=== Peer counts ==="
for i in $(seq 0 $((NODES - 1))); do
    PORT=$((BASE_PORT + i))
    PEERS=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
        "http://127.0.0.1:$PORT" 2>/dev/null | \
        jq -r '.result // "0x0"' | xargs printf "%d" 2>/dev/null || echo "0")
    echo "  Node $i: $PEERS peers"
done

echo ""
echo "=== Network setup complete ==="
