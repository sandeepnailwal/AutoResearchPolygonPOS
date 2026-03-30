#!/bin/bash
# Tear down all AWS infrastructure
# Usage: ./scripts/aws/destroy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/infra"

echo "=== AutoResearch: Destroying AWS Infrastructure ==="
echo ""
echo "WARNING: This will terminate the EC2 instance and delete all data on it."
echo ""
read -p "Are you sure? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

cd "$INFRA_DIR"
terraform destroy -auto-approve

echo ""
echo "=== Infrastructure Destroyed ==="
echo "No more AWS charges will accrue."
