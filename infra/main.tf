terraform {
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

locals {
  bootstrap_vars = {
    region             = var.aws_region
    openrouter_api_key = var.openrouter_api_key
    slack_bot_token    = var.slack_bot_token
    slack_app_token    = var.slack_app_token
    github_memory_repo = var.github_memory_repo
    gemini_api_key     = var.gemini_api_key
    github_infra_repo  = var.github_infra_repo
  }
}

# ── Networking (minimal public VPC) ───────────────────────────────────────────

resource "aws_vpc" "openclaw" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = { Name = "openclaw" }
}

resource "aws_subnet" "openclaw" {
  vpc_id                  = aws_vpc.openclaw.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = { Name = "openclaw-public" }
}

resource "aws_internet_gateway" "openclaw" {
  vpc_id = aws_vpc.openclaw.id

  tags = { Name = "openclaw-igw" }
}

resource "aws_route_table" "openclaw" {
  vpc_id = aws_vpc.openclaw.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.openclaw.id
  }

  tags = { Name = "openclaw-rt" }
}

resource "aws_route_table_association" "openclaw" {
  subnet_id      = aws_subnet.openclaw.id
  route_table_id = aws_route_table.openclaw.id
}

# ── Security group: no inbound, all outbound ──────────────────────────────────
# All connections are outbound (SSM, Slack Socket Mode, OpenRouter, GitHub)
# Port 22 intentionally absent — access via SSM Session Manager only

resource "aws_security_group" "openclaw" {
  name        = "openclaw-sg"
  description = "OpenClaw: no inbound, all outbound"
  vpc_id      = aws_vpc.openclaw.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "openclaw-sg" }
}

# ── AMI: latest Ubuntu 24.04 LTS arm64 (for t4g) ─────────────────────────────

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── EC2 instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "openclaw" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t4g.small"
  subnet_id              = aws_subnet.openclaw.id
  vpc_security_group_ids = [aws_security_group.openclaw.id]
  iam_instance_profile   = aws_iam_instance_profile.openclaw.name
  user_data              = templatefile("${path.module}/scripts/bootstrap.sh.tpl", local.bootstrap_vars)

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = { Name = "openclaw" }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────

resource "aws_eip" "openclaw" {
  domain = "vpc"

  tags = { Name = "openclaw-eip" }
}

resource "aws_eip_association" "openclaw" {
  instance_id   = aws_instance.openclaw.id
  allocation_id = aws_eip.openclaw.id
}

# ── DLM: daily AMI snapshot, retain 7 days ───────────────────────────────────

resource "aws_dlm_lifecycle_policy" "openclaw" {
  description        = "Daily AMI snapshot for openclaw - retain 7"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    policy_type    = "IMAGE_MANAGEMENT"
    resource_types = ["INSTANCE"]

    schedule {
      name = "Daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["02:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }

    target_tags = { Name = "openclaw" }
  }
}
