#!/bin/bash
# Check current AWS costs for the autoresearch project
# Usage: ./scripts/aws/check_costs.sh

set -euo pipefail

echo "=== AutoResearch: AWS Cost Check ==="
echo ""

# Get current month costs
MONTH_START=$(date +%Y-%m-01)
TODAY=$(date +%Y-%m-%d)

echo "Period: $MONTH_START to $TODAY"
echo ""

# Total cost this month
aws ce get-cost-and-usage \
    --time-period "Start=$MONTH_START,End=$TODAY" \
    --granularity MONTHLY \
    --metrics "BlendedCost" \
    --output table 2>/dev/null || echo "Cost Explorer not available (takes 24h after first use)"

echo ""

# Check running instances
echo "=== Running EC2 Instances ==="
aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" "Name=tag:Project,Values=autoresearch" \
    --query 'Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,LaunchTime:LaunchTime,IP:PublicIpAddress}' \
    --output table 2>/dev/null || echo "No running instances found"

echo ""

# Check spot instance pricing
echo "=== Current Spot Pricing (c5.4xlarge, us-east-1) ==="
aws ec2 describe-spot-price-history \
    --instance-types c5.4xlarge \
    --product-descriptions "Linux/UNIX" \
    --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[0:3].{AZ:AvailabilityZone,Price:SpotPrice}' \
    --output table 2>/dev/null || echo "Could not fetch spot prices"

echo ""

# Estimate based on running time
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/infra"

if [ -f "$INFRA_DIR/terraform.tfstate" ]; then
    cd "$INFRA_DIR"
    SPOT_ID=$(terraform output -raw instance_id 2>/dev/null || echo "")
    if [ -n "$SPOT_ID" ]; then
        LAUNCH_TIME=$(aws ec2 describe-instances --instance-ids "$SPOT_ID" \
            --query 'Reservations[0].Instances[0].LaunchTime' --output text 2>/dev/null || echo "")
        if [ -n "$LAUNCH_TIME" ]; then
            LAUNCH_EPOCH=$(date -d "$LAUNCH_TIME" +%s 2>/dev/null || echo 0)
            NOW_EPOCH=$(date +%s)
            HOURS=$(( (NOW_EPOCH - LAUNCH_EPOCH) / 3600 ))
            COST_EST=$(echo "$HOURS * 0.25" | bc 2>/dev/null || echo "unknown")
            echo "Running for ~${HOURS} hours"
            echo "Estimated compute cost: ~\$${COST_EST}"
            echo "Estimated storage cost: ~\$$(echo "$HOURS * 0.02" | bc 2>/dev/null || echo "unknown")"
        fi
    fi
fi

echo ""
echo "Budget: \$100-150 total"
echo "Reminder: Run './scripts/aws/destroy.sh' when done!"
