#!/bin/bash
# Setup script for Polygon POS local devnet
# This script installs Bor and Heimdall, and configures a local devnet

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"
BOR_DIR="$DATA_DIR/bor"
HEIMDALL_DIR="$DATA_DIR/heimdall"
BIN_DIR="$PROJECT_DIR/bin"

echo "=== AutoResearch: Polygon POS Node Setup ==="
echo "Project directory: $PROJECT_DIR"
echo ""

# Check prerequisites
check_prerequisites() {
    echo "[1/5] Checking prerequisites..."

    local missing=()

    command -v go >/dev/null 2>&1 || missing+=("go (>=1.21)")
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [ ${#missing[@]} -ne 0 ]; then
        echo "ERROR: Missing prerequisites: ${missing[*]}"
        echo "Please install them and re-run this script."
        exit 1
    fi

    echo "  All prerequisites found."
}

# Clone and build Bor
setup_bor() {
    echo "[2/5] Setting up Bor..."

    if [ -f "$BIN_DIR/bor" ]; then
        echo "  Bor binary already exists, skipping build."
        return
    fi

    mkdir -p "$BIN_DIR"

    if [ ! -d "$DATA_DIR/bor-src" ]; then
        echo "  Cloning Bor repository..."
        git clone --depth 1 https://github.com/maticnetwork/bor.git "$DATA_DIR/bor-src"
    fi

    echo "  Building Bor..."
    cd "$DATA_DIR/bor-src"
    make bor
    cp build/bin/bor "$BIN_DIR/bor"
    cd "$PROJECT_DIR"

    echo "  Bor built successfully."
}

# Clone and build Heimdall
setup_heimdall() {
    echo "[3/5] Setting up Heimdall..."

    if [ -f "$BIN_DIR/heimdalld" ]; then
        echo "  Heimdall binary already exists, skipping build."
        return
    fi

    mkdir -p "$BIN_DIR"

    if [ ! -d "$DATA_DIR/heimdall-src" ]; then
        echo "  Cloning Heimdall repository..."
        git clone --depth 1 https://github.com/maticnetwork/heimdall.git "$DATA_DIR/heimdall-src"
    fi

    echo "  Building Heimdall..."
    cd "$DATA_DIR/heimdall-src"
    make build
    cp build/heimdalld "$BIN_DIR/heimdalld"
    cp build/heimdallcli "$BIN_DIR/heimdallcli" 2>/dev/null || true
    cd "$PROJECT_DIR"

    echo "  Heimdall built successfully."
}

# Initialize devnet
init_devnet() {
    echo "[4/5] Initializing local devnet..."

    mkdir -p "$BOR_DIR" "$HEIMDALL_DIR"

    # Initialize Bor with devnet genesis
    if [ ! -d "$BOR_DIR/bor" ]; then
        echo "  Initializing Bor datadir..."
        # Use dev mode for local testing — no real genesis needed
        echo '{"config":{"chainId":137,"homesteadBlock":0,"eip150Block":0,"eip155Block":0,"eip158Block":0,"byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,"muirGlacierBlock":0,"berlinBlock":0,"londonBlock":0,"bor":{"period":{"0":2},"producerDelay":{"0":4},"sprint":{"0":16},"backupMultiplier":{"0":2},"validatorContract":"0x0000000000000000000000000000000000001000","stateReceiverContract":"0x0000000000000000000000000000000000001001","overrideStateSyncRecords":null,"blockAlloc":{},"jaipurBlock":0,"delhiBlock":0,"indoreBlock":0,"stateSyncConfirmationDelay":{"0":16}}},"nonce":"0x0","timestamp":"0x0","extraData":"0x","gasLimit":"0x1312D00","difficulty":"0x1","mixHash":"0x0000000000000000000000000000000000000000000000000000000000000000","coinbase":"0x0000000000000000000000000000000000000000","alloc":{"0x71562b71999873DB5b286dF957af199Ec94617F7":{"balance":"0x3635C9ADC5DEA00000"}}},"difficulty":"0x1","gasLimit":"0x1312D00"}' > "$DATA_DIR/genesis.json"
        "$BIN_DIR/bor" init --datadir "$BOR_DIR" "$DATA_DIR/genesis.json"
    fi

    echo "  Devnet initialized."
}

# Create convenience scripts
create_scripts() {
    echo "[5/5] Creating convenience scripts..."

    # Create start script
    cat > "$SCRIPT_DIR/start_node.sh" << 'STARTEOF'
#!/bin/bash
# Start the Bor node with the current experiment config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${1:-$PROJECT_DIR/configs/experiment.toml}"

echo "Starting Bor node with config: $CONFIG"
"$PROJECT_DIR/bin/bor" server --config "$CONFIG" --datadir "$PROJECT_DIR/data/bor" 2>&1 | tee "$PROJECT_DIR/results/node.log"
STARTEOF
    chmod +x "$SCRIPT_DIR/start_node.sh"

    echo "  Done."
}

# Main
check_prerequisites
setup_bor
setup_heimdall
init_devnet
create_scripts

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Copy configs/base.toml to configs/experiment.toml"
echo "  2. Run: ./scripts/run_experiment.sh"
echo "  3. View results: python3 scripts/evaluate.py"
