#!/bin/bash
# Run an autoresearch experiment on the remote AWS instance
# Usage: ./scripts/aws/run_remote_experiment.sh [experiment_config.toml] [duration_seconds]
#
# This script:
# 1. Uploads the experiment config to the remote instance
# 2. Restarts all Bor nodes with the new config
# 3. Sets up network peering
# 4. Generates load
# 5. Collects metrics from all 8 nodes
# 6. Downloads results locally

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
INFRA_DIR="$PROJECT_DIR/infra"
CONFIG="${1:-$PROJECT_DIR/configs/experiment.toml}"
DURATION="${2:-300}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOCAL_RESULTS="$PROJECT_DIR/results/$TIMESTAMP"

# Get remote IP from Terraform
cd "$INFRA_DIR"
REMOTE_IP=$(terraform output -raw public_ip 2>/dev/null)
KEY_FILE="$HOME/.ssh/$(grep key_name terraform.tfvars | awk -F'"' '{print $2}').pem"

if [ -z "$REMOTE_IP" ]; then
    echo "ERROR: Could not get instance IP. Is the infrastructure deployed?"
    exit 1
fi

SSH="ssh -o StrictHostKeyChecking=no -i $KEY_FILE ubuntu@$REMOTE_IP"
SCP="scp -o StrictHostKeyChecking=no -i $KEY_FILE"

echo "=== Remote Experiment: $TIMESTAMP ==="
echo "Config: $CONFIG"
echo "Duration: ${DURATION}s"
echo "Remote: $REMOTE_IP"
echo ""

# 1. Upload experiment config
echo "[1/6] Uploading config..."
$SCP "$CONFIG" "ubuntu@$REMOTE_IP:/home/ubuntu/autoresearch/configs/experiment.toml"

# 2. Restart nodes with new config
echo "[2/6] Restarting node cluster..."
$SSH << 'REMOTE_RESTART'
cd /home/ubuntu/autoresearch
docker compose -f docker/docker-compose.yml down
docker compose -f docker/docker-compose.yml up -d
echo "Waiting 15s for nodes to initialize..."
sleep 15
REMOTE_RESTART

# 3. Setup network peering
echo "[3/6] Setting up peer network..."
$SCP "$SCRIPT_DIR/setup_network.sh" "ubuntu@$REMOTE_IP:/tmp/setup_network.sh"
$SSH "bash /tmp/setup_network.sh"

# 4. Generate load + collect metrics
echo "[4/6] Running experiment for ${DURATION}s..."
$SSH << REMOTE_RUN
cd /home/ubuntu/autoresearch
TIMESTAMP="$TIMESTAMP"
DURATION="$DURATION"
RESULTS_DIR="/home/ubuntu/experiment_results/\$TIMESTAMP"
mkdir -p "\$RESULTS_DIR"

# Save config snapshot
cp configs/experiment.toml "\$RESULTS_DIR/config.toml"

