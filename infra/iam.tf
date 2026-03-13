# ── EC2 instance role ─────────────────────────────────────────────────────────
# Replaces the Lightsail IAM user + SSM hybrid activation.
# EC2 instance profile provides auto-rotating credentials via IMDS — no keys on disk.

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
      Resource = "arn:aws:ssm:eu-north-1::parameter/openclaw/*"
    }]
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
