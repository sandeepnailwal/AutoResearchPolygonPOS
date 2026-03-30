#!/bin/bash
# Deploy the autoresearch infrastructure to AWS
# Usage: ./scripts/aws/deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
INFRA_DIR="$PROJECT_DIR/infra"

echo "=== AutoResearch: AWS Deployment ==="
echo ""

# Check prerequisites
for cmd in terraform aws ssh-keygen; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: '$cmd' is required but not installed."
        exit 1
    fi
done

# Check AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS credentials not configured."
    echo "Run: aws configure"
    echo "  OR set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: $ACCOUNT_ID"
echo ""

# Check for terraform.tfvars
if [ ! -f "$INFRA_DIR/terraform.tfvars" ]; then
    echo "No terraform.tfvars found. Creating interactively..."
    echo ""

    # Get user's IP
    MY_IP=$(curl -s ifconfig.me 2>/dev/null || echo "0.0.0.0")
    echo "Your public IP: $MY_IP"

    # Check for existing key pairs
    echo ""
    echo "Existing EC2 key pairs in us-east-1:"
    aws ec2 describe-key-pairs --region us-east-1 --query 'KeyPairs[].KeyName' --output table 2>/dev/null || echo "  (none found)"
    echo ""

    read -p "EC2 Key Pair name (or 'create' to make one): " KEY_NAME
    if [ "$KEY_NAME" = "create" ]; then
        KEY_NAME="autoresearch-polygon"
        echo "Creating key pair: $KEY_NAME"
        aws ec2 create-key-pair --region us-east-1 --key-name "$KEY_NAME" \
            --query 'KeyMaterial' --output text > "$HOME/.ssh/${KEY_NAME}.pem"
        chmod 600 "$HOME/.ssh/${KEY_NAME}.pem"
        echo "Key saved to: ~/.ssh/${KEY_NAME}.pem"
    fi

    cat > "$INFRA_DIR/terraform.tfvars" << EOF
aws_region       = "us-east-1"
key_name         = "$KEY_NAME"
allowed_ssh_cidr = "${MY_IP}/32"
instance_type    = "c5.4xlarge"
spot_max_price   = "0.25"
root_volume_size = 200
EOF
    echo "Created terraform.tfvars"
fi

# Deploy with Terraform
cd "$INFRA_DIR"

echo ""
echo "=== Terraform Init ==="
terraform init

echo ""
echo "=== Terraform Plan ==="
terraform plan

echo ""
read -p "Apply this plan? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "=== Terraform Apply ==="
terraform apply -auto-approve

# Get outputs
PUBLIC_IP=$(terraform output -raw public_ip)
SSH_CMD=$(terraform output -raw ssh_command)

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Instance IP: $PUBLIC_IP"
echo "SSH: $SSH_CMD"
echo ""
echo "Waiting for instance setup to complete (this takes 5-10 minutes)..."
echo "Monitor with: $SSH_CMD 'tail -f /var/log/cloud-init-output.log'"
echo ""

# Wait for setup to complete
echo "Polling for setup completion..."
for i in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$HOME/.ssh/$(terraform output -raw key_name 2>/dev/null || echo 'autoresearch-polygon').pem" "ubuntu@$PUBLIC_IP" "test -f /home/ubuntu/.setup_complete" 2>/dev/null; then
        echo "Setup complete!"
        break
    fi
    echo "  ... still setting up (attempt $i/60)"
    sleep 30
done

echo ""
echo "=== Next Steps ==="
echo "1. SSH into the instance:"
echo "   $SSH_CMD"
echo ""
echo "2. Start the node cluster:"
echo "   cd autoresearch && docker compose -f docker/docker-compose.yml up -d"
echo ""
echo "3. Run an experiment:"
echo "   ./scripts/run_experiment.sh"
echo ""
echo "4. View Grafana dashboard:"
echo "   http://$PUBLIC_IP:3000 (admin / autoresearch)"
echo ""
echo "=== Cost Estimate ==="
echo "Spot instance: ~\$0.20-0.25/hr = ~\$5-6/day"
echo "EBS storage: ~\$0.50/day (200GB gp3)"
echo "Total: ~\$6-7/day = ~\$42-49/week"
echo ""
echo "REMEMBER: Run './scripts/aws/destroy.sh' when done to stop costs!"