# Start metrics collection for all nodes
for i in \$(seq 0 7); do
    PORT=\$((8545 + i))
    METRICS_FILE="\$RESULTS_DIR/metrics_node\${i}.csv"
    echo "timestamp,block_number,cpu_percent,memory_mb,peer_count,pending_txs,queued_txs" > "\$METRICS_FILE"

    (
        END_TIME=\$((SECONDS + DURATION))
        while [ \$SECONDS -lt \$END_TIME ]; do
            TS=\$(date +%s)

            # Block number
            BLOCK=\$(curl -s -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                http://127.0.0.1:\$PORT 2>/dev/null | jq -r '.result // "0x0"' | xargs printf "%d" 2>/dev/null || echo 0)

            # Peer count
            PEERS=\$(curl -s -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
                http://127.0.0.1:\$PORT 2>/dev/null | jq -r '.result // "0x0"' | xargs printf "%d" 2>/dev/null || echo 0)

            # TxPool status
            TXPOOL=\$(curl -s -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"txpool_status","params":[],"id":1}' \
                http://127.0.0.1:\$PORT 2>/dev/null)
            PENDING=\$(echo "\$TXPOOL" | jq -r '.result.pending // "0x0"' | xargs printf "%d" 2>/dev/null || echo 0)
            QUEUED=\$(echo "\$TXPOOL" | jq -r '.result.queued // "0x0"' | xargs printf "%d" 2>/dev/null || echo 0)

            # Container CPU/mem
            CONTAINER="bor-node-\$i"
            STATS=\$(docker stats --no-stream --format "{{.CPUPerc}},{{.MemUsage}}" "\$CONTAINER" 2>/dev/null || echo "0%,0MiB")
            CPU=\$(echo "\$STATS" | cut -d',' -f1 | tr -d '%')
            MEM=\$(echo "\$STATS" | cut -d',' -f2 | cut -d'/' -f1 | tr -d ' MiGBb')

            echo "\$TS,\$BLOCK,\$CPU,\$MEM,\$PEERS,\$PENDING,\$QUEUED" >> "\$METRICS_FILE"
            sleep 5
        done
    ) &
done

# Generate transaction load from node-0
echo "Generating load at 10 TPS for \${DURATION}s..."
python3 scripts/generate_load.py --rpc http://127.0.0.1:8545 --tps 10 --duration "\$DURATION" --mode mixed > "\$RESULTS_DIR/load_summary.txt" 2>&1 || true

# Wait for metrics collectors
wait

# Collect block propagation data
echo "Collecting block propagation data..."
python3 - << 'PYEOF' > "\$RESULTS_DIR/propagation.csv"
import json, urllib.request, time, csv, sys

NODES = 8
BASE_PORT = 8545

def rpc(port, method, params=[]):
    payload = json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}).encode()
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{port}", data=payload,
                                     headers={"Content-Type":"application/json"})
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.loads(r.read()).get("result")
    except: return None

writer = csv.writer(sys.stdout)
writer.writerow(["node_id","location","block_number","peer_count","latest_block_time"])

locations = ["us-east","eu-west","eu-central","ap-southeast","ap-northeast","ap-south","sa-east","ap-southeast-2"]

for i in range(NODES):
    port = BASE_PORT + i
    block_hex = rpc(port, "eth_blockNumber")
    block_num = int(block_hex, 16) if block_hex else 0

    peers_hex = rpc(port, "net_peerCount")
    peers = int(peers_hex, 16) if peers_hex else 0

    block_data = rpc(port, "eth_getBlockByNumber", [block_hex, False]) if block_hex else None
    block_time = int(block_data["timestamp"], 16) if block_data and block_data.get("timestamp") else 0

    writer.writerow([i, locations[i], block_num, peers, block_time])
PYEOF

# Collect node logs
for i in \$(seq 0 7); do
    docker logs "bor-node-\$i" > "\$RESULTS_DIR/node\${i}.log" 2>&1 || true
done

# Collect debug metrics from each node
for i in \$(seq 0 7); do
    PORT=\$((8545 + i))
    curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"debug_metrics","params":[true],"id":1}' \
        http://127.0.0.1:\$PORT > "\$RESULTS_DIR/debug_metrics_node\${i}.json" 2>/dev/null || true
done

echo "Remote results saved to: \$RESULTS_DIR"
REMOTE_RUN

# 5. Download results
echo "[5/6] Downloading results..."
mkdir -p "$LOCAL_RESULTS"
$SCP -r "ubuntu@$REMOTE_IP:/home/ubuntu/experiment_results/$TIMESTAMP/*" "$LOCAL_RESULTS/"

# 6. Evaluate
echo "[6/6] Evaluating results..."
echo ""
echo "=== Experiment $TIMESTAMP Complete ==="
echo "Results: $LOCAL_RESULTS"
echo ""
ls -la "$LOCAL_RESULTS/"
echo ""
echo "Next: python3 scripts/evaluate.py $LOCAL_RESULTS"
