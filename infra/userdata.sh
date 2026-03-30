#!/bin/bash
# EC2 userdata — runs on first boot to install everything needed
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# --- System packages ---
apt-get update
apt-get install -y \
  build-essential git make wget curl jq unzip \
  docker.io docker-compose-v2 \
  iproute2 iptables \
  python3 python3-pip \
  prometheus prometheus-node-exporter \
  linux-tools-common linux-tools-generic

# Enable Docker
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# --- Install Go 1.22 ---
GO_VERSION="1.22.5"
wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> /home/ubuntu/.bashrc
echo 'export GOPATH=/home/ubuntu/go' >> /home/ubuntu/.bashrc
echo 'export PATH=$PATH:/home/ubuntu/go/bin' >> /home/ubuntu/.bashrc
export PATH=$PATH:/usr/local/go/bin

# --- Install Grafana ---
apt-get install -y apt-transport-https software-properties-common
mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y grafana
systemctl enable grafana-server
systemctl start grafana-server

# --- Clone project repo ---
cd /home/ubuntu
git clone https://github.com/sandeepnailwal/AutoResearchPolygonPOS.git autoresearch || true
chown -R ubuntu:ubuntu /home/ubuntu/autoresearch

# --- Clone and build Bor ---
cd /home/ubuntu
git clone --depth 1 --branch v1.5.2 https://github.com/maticnetwork/bor.git bor-src
cd bor-src
make bor
cp build/bin/bor /usr/local/bin/bor
cd /home/ubuntu
chown -R ubuntu:ubuntu /home/ubuntu/bor-src

# --- Signal that setup is complete ---
touch /home/ubuntu/.setup_complete
echo "=== AutoResearch setup complete at $(date) ===" >> /var/log/userdata.log
