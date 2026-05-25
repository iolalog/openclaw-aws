# ── EC2 instance role ─────────────────────────────────────────────────────────
# Replaces the Lightsail IAM user + SSM hybrid activation.
# EC2 instance profile provides auto-rotating credentials via IMDS — no keys on disk.

locals {
  peer_account_id = var.peer_aws_account_id != "" ? var.peer_aws_account_id : data.aws_caller_identity.current.account_id
}

resource "aws_iam_role" "openclaw" {
  name = "openclaw-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.openclaw.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Scoped inline policy — expand deliberately as skills are added
resource "aws_iam_role_policy" "openclaw_cost_explorer" {
  name = "openclaw-cost-explorer"
  role = aws_iam_role.openclaw.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ce:Get*", "ce:Describe*", "ce:List*"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "openclaw_ssm_parameters" {
  name = "openclaw-ssm-parameters"
  role = aws_iam_role.openclaw.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/openclaw/*"
    }]
  })
}

# Peer monitoring — only created when var.peer_instance_id is set.
# See docs/peer-monitoring.md for the full setup pattern.
resource "aws_iam_role_policy" "openclaw_ssm_send_command" {
  count = var.peer_instance_id != "" ? 1 : 0
  name  = "openclaw-ssm-send-command"
  role  = aws_iam_role.openclaw.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${local.peer_account_id}:instance/${var.peer_instance_id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation"]
        Resource = "arn:aws:ssm:${var.aws_region}:${local.peer_account_id}:*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "openclaw" {
  name = "openclaw-instance-profile"
  role = aws_iam_role.openclaw.name
}

# ── DLM role for automated AMI snapshots ──────────────────────────────────────

resource "aws_iam_role" "dlm" {
  name = "openclaw-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm_full" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRoleForAMIManagement"
}
