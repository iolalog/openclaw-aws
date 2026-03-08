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
    ssm_activation_id     = aws_ssm_activation.openclaw.id
    ssm_activation_code   = aws_ssm_activation.openclaw.activation_code
    region                = var.aws_region
    openrouter_api_key    = var.openrouter_api_key
    slack_bot_token       = var.slack_bot_token
    slack_app_token       = var.slack_app_token
    github_memory_repo    = var.github_memory_repo
    aws_access_key_id     = aws_iam_access_key.openclaw.id
    aws_secret_access_key = aws_iam_access_key.openclaw.secret
  }
}

resource "aws_lightsail_instance" "openclaw" {
  name              = "openclaw"
  availability_zone = "${var.aws_region}a"
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = "micro_3_0"
  user_data         = templatefile("${path.module}/scripts/bootstrap.sh.tpl", local.bootstrap_vars)

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "aws_lightsail_instance_public_ports" "openclaw" {
  instance_name = aws_lightsail_instance.openclaw.name

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }
  # Port 22 intentionally absent
}

resource "aws_lightsail_static_ip" "openclaw" {
  name = "openclaw-ip"
}

resource "aws_lightsail_static_ip_attachment" "openclaw" {
  static_ip_name = aws_lightsail_static_ip.openclaw.name
  instance_name  = aws_lightsail_instance.openclaw.name
}
