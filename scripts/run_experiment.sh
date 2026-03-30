#!/bin/bash
# Run a single autoresearch experiment on the Polygon POS node
# Each experiment runs for a configurable duration (default: 5 minutes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${1:-$PROJECT_DIR/configs/experiment.toml}"
DURATION="${2:-300}" # 5 minutes default
RESULTS_DIR="$PROJECT_DIR/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPERIMENT_DIR="$RESULTS_DIR/$TIMESTAMP"

echo "=== AutoResearch Experiment ==="
echo "Config: $CONFIG"
echo "Duration: ${DURATION}s"
echo "Results: $EXPERIMENT_DIR"
echo ""

# Validate config exists
if [ ! -f "$CONFIG" ]; then
    echo "ERROR: Config file not found: $CONFIG"
    echo "Copy configs/base.toml to configs/experiment.toml first."
    exit 1
fi

# Check if bor binary exists
BOR_BIN="$PROJECT_DIR/bin/bor"
if [ ! -f "$BOR_BIN" ]; then
    echo "ERROR: Bor binary not found. Run ./scripts/setup_devnet.sh first."
    exit 1
fi

# Create experiment directory
mkdir -p "$EXPERIMENT_DIR"

# Copy config for this experiment (for reproducibility)
cp "$CONFIG" "$EXPERIMENT_DIR/config.toml"

# Record system info
{
    echo "=== System Info ==="
    echo "Date: $(date -u)"
    echo "Hostname: $(hostname)"
    echo "OS: $(uname -a)"
    echo "CPU: $(nproc) cores"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "Disk: $(df -h "$PROJECT_DIR" | tail -1 | awk '{print $4 " available"}')"
    echo ""
} > "$EXPERIMENT_DIR/system_info.txt"

# Function to collect metrics during the run
collect_metrics() {
    local pid=$1
    local interval=5
    local metrics_file="$EXPERIMENT_DIR/metrics.csv"

    echo "timestamp,cpu_percent,memory_mb,disk_read_mb,disk_write_mb,goroutines,peers" > "$metrics_file"

    while kill -0 "$pid" 2>/dev/null; do
        local ts=$(date +%s)

        # CPU and memory from /proc
        local cpu_mem
        cpu_mem=$(ps -p "$pid" -o %cpu=,rss= 2>/dev/null || echo "0 0")
        local cpu=$(echo "$cpu_mem" | awk '{print $1}')
        local mem_kb=$(echo "$cpu_mem" | awk '{print $2}')
        local mem_mb=$((mem_kb / 1024))

        # Disk I/O from /proc/[pid]/io
        local read_bytes=0
        local write_bytes=0
        if [ -f "/proc/$pid/io" ]; then
            read_bytes=$(grep "read_bytes" "/proc/$pid/io" 2>/dev/null | awk '{print $2}' || echo 0)
            write_bytes=$(grep "write_bytes" "/proc/$pid/io" 2>/dev/null | awk '{print $2}' || echo 0)
        fi
        local read_mb=$((read_bytes / 1048576))
        local write_mb=$((write_bytes / 1048576))

        # Try to get peer count and goroutines from debug API
        local peers=0
        local goroutines=0
        if command -v curl >/dev/null 2>&1; then
            peers=$(curl -s -X POST -H "Content-Type: application/json" \
                --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
                http://localhost:8545 2>/dev/null | python3 -c "import sys,json; print(int(json.load(sys.stdin).get('result','0x0'),16))" 2>/dev/null || echo 0)
        fi

        echo "$ts,$cpu,$mem_mb,$read_mb,$write_mb,$goroutines,$peers" >> "$metrics_file"

        sleep "$interval"
    done
}

# Kill any existing bor process
pkill -f "bor server" 2>/dev/null || true
sleep 2

echo "Starting Bor node..."
"$BOR_BIN" server \
    --config "$CONFIG" \
    --datadir "$PROJECT_DIR/data/bor" \
    --dev \
    --dev.period 2 \
    --http \
    --http.addr "127.0.0.1" \
    --http.port 8545 \
    --http.api "eth,net,web3,txpool,debug,bor,admin" \
    --verbosity 3 \
    > "$EXPERIMENT_DIR/node.log" 2>&1 &

BOR_PID=$!
echo "Bor started with PID: $BOR_PID"

# Wait for node to start
echo "Waiting for node to initialize..."
sleep 10

# Check if node is still running
if ! kill -0 "$BOR_PID" 2>/dev/null; then
    echo "ERROR: Bor node failed to start. Check logs:"
    tail -20 "$EXPERIMENT_DIR/node.log"
    exit 1
fi

echo "Node running. Collecting metrics for ${DURATION}s..."

# Start metrics collection in background
collect_metrics "$BOR_PID" &
METRICS_PID=$!

# Run benchmark transactions if the node supports it
if command -v curl >/dev/null 2>&1; then
    echo "Generating benchmark load..."
    (
        sleep 5
        for i in $(seq 1 100); do
            # Send simple transactions to generate block activity
            curl -s -X POST -H "Content-Type: application/json" \
                --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":$i}" \
                http://localhost:8545 > /dev/null 2>&1 || true
            sleep $((DURATION / 100))
        done
    ) &
    LOAD_PID=$!
fi

# Wait for experiment duration
echo "Experiment running... (will stop in ${DURATION}s)"
sleep "$DURATION"

# Collect final state
echo "Collecting final metrics..."

# Get block number at end
if command -v curl >/dev/null 2>&1; then
    FINAL_BLOCK=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 2>/dev/null | python3 -c "import sys,json; print(int(json.load(sys.stdin).get('result','0x0'),16))" 2>/dev/null || echo 0)
    echo "Final block number: $FINAL_BLOCK"
    echo "final_block=$FINAL_BLOCK" > "$EXPERIMENT_DIR/final_state.txt"

    # Get debug metrics if available
    curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"debug_metrics","params":[true],"id":1}' \
        http://localhost:8545 2>/dev/null > "$EXPERIMENT_DIR/debug_metrics.json" || true

    # Get txpool status
    curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"txpool_status","params":[],"id":1}' \
        http://localhost:8545 2>/dev/null > "$EXPERIMENT_DIR/txpool_status.json" || true
fi

# Stop the node
echo "Stopping Bor node..."
kill "$BOR_PID" 2>/dev/null || true
kill "$METRICS_PID" 2>/dev/null || true
kill "$LOAD_PID" 2>/dev/null || true
wait "$BOR_PID" 2>/dev/null || true

# Extract key metrics from logs
echo "Extracting metrics from logs..."
{
    echo "=== Experiment Summary ==="
    echo "Config: $CONFIG"
    echo "Duration: ${DURATION}s"
    echo "Final Block: ${FINAL_BLOCK:-unknown}"
    echo ""
    echo "=== Block Import Times ==="
    grep -i "imported\|block" "$EXPERIMENT_DIR/node.log" | tail -20 || echo "No block import logs found"
    echo ""
    echo "=== Errors ==="
    grep -i "error\|fatal\|panic" "$EXPERIMENT_DIR/node.log" | head -10 || echo "No errors found"
} > "$EXPERIMENT_DIR/summary.txt"

echo ""
echo "=== Experiment Complete ==="
echo "Results saved to: $EXPERIMENT_DIR"
echo "Run 'python3 scripts/evaluate.py $EXPERIMENT_DIR' to analyze results."
