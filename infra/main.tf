terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "key_name" {
  description = "Name of existing EC2 key pair for SSH access"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "Your IP CIDR for SSH access (e.g., 1.2.3.4/32)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  default = "c5.4xlarge" # 16 vCPU, 32GB RAM — enough for 10 Bor nodes in dev mode
}

variable "spot_max_price" {
  default = "0.25" # ~65% savings vs on-demand ($0.68)
}

variable "root_volume_size" {
  default = 200 # GB — enough for 10 nodes' chain data
}

# --- AMI: Latest Ubuntu 22.04 ---
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Security Group ---
resource "aws_security_group" "autoresearch" {
  name_prefix = "autoresearch-polygon-"
  description = "AutoResearch Polygon POS experiment"

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Grafana dashboard
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Prometheus
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "autoresearch-polygon"
    Project = "autoresearch"
  }
}

# --- Spot Instance Request ---
resource "aws_spot_instance_request" "node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.autoresearch.id]
  spot_price             = var.spot_max_price
  wait_for_fulfillment   = true
  spot_type              = "one-time"

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    iops        = 6000
    throughput  = 250
  }

  user_data = file("${path.module}/userdata.sh")

  tags = {
    Name    = "autoresearch-polygon-pos"
    Project = "autoresearch"
  }
}

# Tag the actual instance (spot requests don't auto-tag instances)
resource "aws_ec2_tag" "instance_name" {
  resource_id = aws_spot_instance_request.node.spot_instance_id
  key         = "Name"
  value       = "autoresearch-polygon-pos"
}

# --- Outputs ---
output "instance_id" {
  value = aws_spot_instance_request.node.spot_instance_id
}

output "public_ip" {
  value = aws_spot_instance_request.node.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_spot_instance_request.node.public_ip}"
}

output "grafana_url" {
  value = "http://${aws_spot_instance_request.node.public_ip}:3000"
}

output "estimated_hourly_cost" {
  value = "~$${var.spot_max_price}/hr (spot) = ~$${var.spot_max_price * 24}/day"
}
